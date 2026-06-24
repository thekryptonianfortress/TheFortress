const express = require('express');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const { v4: uuidv4 } = require('uuid');
const db = require('./db');

const router = express.Router();

function generateVirtualId() {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  let part = (n) => Array.from({ length: n }, () => chars[Math.floor(Math.random() * chars.length)]).join('');
  return `PGR-${part(4)}-${part(4)}`;
}

function signToken(userId) {
  return jwt.sign({ sub: userId }, process.env.JWT_SECRET, { expiresIn: '30d' });
}

// POST /auth/register
router.post('/register', async (req, res) => {
  try {
    const { username, password, public_key } = req.body;
    if (!username || !password || !public_key) {
      return res.status(400).json({ error: 'Missing required fields' });
    }
    if (password.length < 8) {
      return res.status(400).json({ error: 'Password must be at least 8 characters' });
    }

    const passwordHash = await bcrypt.hash(password, 12);
    let virtualId;
    let attempts = 0;
    // Ensure uniqueness
    while (attempts < 10) {
      virtualId = generateVirtualId();
      const existing = await db.query('SELECT id FROM users WHERE virtual_id = $1', [virtualId]);
      if (existing.rows.length === 0) break;
      attempts++;
    }

    const result = await db.query(
      `INSERT INTO users (virtual_id, username, password_hash, public_key)
       VALUES ($1, $2, $3, $4) RETURNING id, virtual_id, username, public_key`,
      [virtualId, username.trim(), passwordHash, public_key]
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

    const result = await db.query(
      'SELECT id, virtual_id, username, public_key, avatar_url, password_hash FROM users WHERE virtual_id = $1',
      [virtual_id.toUpperCase()]
    );
    if (result.rows.length === 0) {
      return res.status(401).json({ error: 'Invalid Pager ID or password' });
    }

    const user = result.rows[0];
    const valid = await bcrypt.compare(password, user.password_hash);
    if (!valid) {
      return res.status(401).json({ error: 'Invalid Pager ID or password' });
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
       RETURNING id, virtual_id, username, avatar_url`,
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
