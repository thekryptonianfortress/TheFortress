const express = require('express');
const { v4: uuidv4 } = require('uuid');
const db = require('../db');
const { authenticate } = require('../middleware');
const { getIo, getOnlineUsers } = require('../signaling');

const router = express.Router();

// Ensure server-side chat clear tracking table exists
db.query(`
  CREATE TABLE IF NOT EXISTS chat_clears (
    user_id UUID NOT NULL,
    peer_id UUID NOT NULL,
    cleared_before TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, peer_id)
  )
`).catch(err => console.error('[chat_clears] init error:', err.message));

// GET /messages/:peerId  — fetch conversation history (newest first)
// ?since=ISO_TIMESTAMP  — only fetch messages after this time (for polling)
// ?limit=N              — max messages (default 100, max 200)
router.get('/:peerId', authenticate, async (req, res) => {
  try {
    const { peerId } = req.params;
    const limit = Math.min(parseInt(req.query.limit) || 100, 200);
    const since = req.query.since;

    // Filter messages before the user's last clear (server-side, survives reinstalls)
    let query = `
      SELECT id, sender_id, recipient_id, encrypted_content, nonce, status,
             created_at, edited_at, is_deleted, reply_to_id, reactions
      FROM messages
      WHERE ((sender_id = $1 AND recipient_id = $2)
          OR (sender_id = $2 AND recipient_id = $1))
        AND created_at > COALESCE(
          (SELECT cleared_before FROM chat_clears WHERE user_id = $1 AND peer_id = $2),
          '-infinity'::timestamptz
        )
    `;
    const params = [req.userId, peerId];

    if (since) {
      params.push(since);
      query += ` AND created_at > $${params.length}`;
    }

    // DESC so the newest 100 are always returned (client re-sorts for display)
    params.push(limit);
    query += ` ORDER BY created_at DESC LIMIT $${params.length}`;

    const result = await db.query(query, params);
    res.json(result.rows);
  } catch (err) {
    console.error('[messages GET]', err.message);
    res.status(500).json({ error: 'Failed to fetch messages' });
  }
});

// DELETE /messages/:peerId — server-side chat clear (per-user, non-destructive)
router.delete('/:peerId', authenticate, async (req, res) => {
  try {
    const { peerId } = req.params;
    await db.query(
      `INSERT INTO chat_clears (user_id, peer_id, cleared_before)
       VALUES ($1, $2, NOW())
       ON CONFLICT (user_id, peer_id) DO UPDATE SET cleared_before = NOW()`,
      [req.userId, peerId]
    );
    res.json({ ok: true });
  } catch (err) {
    console.error('[messages DELETE]', err.message);
    res.status(500).json({ error: 'Failed to clear chat' });
  }
});

// POST /messages/quick-reply — send a message from notification inline reply (no WebSocket needed)
router.post('/quick-reply', authenticate, async (req, res) => {
  try {
    const { recipient_virtual_id, content } = req.body;
    if (!recipient_virtual_id || !content?.trim()) {
      return res.status(400).json({ error: 'Missing fields' });
    }

    const recipientRes = await db.query(
      'SELECT id, virtual_id, username FROM users WHERE virtual_id = $1',
      [recipient_virtual_id.toUpperCase()]
    );
    const recipient = recipientRes.rows[0];
    if (!recipient) return res.status(404).json({ error: 'Recipient not found' });

    const senderRes = await db.query(
      'SELECT virtual_id, username FROM users WHERE id = $1',
      [req.userId]
    );
    const sender = senderRes.rows[0];

    const msgId = uuidv4();
    await db.query(
      `INSERT INTO messages (id, sender_id, recipient_id, encrypted_content, nonce, status)
       VALUES ($1, $2, $3, $4, '', 'sent') ON CONFLICT DO NOTHING`,
      [msgId, req.userId, recipient.id, content.trim()]
    );

    // Deliver via WebSocket if recipient is currently online, otherwise FCM push
    const io = getIo();
    const onlineUsers = getOnlineUsers();
    const recipientSocketId = onlineUsers.get(recipient.id);
    if (io && recipientSocketId) {
      const msgRow = await db.query('SELECT created_at FROM messages WHERE id = $1', [msgId]);
      const createdAt = msgRow.rows[0]?.created_at?.toISOString() || new Date().toISOString();
      io.to(recipientSocketId).emit('new-message', {
        message_id: msgId,
        sender_id: req.userId,
        sender_virtual_id: sender.virtual_id,
        sender_username: sender.username,
        sender_public_key: null,
        encrypted_content: content.trim(),
        nonce: '',
        reply_to_id: null,
        created_at: createdAt,
      });
      await db.query("UPDATE messages SET status = 'delivered' WHERE id = $1", [msgId]);
    } else {
      // Recipient has killed the app — wake them via FCM
      const fcmRes = await db.query('SELECT fcm_token FROM users WHERE id = $1', [recipient.id]);
      const fcmToken = fcmRes.rows[0]?.fcm_token;
      if (fcmToken) {
        const preview = content.trim().length > 60
          ? content.trim().substring(0, 60) + '…'
          : content.trim();
        const admin = require('firebase-admin');
        try {
          await admin.messaging().send({
            token: fcmToken,
            data: {
              type: 'new_message',
              sender_username: sender.username,
              sender_virtual_id: sender.virtual_id,
              preview,
            },
            android: { priority: 'high' },
          });
        } catch (e) {
          console.error('[quick-reply] FCM error:', e.message);
        }
      }
    }

    res.json({ ok: true, message_id: msgId });
  } catch (err) {
    console.error('[quick-reply]', err.message);
    res.status(500).json({ error: 'Failed to send reply' });
  }
});

module.exports = router;
