const express = require('express');
const bcrypt = require('bcryptjs');
const db = require('../db');
const { authenticate } = require('../middleware');

const router = express.Router();

// One-time migration: add avatar_url column
db.query('ALTER TABLE users ADD COLUMN IF NOT EXISTS avatar_url TEXT')
  .catch(err => console.error('[users] migration error:', err.message));

// GET /users/me — own profile (used on app start to refresh avatar/username)
router.get('/me', authenticate, async (req, res) => {
  try {
    const result = await db.query(
      'SELECT id, virtual_id, username, avatar_url, last_seen FROM users WHERE id = $1',
      [req.userId]
    );
    if (result.rows.length === 0) return res.status(404).json({ error: 'User not found' });
    res.json(result.rows[0]);
  } catch (err) {
    console.error('[users/me]', err.message);
    res.status(500).json({ error: 'Failed to fetch profile' });
  }
});

// POST /users/profile — update username and/or avatar_url
router.post('/profile', authenticate, async (req, res) => {
  try {
    const { username, avatar_url } = req.body;
    if (!username && avatar_url === undefined) {
      return res.status(400).json({ error: 'Nothing to update' });
    }

    if (username) {
      const trimmed = username.trim();
      if (trimmed.length < 2 || trimmed.length > 32) {
        return res.status(400).json({ error: 'Username must be 2–32 characters' });
      }
      // Check uniqueness (allow keeping same username)
      const existing = await db.query(
        'SELECT id FROM users WHERE username = $1 AND id != $2',
        [trimmed, req.userId]
      );
      if (existing.rows.length > 0) {
        return res.status(409).json({ error: 'Username already taken' });
      }
    }

    const fields = [];
    const values = [];
    if (username) { fields.push(`username = $${fields.length + 1}`); values.push(username.trim()); }
    if (avatar_url !== undefined) { fields.push(`avatar_url = $${fields.length + 1}`); values.push(avatar_url); }
    values.push(req.userId);

    const result = await db.query(
      `UPDATE users SET ${fields.join(', ')} WHERE id = $${values.length}
       RETURNING id, virtual_id, username, avatar_url`,
      values
    );
    res.json(result.rows[0]);
  } catch (err) {
    console.error('[users/profile]', err.message);
    res.status(500).json({ error: 'Failed to update profile' });
  }
});

// POST /users/change-password — change password
router.post('/change-password', authenticate, async (req, res) => {
  try {
    const { current_password, new_password } = req.body;
    if (!current_password || !new_password) {
      return res.status(400).json({ error: 'Missing fields' });
    }
    if (new_password.length < 8) {
      return res.status(400).json({ error: 'New password must be at least 8 characters' });
    }

    const result = await db.query(
      'SELECT password_hash FROM users WHERE id = $1',
      [req.userId]
    );
    if (result.rows.length === 0) return res.status(404).json({ error: 'User not found' });

    const valid = await bcrypt.compare(current_password, result.rows[0].password_hash);
    if (!valid) return res.status(401).json({ error: 'Current password is incorrect' });

    const newHash = await bcrypt.hash(new_password, 12);
    await db.query('UPDATE users SET password_hash = $1 WHERE id = $2', [newHash, req.userId]);
    res.json({ ok: true });
  } catch (err) {
    console.error('[users/password]', err.message);
    res.status(500).json({ error: 'Failed to change password' });
  }
});

// POST /users/public-key  — update public key (e.g. after device reinstall)
router.post('/public-key', authenticate, async (req, res) => {
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
      'SELECT id, virtual_id, username, public_key, avatar_url, last_seen FROM users WHERE virtual_id = $1',
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
