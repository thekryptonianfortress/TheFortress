const jwt = require('jsonwebtoken');
const db = require('./db');

// Map: userId -> socketId
const onlineUsers = new Map();
// Map: virtualId -> socketId  (for direct routing in group call P2P)
const virtualIdToSocket = new Map();
// Map: groupId -> [{userId, virtualId, username}]
const groupCallRooms = new Map();
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
  io.use(async (socket, next) => {
    const token = socket.handshake.auth?.token;
    if (!token) return next(new Error('Unauthorized'));
    try {
      const payload = jwt.verify(token, process.env.JWT_SECRET);
      socket.userId = payload.sub;
      const res = await db.query('SELECT virtual_id FROM users WHERE id = $1', [payload.sub]);
      socket.virtualId = res.rows[0]?.virtual_id || null;
      next();
    } catch (err) {
      next(new Error('Invalid token'));
    }
  });

  io.on('connection', async (socket) => {
    const userId = socket.userId;
    onlineUsers.set(userId, socket.id);
    if (socket.virtualId) virtualIdToSocket.set(socket.virtualId, socket.id);
    console.log(`[socket] connected userId=${userId} online=${onlineUsers.size}`);

    await db.query('UPDATE users SET last_seen = NOW() WHERE id = $1', [userId]);
    broadcastPresence(io, userId, true);

    // Send this user the current online status of all their contacts
    try {
      const contactsRes = await db.query(
        'SELECT contact_id FROM contacts WHERE user_id = $1',
        [userId]
      );
      const presence = contactsRes.rows.map(r => ({
        user_id: r.contact_id,
        is_online: onlineUsers.has(r.contact_id),
      }));
      socket.emit('contacts-presence', presence);
    } catch (e) {
      console.error('[socket] contacts-presence error:', e.message);
    }

    // Deliver any messages that arrived while this user was offline
    const pendingRes = await db.query(
      `SELECT m.id, m.sender_id, m.encrypted_content, m.nonce, m.reply_to_id, m.created_at,
              m.attachment_url, m.attachment_type, m.attachment_name, m.attachment_size,
              u.virtual_id AS sender_virtual_id, u.username AS sender_username, u.public_key AS sender_public_key
       FROM messages m
       JOIN users u ON u.id = m.sender_id
       WHERE m.recipient_id = $1 AND m.status = 'sent'
       ORDER BY m.created_at ASC`,
      [userId]
    );
    const autoAddedSenders = new Set();
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
        attachment_url: msg.attachment_url || null,
        attachment_type: msg.attachment_type || null,
        attachment_name: msg.attachment_name || null,
        attachment_size: msg.attachment_size || null,
        created_at: msg.created_at.toISOString(),
      });
      await db.query("UPDATE messages SET status = 'delivered' WHERE id = $1", [msg.id]);

      // Auto-add sender to contacts if not already there (once per sender per session)
      if (!autoAddedSenders.has(msg.sender_id)) {
        autoAddedSenders.add(msg.sender_id);
        try {
          const ec = await db.query(
            'SELECT 1 FROM contacts WHERE user_id = $1 AND contact_id = $2',
            [userId, msg.sender_id]
          );
          if (ec.rows.length === 0) {
            const { v4: uuidv4 } = require('uuid');
            const cId = uuidv4();
            await db.query(
              'INSERT INTO contacts (id, user_id, contact_id) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING',
              [cId, userId, msg.sender_id]
            );
            const sRes = await db.query(
              'SELECT virtual_id, username, public_key, avatar_url FROM users WHERE id = $1',
              [msg.sender_id]
            );
            if (sRes.rows.length > 0) {
              const s = sRes.rows[0];
              socket.emit('contact-auto-added', {
                id: cId,
                user_id: userId,
                contact_id: msg.sender_id,
                virtual_id: s.virtual_id,
                username: s.username,
                public_key: s.public_key,
                avatar_url: s.avatar_url || null,
              });
            }
          }
        } catch (e) {
          console.error('[auto-add contact pending]', e.message);
        }
      }
    }

    // ── Call Signaling ─────────────────────────────────────────

    socket.on('call-offer', async (data) => {
      const { target_virtual_id, sdp, caller_username, caller_virtual_id, is_video } = data;
      const target = await getUserByVirtualId(target_virtual_id);
      if (!target) return;

      const callId = makeCallId(userId, target.id);
      const targetSocketId = onlineUsers.get(target.id);

      socket.emit('call-offer-ack', { call_id: callId, target_virtual_id, target_online: !!targetSocketId });

      if (targetSocketId) {
        io.to(targetSocketId).emit('incoming-call', {
          call_id: callId,
          caller_id: userId,
          caller_virtual_id,
          caller_username,
          sdp,
          is_video: !!is_video,
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
      const { recipient_virtual_id, message_id, encrypted_content, nonce, reply_to_id,
              attachment_url, attachment_type, attachment_name, attachment_size, created_at } = data;
      const recipient = await getUserByVirtualId(recipient_virtual_id);
      if (!recipient) return;

      console.log(`[send-message] from=${userId} to=${recipient.id} msgId=${message_id}`);

      // Use client-provided created_at when present (preserves original LAN-period send time).
      await db.query(
        `INSERT INTO messages (id, sender_id, recipient_id, encrypted_content, nonce, status, reply_to_id,
                               attachment_url, attachment_type, attachment_name, attachment_size, created_at)
         VALUES ($1, $2, $3, $4, $5, 'sent', $6, $7, $8, $9, $10, COALESCE($11::timestamptz, NOW()))
         ON CONFLICT DO NOTHING`,
        [message_id, userId, recipient.id, encrypted_content, nonce, reply_to_id || null,
         attachment_url || null, attachment_type || null, attachment_name || null, attachment_size || null,
         created_at || null]
      );

      const sender = await db.query(
        'SELECT virtual_id, username, public_key, avatar_url FROM users WHERE id = $1',
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
          attachment_url: attachment_url || null,
          attachment_type: attachment_type || null,
          attachment_name: attachment_name || null,
          attachment_size: attachment_size || null,
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

      // Auto-add sender to recipient's contacts if not already there
      try {
        const ec = await db.query(
          'SELECT 1 FROM contacts WHERE user_id = $1 AND contact_id = $2',
          [recipient.id, userId]
        );
        if (ec.rows.length === 0) {
          const { v4: uuidv4 } = require('uuid');
          const contactRowId = uuidv4();
          await db.query(
            'INSERT INTO contacts (id, user_id, contact_id) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING',
            [contactRowId, recipient.id, userId]
          );
          if (recipientSocket) {
            io.to(recipientSocket).emit('contact-auto-added', {
              id: contactRowId,
              user_id: recipient.id,
              contact_id: userId,
              virtual_id: senderInfo.virtual_id,
              username: senderInfo.username,
              public_key: senderInfo.public_key,
              avatar_url: senderInfo.avatar_url || null,
            });
          }
        }
      } catch (e) {
        console.error('[auto-add contact]', e.message);
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

    // ── Group Messaging ────────────────────────────────────────

    socket.on('group-send-message', async (data) => {
      const { group_id, message_id, content, reply_to_id,
              attachment_url, attachment_type, attachment_name, attachment_size } = data;
      if (!group_id || !message_id) return;

      // Verify active membership
      const memberCheck = await db.query(
        `SELECT 1 FROM group_members WHERE group_id = $1 AND user_id = $2 AND status = 'active'`,
        [group_id, userId]
      );
      if (memberCheck.rows.length === 0) return;

      const senderRes = await db.query(
        'SELECT username, virtual_id, avatar_url FROM users WHERE id = $1', [userId]
      );
      const sender = senderRes.rows[0];

      await db.query(
        `INSERT INTO group_messages (id, group_id, sender_id, content, reply_to_id,
           attachment_url, attachment_type, attachment_name, attachment_size)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) ON CONFLICT DO NOTHING`,
        [message_id, group_id, userId, content || '', reply_to_id || null,
         attachment_url || null, attachment_type || null, attachment_name || null, attachment_size || null]
      );

      const msgRow = await db.query('SELECT created_at FROM group_messages WHERE id = $1', [message_id]);
      const createdAt = msgRow.rows[0]?.created_at?.toISOString() || new Date().toISOString();

      const payload = {
        message_id, group_id,
        sender_id: userId,
        sender_username: sender.username,
        sender_virtual_id: sender.virtual_id,
        sender_avatar_url: sender.avatar_url || null,
        content: content || '',
        reply_to_id: reply_to_id || null,
        attachment_url: attachment_url || null,
        attachment_type: attachment_type || null,
        attachment_name: attachment_name || null,
        attachment_size: attachment_size || null,
        created_at: createdAt,
      };

      // Deliver to all active members (except sender — ack separately)
      const membersRes = await db.query(
        `SELECT gm.user_id, u.fcm_token FROM group_members gm
         JOIN users u ON u.id = gm.user_id
         WHERE gm.group_id = $1 AND gm.status = 'active' AND gm.user_id != $2`,
        [group_id, userId]
      );
      const groupRes = await db.query('SELECT name FROM groups WHERE id = $1', [group_id]);
      const groupName = groupRes.rows[0]?.name || 'Group';

      for (const m of membersRes.rows) {
        const s = onlineUsers.get(m.user_id);
        if (s) {
          io.to(s).emit('group-message', payload);
        } else {
          const preview = (content || '').length > 60
            ? (content || '').substring(0, 60) + '…'
            : (content || attachment_type || 'Attachment');
          sendPushNotification(m.fcm_token, {
            type: 'group_message',
            group_id,
            group_name: groupName,
            sender_username: sender.username,
            preview,
          });
        }
      }

      // Ack to sender
      socket.emit('group-message-ack', { message_id, group_id, created_at: createdAt });
    });

    socket.on('group-typing', async (data) => {
      const { group_id } = data;
      if (!group_id) return;
      const memberCheck = await db.query(
        `SELECT 1 FROM group_members WHERE group_id = $1 AND user_id = $2 AND status = 'active'`,
        [group_id, userId]
      );
      if (memberCheck.rows.length === 0) return;
      const membersRes = await db.query(
        `SELECT user_id FROM group_members WHERE group_id = $1 AND status = 'active' AND user_id != $2`,
        [group_id, userId]
      );
      for (const m of membersRes.rows) {
        const s = onlineUsers.get(m.user_id);
        if (s) io.to(s).emit('group-user-typing', { group_id, user_id: userId });
      }
    });

    socket.on('group-edit-message', async (data) => {
      const { message_id, new_content, group_id } = data;
      const result = await db.query(
        `UPDATE group_messages SET content = $1, edited_at = NOW()
         WHERE id = $2 AND sender_id = $3 RETURNING edited_at, group_id`,
        [new_content, message_id, userId]
      );
      if (result.rowCount === 0) return;
      const gid = group_id || result.rows[0].group_id;
      const editedAt = result.rows[0].edited_at.toISOString();
      const membersRes = await db.query(
        `SELECT user_id FROM group_members WHERE group_id = $1 AND status = 'active'`,
        [gid]
      );
      for (const m of membersRes.rows) {
        const s = onlineUsers.get(m.user_id);
        if (s) io.to(s).emit('group-message-edited', { message_id, group_id: gid, new_content, edited_at: editedAt });
      }
    });

    socket.on('group-delete-message', async (data) => {
      const { message_id, group_id } = data;
      const result = await db.query(
        `UPDATE group_messages SET is_deleted = true WHERE id = $1 AND sender_id = $2 RETURNING group_id`,
        [message_id, userId]
      );
      if (result.rowCount === 0) return;
      const gid = group_id || result.rows[0].group_id;
      const membersRes = await db.query(
        `SELECT user_id FROM group_members WHERE group_id = $1 AND status = 'active'`,
        [gid]
      );
      for (const m of membersRes.rows) {
        const s = onlineUsers.get(m.user_id);
        if (s) io.to(s).emit('group-message-deleted', { message_id, group_id: gid });
      }
    });

    socket.on('group-add-reaction', async (data) => {
      const { message_id, emoji, group_id } = data;
      if (!message_id || !emoji) return;

      const msgRes = await db.query(
        'SELECT reactions, group_id FROM group_messages WHERE id = $1', [message_id]
      );
      if (msgRes.rows.length === 0) return;

      let reactions = msgRes.rows[0].reactions || {};
      const gid = group_id || msgRes.rows[0].group_id;

      const users = reactions[emoji] || [];
      const idx = users.indexOf(userId);
      if (idx === -1) {
        reactions[emoji] = [...users, userId];
      } else {
        reactions[emoji] = users.filter(u => u !== userId);
        if (reactions[emoji].length === 0) delete reactions[emoji];
      }

      await db.query('UPDATE group_messages SET reactions = $1 WHERE id = $2', [reactions, message_id]);

      const membersRes = await db.query(
        `SELECT user_id FROM group_members WHERE group_id = $1 AND status = 'active'`,
        [gid]
      );
      const payload = { message_id, group_id: gid, reactions, reactor_id: userId };
      for (const m of membersRes.rows) {
        const s = onlineUsers.get(m.user_id);
        if (s) io.to(s).emit('group-reaction-added', payload);
      }
    });

    // ── Group Call Room Management ──────────────────────────────

    socket.on('group-call-start', async (data) => {
      const { group_id, is_video, virtual_id, username } = data;
      try {
        const mc = await db.query(
          `SELECT 1 FROM group_members WHERE group_id = $1 AND user_id = $2 AND status = 'active'`,
          [group_id, userId]
        );
        if (mc.rows.length === 0) return;

        if (!groupCallRooms.has(group_id)) groupCallRooms.set(group_id, []);
        const room = groupCallRooms.get(group_id);
        const ei = room.findIndex(p => p.userId === userId);
        if (ei !== -1) room.splice(ei, 1);
        room.push({ userId, virtualId: virtual_id, username });

        const groupRes = await db.query('SELECT name FROM groups WHERE id = $1', [group_id]);
        const groupName = groupRes.rows[0]?.name || 'Group';

        const membersRes = await db.query(
          `SELECT u.id FROM group_members gm JOIN users u ON u.id = gm.user_id
           WHERE gm.group_id = $1 AND gm.status = 'active' AND gm.user_id != $2`,
          [group_id, userId]
        );
        for (const m of membersRes.rows) {
          const s = onlineUsers.get(m.id);
          if (s) {
            io.to(s).emit('group-call-incoming', {
              group_id, group_name: groupName, is_video: !!is_video,
              caller_virtual_id: virtual_id, caller_username: username,
            });
          }
        }
      } catch (e) { console.error('[group-call-start]', e.message); }
    });

    socket.on('group-call-join', async (data) => {
      const { group_id, virtual_id, username } = data;
      try {
        const mc = await db.query(
          `SELECT 1 FROM group_members WHERE group_id = $1 AND user_id = $2 AND status = 'active'`,
          [group_id, userId]
        );
        if (mc.rows.length === 0) return;

        const room = groupCallRooms.get(group_id) || [];
        const existingParticipants = room.map(p => ({ virtual_id: p.virtualId, username: p.username }));
        const ei = room.findIndex(p => p.userId === userId);
        if (ei !== -1) room.splice(ei, 1);
        room.push({ userId, virtualId: virtual_id, username });
        groupCallRooms.set(group_id, room);

        socket.emit('group-call-joined', { group_id, participants: existingParticipants });

        for (const p of room) {
          if (p.userId === userId) continue;
          const ps = onlineUsers.get(p.userId);
          if (ps) io.to(ps).emit('group-call-member-joined', { group_id, virtual_id, username });
        }
      } catch (e) { console.error('[group-call-join]', e.message); }
    });

    socket.on('group-call-leave', (data) => {
      const { group_id } = data;
      const room = groupCallRooms.get(group_id);
      if (!room) return;
      const leaver = room.find(p => p.userId === userId);
      const idx = room.findIndex(p => p.userId === userId);
      if (idx !== -1) room.splice(idx, 1);
      if (room.length === 0) groupCallRooms.delete(group_id);
      if (leaver) {
        for (const p of room) {
          const ps = onlineUsers.get(p.userId);
          if (ps) io.to(ps).emit('group-call-member-left', { group_id, virtual_id: leaver.virtualId });
        }
      }
    });

    // ── Group Call P2P Signaling (gc-*) ─────────────────────────

    socket.on('gc-offer', (data) => {
      const { target_virtual_id, sdp, from_virtual_id, from_username, group_id, conn_id, is_video } = data;
      const ts = virtualIdToSocket.get(target_virtual_id);
      if (ts) io.to(ts).emit('gc-incoming-offer', { from_virtual_id, from_username, sdp, group_id, conn_id, is_video: !!is_video });
    });

    socket.on('gc-answer', (data) => {
      const { target_virtual_id, sdp, conn_id } = data;
      const ts = virtualIdToSocket.get(target_virtual_id);
      if (ts) io.to(ts).emit('gc-call-answered', { from_virtual_id: socket.virtualId, sdp, conn_id });
    });

    socket.on('gc-ice', (data) => {
      const { target_virtual_id, candidate, conn_id } = data;
      const ts = virtualIdToSocket.get(target_virtual_id);
      if (ts) io.to(ts).emit('gc-ice-candidate', { from_virtual_id: socket.virtualId, candidate, conn_id });
    });

    socket.on('gc-peer-end', (data) => {
      const { target_virtual_id } = data;
      const ts = virtualIdToSocket.get(target_virtual_id);
      if (ts) io.to(ts).emit('gc-peer-ended', { from_virtual_id: socket.virtualId });
    });

    // ── Disconnect ─────────────────────────────────────────────

    socket.on('disconnect', async () => {
      onlineUsers.delete(userId);
      if (socket.virtualId) virtualIdToSocket.delete(socket.virtualId);
      // Clean up group call rooms on disconnect
      for (const [gid, room] of groupCallRooms.entries()) {
        const idx = room.findIndex(p => p.userId === userId);
        if (idx !== -1) {
          const leaver = room[idx];
          room.splice(idx, 1);
          if (room.length === 0) { groupCallRooms.delete(gid); }
          else {
            for (const p of room) {
              const ps = onlineUsers.get(p.userId);
              if (ps) io.to(ps).emit('gc-peer-ended', { from_virtual_id: leaver.virtualId });
            }
          }
        }
      }
      console.log(`[socket] disconnected userId=${userId} online=${onlineUsers.size}`);
      const now = new Date().toISOString();
      await db.query('UPDATE users SET last_seen = NOW() WHERE id = $1', [userId]);
      broadcastPresence(io, userId, false, now);
    });
  });
}

function broadcastPresence(io, userId, isOnline, lastSeen = null) {
  io.emit('presence-update', { user_id: userId, is_online: isOnline, last_seen: lastSeen });
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
