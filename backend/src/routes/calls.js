const express = require('express');
const router = express.Router();
const { requireAuth } = require('../middleware');
const { getIo, getOnlineUsers } = require('../signaling');

// POST /calls/reject
// Called by the Flutter background isolate when the user taps "Reject" on the
// notification while the app is backgrounded/killed (no socket available).
// Looks up the caller via the call_id format "callerId::calleeId::timestamp"
// and emits call-rejected to their socket.
router.post('/reject', requireAuth, (req, res) => {
  const { call_id } = req.body;
  if (!call_id) return res.status(400).json({ error: 'call_id required' });

  const parts = call_id.split('::');
  if (parts.length < 2) return res.status(400).json({ error: 'invalid call_id' });

  const callerId = parts[0];
  const io = getIo();
  const onlineUsers = getOnlineUsers();

  const callerSocketId = onlineUsers.get(callerId);
  if (callerSocketId && io) {
    io.to(callerSocketId).emit('call-rejected', { call_id });
  }

  res.json({ ok: true });
});

module.exports = router;
