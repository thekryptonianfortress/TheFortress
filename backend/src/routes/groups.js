const express = require('express');
const { v4: uuidv4 } = require('uuid');
const db = require('../db');
const { authenticate } = require('../middleware');
const { getIo, getOnlineUsers } = require('../signaling');

const router = express.Router();

// ── Table init ─────────────────────────────────────────────

(async () => {
  try {
    await db.query(`
      CREATE TABLE IF NOT EXISTS groups (
        id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        name TEXT NOT NULL,
        description TEXT,
        avatar_url TEXT,
        theme_id TEXT DEFAULT 'midnight',
        join_code CHAR(8) UNIQUE NOT NULL,
        created_by UUID REFERENCES users(id),
        created_at TIMESTAMPTZ DEFAULT NOW()
      )
    `);
    await db.query(`ALTER TABLE groups ADD COLUMN IF NOT EXISTS theme_id TEXT DEFAULT 'midnight'`);
    await db.query(`
      CREATE TABLE IF NOT EXISTS group_members (
        id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        group_id UUID REFERENCES groups(id) ON DELETE CASCADE,
        user_id UUID REFERENCES users(id) ON DELETE CASCADE,
        role TEXT NOT NULL DEFAULT 'member',
        status TEXT NOT NULL DEFAULT 'pending',
        joined_at TIMESTAMPTZ DEFAULT NOW(),
        UNIQUE(group_id, user_id)
      )
    `);
    await db.query(`
      CREATE TABLE IF NOT EXISTS group_messages (
        id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        group_id UUID REFERENCES groups(id) ON DELETE CASCADE,
        sender_id UUID REFERENCES users(id),
        content TEXT NOT NULL DEFAULT '',
        attachment_url TEXT,
        attachment_type TEXT,
        attachment_name TEXT,
        attachment_size INTEGER,
        reply_to_id UUID REFERENCES group_messages(id),
        reactions JSONB NOT NULL DEFAULT '{}',
        is_deleted BOOLEAN NOT NULL DEFAULT FALSE,
        edited_at TIMESTAMPTZ,
        created_at TIMESTAMPTZ DEFAULT NOW()
      )
    `);
    console.log('[groups] tables ready');
  } catch (err) {
    console.error('[groups] table init error:', err.message);
  }
})();

// ── Helpers ────────────────────────────────────────────────

function generateJoinCode() {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  let code = '';
  for (let i = 0; i < 8; i++) {
    code += chars[Math.floor(Math.random() * chars.length)];
  }
  return code;
}

async function notifyMembers(groupId, event, payload, excludeUserId = null) {
  const io = getIo();
  const onlineUsers = getOnlineUsers();
  if (!io) return;
  const res = await db.query(
    `SELECT user_id FROM group_members WHERE group_id = $1 AND status = 'active'`,
    [groupId]
  );
  for (const m of res.rows) {
    if (m.user_id === excludeUserId) continue;
    const s = onlineUsers.get(m.user_id);
    if (s) io.to(s).emit(event, payload);
  }
}

async function isAdmin(groupId, userId) {
  const res = await db.query(
    `SELECT 1 FROM group_members WHERE group_id = $1 AND user_id = $2 AND role = 'admin' AND status = 'active'`,
    [groupId, userId]
  );
  return res.rows.length > 0;
}

async function isMember(groupId, userId) {
  const res = await db.query(
    `SELECT status FROM group_members WHERE group_id = $1 AND user_id = $2`,
    [groupId, userId]
  );
  return res.rows.length > 0 && res.rows[0].status === 'active';
}

// ── Routes ─────────────────────────────────────────────────

