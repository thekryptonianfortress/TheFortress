const jwt = require('jsonwebtoken');
const db = require('./db');

// Map: userId -> socketId
const onlineUsers = new Map();
let _io = null;

function getIo() { return _io; }
function getOnlineUsers() { return onlineUsers; }

function makeCallId(callerId, calleeId) {
  return `${callerId}::${calleeId}::${Date.now()}`;
}
function parseCallId(callId) {
  const parts = callId.split('::');
  return { callerId: parts[0], calleeId: parts[1] };
}

function setupSignaling(io) {
  _io = io;
  io.use((socket, next) => {
    const token = socket.handshake.auth?.token;
    if (!token) return next(new Error('Unauthorized'));
    try {
      const payload = jwt.verify(token, process.env.JWT_SECRET);
      socket.userId = payload.sub;
      next();
    } catch (err) {
      next(new Error('Invalid token'));
    }
  });

  io.on('connection', async (socket) => {
    const userId = socket.userId;
    onlineUsers.set(userId, socket.id);
    console.log(`[socket] connected userId=${userId} online=${onlineUsers.size}`);

    await db.query('UPDATE users SET last_seen = NOW() WHERE id = $1', [userId]);
    broadcastPresence(io, userId, true);

    // Deliver any messages that arrived while this user was offline
    const pendingRes = await db.query(
      `SELECT m.id, m.sender_id, m.encrypted_content, m.nonce, m.reply_to_id, m.created_at,
              u.virtual_id AS sender_virtual_id, u.username AS sender_username, u.public_key AS sender_public_key
       FROM messages m
       JOIN users u ON u.id = m.sender_id
       WHERE m.recipient_id = $1 AND m.status = 'sent'
       ORDER BY m.created_at ASC`,
      [userId]
    );
    for (const msg of pendingRes.rows) {
      socket.emit('new-message', {
        message_id: msg.id,
        sender_id: msg.sender_id,
        sender_virtual_id: msg.sender_virtual_id,
        sender_username: msg.sender_username,
        sender_public_key: msg.sender_public_key,
        encrypted_content: msg.encrypted_content,
        nonce: msg.nonce || '',
        reply_to_id: msg.reply_to_id || null,
        created_at: msg.created_at.toISOString(),
      });
      await db.query("UPDATE messages SET status = 'delivered' WHERE id = $1", [msg.id]);
    }

    // ── Call Signaling ─────────────────────────────────────────

    socket.on('call-offer', async (data) => {
      const { target_virtual_id, sdp, caller_username, caller_virtual_id } = data;
      const target = await getUserByVirtualId(target_virtual_id);
      if (!target) return;

      const callId = makeCallId(userId, target.id);
      const targetSocketId = onlineUsers.get(target.id);

      socket.emit('call-offer-ack', { call_id: callId, target_online: !!targetSocketId });

      if (targetSocketId) {
        io.to(targetSocketId).emit('incoming-call', {
          call_id: callId,
          caller_id: userId,
          caller_virtual_id,
          caller_username,
          sdp,
        });
        sendPushNotification(target.fcm_token, {
          type: 'incoming_call',
          call_id: callId,
          caller_username,
          caller_virtual_id,
        });
      } else {
        sendPushNotification(target.fcm_token, {
          type: 'missed_call',
          caller_username,
          caller_virtual_id,
        });
      }
    });

    socket.on('call-answer', (data) => {
      const { call_id, sdp } = data;
      const { callerId } = parseCallId(call_id);
      const callerSocket = onlineUsers.get(callerId);
      if (callerSocket) io.to(callerSocket).emit('call-answered', { call_id, sdp });
    });

    socket.on('call-reject', (data) => {
      const { call_id } = data;
      const { callerId } = parseCallId(call_id);
      const callerSocket = onlineUsers.get(callerId);
      if (callerSocket) io.to(callerSocket).emit('call-rejected', { call_id });
    });

    socket.on('call-end', (data) => {
      const { call_id } = data;
      const { callerId, calleeId } = parseCallId(call_id);
      [callerId, calleeId].forEach((uid) => {
        const s = onlineUsers.get(uid);
        if (s && s !== socket.id) io.to(s).emit('call-ended', { call_id });
      });
    });

    socket.on('ice-candidate', (data) => {
      const { call_id, candidate } = data;
      const { callerId, calleeId } = parseCallId(call_id);
      const peerId = callerId === userId ? calleeId : callerId;
      const peerSocket = onlineUsers.get(peerId);
      if (peerSocket) io.to(peerSocket).emit('ice-candidate', { call_id, candidate });
    });

    // ── Messaging ──────────────────────────────────────────────

    socket.on('send-message', async (data) => {
      const { recipient_virtual_id, message_id, encrypted_content, nonce, reply_to_id } = data;
      const recipient = await getUserByVirtualId(recipient_virtual_id);
      if (!recipient) return;

      console.log(`[send-message] from=${userId} to=${recipient.id} msgId=${message_id}`);

      await db.query(
        `INSERT INTO messages (id, sender_id, recipient_id, encrypted_content, nonce, status, reply_to_id)
         VALUES ($1, $2, $3, $4, $5, 'sent', $6)
         ON CONFLICT DO NOTHING`,
        [message_id, userId, recipient.id, encrypted_content, nonce, reply_to_id || null]
      );

      const sender = await db.query(
        'SELECT virtual_id, username, public_key FROM users WHERE id = $1',
        [userId]
      );
      const senderInfo = sender.rows[0];

      const recipientSocket = onlineUsers.get(recipient.id);
      const status = recipientSocket ? 'delivered' : 'sent';

      if (recipientSocket) {
        // Fetch created_at from DB to send accurate timestamp
        const msgRow = await db.query('SELECT created_at FROM messages WHERE id = $1', [message_id]);
        const createdAt = msgRow.rows[0]?.created_at?.toISOString() || new Date().toISOString();

        io.to(recipientSocket).emit('new-message', {
          message_id,
          sender_id: userId,
          sender_virtual_id: senderInfo.virtual_id,
          sender_username: senderInfo.username,
          sender_public_key: senderInfo.public_key,
          encrypted_content,
          nonce,
          reply_to_id: reply_to_id || null,
          created_at: createdAt,
        });
        await db.query("UPDATE messages SET status = 'delivered' WHERE id = $1", [message_id]);
      } else {
        const preview = encrypted_content.length > 60
          ? encrypted_content.substring(0, 60) + '…'
          : encrypted_content;
        sendPushNotification(recipient.fcm_token, {
          type: 'new_message',
          sender_username: senderInfo.username,
          sender_virtual_id: senderInfo.virtual_id,
          preview,
        });
      }

      // Ack back to sender with final status
      socket.emit('message-ack', {
        message_id,
        recipient_id: recipient.id,
        status,
      });
    });

    socket.on('typing', async (data) => {
      const { recipient_virtual_id } = data;
      const recipient = await getUserByVirtualId(recipient_virtual_id);
      if (!recipient) return;
      const recipientSocket = onlineUsers.get(recipient.id);
      if (recipientSocket) {
        io.to(recipientSocket).emit('user-typing', { sender_id: userId });
      }
    });

    socket.on('read-receipt', async (data) => {
      const { message_ids, sender_id } = data;
      if (!Array.isArray(message_ids) || message_ids.length === 0) return;
      await db.query(
        `UPDATE messages SET status = 'read' WHERE id = ANY($1) AND recipient_id = $2`,
        [message_ids, userId]
      );
      const senderSocket = onlineUsers.get(sender_id);
      if (senderSocket) {
        io.to(senderSocket).emit('messages-read', {
          message_ids,
          reader_id: userId,
        });
      }
    });

    socket.on('edit-message', async (data) => {
      const { message_id, new_content, recipient_virtual_id } = data;
      const result = await db.query(
        `UPDATE messages SET encrypted_content = $1, edited_at = NOW()
         WHERE id = $2 AND sender_id = $3
         RETURNING edited_at`,
        [new_content, message_id, userId]
      );
      if (result.rowCount === 0) return;

      const editedAt = result.rows[0].edited_at.toISOString();
      const recipient = await getUserByVirtualId(recipient_virtual_id);
      if (!recipient) return;
      const recipientSocket = onlineUsers.get(recipient.id);
      if (recipientSocket) {
        io.to(recipientSocket).emit('message-edited', {
          message_id,
          new_content,
          edited_at: editedAt,
        });
      }
    });

    socket.on('delete-message', async (data) => {
      const { message_id, recipient_virtual_id } = data;
      const result = await db.query(
        `UPDATE messages SET is_deleted = true WHERE id = $1 AND sender_id = $2`,
        [message_id, userId]
      );
      if (result.rowCount === 0) return;

      const recipient = await getUserByVirtualId(recipient_virtual_id);
      if (!recipient) return;
      const recipientSocket = onlineUsers.get(recipient.id);
      if (recipientSocket) {
        io.to(recipientSocket).emit('message-deleted', { message_id });
      }
    });

    socket.on('add-reaction', async (data) => {
      const { message_id, emoji, recipient_virtual_id } = data;
      if (!message_id || !emoji) return;

      // Load current reactions, toggle this user's reaction
      const msgRes = await db.query('SELECT reactions, sender_id FROM messages WHERE id = $1', [message_id]);
      if (msgRes.rows.length === 0) return;

      let reactions = msgRes.rows[0].reactions || {};
      if (typeof reactions === 'string') reactions = JSON.parse(reactions);

      const users = reactions[emoji] || [];
      const idx = users.indexOf(userId);
      if (idx === -1) {
        reactions[emoji] = [...users, userId];
      } else {
        // toggle off
        reactions[emoji] = users.filter(u => u !== userId);
        if (reactions[emoji].length === 0) delete reactions[emoji];
      }

      await db.query('UPDATE messages SET reactions = $1 WHERE id = $2', [JSON.stringify(reactions), message_id]);

      const recipient = await getUserByVirtualId(recipient_virtual_id);
      const payload = { message_id, reactions, reactor_id: userId };
      // Notify recipient
      if (recipient) {
        const recipientSocket = onlineUsers.get(recipient.id);
        if (recipientSocket) io.to(recipientSocket).emit('reaction-added', payload);
      }
      // Echo back to sender too
      socket.emit('reaction-added', payload);
    });

    // ── Disconnect ─────────────────────────────────────────────

    socket.on('disconnect', async () => {
      onlineUsers.delete(userId);
      console.log(`[socket] disconnected userId=${userId} online=${onlineUsers.size}`);
      await db.query('UPDATE users SET last_seen = NOW() WHERE id = $1', [userId]);
      broadcastPresence(io, userId, false);
    });
  });
}

function broadcastPresence(io, userId, isOnline) {
  io.emit('presence-update', { user_id: userId, is_online: isOnline });
}

async function getUserByVirtualId(virtualId) {
  const result = await db.query(
    'SELECT id, virtual_id, username, public_key, fcm_token FROM users WHERE virtual_id = $1',
    [virtualId.toUpperCase()]
  );
  return result.rows[0] || null;
}

async function sendPushNotification(fcmToken, data) {
  if (!fcmToken) return;
  try {
    const admin = require('firebase-admin');
    await admin.messaging().send({
      token: fcmToken,
      data: Object.fromEntries(Object.entries(data).map(([k, v]) => [k, String(v)])),
      android: { priority: 'high' },
    });
  } catch (err) {
    console.error('FCM error:', err.message);
  }
}

module.exports = { setupSignaling, getIo, getOnlineUsers };
