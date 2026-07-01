const express = require('express');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const db = require('./db');

const router = express.Router();

function signToken(userId) {
  return jwt.sign({ sub: userId }, process.env.JWT_SECRET, { expiresIn: '30d' });
}

// POST /auth/register
router.post('/register', async (req, res) => {
  try {
    const { username, password, public_key, phone_number } = req.body;
    if (!username || !password || !public_key || !phone_number) {
      return res.status(400).json({ error: 'Missing required fields' });
    }
    if (password.length < 8) {
      return res.status(400).json({ error: 'Password must be at least 8 characters' });
    }
    // Normalize E.164: strip leading zero from subscriber number (e.g. +25407... → +2547...)
    phone_number = phone_number.replace(/^(\+\d{1,4})0+(\d)/, '$1$2');
    if (!/^\+\d{7,15}$/.test(phone_number)) {
      return res.status(400).json({ error: 'Invalid phone number format' });
    }

    // Check phone uniqueness
    const phoneCheck = await db.query(
      'SELECT id FROM users WHERE phone_number = $1 OR virtual_id = $1',
      [phone_number]
    );
    if (phoneCheck.rows.length > 0) {
      return res.status(409).json({ error: 'Phone number already registered' });
    }

    const passwordHash = await bcrypt.hash(password, 12);
    // Phone number is the virtual_id for new accounts
    const virtualId = phone_number;

    const result = await db.query(
      `INSERT INTO users (virtual_id, phone_number, username, password_hash, public_key)
       VALUES ($1, $2, $3, $4, $5) RETURNING id, virtual_id, phone_number, username, public_key`,
      [virtualId, phone_number, username.trim(), passwordHash, public_key]
    );
    const user = result.rows[0];
    const token = signToken(user.id);

    res.status(201).json({ token, user });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Registration failed' });
  }
});

// POST /auth/login
router.post('/login', async (req, res) => {
  try {
    const { virtual_id, password } = req.body;
    if (!virtual_id || !password) {
      return res.status(400).json({ error: 'Missing credentials' });
    }

    const isPhone = virtual_id.startsWith('+');
    let result;
    if (isPhone) {
      // Phone number login — search phone_number column first, then virtual_id
      result = await db.query(
        `SELECT id, virtual_id, phone_number, username, public_key, avatar_url, password_hash
         FROM users WHERE phone_number = $1 OR virtual_id = $1`,
        [virtual_id]
      );
    } else {
      // Legacy Pager ID login
      result = await db.query(
        `SELECT id, virtual_id, phone_number, username, public_key, avatar_url, password_hash
         FROM users WHERE virtual_id = $1`,
        [virtual_id.toUpperCase()]
      );
    }

    if (result.rows.length === 0) {
      return res.status(401).json({ error: 'Invalid credentials' });
    }

    const user = result.rows[0];
    const valid = await bcrypt.compare(password, user.password_hash);
    if (!valid) {
      return res.status(401).json({ error: 'Invalid credentials' });
    }

    await db.query('UPDATE users SET last_seen = NOW() WHERE id = $1', [user.id]);
    const token = signToken(user.id);
    const { password_hash, ...safeUser } = user;

    res.json({ token, user: safeUser });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Login failed' });
  }
});

// PUT /auth/fcm-token
router.put('/fcm-token', require('./middleware').authenticate, async (req, res) => {
  try {
    const { fcm_token } = req.body;
    await db.query('UPDATE users SET fcm_token = $1 WHERE id = $2', [fcm_token, req.userId]);
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ error: 'Failed to update FCM token' });
  }
});

// POST /auth/update-profile — update username and/or avatar_url
router.post('/update-profile', require('./middleware').authenticate, async (req, res) => {
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
    console.error('[auth/update-profile]', err.message);
    res.status(500).json({ error: 'Failed to update profile' });
  }
});

// POST /auth/change-password — change password
router.post('/change-password', require('./middleware').authenticate, async (req, res) => {
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
    console.error('[auth/change-password]', err.message);
    res.status(500).json({ error: 'Failed to change password' });
  }
});

module.exports = router;