// POST /groups — create group
router.post('/', authenticate, async (req, res) => {
  try {
    const { name, description, avatar_url, theme_id } = req.body;
    if (!name?.trim()) return res.status(400).json({ error: 'Group name required' });

    let joinCode;
    for (let i = 0; i < 10; i++) {
      const candidate = generateJoinCode();
      const exists = await db.query('SELECT 1 FROM groups WHERE join_code = $1', [candidate]);
      if (exists.rows.length === 0) { joinCode = candidate; break; }
    }
    if (!joinCode) return res.status(500).json({ error: 'Failed to generate join code' });

    const result = await db.query(
      `INSERT INTO groups (id, name, description, avatar_url, theme_id, join_code, created_by)
       VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING *`,
      [uuidv4(), name.trim(), description?.trim() || null, avatar_url || null, theme_id || 'midnight', joinCode, req.userId]
    );
    const group = result.rows[0];

    await db.query(
      `INSERT INTO group_members (id, group_id, user_id, role, status)
       VALUES ($1, $2, $3, 'admin', 'active')`,
      [uuidv4(), group.id, req.userId]
    );

    res.json({ ...group, my_role: 'admin', member_count: 1 });
  } catch (err) {
    console.error('[groups POST]', err.message);
    res.status(500).json({ error: 'Failed to create group' });
  }
});

// GET /groups — list my active groups
router.get('/', authenticate, async (req, res) => {
  try {
    const result = await db.query(
      `SELECT g.*, gm.role AS my_role,
              (SELECT COUNT(*) FROM group_members WHERE group_id = g.id AND status = 'active') AS member_count,
              (SELECT COUNT(*) FROM group_members WHERE group_id = g.id AND status = 'pending') AS pending_count,
              (SELECT content FROM group_messages WHERE group_id = g.id AND is_deleted = false ORDER BY created_at DESC LIMIT 1) AS last_message,
              (SELECT created_at FROM group_messages WHERE group_id = g.id ORDER BY created_at DESC LIMIT 1) AS last_message_at
       FROM groups g
       JOIN group_members gm ON gm.group_id = g.id
       WHERE gm.user_id = $1 AND gm.status = 'active'
       ORDER BY last_message_at DESC NULLS LAST, g.created_at DESC`,
      [req.userId]
    );
    res.json(result.rows);
  } catch (err) {
    console.error('[groups GET /]', err.message);
    res.status(500).json({ error: 'Failed to fetch groups' });
  }
});

// GET /groups/:id — group info + members
router.get('/:id', authenticate, async (req, res) => {
  try {
    const { id } = req.params;

    const memberCheck = await db.query(
      'SELECT role, status FROM group_members WHERE group_id = $1 AND user_id = $2',
      [id, req.userId]
    );
    if (memberCheck.rows.length === 0 || memberCheck.rows[0].status === 'banned') {
      return res.status(403).json({ error: 'Not a member' });
    }

    const groupRes = await db.query('SELECT * FROM groups WHERE id = $1', [id]);
    if (groupRes.rows.length === 0) return res.status(404).json({ error: 'Group not found' });

    const membersRes = await db.query(
      `SELECT gm.id, gm.group_id, gm.user_id, gm.role, gm.status, gm.joined_at,
              u.username, u.virtual_id, u.avatar_url
       FROM group_members gm
       JOIN users u ON u.id = gm.user_id
       WHERE gm.group_id = $1
       ORDER BY gm.role DESC, gm.joined_at ASC`,
      [id]
    );

    res.json({
      ...groupRes.rows[0],
      my_role: memberCheck.rows[0].role,
      my_status: memberCheck.rows[0].status,
      members: membersRes.rows,
    });
  } catch (err) {
    console.error('[groups GET /:id]', err.message);
    res.status(500).json({ error: 'Failed to fetch group' });
  }
});

