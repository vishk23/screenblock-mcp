-- SQLite mirror of db/schema.sql (Postgres). Timestamps are ISO-8601 UTC TEXT
-- (lexicographically ordered), booleans are 0/1, ids are TEXT uuids from JS,
-- days_of_week/meta are JSON TEXT. Idempotent.
pragma journal_mode = WAL;
pragma foreign_keys = ON;

create table if not exists groups (
  id text primary key,
  user_id text not null default 'default',
  name text not null,
  has_selection integer not null default 0,
  created_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  mode text not null default 'quota',
  quota_per_day integer not null default 2,
  quota_minutes integer not null default 10,
  unique (user_id, name)
);

create table if not exists policies (
  id text primary key,
  user_id text not null default 'default',
  group_id text not null references groups(id) on delete cascade,
  kind text not null check (kind in ('schedule','limit','block')),
  active integer not null default 1,
  days_of_week text,           -- JSON array
  start_time text,
  end_time text,
  minutes_per_day integer,
  until text,
  timezone text,
  created_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

create table if not exists grants (
  id text primary key,
  user_id text not null default 'default',
  group_id text not null references groups(id) on delete cascade,
  minutes integer not null,
  reason text,
  starts_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  expires_at text not null,
  status text not null default 'pending' check (status in ('pending','active','expired','cancelled')),
  updated_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  source text not null default 'chat'
);

create table if not exists goals (
  id text primary key,
  user_id text not null default 'default',
  date text not null,
  text text not null,
  target text,
  updated_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  unique (user_id, date)
);

create table if not exists events (
  id integer primary key autoincrement,
  user_id text not null default 'default',
  group_id text references groups(id) on delete set null,
  type text not null,
  ts text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  meta text not null default '{}'
);
create index if not exists events_ts_idx on events (ts);

create table if not exists devices (
  id text primary key,
  user_id text not null default 'default',
  apns_token text not null unique,
  applied_through text,
  last_seen_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

create table if not exists earn_rules (
  id text primary key,
  user_id text not null default 'default',
  reward_group_id text not null references groups(id) on delete cascade,
  threshold_minutes integer not null,
  reward_minutes integer not null,
  max_per_day integer not null default 3,
  active integer not null default 1,
  updated_at text not null default (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  unique (user_id, reward_group_id)
);
