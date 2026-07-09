# ScreenCP Backend (Brain + Front Door) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A single Node/TypeScript service exposing (a) an MCP server ChatGPT/Claude can call to manage screen-time policy and (b) a device API the future iOS app syncs against, backed by Supabase Postgres, with an APNs delivery ladder.

**Architecture:** One stateless-per-request Express service (spec §4, "Option C"). State lives in Postgres. Tool handlers and delivery-ladder logic are pure-ish modules behind `Repo` and `PushSender` interfaces so everything is unit-testable with fakes; Postgres and APNs are thin adapters. MCP uses Streamable HTTP (stateless mode) from the official SDK.

**Tech Stack:** Node 22+, TypeScript (ESM), Express 4, `@modelcontextprotocol/sdk`, `zod`, `pg`, `apns2`, Vitest + Supertest. Deploy: Fly.io (Docker). DB: Supabase Postgres (plain `DATABASE_URL`; no Supabase client lib needed server-side in this plan).

**Companion plans (not this document):** Plan 2 = iOS Enforcer (incl. the two spikes from spec §9); Plan 3 = end-to-end integration. This plan is complete and testable standalone: every tool works and honestly reports `no_device_registered` delivery state until the iOS app exists.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-08-screencp-v1-design.md`. Axioms in spec §3 govern all decisions.
- Single-user v1: all rows default `user_id = 'default'`; no multi-tenant logic. Do not add auth complexity beyond the two bearer secrets.
- Auth bootstrap (spec §12 decision, resolved here): secret-in-URL-path (`/mcp/<MCP_BEARER_TOKEN>`) **or** `Authorization: Bearer` header — because ChatGPT/Claude custom-connector UIs support OAuth or no-auth, not custom headers. OAuth 2.1 is Phase 4, not this plan.
- Grants are server-capped at `MAX_GRANT_MINUTES` (default 60) — clamp, never reject (spec §8).
- Every mutating MCP tool response must include delivery state: `applied` | `pending` | `no_device_registered` (spec §6).
- Destructive tools (`unblock`, `remove_policy`) carry `annotations: { destructiveHint: true }`; read-only tools carry `readOnlyHint: true` (spec §6).
- Tool results are compact JSON in a single text content block — token-efficient per Anthropic tool guidance.
- ESM throughout (`"type": "module"`); relative imports use `.js` extension (NodeNext resolution).
- TDD: every task writes the failing test first. Commit at the end of every task.

## File Structure

```
server/
  package.json  tsconfig.json  vitest.config.ts  .env.example  .gitignore
  db/schema.sql                — full DDL (spec §5)
  src/
    types.ts                   — domain types (Group, Policy, Grant, Goal, EventRow, Device)
    config.ts                  — env → Config
    domain.ts                  — pure logic: matchGroup, deliveryState, grantRemainingMinutes, todayInTz, buildSummary
    repo.ts                    — Repo interface + PgRepo (pg Pool adapter)
    push.ts                    — PushSender interface, ApnsSender (apns2), Ladder (silent→visible fallback)
    mcp.ts                     — buildMcpServer(deps): all 11 tools
    deviceApi.ts               — Express router: register/sync/ack/events
    app.ts                     — makeApp(deps): Express wiring + auth middleware
    index.ts                   — entrypoint: load config, build deps, listen
  test/
    fakes.ts                   — FakeRepo (in-memory Repo), FakePush, FakeSender
    config.test.ts  domain.test.ts  repo.integration.test.ts
    tools.test.ts   deviceApi.test.ts  push.test.ts  app.test.ts
  Dockerfile  fly.toml  .dockerignore
```

Responsibility boundaries: `domain.ts` has zero I/O (pure functions). `mcp.ts` and `deviceApi.ts` depend only on the `Repo`/`Push` interfaces, never on `pg` or `apns2` directly. `PgRepo` and `ApnsSender` are the only modules touching external systems.

---

### Task 1: Project scaffold + config module

**Files:**
- Create: `server/package.json`, `server/tsconfig.json`, `server/vitest.config.ts`, `server/.gitignore`, `server/.env.example`, `server/src/config.ts`
- Test: `server/test/config.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces: `loadConfig(env?): Config` where `Config = { port: number; databaseUrl: string; mcpBearerToken: string; deviceBearerToken: string; maxGrantMinutes: number; timezone: string; apns: { teamId; keyId; key; topic; production } | null }`. All later tasks import `Config` from `../src/config.js`.

- [ ] **Step 1: Create scaffold files**

`server/package.json`:

```json
{
  "name": "screencp-server",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "engines": { "node": ">=22" },
  "scripts": {
    "build": "tsc -p tsconfig.json",
    "dev": "tsx src/index.ts",
    "start": "node dist/index.js",
    "test": "vitest run",
    "db:apply": "psql \"$DATABASE_URL\" -f db/schema.sql"
  },
  "dependencies": {
    "@modelcontextprotocol/sdk": "^1.12.0",
    "apns2": "^11.7.0",
    "dotenv": "^16.4.5",
    "express": "^4.21.2",
    "pg": "^8.13.1",
    "zod": "^3.24.1"
  },
  "devDependencies": {
    "@types/express": "^4.17.21",
    "@types/node": "^22.10.0",
    "@types/pg": "^8.11.10",
    "@types/supertest": "^6.0.2",
    "supertest": "^7.0.0",
    "tsx": "^4.19.2",
    "typescript": "^5.7.2",
    "vitest": "^2.1.8"
  }
}
```

`server/tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "outDir": "dist",
    "rootDir": "src",
    "declaration": false,
    "sourceMap": true
  },
  "include": ["src"]
}
```

`server/vitest.config.ts`:

```ts
import { defineConfig } from 'vitest/config';
export default defineConfig({ test: { environment: 'node' } });
```

`server/.gitignore`:

```
node_modules/
dist/
.env
```

`server/.env.example`:

```
PORT=8080
DATABASE_URL=postgres://postgres:password@db.xxxx.supabase.co:5432/postgres
MCP_BEARER_TOKEN=generate-a-long-random-string
DEVICE_BEARER_TOKEN=generate-a-different-long-random-string
MAX_GRANT_MINUTES=60
TIMEZONE=America/Los_Angeles
# APNs (leave unset until Plan 2 — server runs without push)
# APNS_TEAM_ID=ABCDE12345
# APNS_KEY_ID=XYZ987
# APNS_KEY_P8="-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----"
# APNS_TOPIC=com.yourname.screencp
# APNS_PRODUCTION=false
```

Run: `cd /Users/vk/VKDEV/screencp/server && npm install`
Expected: installs cleanly (lockfile created).

- [ ] **Step 2: Write the failing test**

`server/test/config.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { loadConfig } from '../src/config.js';

const base = {
  DATABASE_URL: 'postgres://x',
  MCP_BEARER_TOKEN: 't1',
  DEVICE_BEARER_TOKEN: 't2',
};

describe('loadConfig', () => {
  it('loads required values and applies defaults', () => {
    const c = loadConfig(base);
    expect(c.databaseUrl).toBe('postgres://x');
    expect(c.port).toBe(8080);
    expect(c.maxGrantMinutes).toBe(60);
    expect(c.timezone).toBe('America/Los_Angeles');
    expect(c.apns).toBeNull();
  });

  it('throws naming the missing env var', () => {
    expect(() => loadConfig({})).toThrow(/DATABASE_URL/);
  });

  it('parses APNs config and unescapes the key when APNS_TEAM_ID is set', () => {
    const c = loadConfig({
      ...base,
      APNS_TEAM_ID: 'TEAM',
      APNS_KEY_ID: 'KEY',
      APNS_KEY_P8: '-----BEGIN PRIVATE KEY-----\\nabc\\n-----END PRIVATE KEY-----',
      APNS_TOPIC: 'com.x.app',
      APNS_PRODUCTION: 'true',
    });
    expect(c.apns).toEqual({
      teamId: 'TEAM',
      keyId: 'KEY',
      key: '-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----',
      topic: 'com.x.app',
      production: true,
    });
  });
});
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd /Users/vk/VKDEV/screencp/server && npx vitest run test/config.test.ts`
Expected: FAIL — cannot find module `../src/config.js`.

- [ ] **Step 4: Write minimal implementation**

`server/src/config.ts`:

```ts
export interface ApnsConfig {
  teamId: string;
  keyId: string;
  key: string;
  topic: string;
  production: boolean;
}

export interface Config {
  port: number;
  databaseUrl: string;
  mcpBearerToken: string;
  deviceBearerToken: string;
  maxGrantMinutes: number;
  timezone: string;
  apns: ApnsConfig | null;
}

type Env = Record<string, string | undefined>;

export function loadConfig(env: Env = process.env): Config {
  const required = (k: string): string => {
    const v = env[k];
    if (!v) throw new Error(`Missing required env var: ${k}`);
    return v;
  };
  return {
    port: Number(env.PORT ?? 8080),
    databaseUrl: required('DATABASE_URL'),
    mcpBearerToken: required('MCP_BEARER_TOKEN'),
    deviceBearerToken: required('DEVICE_BEARER_TOKEN'),
    maxGrantMinutes: Number(env.MAX_GRANT_MINUTES ?? 60),
    timezone: env.TIMEZONE ?? 'America/Los_Angeles',
    apns: env.APNS_TEAM_ID
      ? {
          teamId: env.APNS_TEAM_ID,
          keyId: required('APNS_KEY_ID'),
          key: required('APNS_KEY_P8').replace(/\\n/g, '\n'),
          topic: required('APNS_TOPIC'),
          production: env.APNS_PRODUCTION === 'true',
        }
      : null,
  };
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `npx vitest run test/config.test.ts`
Expected: 3 passed.

- [ ] **Step 6: Commit**

```bash
cd /Users/vk/VKDEV/screencp
git add server
git commit -m "feat(server): scaffold TypeScript project with config module"
```

---

### Task 2: Domain types + DB schema + Repo interface + fakes

**Files:**
- Create: `server/src/types.ts`, `server/db/schema.sql`, `server/src/repo.ts` (interface only this task), `server/test/fakes.ts`
- Test: `server/test/fakes.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces (used by every later task):
  - Types: `PolicyKind = 'schedule'|'limit'|'block'`; `Group { id, name, hasSelection, updatedAt }`; `Policy { id, groupId, kind, active, daysOfWeek?, startTime?, endTime?, minutesPerDay?, until?, timezone?, updatedAt }`; `Grant { id, groupId, minutes, reason, startsAt, expiresAt, status: 'pending'|'active'|'expired'|'cancelled', updatedAt }`; `Goal { date, text, target }`; `EventRow { id, groupId, type, ts, meta }`; `Device { id, apnsToken, appliedThrough, lastSeenAt }`. All timestamps are ISO-8601 strings in the domain layer.
  - `Repo` interface (exact signatures in Step 1 code).
  - `FakeRepo implements Repo` and `FakePush implements Push` (`Push = { policyChanged(changedAt: Date, description: string): void }`) for all later tests.

- [ ] **Step 1: Write types, Repo interface, and schema**

`server/src/types.ts`:

```ts
export type PolicyKind = 'schedule' | 'limit' | 'block';

export interface Group {
  id: string;
  name: string;
  hasSelection: boolean;
  updatedAt: string;
}

export interface Policy {
  id: string;
  groupId: string;
  kind: PolicyKind;
  active: boolean;
  daysOfWeek?: number[]; // 0=Sun … 6=Sat
  startTime?: string;    // "HH:MM"
  endTime?: string;      // "HH:MM"
  minutesPerDay?: number;
  until?: string | null; // ISO timestamp for block_now(until)
  timezone?: string;
  updatedAt: string;
}

export type GrantStatus = 'pending' | 'active' | 'expired' | 'cancelled';

export interface Grant {
  id: string;
  groupId: string;
  minutes: number;
  reason: string | null;
  startsAt: string;
  expiresAt: string;
  status: GrantStatus;
  updatedAt: string;
}

export interface Goal {
  date: string; // YYYY-MM-DD
  text: string;
  target: string | null;
}

export interface EventRow {
  id: number;
  groupId: string | null;
  type: string;
  ts: string;
  meta: Record<string, unknown>;
}

export interface Device {
  id: string;
  apnsToken: string;
  appliedThrough: string | null;
  lastSeenAt: string;
}

export interface NewEvent {
  type: string;
  groupId?: string | null;
  ts?: string;
  meta?: Record<string, unknown>;
}

export interface SyncPayload {
  groups: Group[];
  policies: Policy[];
  grants: Grant[];
  serverTime: string;
}
```

