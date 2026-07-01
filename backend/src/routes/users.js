const express = require('express');
const bcrypt = require('bcryptjs');
const db = require('../db');
const { authenticate } = require('../middleware');

const router = express.Router();

// One-time migrations
db.query('ALTER TABLE users ADD COLUMN IF NOT EXISTS avatar_url TEXT')
  .catch(err => console.error('[users] migration error:', err.message));
db.query('ALTER TABLE users ADD COLUMN IF NOT EXISTS phone_number VARCHAR(20) UNIQUE')
  .catch(err => console.error('[users] phone migration error:', err.message));
// Widen virtual_id to hold phone numbers (was VARCHAR(13), phone numbers up to +15 digits = 16 chars)
db.query('ALTER TABLE users ALTER COLUMN virtual_id TYPE VARCHAR(20)')
  .catch(err => console.error('[users] virtual_id widen error:', err.message));

// GET /users/me — own profile
router.get('/me', authenticate, async (req, res) => {
  try {
    const result = await db.query(
      'SELECT id, virtual_id, phone_number, username, avatar_url, last_seen FROM users WHERE id = $1',
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
       RETURNING id, virtual_id, phone_number, username, avatar_url`,
      values
    );
    res.json(result.rows[0]);
  } catch (err) {
    console.error('[users/profile]', err.message);
    res.status(500).json({ error: 'Failed to update profile' });
  }
});

// POST /users/phone — link or update phone number for existing accounts
// Updates both phone_number and virtual_id so the phone becomes the primary identifier
router.post('/phone', authenticate, async (req, res) => {
  try {
    let { phone_number } = req.body;
    if (!phone_number) {
      return res.status(400).json({ error: 'Invalid phone number format' });
    }
    // Normalize E.164: strip leading zero from subscriber number
    // e.g. +25407... → +2547...
    phone_number = phone_number.replace(/^(\+\d{1,4})0+(\d)/, '$1$2');
    if (!/^\+\d{7,15}$/.test(phone_number)) {
      return res.status(400).json({ error: 'Invalid phone number format' });
    }

    // Check uniqueness (excluding self)
    const existing = await db.query(
      'SELECT id FROM users WHERE (phone_number = $1 OR virtual_id = $1) AND id != $2',
      [phone_number, req.userId]
    );
    if (existing.rows.length > 0) {
      return res.status(409).json({ error: 'Phone number already in use' });
    }

    const result = await db.query(
      `UPDATE users SET phone_number = $1, virtual_id = $1
       WHERE id = $2
       RETURNING id, virtual_id, phone_number, username, avatar_url`,
      [phone_number, req.userId]
    );
    res.json(result.rows[0]);
  } catch (err) {
    console.error('[users/phone]', err.message);
    res.status(500).json({ error: 'Failed to update phone number' });
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

// GET /users/:virtualId  — lookup a user by phone number or Pager ID
router.get('/:virtualId', authenticate, async (req, res) => {
  try {
    const identifier = req.params.virtualId;
    const result = await db.query(
      `SELECT id, virtual_id, phone_number, username, public_key, avatar_url, last_seen
       FROM users WHERE virtual_id = $1 OR phone_number = $2`,
      [identifier.toUpperCase(), identifier]
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