// POST /groups/join — request to join via code
router.post('/join', authenticate, async (req, res) => {
  try {
    const { join_code } = req.body;
    if (!join_code) return res.status(400).json({ error: 'Join code required' });

    const groupRes = await db.query(
      'SELECT * FROM groups WHERE join_code = $1',
      [join_code.toUpperCase().trim()]
    );
    if (groupRes.rows.length === 0) return res.status(404).json({ error: 'Invalid join code' });
    const group = groupRes.rows[0];

    const existing = await db.query(
      'SELECT status FROM group_members WHERE group_id = $1 AND user_id = $2',
      [group.id, req.userId]
    );
    if (existing.rows.length > 0) {
      const st = existing.rows[0].status;
      if (st === 'active') return res.status(409).json({ error: 'Already a member' });
      if (st === 'pending') return res.status(409).json({ error: 'Join request already pending' });
      if (st === 'banned') return res.status(403).json({ error: 'You have been banned from this group' });
    }

    const userRes = await db.query(
      'SELECT username, virtual_id, avatar_url FROM users WHERE id = $1',
      [req.userId]
    );
    const user = userRes.rows[0];

    await db.query(
      `INSERT INTO group_members (id, group_id, user_id, role, status)
       VALUES ($1, $2, $3, 'member', 'pending')`,
      [uuidv4(), group.id, req.userId]
    );

    // Notify admins
    const io = getIo();
    const onlineUsers = getOnlineUsers();
    if (io) {
      const adminsRes = await db.query(
        `SELECT user_id FROM group_members WHERE group_id = $1 AND role = 'admin' AND status = 'active'`,
        [group.id]
      );
      for (const admin of adminsRes.rows) {
        const s = onlineUsers.get(admin.user_id);
        if (s) io.to(s).emit('group-join-request', {
          group_id: group.id,
          group_name: group.name,
          user_id: req.userId,
          username: user.username,
          virtual_id: user.virtual_id,
          avatar_url: user.avatar_url || null,
        });
      }
    }

    res.json({ ok: true, group_id: group.id, group_name: group.name, status: 'pending' });
  } catch (err) {
    console.error('[groups POST /join]', err.message);
    res.status(500).json({ error: 'Failed to join group' });
  }
});

// PUT /groups/:id/members/:userId/approve
router.put('/:id/members/:userId/approve', authenticate, async (req, res) => {
  try {
    const { id, userId } = req.params;
    if (!await isAdmin(id, req.userId)) return res.status(403).json({ error: 'Not an admin' });

    const result = await db.query(
      `UPDATE group_members SET status = 'active', joined_at = NOW()
       WHERE group_id = $1 AND user_id = $2 AND status = 'pending'
       RETURNING *`,
      [id, userId]
    );
    if (result.rowCount === 0) return res.status(404).json({ error: 'Pending request not found' });

    const groupRes = await db.query('SELECT name FROM groups WHERE id = $1', [id]);
    const userRes = await db.query('SELECT username, virtual_id, avatar_url FROM users WHERE id = $1', [userId]);
    const user = userRes.rows[0];

    const io = getIo();
    const onlineUsers = getOnlineUsers();
    if (io) {
      // Notify approved user
      const s = onlineUsers.get(userId);
      if (s) io.to(s).emit('group-member-approved', { group_id: id, group_name: groupRes.rows[0].name });
      // Notify existing members
      await notifyMembers(id, 'group-member-joined', {
        group_id: id,
        user_id: userId,
        username: user.username,
        virtual_id: user.virtual_id,
        avatar_url: user.avatar_url || null,
      }, userId);
    }

    res.json({ ok: true });
  } catch (err) {
    console.error('[groups approve]', err.message);
    res.status(500).json({ error: 'Failed to approve member' });
  }
});

// PUT /groups/:id/members/:userId/reject
router.put('/:id/members/:userId/reject', authenticate, async (req, res) => {
  try {
    const { id, userId } = req.params;
    if (!await isAdmin(id, req.userId)) return res.status(403).json({ error: 'Not an admin' });

    await db.query(
      `DELETE FROM group_members WHERE group_id = $1 AND user_id = $2 AND status = 'pending'`,
      [id, userId]
    );

    const io = getIo();
    const onlineUsers = getOnlineUsers();
    if (io) {
      const s = onlineUsers.get(userId);
      if (s) io.to(s).emit('group-member-rejected', { group_id: id });
    }

    res.json({ ok: true });
  } catch (err) {
    console.error('[groups reject]', err.message);
    res.status(500).json({ error: 'Failed to reject member' });
  }
});

