const express = require('express');
const { v4: uuidv4 } = require('uuid');
const db = require('../db');
const { authenticate } = require('../middleware');

const router = express.Router();

// GET /contacts
router.get('/', authenticate, async (req, res) => {
  try {
    const result = await db.query(
      `SELECT c.id, c.user_id, c.contact_id,
              u.virtual_id, u.username, u.public_key, u.last_seen, u.avatar_url
       FROM contacts c
       JOIN users u ON u.id = c.contact_id
       WHERE c.user_id = $1
       ORDER BY u.username`,
      [req.userId]
    );
    res.json(result.rows);
  } catch (err) {
    res.status(500).json({ error: 'Failed to fetch contacts' });
  }
});

// POST /contacts  — add by virtual_id
router.post('/', authenticate, async (req, res) => {
  try {
    const { virtual_id } = req.body;
    if (!virtual_id) return res.status(400).json({ error: 'virtual_id required' });

    const userResult = await db.query(
      'SELECT id, virtual_id, username, public_key, last_seen FROM users WHERE virtual_id = $1',
      [virtual_id.toUpperCase()]
    );
    if (userResult.rows.length === 0) {
      return res.status(404).json({ error: 'User not found' });
    }
    const contact = userResult.rows[0];

    if (contact.id === req.userId) {
      return res.status(400).json({ error: 'Cannot add yourself' });
    }

    const id = uuidv4();
    await db.query(
      'INSERT INTO contacts (id, user_id, contact_id) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING',
      [id, req.userId, contact.id]
    );

    // Return full contact info
    const row = await db.query(
      `SELECT c.id, c.user_id, c.contact_id,
              u.virtual_id, u.username, u.public_key, u.last_seen, u.avatar_url
       FROM contacts c JOIN users u ON u.id = c.contact_id
       WHERE c.user_id = $1 AND c.contact_id = $2`,
      [req.userId, contact.id]
    );

    res.status(201).json(row.rows[0]);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Failed to add contact' });
  }
});

// DELETE /contacts/:id
router.delete('/:id', authenticate, async (req, res) => {
  try {
    await db.query('DELETE FROM contacts WHERE id = $1 AND user_id = $2', [req.params.id, req.userId]);
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ error: 'Failed to remove contact' });
  }
});

module.exports = router;
