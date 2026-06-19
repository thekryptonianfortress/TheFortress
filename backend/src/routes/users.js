const express = require('express');
const db = require('../db');
const { authenticate } = require('../middleware');

const router = express.Router();

// PUT /users/public-key  — update public key (e.g. after device reinstall)
router.put('/public-key', authenticate, async (req, res) => {
  try {
    const { public_key } = req.body;
    if (!public_key) return res.status(400).json({ error: 'Missing public_key' });
    await db.query('UPDATE users SET public_key = $1 WHERE id = $2', [public_key, req.userId]);
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ error: 'Failed to update public key' });
  }
});

// GET /users/:virtualId  — lookup a user by Pager ID
router.get('/:virtualId', authenticate, async (req, res) => {
  try {
    const result = await db.query(
      'SELECT id, virtual_id, username, public_key, last_seen FROM users WHERE virtual_id = $1',
      [req.params.virtualId.toUpperCase()]
    );
    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'User not found' });
    }
    res.json(result.rows[0]);
  } catch (err) {
    res.status(500).json({ error: 'Lookup failed' });
  }
});

module.exports = router;