`server/src/repo.ts` (interface only; `PgRepo` comes in Task 3):

```ts
import type {
  Group, Policy, PolicyKind, Grant, Goal, EventRow, Device, NewEvent, SyncPayload,
} from './types.js';

export interface Repo {
  listGroups(): Promise<Group[]>;
  createGroup(name: string): Promise<Group>;
  setGroupSelection(id: string, hasSelection: boolean): Promise<void>;

  listPolicies(activeOnly?: boolean): Promise<Policy[]>;
  /** Deactivates any active policy of this kind on the group, inserts the new one. */
  replacePolicy(
    groupId: string,
    kind: PolicyKind,
    fields: Pick<Policy, 'daysOfWeek' | 'startTime' | 'endTime' | 'minutesPerDay' | 'until' | 'timezone'>,
  ): Promise<Policy>;
  /** Sets active=false. Returns count deactivated. kind omitted = all kinds. */
  deactivatePolicies(groupId: string, kind?: PolicyKind): Promise<number>;

  listGrants(statuses?: Grant['status'][]): Promise<Grant[]>;
  createGrant(groupId: string, minutes: number, reason: string | null, expiresAt: Date): Promise<Grant>;
  /** Marks pending/active grants with expires_at <= now as expired. Returns count. */
  expireGrants(now: Date): Promise<number>;

  upsertGoal(date: string, text: string, target: string | null): Promise<Goal>;
  getGoal(date: string): Promise<Goal | null>;

  insertEvents(events: NewEvent[]): Promise<number>;
  /** Events whose ts falls on `date` (YYYY-MM-DD) in `timezone`. */
  listEventsOn(date: string, timezone: string): Promise<EventRow[]>;

  registerDevice(apnsToken: string): Promise<Device>;
  listDevices(): Promise<Device[]>;
  ackDevice(apnsToken: string, appliedThrough: Date): Promise<void>;

  /** Everything updated after `since` (all rows when null), for device pull-sync. */
  changesSince(since: Date | null): Promise<SyncPayload>;
}
```

`server/db/schema.sql`:

```sql
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
```

- [ ] **Step 2: Write the failing test (FakeRepo behavior)**

`server/test/fakes.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { FakeRepo } from './fakes.js';

describe('FakeRepo', () => {
  it('creates and lists groups', async () => {
    const repo = new FakeRepo();
    const g = await repo.createGroup('Social');
    expect(g.name).toBe('Social');
    expect(g.hasSelection).toBe(false);
    expect(await repo.listGroups()).toHaveLength(1);
  });

  it('replacePolicy deactivates the previous policy of the same kind', async () => {
    const repo = new FakeRepo();
    const g = await repo.createGroup('Social');
    await repo.replacePolicy(g.id, 'limit', { minutesPerDay: 30 });
    const p2 = await repo.replacePolicy(g.id, 'limit', { minutesPerDay: 45 });
    const active = await repo.listPolicies(true);
    expect(active).toHaveLength(1);
    expect(active[0].id).toBe(p2.id);
    expect(active[0].minutesPerDay).toBe(45);
    expect(await repo.listPolicies(false)).toHaveLength(2);
  });

  it('expireGrants flips overdue grants and returns the count', async () => {
    const repo = new FakeRepo();
    const g = await repo.createGroup('Social');
    await repo.createGrant(g.id, 15, null, new Date('2026-07-08T12:15:00Z'));
    expect(await repo.expireGrants(new Date('2026-07-08T12:00:00Z'))).toBe(0);
    expect(await repo.expireGrants(new Date('2026-07-08T12:16:00Z'))).toBe(1);
    const [grant] = await repo.listGrants();
    expect(grant.status).toBe('expired');
  });

  it('changesSince filters by updatedAt and ackDevice records progress', async () => {
    const repo = new FakeRepo();
    const g = await repo.createGroup('Social');
    const before = new Date(Date.now() + 60_000); // future: nothing newer
    expect((await repo.changesSince(before)).groups).toHaveLength(0);
    expect((await repo.changesSince(null)).groups).toHaveLength(1);

    await repo.registerDevice('tok1');
    await repo.ackDevice('tok1', new Date('2026-07-08T12:00:00Z'));
    const [d] = await repo.listDevices();
    expect(d.appliedThrough).toBe('2026-07-08T12:00:00.000Z');
    expect(g.id).toBeTruthy();
  });

  it('upserts goals by date and filters events by local date', async () => {
    const repo = new FakeRepo();
    await repo.upsertGoal('2026-07-08', '3 focus hours', null);
    await repo.upsertGoal('2026-07-08', '4 focus hours', '4h');
    expect((await repo.getGoal('2026-07-08'))?.text).toBe('4 focus hours');

    await repo.insertEvents([
      { type: 'shield_shown', ts: '2026-07-08T19:00:00Z' },  // Jul 8 in LA
      { type: 'shield_shown', ts: '2026-07-09T05:00:00Z' },  // still Jul 8 in LA (22:00)
      { type: 'shield_shown', ts: '2026-07-09T12:00:00Z' },  // Jul 9 in LA
    ]);
    const rows = await repo.listEventsOn('2026-07-08', 'America/Los_Angeles');
    expect(rows).toHaveLength(2);
  });
});
```

- [ ] **Step 3: Run test to verify it fails**

Run: `npx vitest run test/fakes.test.ts`
Expected: FAIL — cannot find module `./fakes.js`.

- [ ] **Step 4: Implement FakeRepo + FakePush**

`server/test/fakes.ts`:

```ts
import { randomUUID } from 'node:crypto';
import type { Repo } from '../src/repo.js';
import type {
  Group, Policy, PolicyKind, Grant, Goal, EventRow, Device, NewEvent, SyncPayload,
} from '../src/types.js';
import type { Push } from '../src/push.js';

const iso = (d: Date) => d.toISOString();

/** YYYY-MM-DD of an instant in a timezone (mirrors domain.todayInTz). */
function localDate(tsIso: string, timezone: string): string {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: timezone, year: 'numeric', month: '2-digit', day: '2-digit',
  }).format(new Date(tsIso));
}

export class FakeRepo implements Repo {
  groups: Group[] = [];
  policies: Policy[] = [];
  grants: Grant[] = [];
  goals: Goal[] = [];
  events: EventRow[] = [];
  devices: Device[] = [];
  private eventId = 0;

  async listGroups() { return [...this.groups]; }

  async createGroup(name: string): Promise<Group> {
    if (this.groups.some((g) => g.name === name)) throw new Error(`duplicate group: ${name}`);
    const g: Group = { id: randomUUID(), name, hasSelection: false, updatedAt: iso(new Date()) };
    this.groups.push(g);
    return g;
  }

  async setGroupSelection(id: string, hasSelection: boolean) {
    const g = this.groups.find((x) => x.id === id);
    if (g) { g.hasSelection = hasSelection; g.updatedAt = iso(new Date()); }
  }

  async listPolicies(activeOnly = true) {
    return this.policies.filter((p) => !activeOnly || p.active);
  }

  async replacePolicy(
    groupId: string,
    kind: PolicyKind,
    fields: Pick<Policy, 'daysOfWeek' | 'startTime' | 'endTime' | 'minutesPerDay' | 'until' | 'timezone'>,
  ): Promise<Policy> {
    for (const p of this.policies) {
      if (p.groupId === groupId && p.kind === kind && p.active) {
        p.active = false; p.updatedAt = iso(new Date());
      }
    }
    const policy: Policy = {
      id: randomUUID(), groupId, kind, active: true, ...fields, updatedAt: iso(new Date()),
    };
    this.policies.push(policy);
    return policy;
  }

  async deactivatePolicies(groupId: string, kind?: PolicyKind) {
    let n = 0;
    for (const p of this.policies) {
      if (p.groupId === groupId && p.active && (!kind || p.kind === kind)) {
        p.active = false; p.updatedAt = iso(new Date()); n++;
      }
    }
    return n;
  }

  async listGrants(statuses?: Grant['status'][]) {
    return this.grants.filter((g) => !statuses || statuses.includes(g.status));
  }

  async createGrant(groupId: string, minutes: number, reason: string | null, expiresAt: Date): Promise<Grant> {
    const grant: Grant = {
      id: randomUUID(), groupId, minutes, reason,
      startsAt: iso(new Date()), expiresAt: iso(expiresAt),
      status: 'pending', updatedAt: iso(new Date()),
    };
    this.grants.push(grant);
    return grant;
  }

  async expireGrants(now: Date) {
    let n = 0;
    for (const g of this.grants) {
      if ((g.status === 'pending' || g.status === 'active') && new Date(g.expiresAt) <= now) {
        g.status = 'expired'; g.updatedAt = iso(new Date()); n++;
      }
    }
    return n;
  }

  async upsertGoal(date: string, text: string, target: string | null): Promise<Goal> {
    const existing = this.goals.find((g) => g.date === date);
    if (existing) { existing.text = text; existing.target = target; return existing; }
    const goal: Goal = { date, text, target };
    this.goals.push(goal);
    return goal;
  }

  async getGoal(date: string) { return this.goals.find((g) => g.date === date) ?? null; }

  async insertEvents(events: NewEvent[]) {
    for (const e of events) {
      this.events.push({
        id: ++this.eventId,
        groupId: e.groupId ?? null,
        type: e.type,
        ts: e.ts ?? iso(new Date()),
        meta: e.meta ?? {},
      });
    }
    return events.length;
  }

  async listEventsOn(date: string, timezone: string) {
    return this.events.filter((e) => localDate(e.ts, timezone) === date);
  }

  async registerDevice(apnsToken: string): Promise<Device> {
    const existing = this.devices.find((d) => d.apnsToken === apnsToken);
    if (existing) { existing.lastSeenAt = iso(new Date()); return existing; }
    const d: Device = { id: randomUUID(), apnsToken, appliedThrough: null, lastSeenAt: iso(new Date()) };
    this.devices.push(d);
    return d;
  }

  async listDevices() { return [...this.devices]; }

  async ackDevice(apnsToken: string, appliedThrough: Date) {
    const d = this.devices.find((x) => x.apnsToken === apnsToken);
    if (d) { d.appliedThrough = iso(appliedThrough); d.lastSeenAt = iso(new Date()); }
  }

  async changesSince(since: Date | null): Promise<SyncPayload> {
    const newer = (u: string) => !since || new Date(u) > since;
    return {
      groups: this.groups.filter((g) => newer(g.updatedAt)),
      policies: this.policies.filter((p) => newer(p.updatedAt)),
      grants: this.grants.filter((g) => newer(g.updatedAt)),
      serverTime: iso(new Date()),
    };
  }
}

export class FakePush implements Push {
  calls: Array<{ changedAt: Date; description: string }> = [];
  policyChanged(changedAt: Date, description: string) {
    this.calls.push({ changedAt, description });
  }
}
```

Also create the `Push` interface stub now so `fakes.ts` compiles — `server/src/push.ts`:

```ts
export interface Push {
  /** Fire-and-forget: notify device(s) that policy changed at `changedAt`. */
  policyChanged(changedAt: Date, description: string): void;
}
```

