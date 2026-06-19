const express = require('express');
const db = require('../db');
const { authenticate } = require('../middleware');

const router = express.Router();

// GET /messages/:peerId  — fetch conversation history
router.get('/:peerId', authenticate, async (req, res) => {
  try {
    const { peerId } = req.params;
    const limit = Math.min(parseInt(req.query.limit) || 50, 200);

    const result = await db.query(
      `SELECT id, sender_id, recipient_id, encrypted_content, nonce, status, created_at
       FROM messages
       WHERE (sender_id = $1 AND recipient_id = $2)
          OR (sender_id = $2 AND recipient_id = $1)
       ORDER BY created_at ASC
       LIMIT $3`,
      [req.userId, peerId, limit]
    );
    res.json(result.rows);
  } catch (err) {
    res.status(500).json({ error: 'Failed to fetch messages' });
  }
});

module.exports = router;
