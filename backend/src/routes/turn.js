const express = require('express');
const crypto = require('crypto');
const { authenticate } = require('../middleware');

const router = express.Router();

// GET /turn-credentials  — generate short-lived TURN credentials
// Uses TURN REST API spec (coturn compatible)
router.get('/', authenticate, async (req, res) => {
  try {
    const secret = process.env.TURN_SECRET || 'pager_turn_secret';
    const turnHost = process.env.TURN_HOST || 'your-server-ip';
    const turnPort = process.env.TURN_PORT || '3478';

    const ttl = 12 * 3600; // 12 hours
    const timestamp = Math.floor(Date.now() / 1000) + ttl;
    const username = `${timestamp}:pager`;
    const credential = crypto
      .createHmac('sha1', secret)
      .update(username)
      .digest('base64');

    const iceServers = [
      { urls: 'stun:stun.l.google.com:19302' },
      { urls: 'stun:stun1.l.google.com:19302' },
      {
        urls: `turn:${turnHost}:${turnPort}`,
        username,
        credential,
      },
      {
        urls: `turns:${turnHost}:${parseInt(turnPort) + 1}`,
        username,
        credential,
      },
    ];

    res.json({ ice_servers: iceServers, expires_in: ttl });
  } catch (err) {
    res.status(500).json({ error: 'Failed to generate TURN credentials' });
  }
});

module.exports = router;