(The Ladder and ApnsSender are added to this same file in Task 6.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `npx vitest run test/fakes.test.ts`
Expected: 5 passed.

- [ ] **Step 6: Commit**

```bash
cd /Users/vk/VKDEV/screencp
git add server
git commit -m "feat(server): domain types, DB schema, Repo interface, in-memory fakes"
```

---

### Task 3: PgRepo (Postgres adapter)

**Files:**
- Modify: `server/src/repo.ts` (append `PgRepo` below the interface)
- Test: `server/test/repo.integration.test.ts`

**Interfaces:**
- Consumes: `Repo` interface, types from Task 2; `pg.Pool`.
- Produces: `class PgRepo implements Repo { constructor(pool: pg.Pool) }` and `makePool(databaseUrl: string): pg.Pool`. Used only by `index.ts` (Task 8).

Integration test runs against a real Postgres via `DATABASE_URL` and **skips itself** when the var is absent, so CI/local runs stay green before Supabase is provisioned. Unit coverage of behavior semantics already exists via `FakeRepo` (kept semantically identical — that is the contract).

- [ ] **Step 1: Write the failing (gated) integration test**

`server/test/repo.integration.test.ts`:

```ts
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { readFileSync } from 'node:fs';
import pg from 'pg';
import { PgRepo, makePool } from '../src/repo.js';

const url = process.env.DATABASE_URL;
const d = url ? describe : describe.skip;

d('PgRepo (integration — requires DATABASE_URL)', () => {
  let pool: pg.Pool;
  let repo: PgRepo;

  beforeAll(async () => {
    pool = makePool(url!);
    await pool.query(readFileSync(new URL('../db/schema.sql', import.meta.url), 'utf8'));
    // isolate: wipe rows (single-user personal DB; fine for tests)
    await pool.query('delete from events; delete from grants; delete from policies; delete from goals; delete from devices; delete from groups;');
    repo = new PgRepo(pool);
  });

  afterAll(async () => { await pool.end(); });

  it('round-trips a group, policy replacement, grant lifecycle, goal, events, device ack, and sync', async () => {
    const g = await repo.createGroup('Social');
    expect(g.hasSelection).toBe(false);

    await repo.replacePolicy(g.id, 'limit', { minutesPerDay: 30 });
    const p2 = await repo.replacePolicy(g.id, 'limit', { minutesPerDay: 45 });
    const active = await repo.listPolicies(true);
    expect(active).toHaveLength(1);
    expect(active[0].id).toBe(p2.id);

    const sched = await repo.replacePolicy(g.id, 'schedule', {
      daysOfWeek: [1, 2, 3, 4, 5], startTime: '09:00', endTime: '17:00', timezone: 'America/Los_Angeles',
    });
    expect(sched.daysOfWeek).toEqual([1, 2, 3, 4, 5]);

    const grant = await repo.createGrant(g.id, 15, 'on the bus', new Date(Date.now() - 1000));
    expect(grant.status).toBe('pending');
    expect(await repo.expireGrants(new Date())).toBe(1);

    await repo.upsertGoal('2026-07-08', '3 focus hours', null);
    await repo.upsertGoal('2026-07-08', '4 focus hours', '4h');
    expect((await repo.getGoal('2026-07-08'))?.text).toBe('4 focus hours');

    await repo.insertEvents([{ type: 'shield_shown', groupId: g.id, ts: '2026-07-08T19:00:00Z' }]);
    expect(await repo.listEventsOn('2026-07-08', 'America/Los_Angeles')).toHaveLength(1);

    await repo.registerDevice('tok1');
    await repo.ackDevice('tok1', new Date('2026-07-08T12:00:00Z'));
    expect((await repo.listDevices())[0].appliedThrough).toBe('2026-07-08T12:00:00.000Z');

    const all = await repo.changesSince(null);
    expect(all.groups).toHaveLength(1);
    expect(all.policies.length).toBeGreaterThanOrEqual(3); // 2 limits (1 inactive) + schedule
    const none = await repo.changesSince(new Date(Date.now() + 60_000));
    expect(none.policies).toHaveLength(0);
    expect(await repo.deactivatePolicies(g.id)).toBe(2);
  });
});
```

- [ ] **Step 2: Run to verify it is skipped (no DATABASE_URL) / fails (with one)**

Run: `npx vitest run test/repo.integration.test.ts`
Expected without `DATABASE_URL`: suite skipped, exit 0. With it: FAIL — `PgRepo` not exported.

- [ ] **Step 3: Implement PgRepo**

Append to `server/src/repo.ts`:

```ts
import pg from 'pg';

export function makePool(databaseUrl: string): pg.Pool {
  return new pg.Pool({ connectionString: databaseUrl, max: 5 });
}

const isoOrNull = (v: Date | null): string | null => (v ? v.toISOString() : null);

const rowToGroup = (r: any): Group => ({
  id: r.id, name: r.name, hasSelection: r.has_selection, updatedAt: r.updated_at.toISOString(),
});

const rowToPolicy = (r: any): Policy => ({
  id: r.id,
  groupId: r.group_id,
  kind: r.kind,
  active: r.active,
  daysOfWeek: r.days_of_week ?? undefined,
  startTime: r.start_time ?? undefined,
  endTime: r.end_time ?? undefined,
  minutesPerDay: r.minutes_per_day ?? undefined,
  until: isoOrNull(r.until),
  timezone: r.timezone ?? undefined,
  updatedAt: r.updated_at.toISOString(),
});

const rowToGrant = (r: any): Grant => ({
  id: r.id, groupId: r.group_id, minutes: r.minutes, reason: r.reason,
  startsAt: r.starts_at.toISOString(), expiresAt: r.expires_at.toISOString(),
  status: r.status, updatedAt: r.updated_at.toISOString(),
});

const rowToDevice = (r: any): Device => ({
  id: r.id, apnsToken: r.apns_token,
  appliedThrough: isoOrNull(r.applied_through), lastSeenAt: r.last_seen_at.toISOString(),
});

export class PgRepo implements Repo {
  constructor(private pool: pg.Pool) {}

  async listGroups() {
    const { rows } = await this.pool.query('select * from groups order by name');
    return rows.map(rowToGroup);
  }

  async createGroup(name: string) {
    const { rows } = await this.pool.query(
      'insert into groups (name) values ($1) returning *', [name],
    );
    return rowToGroup(rows[0]);
  }

  async setGroupSelection(id: string, hasSelection: boolean) {
    await this.pool.query(
      'update groups set has_selection = $2, updated_at = now() where id = $1',
      [id, hasSelection],
    );
  }

  async listPolicies(activeOnly = true) {
    const { rows } = await this.pool.query(
      activeOnly ? 'select * from policies where active order by updated_at'
                 : 'select * from policies order by updated_at',
    );
    return rows.map(rowToPolicy);
  }

  async replacePolicy(
    groupId: string,
    kind: PolicyKind,
    fields: Pick<Policy, 'daysOfWeek' | 'startTime' | 'endTime' | 'minutesPerDay' | 'until' | 'timezone'>,
  ) {
    const client = await this.pool.connect();
    try {
      await client.query('begin');
      await client.query(
        'update policies set active = false, updated_at = now() where group_id = $1 and kind = $2 and active',
        [groupId, kind],
      );
      const { rows } = await client.query(
        `insert into policies (group_id, kind, days_of_week, start_time, end_time, minutes_per_day, until, timezone)
         values ($1, $2, $3, $4, $5, $6, $7, $8) returning *`,
        [groupId, kind, fields.daysOfWeek ?? null, fields.startTime ?? null, fields.endTime ?? null,
         fields.minutesPerDay ?? null, fields.until ?? null, fields.timezone ?? null],
      );
      await client.query('commit');
      return rowToPolicy(rows[0]);
    } catch (e) {
      await client.query('rollback');
      throw e;
    } finally {
      client.release();
    }
  }

  async deactivatePolicies(groupId: string, kind?: PolicyKind) {
    const { rowCount } = await this.pool.query(
      kind
        ? 'update policies set active = false, updated_at = now() where group_id = $1 and kind = $2 and active'
        : 'update policies set active = false, updated_at = now() where group_id = $1 and active',
      kind ? [groupId, kind] : [groupId],
    );
    return rowCount ?? 0;
  }

  async listGrants(statuses?: Grant['status'][]) {
    const { rows } = await this.pool.query(
      statuses ? 'select * from grants where status = any($1) order by expires_at'
               : 'select * from grants order by expires_at',
      statuses ? [statuses] : [],
    );
    return rows.map(rowToGrant);
  }

  async createGrant(groupId: string, minutes: number, reason: string | null, expiresAt: Date) {
    const { rows } = await this.pool.query(
      'insert into grants (group_id, minutes, reason, expires_at) values ($1, $2, $3, $4) returning *',
      [groupId, minutes, reason, expiresAt],
    );
    return rowToGrant(rows[0]);
  }

  async expireGrants(now: Date) {
    const { rowCount } = await this.pool.query(
      `update grants set status = 'expired', updated_at = now()
       where status in ('pending','active') and expires_at <= $1`,
      [now],
    );
    return rowCount ?? 0;
  }

  async upsertGoal(date: string, text: string, target: string | null) {
    const { rows } = await this.pool.query(
      `insert into goals (date, text, target) values ($1, $2, $3)
       on conflict (user_id, date) do update set text = $2, target = $3, updated_at = now()
       returning to_char(date, 'YYYY-MM-DD') as date, text, target`,
      [date, text, target],
    );
    return rows[0] as Goal;
  }

  async getGoal(date: string) {
    const { rows } = await this.pool.query(
      `select to_char(date, 'YYYY-MM-DD') as date, text, target from goals where date = $1`,
      [date],
    );
    return (rows[0] as Goal) ?? null;
  }

  async insertEvents(events: NewEvent[]) {
    for (const e of events) {
      await this.pool.query(
        'insert into events (group_id, type, ts, meta) values ($1, $2, coalesce($3, now()), $4)',
        [e.groupId ?? null, e.type, e.ts ?? null, JSON.stringify(e.meta ?? {})],
      );
    }
    return events.length;
  }

  async listEventsOn(date: string, timezone: string) {
    const { rows } = await this.pool.query(
      `select id, group_id, type, ts, meta from events
       where (ts at time zone $2)::date = $1::date order by ts`,
      [date, timezone],
    );
    return rows.map((r: any): EventRow => ({
      id: Number(r.id), groupId: r.group_id, type: r.type, ts: r.ts.toISOString(), meta: r.meta,
    }));
  }

  async registerDevice(apnsToken: string) {
    const { rows } = await this.pool.query(
      `insert into devices (apns_token) values ($1)
       on conflict (apns_token) do update set last_seen_at = now() returning *`,
      [apnsToken],
    );
    return rowToDevice(rows[0]);
  }

  async listDevices() {
    const { rows } = await this.pool.query('select * from devices order by last_seen_at desc');
    return rows.map(rowToDevice);
  }

  async ackDevice(apnsToken: string, appliedThrough: Date) {
    await this.pool.query(
      'update devices set applied_through = $2, last_seen_at = now() where apns_token = $1',
      [apnsToken, appliedThrough],
    );
  }

  async changesSince(since: Date | null): Promise<SyncPayload> {
    const [g, p, gr, t] = await Promise.all([
      this.pool.query(since ? 'select * from groups where updated_at > $1' : 'select * from groups', since ? [since] : []),
      this.pool.query(since ? 'select * from policies where updated_at > $1' : 'select * from policies', since ? [since] : []),
      this.pool.query(since ? 'select * from grants where updated_at > $1' : 'select * from grants', since ? [since] : []),
      this.pool.query('select now() as now'),
    ]);
    return {
      groups: g.rows.map(rowToGroup),
      policies: p.rows.map(rowToPolicy),
      grants: gr.rows.map(rowToGrant),
      serverTime: t.rows[0].now.toISOString(),
    };
  }
}
```

- [ ] **Step 4: Typecheck and run the gated test**

Run: `npx tsc -p tsconfig.json --noEmit && npx vitest run test/repo.integration.test.ts`
Expected: typecheck clean; suite skipped (or 1 passed if `DATABASE_URL` is exported to a Supabase/local Postgres).

- [ ] **Step 5: Commit**

```bash
cd /Users/vk/VKDEV/screencp
git add server
git commit -m "feat(server): PgRepo Postgres adapter with gated integration test"
```

---

### Task 4: Pure domain logic

**Files:**
- Create: `server/src/domain.ts`
- Test: `server/test/domain.test.ts`

**Interfaces:**
- Consumes: types from Task 2.
- Produces (used by `mcp.ts` in Task 5):
  - `matchGroup(groups: Group[], query: string): Group | null` — case-insensitive exact → unique prefix → unique substring; `null` on no/ambiguous match.
  - `deliveryState(updatedAt: string, devices: Device[]): 'applied' | 'pending' | 'no_device_registered'`
  - `grantRemainingMinutes(grant: Grant, now: Date): number`
  - `todayInTz(timezone: string, now?: Date): string` — `YYYY-MM-DD`
  - `buildSummary(input: { events: EventRow[]; grants: Grant[]; goal: Goal | null; groups: Group[] }): Summary` where `Summary = { goal: Goal | null; shieldShown: Record<string, number>; shieldTaps: number; thresholdsCrossed: Array<{ group: string; thresholdMinutes: number; at: string }>; grantsUsed: Array<{ group: string; minutes: number; reason: string | null }> }` (group referenced by *name*).

- [ ] **Step 1: Write the failing test**

`server/test/domain.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import {
  matchGroup, deliveryState, grantRemainingMinutes, todayInTz, buildSummary,
} from '../src/domain.js';
import type { Group, Device, Grant, EventRow } from '../src/types.js';

const g = (id: string, name: string): Group => ({ id, name, hasSelection: true, updatedAt: '2026-07-08T00:00:00.000Z' });

describe('matchGroup', () => {
  const groups = [g('1', 'Social'), g('2', 'Social News'), g('3', 'Work Distractions')];
  it('matches exact name case-insensitively', () => {
    expect(matchGroup(groups, 'social')?.id).toBe('1');
  });
  it('matches a unique prefix', () => {
    expect(matchGroup(groups, 'work')?.id).toBe('3');
  });
  it('matches a unique substring', () => {
    expect(matchGroup(groups, 'distract')?.id).toBe('3');
  });
  it('returns null on ambiguous or missing', () => {
    expect(matchGroup(groups, 'soc')).toBeNull();     // prefix of two, no exact
    expect(matchGroup(groups, 'games')).toBeNull();
  });
});

describe('deliveryState', () => {
  const dev = (applied: string | null): Device => ({ id: 'd', apnsToken: 't', appliedThrough: applied, lastSeenAt: '2026-07-08T00:00:00.000Z' });
  it('no devices → no_device_registered', () => {
    expect(deliveryState('2026-07-08T12:00:00.000Z', [])).toBe('no_device_registered');
  });
  it('device acked past the change → applied', () => {
    expect(deliveryState('2026-07-08T12:00:00.000Z', [dev('2026-07-08T12:00:01.000Z')])).toBe('applied');
  });
  it('device behind the change (or never acked) → pending', () => {
    expect(deliveryState('2026-07-08T12:00:00.000Z', [dev('2026-07-08T11:00:00.000Z')])).toBe('pending');
    expect(deliveryState('2026-07-08T12:00:00.000Z', [dev(null)])).toBe('pending');
  });
});

describe('grantRemainingMinutes', () => {
  const grant: Grant = {
    id: 'g', groupId: '1', minutes: 15, reason: null,
    startsAt: '2026-07-08T12:00:00.000Z', expiresAt: '2026-07-08T12:15:00.000Z',
    status: 'active', updatedAt: '2026-07-08T12:00:00.000Z',
  };
  it('rounds up remaining minutes and floors at 0', () => {
    expect(grantRemainingMinutes(grant, new Date('2026-07-08T12:00:30Z'))).toBe(15);
    expect(grantRemainingMinutes(grant, new Date('2026-07-08T12:14:01Z'))).toBe(1);
    expect(grantRemainingMinutes(grant, new Date('2026-07-08T12:16:00Z'))).toBe(0);
  });
});

describe('todayInTz', () => {
  it('resolves the local calendar date across timezones', () => {
    const now = new Date('2026-07-09T05:00:00Z'); // 22:00 Jul 8 in LA, 14:00 Jul 9 in Tokyo
    expect(todayInTz('America/Los_Angeles', now)).toBe('2026-07-08');
    expect(todayInTz('Asia/Tokyo', now)).toBe('2026-07-09');
  });
});

describe('buildSummary', () => {
  it('aggregates events, grants, and goal by group name', () => {
    const groups = [g('1', 'Social')];
    const events: EventRow[] = [
      { id: 1, groupId: '1', type: 'shield_shown', ts: '2026-07-08T10:00:00.000Z', meta: {} },
      { id: 2, groupId: '1', type: 'shield_shown', ts: '2026-07-08T11:00:00.000Z', meta: {} },
      { id: 3, groupId: '1', type: 'shield_action_tapped', ts: '2026-07-08T11:00:05.000Z', meta: {} },
      { id: 4, groupId: '1', type: 'threshold_crossed', ts: '2026-07-08T14:00:00.000Z', meta: { thresholdMinutes: 30 } },
      { id: 5, groupId: null, type: 'policy_applied', ts: '2026-07-08T09:00:00.000Z', meta: {} },
    ];
    const grants: Grant[] = [{
      id: 'gr', groupId: '1', minutes: 15, reason: 'on the bus',
      startsAt: '2026-07-08T12:00:00.000Z', expiresAt: '2026-07-08T12:15:00.000Z',
      status: 'expired', updatedAt: '2026-07-08T12:15:00.000Z',
    }];
    const s = buildSummary({ events, grants, goal: { date: '2026-07-08', text: '3 focus hours', target: null }, groups });
    expect(s.goal?.text).toBe('3 focus hours');
    expect(s.shieldShown).toEqual({ Social: 2 });
    expect(s.shieldTaps).toBe(1);
    expect(s.thresholdsCrossed).toEqual([{ group: 'Social', thresholdMinutes: 30, at: '2026-07-08T14:00:00.000Z' }]);
    expect(s.grantsUsed).toEqual([{ group: 'Social', minutes: 15, reason: 'on the bus' }]);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run test/domain.test.ts`
Expected: FAIL — cannot find module `../src/domain.js`.

- [ ] **Step 3: Implement domain.ts**

`server/src/domain.ts`:

```ts
import type { Group, Device, Grant, Goal, EventRow } from './types.js';

export function matchGroup(groups: Group[], query: string): Group | null {
  const q = query.trim().toLowerCase();
  const exact = groups.filter((g) => g.name.toLowerCase() === q);
  if (exact.length === 1) return exact[0];
  const prefix = groups.filter((g) => g.name.toLowerCase().startsWith(q));
  if (prefix.length === 1) return prefix[0];
  const substr = groups.filter((g) => g.name.toLowerCase().includes(q));
  if (substr.length === 1) return substr[0];
  return null;
}

export function deliveryState(
  updatedAt: string,
  devices: Device[],
): 'applied' | 'pending' | 'no_device_registered' {
  if (devices.length === 0) return 'no_device_registered';
  const applied = devices.some(
    (d) => d.appliedThrough !== null && new Date(d.appliedThrough) >= new Date(updatedAt),
  );
  return applied ? 'applied' : 'pending';
}

export function grantRemainingMinutes(grant: Grant, now: Date): number {
  const ms = new Date(grant.expiresAt).getTime() - now.getTime();
  return Math.max(0, Math.ceil(ms / 60_000));
}

export function todayInTz(timezone: string, now: Date = new Date()): string {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: timezone, year: 'numeric', month: '2-digit', day: '2-digit',
  }).format(now);
}

export interface Summary {
  goal: Goal | null;
  shieldShown: Record<string, number>;
  shieldTaps: number;
  thresholdsCrossed: Array<{ group: string; thresholdMinutes: number; at: string }>;
  grantsUsed: Array<{ group: string; minutes: number; reason: string | null }>;
}

export function buildSummary(input: {
  events: EventRow[];
  grants: Grant[];
  goal: Goal | null;
  groups: Group[];
}): Summary {
  const nameOf = (groupId: string | null): string =>
    input.groups.find((g) => g.id === groupId)?.name ?? 'unknown';

  const shieldShown: Record<string, number> = {};
  let shieldTaps = 0;
  const thresholdsCrossed: Summary['thresholdsCrossed'] = [];

  for (const e of input.events) {
    if (e.type === 'shield_shown') {
      const name = nameOf(e.groupId);
      shieldShown[name] = (shieldShown[name] ?? 0) + 1;
    } else if (e.type === 'shield_action_tapped') {
      shieldTaps++;
    } else if (e.type === 'threshold_crossed') {
      thresholdsCrossed.push({
        group: nameOf(e.groupId),
        thresholdMinutes: Number(e.meta.thresholdMinutes ?? 0),
        at: e.ts,
      });
    }
  }

  return {
    goal: input.goal,
    shieldShown,
    shieldTaps,
    thresholdsCrossed,
    grantsUsed: input.grants.map((g) => ({
      group: nameOf(g.groupId), minutes: g.minutes, reason: g.reason,
    })),
  };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run test/domain.test.ts`
Expected: all passed.

- [ ] **Step 5: Commit**

```bash
cd /Users/vk/VKDEV/screencp
git add server
git commit -m "feat(server): pure domain logic (group matching, delivery state, summary)"
```

---

### Task 5: MCP server with all 11 tools

**Files:**
- Create: `server/src/mcp.ts`
- Test: `server/test/tools.test.ts`

**Interfaces:**
- Consumes: `Repo` (Task 2/3), `Push` (Task 2 stub), `Config` (Task 1), domain functions (Task 4). SDK: `McpServer` from `@modelcontextprotocol/sdk/server/mcp.js`, `InMemoryTransport` from `@modelcontextprotocol/sdk/inMemory.js` (tests), `Client` from `@modelcontextprotocol/sdk/client/index.js` (tests).
- Produces: `buildMcpServer(deps: { repo: Repo; push: Push; config: Config; now?: () => Date }): McpServer`. Used by `app.ts` (Task 8). Tool names/args exactly as spec §6.

Every tool result is one JSON text block. Every mutating tool: writes via `repo`, fires `push.policyChanged(changedAt, description)`, returns `delivery` computed by `deliveryState(...)` (always `pending`/`no_device_registered` immediately after a fresh write — honest by construction).

- [ ] **Step 1: Write the failing test**

`server/test/tools.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { buildMcpServer } from '../src/mcp.js';
import { FakeRepo, FakePush } from './fakes.js';
import type { Config } from '../src/config.js';

const NOW = new Date('2026-07-08T12:00:00Z'); // 05:00 Jul 8 in LA

const config: Config = {
  port: 0, databaseUrl: '', mcpBearerToken: 'x', deviceBearerToken: 'y',
  maxGrantMinutes: 60, timezone: 'America/Los_Angeles', apns: null,
};

async function setup() {
  const repo = new FakeRepo();
  const push = new FakePush();
  const server = buildMcpServer({ repo, push, config, now: () => NOW });
  const client = new Client({ name: 'test', version: '0.0.0' });
  const [ct, st] = InMemoryTransport.createLinkedPair();
  await Promise.all([server.connect(st), client.connect(ct)]);
  const call = async (name: string, args: Record<string, unknown> = {}) => {
    const r = await client.callTool({ name, arguments: args });
    const text = (r.content as Array<{ type: string; text: string }>)[0].text;
    return { json: JSON.parse(text), isError: r.isError === true };
  };
  return { repo, push, call };
}

describe('MCP tools', () => {
  it('lists all 11 tools', async () => {
    const { repo, push } = { repo: new FakeRepo(), push: new FakePush() };
    const server = buildMcpServer({ repo, push, config, now: () => NOW });
    const client = new Client({ name: 't', version: '0' });
    const [ct, st] = InMemoryTransport.createLinkedPair();
    await Promise.all([server.connect(st), client.connect(ct)]);
    const { tools } = await client.listTools();
    expect(tools.map((t) => t.name).sort()).toEqual([
      'block_now', 'create_group', 'get_status', 'get_today_summary', 'grant_temp_access',
      'list_groups', 'remove_policy', 'set_goal', 'set_limit', 'set_schedule', 'unblock',
    ]);
  });

  it('create_group returns setup instruction; duplicate is an error', async () => {
    const { call } = await setup();
    const r = await call('create_group', { name: 'Social' });
    expect(r.json.group.name).toBe('Social');
    expect(r.json.note).toMatch(/open the ScreenCP iOS app/);
    const dup = await call('create_group', { name: 'Social' });
    expect(dup.isError).toBe(true);
  });

  it('unknown group name errors and lists existing groups', async () => {
    const { call } = await setup();
    await call('create_group', { name: 'Social' });
    const r = await call('set_limit', { group: 'Games', minutes_per_day: 30 });
    expect(r.isError).toBe(true);
    expect(r.json.error).toMatch(/No group matches "Games"/);
    expect(r.json.error).toMatch(/Social/);
  });

  it('set_limit creates a policy, fires push, reports no_device_registered', async () => {
    const { repo, push, call } = await setup();
    await call('create_group', { name: 'Social' });
    const r = await call('set_limit', { group: 'social', minutes_per_day: 30 });
    expect(r.json.policy.kind).toBe('limit');
    expect(r.json.policy.minutesPerDay).toBe(30);
    expect(r.json.delivery).toBe('no_device_registered');
    expect(r.json.setup_required).toMatch(/no apps selected/); // group unpopulated
    expect(push.calls).toHaveLength(1);
    expect((await repo.listPolicies(true))).toHaveLength(1);
  });

  it('delivery is pending with an unacked device, applied after ack', async () => {
    const { repo, call } = await setup();
    await call('create_group', { name: 'Social' });
    await repo.registerDevice('tok1');
    const r = await call('set_limit', { group: 'Social', minutes_per_day: 30 });
    expect(r.json.delivery).toBe('pending');
    await repo.ackDevice('tok1', new Date(Date.now() + 60_000));
    const s = await call('get_status');
    expect(s.json.policies[0].delivery).toBe('applied');
  });

  it('set_schedule maps day names to numbers', async () => {
    const { repo, call } = await setup();
    await call('create_group', { name: 'Work Distractions' });
    const r = await call('set_schedule', {
      group: 'work', days: ['mon', 'tue', 'wed', 'thu', 'fri'], start: '09:00', end: '17:00',
    });
    expect(r.json.policy.daysOfWeek).toEqual([1, 2, 3, 4, 5]);
    expect(r.json.policy.timezone).toBe('America/Los_Angeles');
    expect((await repo.listPolicies(true))[0].startTime).toBe('09:00');
  });

  it('grant_temp_access clamps to the server max and notes it', async () => {
    const { call } = await setup();
    await call('create_group', { name: 'Social' });
    const r = await call('grant_temp_access', { group: 'Social', minutes: 480, reason: 'marathon' });
    expect(r.json.grant.minutes).toBe(60);
    expect(r.json.note).toMatch(/capped at 60/);
    expect(r.json.grant.expiresAt).toBe('2026-07-08T13:00:00.000Z');
  });

  it('block_now + unblock lifecycle', async () => {
    const { repo, call } = await setup();
    await call('create_group', { name: 'Social' });
    await call('block_now', { group: 'Social' });
    expect((await repo.listPolicies(true)).filter(p => p.kind === 'block')).toHaveLength(1);
    const r = await call('unblock', { group: 'Social' });
    expect(r.json.removed_blocks).toBe(1);
    expect((await repo.listPolicies(true)).filter(p => p.kind === 'block')).toHaveLength(0);
  });

  it('unblock warns about other active policies still standing', async () => {
    const { call } = await setup();
    await call('create_group', { name: 'Social' });
    await call('set_limit', { group: 'Social', minutes_per_day: 30 });
    await call('block_now', { group: 'Social' });
    const r = await call('unblock', { group: 'Social' });
    expect(r.json.still_active).toEqual([{ kind: 'limit', minutesPerDay: 30 }]);
  });

  it('remove_policy deactivates by kind', async () => {
    const { repo, call } = await setup();
    await call('create_group', { name: 'Social' });
    await call('set_limit', { group: 'Social', minutes_per_day: 30 });
    const r = await call('remove_policy', { group: 'Social', kind: 'limit' });
    expect(r.json.removed).toBe(1);
    expect(await repo.listPolicies(true)).toHaveLength(0);
  });

  it('set_goal + get_today_summary aggregate the day', async () => {
    const { repo, call } = await setup();
    const { json: created } = await call('create_group', { name: 'Social' });
    await call('set_goal', { text: '3 focus hours' });
    await repo.insertEvents([
      { type: 'shield_shown', groupId: created.group.id, ts: '2026-07-08T11:00:00Z' },
      { type: 'threshold_crossed', groupId: created.group.id, ts: '2026-07-08T11:30:00Z', meta: { thresholdMinutes: 30 } },
    ]);
    await call('grant_temp_access', { group: 'Social', minutes: 15, reason: 'bus' });
    const r = await call('get_today_summary');
    expect(r.json.date).toBe('2026-07-08');
    expect(r.json.goal.text).toBe('3 focus hours');
    expect(r.json.shieldShown).toEqual({ Social: 1 });
    expect(r.json.thresholdsCrossed[0].thresholdMinutes).toBe(30);
    expect(r.json.grantsUsed).toEqual([{ group: 'Social', minutes: 15, reason: 'bus' }]);
  });

  it('get_status expires overdue grants and shows remaining minutes on live ones', async () => {
    const { repo, call } = await setup();
    const { json: created } = await call('create_group', { name: 'Social' });
    await repo.createGrant(created.group.id, 15, null, new Date('2026-07-08T11:59:00Z')); // overdue at NOW
    await repo.createGrant(created.group.id, 15, 'bus', new Date('2026-07-08T12:10:00Z'));
    const r = await call('get_status');
    expect(r.json.grants).toHaveLength(1);
    expect(r.json.grants[0].remainingMinutes).toBe(10);
    const all = await repo.listGrants();
    expect(all.find((x) => x.expiresAt === '2026-07-08T11:59:00.000Z')?.status).toBe('expired');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run test/tools.test.ts`
Expected: FAIL — cannot find module `../src/mcp.js`.

- [ ] **Step 3: Implement mcp.ts**

`server/src/mcp.ts`:

```ts
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import type { Repo } from './repo.js';
import type { Push } from './push.js';
import type { Config } from './config.js';
import type { Group, Policy } from './types.js';
import {
  matchGroup, deliveryState, grantRemainingMinutes, todayInTz, buildSummary,
} from './domain.js';

export interface Deps {
  repo: Repo;
  push: Push;
  config: Config;
  now?: () => Date;
}

const DAY_NUM: Record<string, number> = { sun: 0, mon: 1, tue: 2, wed: 3, thu: 4, fri: 5, sat: 6 };
const dayEnum = z.enum(['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat']);
const hhmm = z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/, 'must be HH:MM 24h');

type ToolResult = {
  content: Array<{ type: 'text'; text: string }>;
  isError?: boolean;
};

const ok = (obj: unknown): ToolResult => ({
  content: [{ type: 'text', text: JSON.stringify(obj) }],
});
const fail = (message: string): ToolResult => ({
  content: [{ type: 'text', text: JSON.stringify({ error: message }) }],
  isError: true,
});

const policyView = (p: Policy) => ({
  id: p.id, kind: p.kind,
  ...(p.daysOfWeek ? { daysOfWeek: p.daysOfWeek } : {}),
  ...(p.startTime ? { startTime: p.startTime, endTime: p.endTime } : {}),
  ...(p.minutesPerDay != null ? { minutesPerDay: p.minutesPerDay } : {}),
  ...(p.until ? { until: p.until } : {}),
  ...(p.timezone ? { timezone: p.timezone } : {}),
});

export function buildMcpServer(deps: Deps): McpServer {
  const now = deps.now ?? (() => new Date());
  const { repo, config } = deps;
  const server = new McpServer({ name: 'screencp', version: '0.1.0' });

  async function findGroup(name: string): Promise<{ group: Group } | { error: ToolResult }> {
    const groups = await repo.listGroups();
    const group = matchGroup(groups, name);
    if (!group) {
      const names = groups.map((g) => g.name).join(', ') || '(none — use create_group first)';
      return { error: fail(`No group matches "${name}". Existing groups: ${names}`) };
    }
    return { group };
  }

  const setupNote = (group: Group) =>
    group.hasSelection
      ? {}
      : { setup_required: `Group "${group.name}" has no apps selected yet. The user must open the ScreenCP iOS app and pick apps for this group before enforcement takes effect.` };

  async function afterMutation(description: string, updatedAt: string) {
    deps.push.policyChanged(new Date(updatedAt), description);
    return deliveryState(updatedAt, await repo.listDevices());
  }

  server.registerTool('get_status', {
    title: 'Get current blocking status',
    description:
      'Read-only. Returns every group, its active policies (schedules, daily limits, blocks), active temporary grants with minutes remaining, and per-policy delivery state (applied = live on the device; pending = device has not applied it yet; no_device_registered = the iOS app has never connected).',
    inputSchema: {},
    annotations: { readOnlyHint: true },
  }, async () => {
    await repo.expireGrants(now());
    const [groups, policies, grants, devices] = await Promise.all([
      repo.listGroups(), repo.listPolicies(true),
      repo.listGrants(['pending', 'active']), repo.listDevices(),
    ]);
    const nameOf = (id: string) => groups.find((g) => g.id === id)?.name ?? 'unknown';
    return ok({
      groups: groups.map((g) => ({ name: g.name, hasSelection: g.hasSelection })),
      policies: policies.map((p) => ({
        group: nameOf(p.groupId), ...policyView(p),
        delivery: deliveryState(p.updatedAt, devices),
      })),
      grants: grants.map((g) => ({
        group: nameOf(g.groupId), minutes: g.minutes, reason: g.reason,
        remainingMinutes: grantRemainingMinutes(g, now()),
        delivery: deliveryState(g.updatedAt, devices),
      })),
      device_connected: devices.length > 0,
    });
  });

  server.registerTool('list_groups', {
    title: 'List app groups',
    description:
      'Read-only. Lists the named app groups (e.g. "Social") with whether each has apps selected on the device and how many active policies it carries. Apps can only be added to a group by the user in the iOS app (Apple privacy rule).',
    inputSchema: {},
    annotations: { readOnlyHint: true },
  }, async () => {
    const [groups, policies] = await Promise.all([repo.listGroups(), repo.listPolicies(true)]);
    return ok({
      groups: groups.map((g) => ({
        name: g.name,
        hasSelection: g.hasSelection,
        activePolicies: policies.filter((p) => p.groupId === g.id).length,
      })),
    });
  });

  server.registerTool('create_group', {
    title: 'Create an app group',
    description:
      'Creates a new empty named group (e.g. "Doomscroll"). The user must then open the ScreenCP iOS app to pick which apps belong to it — that step cannot be done from chat (Apple privacy rule). Tell the user to do this.',
    inputSchema: { name: z.string().min(1).max(60) },
  }, async ({ name }) => {
    try {
      const group = await repo.createGroup(name.trim());
      return ok({
        group: { id: group.id, name: group.name },
        note: 'Group created. Now open the ScreenCP iOS app and select which apps belong to this group — enforcement starts once apps are selected.',
      });
    } catch {
      return fail(`A group named "${name}" already exists.`);
    }
  });

  server.registerTool('set_schedule', {
    title: 'Set a recurring block schedule',
    description:
      'Blocks a group during a recurring weekly window (e.g. weekdays 09:00-17:00). Replaces any existing schedule on the group. Times are 24h HH:MM in the given timezone (defaults to the user\'s home timezone).',
    inputSchema: {
      group: z.string(),
      days: z.array(dayEnum).min(1),
      start: hhmm,
      end: hhmm,
      timezone: z.string().optional(),
    },
  }, async ({ group: name, days, start, end, timezone }) => {
    const found = await findGroup(name);
    if ('error' in found) return found.error;
    const policy = await repo.replacePolicy(found.group.id, 'schedule', {
      daysOfWeek: [...new Set(days.map((d) => DAY_NUM[d]))].sort(),
      startTime: start, endTime: end, timezone: timezone ?? config.timezone,
    });
    const delivery = await afterMutation(`Schedule for ${found.group.name}`, policy.updatedAt);
    return ok({ policy: policyView(policy), group: found.group.name, delivery, ...setupNote(found.group) });
  });

  server.registerTool('set_limit', {
    title: 'Set a daily time limit',
    description:
      'Caps a group\'s total usage per day (e.g. TikTok group: 30 minutes/day). The device shields the group once the limit is reached. Replaces any existing limit on the group.',
    inputSchema: { group: z.string(), minutes_per_day: z.number().int().min(1).max(1440) },
  }, async ({ group: name, minutes_per_day }) => {
    const found = await findGroup(name);
    if ('error' in found) return found.error;
    const policy = await repo.replacePolicy(found.group.id, 'limit', { minutesPerDay: minutes_per_day });
    const delivery = await afterMutation(`Daily limit for ${found.group.name}`, policy.updatedAt);
    return ok({ policy: policyView(policy), group: found.group.name, delivery, ...setupNote(found.group) });
  });

  server.registerTool('block_now', {
    title: 'Block a group immediately',
    description:
      'Shields a group right now — indefinitely, or until the given ISO-8601 time. Use unblock to lift it.',
    inputSchema: { group: z.string(), until: z.string().datetime().optional() },
  }, async ({ group: name, until }) => {
    const found = await findGroup(name);
    if ('error' in found) return found.error;
    const policy = await repo.replacePolicy(found.group.id, 'block', { until: until ?? null });
    const delivery = await afterMutation(`Block ${found.group.name} now`, policy.updatedAt);
    return ok({ policy: policyView(policy), group: found.group.name, delivery, ...setupNote(found.group) });
  });

  server.registerTool('unblock', {
    title: 'Remove an active block',
    description:
      'Removes any immediate block on a group. Schedules and daily limits on the group stay active — the response lists them so you can tell the user what still applies. For a short exception prefer grant_temp_access.',
    inputSchema: { group: z.string() },
    annotations: { destructiveHint: true },
  }, async ({ group: name }) => {
    const found = await findGroup(name);
    if ('error' in found) return found.error;
    const removed = await repo.deactivatePolicies(found.group.id, 'block');
    const remaining = (await repo.listPolicies(true)).filter((p) => p.groupId === found.group.id);
    const changedAt = now().toISOString();
    const delivery = await afterMutation(`Unblock ${found.group.name}`, changedAt);
    return ok({
      group: found.group.name,
      removed_blocks: removed,
      still_active: remaining.map((p) => {
        const v = policyView(p);
        return { kind: v.kind, ...(v.minutesPerDay != null ? { minutesPerDay: v.minutesPerDay } : {}), ...(v.startTime ? { startTime: v.startTime, endTime: v.endTime } : {}) };
      }),
      delivery,
    });
  });

  server.registerTool('grant_temp_access', {
    title: 'Grant temporary access',
    description:
      `Temporarily lifts blocking on a group for N minutes (max ${'`'}MAX_GRANT_MINUTES${'`'}, default 60 — longer requests are capped; use unblock for open-ended access). The device automatically re-blocks when the grant expires. Log the user's reason when given — it feeds coaching.`,
    inputSchema: {
      group: z.string(),
      minutes: z.number().int().min(1),
      reason: z.string().max(200).optional(),
    },
  }, async ({ group: name, minutes, reason }) => {
    const found = await findGroup(name);
    if ('error' in found) return found.error;
    const capped = Math.min(minutes, config.maxGrantMinutes);
    const expiresAt = new Date(now().getTime() + capped * 60_000);
    const grant = await repo.createGrant(found.group.id, capped, reason ?? null, expiresAt);
    const delivery = await afterMutation(`Allow ${found.group.name} for ${capped} min`, grant.updatedAt);
    return ok({
      grant: { id: grant.id, minutes: capped, expiresAt: grant.expiresAt, reason: grant.reason },
      group: found.group.name,
      delivery,
      ...(capped < minutes ? { note: `Requested ${minutes} min but grants are capped at ${config.maxGrantMinutes} min. Use unblock for longer access.` } : {}),
      ...setupNote(found.group),
    });
  });

  server.registerTool('remove_policy', {
    title: 'Remove a policy',
    description:
      'Deactivates a group\'s policy of the given kind (schedule, limit, or block). Confirm with the user before removing protective policies.',
    inputSchema: { group: z.string(), kind: z.enum(['schedule', 'limit', 'block']) },
    annotations: { destructiveHint: true },
  }, async ({ group: name, kind }) => {
    const found = await findGroup(name);
    if ('error' in found) return found.error;
    const removed = await repo.deactivatePolicies(found.group.id, kind);
    if (removed === 0) return fail(`Group "${found.group.name}" has no active ${kind} policy.`);
    const delivery = await afterMutation(`Remove ${kind} from ${found.group.name}`, now().toISOString());
    return ok({ group: found.group.name, kind, removed, delivery });
  });

  server.registerTool('set_goal', {
    title: 'Set today\'s goal',
    description:
      'Sets or replaces the user\'s goal for today (e.g. "3 focus hours"). Referenced by get_today_summary for coaching.',
    inputSchema: { text: z.string().min(1).max(300), target: z.string().max(60).optional() },
  }, async ({ text: goalText, target }) => {
    const date = todayInTz(config.timezone, now());
    const goal = await repo.upsertGoal(date, goalText, target ?? null);
    return ok({ goal });
  });

  server.registerTool('get_today_summary', {
    title: 'Get adherence summary',
    description:
      'Read-only. Coaching data for a date (default today): the goal, how many times each group\'s shield appeared, shield-bypass taps, usage thresholds crossed (coarse usage signal — exact minute totals are not available off-device by Apple policy), and temporary grants used with reasons.',
    inputSchema: { date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional() },
    annotations: { readOnlyHint: true },
  }, async ({ date }) => {
    const day = date ?? todayInTz(config.timezone, now());
    await repo.expireGrants(now());
    const [events, allGrants, goal, groups] = await Promise.all([
      repo.listEventsOn(day, config.timezone),
      repo.listGrants(),
      repo.getGoal(day),
      repo.listGroups(),
    ]);
    const dayGrants = allGrants.filter(
      (g) => todayInTz(config.timezone, new Date(g.startsAt)) === day && g.status !== 'cancelled',
    );
    return ok({ date: day, ...buildSummary({ events, grants: dayGrants, goal, groups }) });
  });

  return server;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run test/tools.test.ts`
Expected: 12 passed.

- [ ] **Step 5: Run the whole suite + typecheck**

Run: `npx tsc -p tsconfig.json --noEmit && npx vitest run`
Expected: clean typecheck; all suites pass (repo integration skipped without `DATABASE_URL`).

- [ ] **Step 6: Commit**

```bash
cd /Users/vk/VKDEV/screencp
git add server
git commit -m "feat(server): MCP server with all 11 screen-time tools"
```

---

### Task 6: Push delivery ladder + APNs sender

**Files:**
- Modify: `server/src/push.ts` (append below the `Push` interface from Task 2)
- Test: `server/test/push.test.ts`

**Interfaces:**
- Consumes: `Repo` (for device tokens + ack check), `ApnsConfig` from `config.ts`.
- Produces (used by `index.ts` in Task 8):
  - `interface PushSender { sendSilent(token: string): Promise<void>; sendVisible(token: string, title: string, body: string): Promise<void> }`
  - `class Ladder implements Push { constructor(repo: Repo, sender: PushSender, fallbackMs?: number) }` — implements spec §7 rungs 2–3: silent push immediately; if no device has acked past `changedAt` after `fallbackMs` (default 15 000), send a visible Time-Sensitive notification. Rung 1 (Realtime) and rung 4 (reconcile-on-open) are device-side (Plan 2).
  - `class ApnsSender implements PushSender` (apns2 adapter) and `class NoopSender implements PushSender` (used when APNs env is unset).

- [ ] **Step 1: Write the failing test**

`server/test/push.test.ts`:

```ts
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { Ladder, type PushSender } from '../src/push.js';
import { FakeRepo } from './fakes.js';

