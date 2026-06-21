const express = require('express');
const db = require('../db');
const { authenticate } = require('../middleware');

const router = express.Router();

// GET /messages/:peerId  — fetch conversation history
// ?since=ISO_TIMESTAMP  — only fetch messages after this time (for polling)
// ?limit=N              — max messages (default 100, max 200)
router.get('/:peerId', authenticate, async (req, res) => {
  try {
    const { peerId } = req.params;
    const limit = Math.min(parseInt(req.query.limit) || 100, 200);
    const since = req.query.since;

    let query = `
      SELECT id, sender_id, recipient_id, encrypted_content, nonce, status,
             created_at, edited_at, is_deleted, reply_to_id
      FROM messages
      WHERE (sender_id = $1 AND recipient_id = $2)
         OR (sender_id = $2 AND recipient_id = $1)
    `;
    const params = [req.userId, peerId];

    if (since) {
      params.push(since);
      query += ` AND created_at > $${params.length}`;
    }

    params.push(limit);
    query += ` ORDER BY created_at ASC LIMIT $${params.length}`;

    const result = await db.query(query, params);
    res.json(result.rows);
  } catch (err) {
    console.error('[messages GET]', err.message);
    res.status(500).json({ error: 'Failed to fetch messages' });
  }
});

module.exports = router;