// DELETE /groups/:id/members/:userId — kick or leave
router.delete('/:id/members/:userId', authenticate, async (req, res) => {
  try {
    const { id, userId } = req.params;
    const isSelf = userId === req.userId;

    if (!isSelf) {
      if (!await isAdmin(id, req.userId)) return res.status(403).json({ error: 'Not an admin' });
      const targetRes = await db.query(
        `SELECT role FROM group_members WHERE group_id = $1 AND user_id = $2`,
        [id, userId]
      );
      if (targetRes.rows[0]?.role === 'admin') return res.status(403).json({ error: 'Cannot kick an admin' });
    }

    await db.query(
      `DELETE FROM group_members WHERE group_id = $1 AND user_id = $2`,
      [id, userId]
    );

    // Notify all members + removed user
    const io = getIo();
    const onlineUsers = getOnlineUsers();
    if (io) {
      const payload = { group_id: id, user_id: userId };
      await notifyMembers(id, 'group-member-left', payload);
      const s = onlineUsers.get(userId);
      if (s) io.to(s).emit('group-member-left', payload);
    }

    res.json({ ok: true });
  } catch (err) {
    console.error('[groups DELETE member]', err.message);
    res.status(500).json({ error: 'Failed to remove member' });
  }
});

// PUT /groups/:id/promote/:userId — promote to admin
router.put('/:id/promote/:userId', authenticate, async (req, res) => {
  try {
    const { id, userId } = req.params;
    if (!await isAdmin(id, req.userId)) return res.status(403).json({ error: 'Not an admin' });

    await db.query(
      `UPDATE group_members SET role = 'admin' WHERE group_id = $1 AND user_id = $2`,
      [id, userId]
    );

    await notifyMembers(id, 'group-member-promoted', { group_id: id, user_id: userId });

    res.json({ ok: true });
  } catch (err) {
    console.error('[groups promote]', err.message);
    res.status(500).json({ error: 'Failed to promote member' });
  }
});

// GET /groups/:id/messages — fetch message history
router.get('/:id/messages', authenticate, async (req, res) => {
  try {
    const { id } = req.params;
    if (!await isMember(id, req.userId)) return res.status(403).json({ error: 'Not a member' });

    const limit = Math.min(parseInt(req.query.limit) || 100, 200);
    const result = await db.query(
      `SELECT gm.*, u.username AS sender_username, u.virtual_id AS sender_virtual_id, u.avatar_url AS sender_avatar_url
       FROM group_messages gm
       JOIN users u ON u.id = gm.sender_id
       WHERE gm.group_id = $1
       ORDER BY gm.created_at DESC
       LIMIT $2`,
      [id, limit]
    );
    res.json(result.rows.reverse());
  } catch (err) {
    console.error('[groups GET messages]', err.message);
    res.status(500).json({ error: 'Failed to fetch messages' });
  }
});

// PUT /groups/:id — update group info (admin)
router.put('/:id', authenticate, async (req, res) => {
  try {
    const { id } = req.params;
    if (!await isAdmin(id, req.userId)) return res.status(403).json({ error: 'Not an admin' });

    const { name, description, avatar_url, theme_id } = req.body;
    const result = await db.query(
      `UPDATE groups SET
         name = COALESCE(NULLIF($1, ''), name),
         description = COALESCE($2, description),
         avatar_url = COALESCE($3, avatar_url),
         theme_id = COALESCE($5, theme_id)
       WHERE id = $4 RETURNING *`,
      [name?.trim() || '', description?.trim() || null, avatar_url || null, id, theme_id || null]
    );

    await notifyMembers(id, 'group-updated', result.rows[0]);
    res.json(result.rows[0]);
  } catch (err) {
    console.error('[groups PUT /:id]', err.message);
    res.status(500).json({ error: 'Failed to update group' });
  }
});

// DELETE /groups/:id — delete group (creator only)
router.delete('/:id', authenticate, async (req, res) => {
  try {
    const { id } = req.params;
    const groupRes = await db.query('SELECT created_by FROM groups WHERE id = $1', [id]);
    if (groupRes.rows.length === 0) return res.status(404).json({ error: 'Group not found' });
    if (groupRes.rows[0].created_by !== req.userId) {
      return res.status(403).json({ error: 'Only the group creator can delete it' });
    }

    await notifyMembers(id, 'group-deleted', { group_id: id });
    await db.query('DELETE FROM groups WHERE id = $1', [id]);
    res.json({ ok: true });
  } catch (err) {
    console.error('[groups DELETE /:id]', err.message);
    res.status(500).json({ error: 'Failed to delete group' });
  }
});

module.exports = router;