class RecordingSender implements PushSender {
  silent: string[] = [];
  visible: Array<{ token: string; body: string }> = [];
  async sendSilent(token: string) { this.silent.push(token); }
  async sendVisible(token: string, _title: string, body: string) { this.visible.push({ token, body }); }
}

describe('Ladder', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it('sends silent immediately, then visible fallback when no ack arrives', async () => {
    const repo = new FakeRepo();
    await repo.registerDevice('tok1');
    const sender = new RecordingSender();
    const ladder = new Ladder(repo, sender, 15_000);

    ladder.policyChanged(new Date(), 'Block Social now');
    await vi.advanceTimersByTimeAsync(0);
    expect(sender.silent).toEqual(['tok1']);
    expect(sender.visible).toHaveLength(0);

    await vi.advanceTimersByTimeAsync(15_000);
    expect(sender.visible).toEqual([{ token: 'tok1', body: 'Tap to apply: Block Social now' }]);
  });

  it('skips the visible fallback when a device acks in time', async () => {
    const repo = new FakeRepo();
    await repo.registerDevice('tok1');
    const sender = new RecordingSender();
    const ladder = new Ladder(repo, sender, 15_000);

    const changedAt = new Date();
    ladder.policyChanged(changedAt, 'Block Social now');
    await vi.advanceTimersByTimeAsync(0);
    await repo.ackDevice('tok1', new Date(changedAt.getTime() + 1000));

    await vi.advanceTimersByTimeAsync(15_000);
    expect(sender.visible).toHaveLength(0);
  });

  it('does nothing (and does not throw) with zero devices', async () => {
    const ladder = new Ladder(new FakeRepo(), new RecordingSender(), 15_000);
    expect(() => ladder.policyChanged(new Date(), 'x')).not.toThrow();
    await vi.advanceTimersByTimeAsync(15_000);
  });

  it('survives sender failures silently', async () => {
    const repo = new FakeRepo();
    await repo.registerDevice('tok1');
    const failing: PushSender = {
      sendSilent: async () => { throw new Error('apns down'); },
      sendVisible: async () => { throw new Error('apns down'); },
    };
    const ladder = new Ladder(repo, failing, 1000);
    ladder.policyChanged(new Date(), 'x');
    await vi.advanceTimersByTimeAsync(1000); // no unhandled rejection = pass
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run test/push.test.ts`
Expected: FAIL — `Ladder` not exported from `../src/push.js`.

- [ ] **Step 3: Implement Ladder, ApnsSender, NoopSender**

Append to `server/src/push.ts` (below the existing `Push` interface):

```ts
import type { Repo } from './repo.js';
import type { ApnsConfig } from './config.js';

export interface PushSender {
  sendSilent(token: string): Promise<void>;
  sendVisible(token: string, title: string, body: string): Promise<void>;
}

/**
 * Spec §7 rungs 2–3. Silent push immediately (best-effort); if no device has
 * acked past `changedAt` after `fallbackMs`, send a visible Time-Sensitive
 * "Tap to apply" notification (guaranteed-delivery rung).
 */
export class Ladder implements Push {
  constructor(
    private repo: Repo,
    private sender: PushSender,
    private fallbackMs = 15_000,
  ) {}

  policyChanged(changedAt: Date, description: string): void {
    void this.run(changedAt, description).catch(() => { /* push is never fatal */ });
  }

  private async run(changedAt: Date, description: string): Promise<void> {
    const devices = await this.repo.listDevices();
    if (devices.length === 0) return;
    await Promise.all(
      devices.map((d) => this.sender.sendSilent(d.apnsToken).catch(() => {})),
    );
    const timer = setTimeout(() => {
      void (async () => {
        const latest = await this.repo.listDevices();
        const acked = latest.some(
          (d) => d.appliedThrough !== null && new Date(d.appliedThrough) >= changedAt,
        );
        if (acked) return;
        await Promise.all(
          latest.map((d) =>
            this.sender.sendVisible(d.apnsToken, 'ScreenCP', `Tap to apply: ${description}`).catch(() => {}),
          ),
        );
      })().catch(() => {});
    }, this.fallbackMs);
    timer.unref?.();
  }
}

/** Used when APNs env vars are unset (e.g. before Plan 2 registers a device). */
export class NoopSender implements PushSender {
  async sendSilent() {}
  async sendVisible() {}
}

/**
 * apns2 adapter. Verify option names against the installed apns2 README
 * (https://github.com/AndrewBarba/apns2) when wiring — the shapes below match v11.
 */
export class ApnsSender implements PushSender {
  private client: import('apns2').ApnsClient;
  private Notification: typeof import('apns2').Notification;
  private SilentNotification: typeof import('apns2').SilentNotification;

  private constructor(
    client: import('apns2').ApnsClient,
    N: typeof import('apns2').Notification,
    S: typeof import('apns2').SilentNotification,
  ) {
    this.client = client;
    this.Notification = N;
    this.SilentNotification = S;
  }

  static async create(cfg: ApnsConfig): Promise<ApnsSender> {
    const { ApnsClient, Notification, SilentNotification } = await import('apns2');
    const client = new ApnsClient({
      team: cfg.teamId,
      keyId: cfg.keyId,
      signingKey: cfg.key,
      defaultTopic: cfg.topic,
      host: cfg.production ? 'api.push.apple.com' : 'api.sandbox.push.apple.com',
    });
    return new ApnsSender(client, Notification, SilentNotification);
  }

  async sendSilent(token: string): Promise<void> {
    await this.client.send(new this.SilentNotification(token));
  }

  async sendVisible(token: string, title: string, body: string): Promise<void> {
    await this.client.send(
      new this.Notification(token, {
        alert: { title, body },
        // Time-Sensitive so it pierces Focus modes (spec §7 rung 3).
        aps: { 'interruption-level': 'time-sensitive' },
      }),
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx tsc -p tsconfig.json --noEmit && npx vitest run test/push.test.ts`
Expected: typecheck clean (fix apns2 option-name types against the installed version if the compiler disagrees — the ladder tests must stay green regardless); 4 passed.

- [ ] **Step 5: Commit**

```bash
cd /Users/vk/VKDEV/screencp
git add server
git commit -m "feat(server): push delivery ladder with silent->visible fallback and APNs adapter"
```

---

### Task 7: Device API (register / sync / ack / events)

**Files:**
- Create: `server/src/deviceApi.ts`
- Test: `server/test/deviceApi.test.ts`

**Interfaces:**
- Consumes: `Repo`, `Config`.
- Produces: `makeDeviceRouter(deps: { repo: Repo; config: Config }): express.Router` mounted at `/device` by `app.ts` (Task 8). Routes (all require `Authorization: Bearer <DEVICE_BEARER_TOKEN>`):
  - `POST /device/register` `{ apnsToken }` → `{ device }`
  - `GET /device/sync?since=<ISO>` → `SyncPayload` (full payload when `since` omitted); also expires overdue grants first
  - `POST /device/ack` `{ apnsToken, appliedThrough }` → `{ ok: true }`
  - `POST /device/events` `{ events: NewEvent[] }` → `{ inserted }`
  - `POST /device/groups/:id/selection` `{ hasSelection }` → `{ ok: true }` (device reports picker state so `has_selection` stays truthful)

- [ ] **Step 1: Write the failing test**

`server/test/deviceApi.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import express from 'express';
import request from 'supertest';
import { makeDeviceRouter } from '../src/deviceApi.js';
import { FakeRepo } from './fakes.js';
import type { Config } from '../src/config.js';

const config: Config = {
  port: 0, databaseUrl: '', mcpBearerToken: 'mcp-secret', deviceBearerToken: 'device-secret',
  maxGrantMinutes: 60, timezone: 'America/Los_Angeles', apns: null,
};

function makeApp(repo = new FakeRepo()) {
  const app = express();
  app.use(express.json());
  app.use('/device', makeDeviceRouter({ repo, config }));
  return { app, repo };
}

const auth = { Authorization: 'Bearer device-secret' };

describe('device API', () => {
  it('rejects missing/wrong bearer', async () => {
    const { app } = makeApp();
    await request(app).post('/device/register').send({ apnsToken: 't' }).expect(401);
    await request(app).post('/device/register')
      .set('Authorization', 'Bearer wrong').send({ apnsToken: 't' }).expect(401);
  });

  it('registers a device (idempotent) and acks progress', async () => {
    const { app, repo } = makeApp();
    const r1 = await request(app).post('/device/register').set(auth).send({ apnsToken: 'tok1' }).expect(200);
    expect(r1.body.device.apnsToken).toBe('tok1');
    await request(app).post('/device/register').set(auth).send({ apnsToken: 'tok1' }).expect(200);
    expect(await repo.listDevices()).toHaveLength(1);

    await request(app).post('/device/ack').set(auth)
      .send({ apnsToken: 'tok1', appliedThrough: '2026-07-08T12:00:00Z' }).expect(200);
    expect((await repo.listDevices())[0].appliedThrough).toBe('2026-07-08T12:00:00.000Z');
  });

  it('sync returns full payload without since, delta with since, and expires grants', async () => {
    const { app, repo } = makeApp();
    const g = await repo.createGroup('Social');
    await repo.replacePolicy(g.id, 'limit', { minutesPerDay: 30 });
    await repo.createGrant(g.id, 15, null, new Date(Date.now() - 1000)); // already overdue

    const full = await request(app).get('/device/sync').set(auth).expect(200);
    expect(full.body.groups).toHaveLength(1);
    expect(full.body.policies).toHaveLength(1);
    expect(full.body.grants[0].status).toBe('expired'); // sync expired it
    expect(full.body.serverTime).toBeTruthy();

    const future = new Date(Date.now() + 60_000).toISOString();
    const delta = await request(app).get('/device/sync').set(auth)
      .query({ since: future }).expect(200);
    expect(delta.body.groups).toHaveLength(0);
  });

  it('rejects an invalid since parameter', async () => {
    const { app } = makeApp();
    await request(app).get('/device/sync').set(auth).query({ since: 'not-a-date' }).expect(400);
  });

  it('accepts event batches and group selection updates', async () => {
    const { app, repo } = makeApp();
    const g = await repo.createGroup('Social');

    const r = await request(app).post('/device/events').set(auth).send({
      events: [
        { type: 'shield_shown', groupId: g.id, ts: '2026-07-08T11:00:00Z' },
        { type: 'threshold_crossed', groupId: g.id, meta: { thresholdMinutes: 30 } },
      ],
    }).expect(200);
    expect(r.body.inserted).toBe(2);

    await request(app).post(`/device/groups/${g.id}/selection`).set(auth)
      .send({ hasSelection: true }).expect(200);
    expect((await repo.listGroups())[0].hasSelection).toBe(true);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run test/deviceApi.test.ts`
Expected: FAIL — cannot find module `../src/deviceApi.js`.

- [ ] **Step 3: Implement deviceApi.ts**

`server/src/deviceApi.ts`:

```ts
import { Router, type Request, type Response, type NextFunction } from 'express';
import { z } from 'zod';
import type { Repo } from './repo.js';
import type { Config } from './config.js';

export function makeDeviceRouter(deps: { repo: Repo; config: Config }): Router {
  const { repo, config } = deps;
  const router = Router();

  router.use((req: Request, res: Response, next: NextFunction) => {
    const token = (req.headers.authorization ?? '').replace(/^Bearer\s+/i, '');
    if (token !== config.deviceBearerToken) {
      res.status(401).json({ error: 'unauthorized' });
      return;
    }
    next();
  });

  router.post('/register', async (req, res) => {
    const body = z.object({ apnsToken: z.string().min(1) }).safeParse(req.body);
    if (!body.success) { res.status(400).json({ error: body.error.message }); return; }
    const device = await repo.registerDevice(body.data.apnsToken);
    res.json({ device });
  });

  router.get('/sync', async (req, res) => {
    let since: Date | null = null;
    if (typeof req.query.since === 'string' && req.query.since !== '') {
      const parsed = new Date(req.query.since);
      if (Number.isNaN(parsed.getTime())) {
        res.status(400).json({ error: 'invalid since (expect ISO-8601)' });
        return;
      }
      since = parsed;
    }
    await repo.expireGrants(new Date());
    res.json(await repo.changesSince(since));
  });

  router.post('/ack', async (req, res) => {
    const body = z.object({
      apnsToken: z.string().min(1),
      appliedThrough: z.string().datetime({ offset: true }).or(z.string().datetime()),
    }).safeParse(req.body);
    if (!body.success) { res.status(400).json({ error: body.error.message }); return; }
    await repo.ackDevice(body.data.apnsToken, new Date(body.data.appliedThrough));
    res.json({ ok: true });
  });

  router.post('/events', async (req, res) => {
    const body = z.object({
      events: z.array(z.object({
        type: z.string().min(1),
        groupId: z.string().uuid().nullish(),
        ts: z.string().datetime({ offset: true }).or(z.string().datetime()).optional(),
        meta: z.record(z.unknown()).optional(),
      })).max(500),
    }).safeParse(req.body);
    if (!body.success) { res.status(400).json({ error: body.error.message }); return; }
    const inserted = await repo.insertEvents(body.data.events);
    res.json({ inserted });
  });

  router.post('/groups/:id/selection', async (req, res) => {
    const body = z.object({ hasSelection: z.boolean() }).safeParse(req.body);
    if (!body.success) { res.status(400).json({ error: body.error.message }); return; }
    await repo.setGroupSelection(req.params.id, body.data.hasSelection);
    res.json({ ok: true });
  });

  return router;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run test/deviceApi.test.ts`
Expected: 5 passed.

- [ ] **Step 5: Commit**

```bash
cd /Users/vk/VKDEV/screencp
git add server
git commit -m "feat(server): device API for register, sync, ack, events, selection"
```

---

### Task 8: HTTP wiring — Express app + MCP endpoint + entrypoint

**Files:**
- Create: `server/src/app.ts`, `server/src/index.ts`
- Test: `server/test/app.test.ts`

**Interfaces:**
- Consumes: `buildMcpServer` (Task 5), `makeDeviceRouter` (Task 7), `Repo`, `Push`, `Config`. SDK: `StreamableHTTPServerTransport` from `@modelcontextprotocol/sdk/server/streamableHttp.js`; test client: `StreamableHTTPClientTransport` from `@modelcontextprotocol/sdk/client/streamableHttp.js`.
- Produces: `makeApp(deps: { repo: Repo; push: Push; config: Config; now?: () => Date }): express.Express`. `index.ts` is the runtime entrypoint (no tests — it only wires verified parts).

MCP auth per Global Constraints: `/mcp/:secret` path segment **or** `Authorization: Bearer` header (connector UIs cannot set custom headers; secret-in-path works everywhere). Stateless mode: fresh `McpServer` + transport per POST, `sessionIdGenerator: undefined`.

- [ ] **Step 1: Write the failing test**

`server/test/app.test.ts`:

```ts
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import http from 'node:http';
import request from 'supertest';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { makeApp } from '../src/app.js';
import { FakeRepo, FakePush } from './fakes.js';
import type { Config } from '../src/config.js';

const config: Config = {
  port: 0, databaseUrl: '', mcpBearerToken: 'mcp-secret', deviceBearerToken: 'device-secret',
  maxGrantMinutes: 60, timezone: 'America/Los_Angeles', apns: null,
};

describe('app wiring', () => {
  const repo = new FakeRepo();
  const app = makeApp({ repo, push: new FakePush(), config });
  let server: http.Server;
  let baseUrl: string;

  beforeAll(async () => {
    server = http.createServer(app);
    await new Promise<void>((r) => server.listen(0, r));
    const addr = server.address() as { port: number };
    baseUrl = `http://127.0.0.1:${addr.port}`;
  });

  afterAll(() => new Promise<void>((r) => server.close(() => r())));

  it('serves a health check', async () => {
    const r = await request(app).get('/healthz').expect(200);
    expect(r.body.ok).toBe(true);
  });

  it('rejects /mcp without the secret', async () => {
    await request(app).post('/mcp').send({}).expect(401);
    await request(app).post('/mcp/wrong-secret').send({}).expect(401);
  });

  it('completes a real MCP handshake and tool call via secret-in-path', async () => {
    await repo.createGroup('Social');
    const transport = new StreamableHTTPClientTransport(new URL(`${baseUrl}/mcp/mcp-secret`));
    const client = new Client({ name: 'e2e-test', version: '0.0.0' });
    await client.connect(transport);
    const { tools } = await client.listTools();
    expect(tools).toHaveLength(11);
    const result = await client.callTool({ name: 'list_groups', arguments: {} });
    const payload = JSON.parse((result.content as Array<{ text: string }>)[0].text);
    expect(payload.groups[0].name).toBe('Social');
    await client.close();
  });

  it('accepts /mcp with a Bearer header too', async () => {
    const transport = new StreamableHTTPClientTransport(new URL(`${baseUrl}/mcp`), {
      requestInit: { headers: { Authorization: 'Bearer mcp-secret' } },
    });
    const client = new Client({ name: 'e2e-test-2', version: '0.0.0' });
    await client.connect(transport);
    const { tools } = await client.listTools();
    expect(tools).toHaveLength(11);
    await client.close();
  });

  it('mounts the device API behind its own bearer', async () => {
    await request(app).post('/device/register')
      .set('Authorization', 'Bearer device-secret')
      .send({ apnsToken: 'tok1' }).expect(200);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run test/app.test.ts`
Expected: FAIL — cannot find module `../src/app.js`.

- [ ] **Step 3: Implement app.ts and index.ts**

`server/src/app.ts`:

```ts
import express, { type Express, type Request, type Response, type NextFunction } from 'express';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { buildMcpServer, type Deps } from './mcp.js';
import { makeDeviceRouter } from './deviceApi.js';

export function makeApp(deps: Deps): Express {
  const app = express();
  app.use(express.json({ limit: '1mb' }));

  app.get('/healthz', (_req, res) => { res.json({ ok: true }); });

  app.use('/device', makeDeviceRouter(deps));

  const mcpAuth = (req: Request, res: Response, next: NextFunction) => {
    const bearer = (req.headers.authorization ?? '').replace(/^Bearer\s+/i, '');
    const pathSecret = req.params.secret;
    if (bearer === deps.config.mcpBearerToken || pathSecret === deps.config.mcpBearerToken) {
      next();
      return;
    }
    res.status(401).json({ error: 'unauthorized' });
  };

  // Stateless Streamable HTTP: fresh server + transport per request.
  const handleMcp = async (req: Request, res: Response) => {
    const server = buildMcpServer(deps);
    const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
    res.on('close', () => {
      void transport.close();
      void server.close();
    });
    await server.connect(transport);
    await transport.handleRequest(req, res, req.body);
  };

  app.post('/mcp', mcpAuth, handleMcp);
  app.post('/mcp/:secret', mcpAuth, handleMcp);
  // Stateless mode: no server->client stream or session to manage.
  const noSession = (_req: Request, res: Response) => { res.status(405).end(); };
  app.get(['/mcp', '/mcp/:secret'], noSession);
  app.delete(['/mcp', '/mcp/:secret'], noSession);

  return app;
}
```

`server/src/index.ts`:

```ts
import 'dotenv/config';
import { loadConfig } from './config.js';
import { makePool, PgRepo } from './repo.js';
import { Ladder, ApnsSender, NoopSender } from './push.js';
import { makeApp } from './app.js';

const config = loadConfig();
const repo = new PgRepo(makePool(config.databaseUrl));
const sender = config.apns ? await ApnsSender.create(config.apns) : new NoopSender();
const push = new Ladder(repo, sender);

const app = makeApp({ repo, push, config });
app.listen(config.port, () => {
  console.log(`screencp server listening on :${config.port} (apns: ${config.apns ? 'on' : 'off'})`);
});
```

- [ ] **Step 4: Run the full suite + typecheck + boot smoke**

Run: `npx tsc -p tsconfig.json --noEmit && npx vitest run`
Expected: typecheck clean; all suites pass.

Run (boot smoke): `DATABASE_URL='postgres://placeholder' MCP_BEARER_TOKEN=a DEVICE_BEARER_TOKEN=b npx tsx src/index.ts &` then `sleep 1 && curl -s http://127.0.0.1:8080/healthz && kill %1`
Expected: `{"ok":true}` (Pool connects lazily, so a placeholder URL boots fine).

- [ ] **Step 5: Commit**

```bash
cd /Users/vk/VKDEV/screencp
git add server
git commit -m "feat(server): HTTP wiring — MCP endpoint, device API, entrypoint"
```

---

### Task 9: Provision, deploy, and connect (manual + config files)

**Files:**
- Create: `server/Dockerfile`, `server/.dockerignore`, `server/fly.toml`

This task ends with the server live and callable from the real ChatGPT/Claude apps. Steps 3–6 are manual (accounts + phone UI). No unit tests; verification is the checklist in Step 6.

- [ ] **Step 1: Create deploy files**

`server/Dockerfile`:

```dockerfile
FROM node:22-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build && npm prune --omit=dev

FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY db ./db
EXPOSE 8080
CMD ["node", "dist/index.js"]
```

`server/.dockerignore`:

```
node_modules
dist
.env
```

`server/fly.toml` (app name is claimed in Step 3 — adjust if taken):

```toml
app = "screencp"
primary_region = "sjc"

[build]

[http_service]
  internal_port = 8080
  force_https = true
  auto_stop_machines = "stop"
  auto_start_machines = true
  min_machines_running = 0

[[vm]]
  size = "shared-cpu-1x"
  memory = "256mb"
```

Note `auto_stop_machines`: fine for v1 — MCP calls cold-start the machine in ~1s. If ChatGPT connector verification ever times out, set `min_machines_running = 1`.

- [ ] **Step 2: Commit deploy files**

```bash
cd /Users/vk/VKDEV/screencp
git add server/Dockerfile server/.dockerignore server/fly.toml
git commit -m "chore(server): Dockerfile and Fly.io config"
```

- [ ] **Step 3: Provision Supabase + apply schema (manual)**

1. Create a Supabase project at https://supabase.com/dashboard (or reuse an existing one). Region: closest to you.
2. Get the **direct Postgres connection string** (Dashboard → Connect → "Direct connection"; use the pooler URI only if IPv4 is needed from Fly).
3. Apply the schema: `cd server && DATABASE_URL='<connection-string>' npm run db:apply`
   Expected: `CREATE EXTENSION` / `CREATE TABLE` × 6 with no errors.
4. Re-run the gated integration test against it: `DATABASE_URL='<connection-string>' npx vitest run test/repo.integration.test.ts`
   Expected: 1 passed.

- [ ] **Step 4: Deploy to Fly (manual)**

```bash
cd /Users/vk/VKDEV/screencp/server
fly launch --no-deploy --copy-config --name screencp   # accept existing fly.toml
fly secrets set \
  DATABASE_URL='<supabase-connection-string>' \
  MCP_BEARER_TOKEN="$(openssl rand -hex 32)" \
  DEVICE_BEARER_TOKEN="$(openssl rand -hex 32)"
fly deploy
```

Verify: `curl -s https://screencp.fly.dev/healthz` → `{"ok":true}`.
Record the two secrets somewhere safe (password manager): the MCP one goes into the connector URL next; the device one goes into the iOS app in Plan 2.

- [ ] **Step 5: Connect ChatGPT and Claude (manual)**

*ChatGPT:* Settings → Apps & Connectors → Advanced settings → enable **Developer mode**; then Apps & Connectors → **Create**: name `ScreenCP`, MCP server URL `https://screencp.fly.dev/mcp/<MCP_BEARER_TOKEN>`, auth **None** (the secret is in the URL). Expected: connector verifies and lists 11 tools.

*Claude:* Settings → Connectors → **Add custom connector**, same URL, no OAuth. Expected: connector added; tools visible in chat via the + menu.

- [ ] **Step 6: Golden-path verification from ChatGPT (manual)**

In a ChatGPT chat with the ScreenCP connector enabled, verbatim prompts — expected tool behavior:

1. "Create a screen time group called Social." → `create_group`; reply relays the *open-the-iOS-app* note. ✅
2. "Limit Social to 30 minutes a day." → `set_limit`; reply mentions delivery `no_device_registered` (honest: no iOS app yet). ✅
3. "Block Social from 9am to 5pm on weekdays." → `set_schedule` with mon–fri, 09:00–17:00. ✅
4. "What am I blocking right now?" → `get_status` shows the limit + schedule, `device_connected: false`. ✅
5. "Give me 2 hours of Social." → `grant_temp_access` capped at 60 with the cap note relayed. ✅
6. "How did I do today?" → `get_today_summary` returns the goal-less, event-less day cleanly. ✅
7. Repeat step 4 in Claude to confirm the second client. ✅

- [ ] **Step 7: Commit any fixes + tag the milestone**

```bash
cd /Users/vk/VKDEV/screencp
git add -A
git commit -m "chore(server): backend live on Fly, connected to ChatGPT and Claude" --allow-empty
git tag backend-v1
```

---

## Plan self-review (completed at write time)

- **Spec coverage:** All 11 tools of spec §6 ✔ (Task 5, incl. delivery state + destructive/read-only annotations + grant cap of §8). Data model §5 ✔ (Task 2/3 — tokens deliberately absent server-side per axiom 3; `has_selection` sync via Task 7). Delivery ladder §7 rungs 2–3 ✔ (Task 6); rungs 1/4 + NSE spike are device-side → Plan 2. Auth bootstrap decision of §12 resolved in Global Constraints. Error handling §8: unpopulated-group warning ✔, unreachable-device honesty ✔ (`pending`/`no_device_registered`), grant cap ✔; precedence computation is device-side → Plan 2. Testing §9: unit + MCP contract + gated integration + manual golden path ✔.
- **Placeholder scan:** none — every step has complete code or exact manual instructions. The one external-API caveat (apns2 option names) is explicitly bounded in Task 6 Step 4.
- **Type consistency:** `Repo`/`Push`/`PushSender`/`Config`/`Deps` signatures identical across Tasks 2–8; `FakeRepo` is the semantic contract for `PgRepo` (same test expectations in Tasks 2 and 3); tool names/args in Task 9's manual checklist match Task 5's registrations.

