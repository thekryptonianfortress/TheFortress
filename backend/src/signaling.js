const jwt = require('jsonwebtoken');
const db = require('./db');

// Map: userId -> socketId
const onlineUsers = new Map();

// Call ID uses '::' as separator so UUID hyphens don't break parsing
function makeCallId(callerId, calleeId) {
  return `${callerId}::${calleeId}::${Date.now()}`;
}
function parseCallId(callId) {
  const parts = callId.split('::');
  return { callerId: parts[0], calleeId: parts[1] };
}

function setupSignaling(io) {
  // Authenticate WebSocket connections via JWT
  io.use((socket, next) => {
    const token = socket.handshake.auth?.token;
    console.log(`[socket] auth attempt from ${socket.handshake.address} token=${token ? 'present' : 'missing'}`);
    if (!token) {
      console.log('[socket] rejected: no token');
      return next(new Error('Unauthorized'));
    }
    try {
      const payload = jwt.verify(token, process.env.JWT_SECRET);
      socket.userId = payload.sub;
      next();
    } catch (err) {
      console.log(`[socket] rejected: ${err.message}`);
      next(new Error('Invalid token'));
    }
  });

  io.on('connection', async (socket) => {
    const userId = socket.userId;
    onlineUsers.set(userId, socket.id);
    console.log(`[socket] connected userId=${userId} online=${onlineUsers.size}`);

    // Update last_seen and broadcast presence
    await db.query('UPDATE users SET last_seen = NOW() WHERE id = $1', [userId]);
    broadcastPresence(io, userId, true);

    // ── Call Signaling ─────────────────────────────────────────

    socket.on('call-offer', async (data) => {
      const { target_virtual_id, sdp, caller_username, caller_virtual_id } = data;
      const target = await getUserByVirtualId(target_virtual_id);
      if (!target) {
        console.log(`[call-offer] target not found: ${target_virtual_id}`);
        return;
      }

      const callId = makeCallId(userId, target.id);
      const targetSocketId = onlineUsers.get(target.id);
      console.log(`[call-offer] from=${userId} to=${target.id} online=${!!targetSocketId} callId=${callId}`);

      // Always echo call_id back to caller so they can end/track the call
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
      console.log(`[call-answer] callId=${call_id} callerId=${callerId} found=${!!callerSocket}`);
      if (callerSocket) {
        io.to(callerSocket).emit('call-answered', { call_id, sdp });
      }
    });

    socket.on('call-reject', (data) => {
      const { call_id } = data;
      const { callerId } = parseCallId(call_id);
      const callerSocket = onlineUsers.get(callerId);
      console.log(`[call-reject] callerId=${callerId} found=${!!callerSocket}`);
      if (callerSocket) {
        io.to(callerSocket).emit('call-rejected', { call_id });
      }
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
      if (peerSocket) {
        io.to(peerSocket).emit('ice-candidate', { call_id, candidate });
      }
    });

    // ── Messaging ──────────────────────────────────────────────

    socket.on('send-message', async (data) => {
      const { recipient_virtual_id, message_id, encrypted_content, nonce } = data;
      const recipient = await getUserByVirtualId(recipient_virtual_id);
      if (!recipient) {
        console.log(`[send-message] recipient not found: ${recipient_virtual_id}`);
        return;
      }

      console.log(`[send-message] from=${userId} to=${recipient.id} msgId=${message_id}`);

      // Persist message
      await db.query(
        `INSERT INTO messages (id, sender_id, recipient_id, encrypted_content, nonce, status)
         VALUES ($1, $2, $3, $4, $5, 'sent')
         ON CONFLICT DO NOTHING`,
        [message_id, userId, recipient.id, encrypted_content, nonce]
      );

      // Get sender info for recipient
      const sender = await db.query(
        'SELECT virtual_id, username, public_key FROM users WHERE id = $1',
        [userId]
      );
      const senderInfo = sender.rows[0];

      const recipientSocket = onlineUsers.get(recipient.id);
      console.log(`[send-message] recipient online=${!!recipientSocket}`);
      if (recipientSocket) {
        io.to(recipientSocket).emit('new-message', {
          message_id,
          sender_id: userId,
          sender_virtual_id: senderInfo.virtual_id,
          sender_username: senderInfo.username,
          sender_public_key: senderInfo.public_key,
          encrypted_content,
          nonce,
        });
        await db.query("UPDATE messages SET status = 'delivered' WHERE id = $1", [message_id]);
        socket.emit('message-delivered', { message_id, recipient_id: recipient.id });
      } else {
        sendPushNotification(recipient.fcm_token, {
          type: 'new_message',
          sender_username: senderInfo.username,
          preview: 'New encrypted message',
        });
      }
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

module.exports = { setupSignaling };
