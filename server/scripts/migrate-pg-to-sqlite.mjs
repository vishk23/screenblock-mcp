// One-shot migration: copies every row from the Postgres DB (DATABASE_URL) into
// a fresh SQLite file (arg 1), preserving all ids — critically the group ids,
// which the iOS/Mac clients key their local app-selections by.
//
//   DATABASE_URL='postgres://…' node scripts/migrate-pg-to-sqlite.mjs ./screencp.db
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import pg from 'pg';

const require = createRequire(import.meta.url);
const { DatabaseSync } = require('node:sqlite');

const outPath = process.argv[2];
if (!outPath) { console.error('usage: node migrate-pg-to-sqlite.mjs <out.db>'); process.exit(1); }
if (!process.env.DATABASE_URL) { console.error('DATABASE_URL required'); process.exit(1); }

const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL, max: 2 });
const db = new DatabaseSync(outPath);
db.exec(readFileSync(new URL('../db/schema-sqlite.sql', import.meta.url), 'utf8'));

const isoOrNull = (v) => (v ? new Date(v).toISOString() : null);
const B = (v) => (v ? 1 : 0);

async function copy(table, cols, mapRow) {
  const { rows } = await pool.query(`select * from ${table}`);
  if (rows.length === 0) { console.log(`${table}: 0`); return; }
  const placeholders = cols.map(() => '?').join(', ');
  const stmt = db.prepare(`insert into ${table} (${cols.join(', ')}) values (${placeholders})`);
  db.exec('begin');
  for (const r of rows) stmt.run(...mapRow(r));
  db.exec('commit');
  console.log(`${table}: ${rows.length}`);
}

await copy('groups',
  ['id', 'user_id', 'name', 'has_selection', 'created_at', 'updated_at', 'mode', 'quota_per_day', 'quota_minutes'],
  (r) => [r.id, r.user_id, r.name, B(r.has_selection), isoOrNull(r.created_at), isoOrNull(r.updated_at), r.mode, r.quota_per_day, r.quota_minutes]);

await copy('policies',
  ['id', 'user_id', 'group_id', 'kind', 'active', 'days_of_week', 'start_time', 'end_time', 'minutes_per_day', 'until', 'timezone', 'created_at', 'updated_at'],
  (r) => [r.id, r.user_id, r.group_id, r.kind, B(r.active), r.days_of_week ? JSON.stringify(r.days_of_week) : null,
    r.start_time, r.end_time, r.minutes_per_day, isoOrNull(r.until), r.timezone, isoOrNull(r.created_at), isoOrNull(r.updated_at)]);

await copy('grants',
  ['id', 'user_id', 'group_id', 'minutes', 'reason', 'starts_at', 'expires_at', 'status', 'updated_at', 'source'],
  (r) => [r.id, r.user_id, r.group_id, r.minutes, r.reason, isoOrNull(r.starts_at), isoOrNull(r.expires_at), r.status, isoOrNull(r.updated_at), r.source]);

await copy('goals',
  ['id', 'user_id', 'date', 'text', 'target', 'updated_at'],
  (r) => [r.id, r.user_id, (r.date instanceof Date ? r.date.toISOString().slice(0, 10) : r.date), r.text, r.target, isoOrNull(r.updated_at)]);

await copy('events',
  ['id', 'user_id', 'group_id', 'type', 'ts', 'meta'],
  (r) => [Number(r.id), r.user_id, r.group_id, r.type, isoOrNull(r.ts), JSON.stringify(r.meta ?? {})]);

await copy('devices',
  ['id', 'user_id', 'apns_token', 'applied_through', 'last_seen_at'],
  (r) => [r.id, r.user_id, r.apns_token, isoOrNull(r.applied_through), isoOrNull(r.last_seen_at)]);

await copy('earn_rules',
  ['id', 'user_id', 'reward_group_id', 'threshold_minutes', 'reward_minutes', 'max_per_day', 'active', 'updated_at'],
  (r) => [r.id, r.user_id, r.reward_group_id, r.threshold_minutes, r.reward_minutes, r.max_per_day, B(r.active), isoOrNull(r.updated_at)]);

await pool.end();
console.log(`\n✓ wrote ${outPath}`);
