-- ScreenCP schema (spec §5). Idempotent: safe to re-run.
create extension if not exists pgcrypto;

create table if not exists groups (
  id uuid primary key default gen_random_uuid(),
  user_id text not null default 'default',
  name text not null,
  has_selection boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, name)
);

create table if not exists policies (
  id uuid primary key default gen_random_uuid(),
  user_id text not null default 'default',
  group_id uuid not null references groups(id) on delete cascade,
  kind text not null check (kind in ('schedule','limit','block')),
  active boolean not null default true,
  days_of_week int[],
  start_time text,          -- "HH:MM" (kept as text; parsed on device)
  end_time text,            -- "HH:MM"
  minutes_per_day int,
  until timestamptz,
  timezone text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists grants (
  id uuid primary key default gen_random_uuid(),
  user_id text not null default 'default',
  group_id uuid not null references groups(id) on delete cascade,
  minutes int not null,
  reason text,
  starts_at timestamptz not null default now(),
  expires_at timestamptz not null,
  status text not null default 'pending'
    check (status in ('pending','active','expired','cancelled')),
  updated_at timestamptz not null default now()
);

create table if not exists goals (
  id uuid primary key default gen_random_uuid(),
  user_id text not null default 'default',
  date date not null,
  text text not null,
  target text,
  updated_at timestamptz not null default now(),
  unique (user_id, date)
);

create table if not exists events (
  id bigint generated always as identity primary key,
  user_id text not null default 'default',
  group_id uuid references groups(id) on delete set null,
  type text not null,
  ts timestamptz not null default now(),
  meta jsonb not null default '{}'
);
create index if not exists events_ts_idx on events (ts);

create table if not exists devices (
  id uuid primary key default gen_random_uuid(),
  user_id text not null default 'default',
  apns_token text not null unique,
  applied_through timestamptz,
  last_seen_at timestamptz not null default now()
);
