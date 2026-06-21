// Run once: node backend/migrate.js
require('dotenv').config({ path: __dirname + '/.env' });
const db = require('./src/db');

async function migrate() {
  await db.query(`
    ALTER TABLE messages
      ADD COLUMN IF NOT EXISTS edited_at TIMESTAMPTZ,
      ADD COLUMN IF NOT EXISTS is_deleted BOOLEAN NOT NULL DEFAULT false,
      ADD COLUMN IF NOT EXISTS reply_to_id TEXT REFERENCES messages(id) ON DELETE SET NULL
  `);
  console.log('Migration complete.');
  process.exit(0);
}

migrate().catch((err) => {
  console.error('Migration failed:', err.message);
  process.exit(1);
});
