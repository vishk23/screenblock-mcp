import { createRequire } from 'node:module';
import { randomUUID } from 'node:crypto';
// Loaded via createRequire so bundlers (Vitest/Vite) don't try to statically
// resolve this very-new builtin and mangle the node: prefix.
const { DatabaseSync } = createRequire(import.meta.url)('node:sqlite') as typeof import('node:sqlite');
type DatabaseSync = InstanceType<typeof DatabaseSync>;
import { readFileSync } from 'node:fs';
import type { Repo } from './repo.js';
import type {
  Group, GroupMode, Policy, PolicyKind, Grant, GrantSource, Goal, EventRow, Device, NewEvent, SyncPayload, EarnRule,
} from './types.js';

/** Opens (and migrates) the SQLite database at `path` (or ':memory:'). */
export function makeDb(path: string): DatabaseSync {
  const db = new DatabaseSync(path);
  const schemaUrl = new URL('../db/schema-sqlite.sql', import.meta.url);
  db.exec(readFileSync(schemaUrl, 'utf8'));
  db.exec('pragma busy_timeout = 5000');
  return db;
}

const iso = (d: Date): string => d.toISOString();
const nowIso = (): string => new Date().toISOString();
const bool = (v: unknown): boolean => v === 1 || v === true;

/** YYYY-MM-DD of an ISO instant in a timezone (mirrors domain.todayInTz). */
function localDate(tsIso: string, timezone: string): string {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: timezone, year: 'numeric', month: '2-digit', day: '2-digit',
  }).format(new Date(tsIso));
}

/* eslint-disable @typescript-eslint/no-explicit-any */
const rowToGroup = (r: any): Group => ({
  id: r.id, name: r.name, hasSelection: bool(r.has_selection),
  mode: r.mode, quotaPerDay: r.quota_per_day, quotaMinutes: r.quota_minutes,
  updatedAt: r.updated_at,
});

const rowToPolicy = (r: any): Policy => ({
  id: r.id, groupId: r.group_id, kind: r.kind, active: bool(r.active),
  daysOfWeek: r.days_of_week ? JSON.parse(r.days_of_week) : undefined,
  startTime: r.start_time ?? undefined,
  endTime: r.end_time ?? undefined,
  minutesPerDay: r.minutes_per_day ?? undefined,
  until: r.until ?? null,
  timezone: r.timezone ?? undefined,
  updatedAt: r.updated_at,
});

const rowToGrant = (r: any): Grant => ({
  id: r.id, groupId: r.group_id, minutes: r.minutes, reason: r.reason ?? null,
  startsAt: r.starts_at, expiresAt: r.expires_at, status: r.status, source: r.source,
  updatedAt: r.updated_at,
});

const rowToDevice = (r: any): Device => ({
  id: r.id, apnsToken: r.apns_token,
  appliedThrough: r.applied_through ?? null, lastSeenAt: r.last_seen_at,
});

const rowToEarnRule = (r: any): EarnRule => ({
  id: r.id, rewardGroupId: r.reward_group_id, thresholdMinutes: r.threshold_minutes,
  rewardMinutes: r.reward_minutes, maxPerDay: r.max_per_day, active: bool(r.active),
  updatedAt: r.updated_at,
});

export class SqliteRepo implements Repo {
  constructor(private db: DatabaseSync) {}

  async listGroups() {
    return this.db.prepare('select * from groups order by name').all().map(rowToGroup);
  }

  async createGroup(name: string) {
    const id = randomUUID();
    const now = nowIso();
    // Throws on the unique(user_id, name) constraint, matching PgRepo.
    this.db.prepare('insert into groups (id, name, created_at, updated_at) values (?, ?, ?, ?)')
      .run(id, name, now, now);
    return rowToGroup(this.db.prepare('select * from groups where id = ?').get(id));
  }

  async setGroupSelection(id: string, hasSelection: boolean) {
    this.db.prepare('update groups set has_selection = ?, updated_at = ? where id = ?')
      .run(hasSelection ? 1 : 0, nowIso(), id);
  }

  async setGroupMode(id: string, mode: GroupMode, quotaPerDay?: number, quotaMinutes?: number) {
    this.db.prepare(
      `update groups set mode = ?,
         quota_per_day = coalesce(?, quota_per_day),
         quota_minutes = coalesce(?, quota_minutes),
         updated_at = ? where id = ?`,
    ).run(mode, quotaPerDay ?? null, quotaMinutes ?? null, nowIso(), id);
    return rowToGroup(this.db.prepare('select * from groups where id = ?').get(id));
  }

  async listPolicies(activeOnly = true) {
    const sql = activeOnly
      ? 'select * from policies where active = 1 order by updated_at'
      : 'select * from policies order by updated_at';
    return this.db.prepare(sql).all().map(rowToPolicy);
  }

  async replacePolicy(
    groupId: string,
    kind: PolicyKind,
    fields: Pick<Policy, 'daysOfWeek' | 'startTime' | 'endTime' | 'minutesPerDay' | 'until' | 'timezone'>,
  ) {
    const now = nowIso();
    const id = randomUUID();
    const tx = this.db.prepare('begin');
    try {
      tx.run();
      this.db.prepare('update policies set active = 0, updated_at = ? where group_id = ? and kind = ? and active = 1')
        .run(now, groupId, kind);
      this.db.prepare(
        `insert into policies (id, group_id, kind, active, days_of_week, start_time, end_time, minutes_per_day, until, timezone, created_at, updated_at)
         values (?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ).run(id, groupId, kind,
        fields.daysOfWeek ? JSON.stringify(fields.daysOfWeek) : null,
        fields.startTime ?? null, fields.endTime ?? null, fields.minutesPerDay ?? null,
        fields.until ?? null, fields.timezone ?? null, now, now);
      this.db.prepare('commit').run();
    } catch (e) {
      this.db.prepare('rollback').run();
      throw e;
    }
    return rowToPolicy(this.db.prepare('select * from policies where id = ?').get(id));
  }

  async deactivatePolicies(groupId: string, kind?: PolicyKind) {
    const now = nowIso();
    const res = kind
      ? this.db.prepare('update policies set active = 0, updated_at = ? where group_id = ? and kind = ? and active = 1').run(now, groupId, kind)
      : this.db.prepare('update policies set active = 0, updated_at = ? where group_id = ? and active = 1').run(now, groupId);
    return Number(res.changes);
  }

  async listGrants(statuses?: Grant['status'][]) {
    if (statuses) {
      const placeholders = statuses.map(() => '?').join(', ');
      return this.db.prepare(`select * from grants where status in (${placeholders}) order by expires_at`)
        .all(...statuses).map(rowToGrant);
    }
    return this.db.prepare('select * from grants order by expires_at').all().map(rowToGrant);
  }

  async createGrant(groupId: string, minutes: number, reason: string | null, expiresAt: Date, source: GrantSource = 'chat', id?: string, startsAt?: Date) {
    const gid = id ?? randomUUID();
    const now = nowIso();
    // Client-supplied id makes shield-created grant uploads idempotent.
    this.db.prepare(
      `insert into grants (id, group_id, minutes, reason, starts_at, expires_at, source, status, updated_at)
       values (?, ?, ?, ?, ?, ?, ?, 'pending', ?)
       on conflict(id) do update set updated_at = grants.updated_at`,
    ).run(gid, groupId, minutes, reason, iso(startsAt ?? new Date()), iso(expiresAt), source, now);
    return rowToGrant(this.db.prepare('select * from grants where id = ?').get(gid));
  }

  async expireGrants(now: Date) {
    const res = this.db.prepare(
      `update grants set status = 'expired', updated_at = ?
       where status in ('pending','active') and expires_at <= ?`,
    ).run(nowIso(), iso(now));
    return Number(res.changes);
  }

  async cancelGrants(groupId: string) {
    const res = this.db.prepare(
      `update grants set status = 'cancelled', updated_at = ?
       where group_id = ? and status in ('pending','active')`,
    ).run(nowIso(), groupId);
    return Number(res.changes);
  }

  async listEarnRules(activeOnly = true) {
    const sql = activeOnly ? 'select * from earn_rules where active = 1' : 'select * from earn_rules';
    return this.db.prepare(sql).all().map(rowToEarnRule);
  }

  async upsertEarnRule(rewardGroupId: string, thresholdMinutes: number, rewardMinutes: number, maxPerDay: number, active: boolean) {
    const now = nowIso();
    this.db.prepare(
      `insert into earn_rules (id, reward_group_id, threshold_minutes, reward_minutes, max_per_day, active, updated_at)
       values (?, ?, ?, ?, ?, ?, ?)
       on conflict(user_id, reward_group_id) do update set
         threshold_minutes = excluded.threshold_minutes, reward_minutes = excluded.reward_minutes,
         max_per_day = excluded.max_per_day, active = excluded.active, updated_at = excluded.updated_at`,
    ).run(randomUUID(), rewardGroupId, thresholdMinutes, rewardMinutes, maxPerDay, active ? 1 : 0, now);
    return rowToEarnRule(this.db.prepare('select * from earn_rules where reward_group_id = ?').get(rewardGroupId));
  }

  async upsertGoal(date: string, text: string, target: string | null) {
    const now = nowIso();
    this.db.prepare(
      `insert into goals (id, date, text, target, updated_at) values (?, ?, ?, ?, ?)
       on conflict(user_id, date) do update set text = excluded.text, target = excluded.target, updated_at = excluded.updated_at`,
    ).run(randomUUID(), date, text, target, now);
    const r = this.db.prepare('select date, text, target from goals where date = ?').get(date) as any;
    return { date: r.date, text: r.text, target: r.target ?? null } as Goal;
  }

  async getGoal(date: string) {
    const r = this.db.prepare('select date, text, target from goals where date = ?').get(date) as any;
    return r ? ({ date: r.date, text: r.text, target: r.target ?? null } as Goal) : null;
  }

  async insertEvents(events: NewEvent[]) {
    if (events.length === 0) return 0;
    const stmt = this.db.prepare('insert into events (group_id, type, ts, meta) values (?, ?, ?, ?)');
    this.db.prepare('begin').run();
    try {
      for (const e of events) {
        stmt.run(e.groupId ?? null, e.type, e.ts ?? nowIso(), JSON.stringify(e.meta ?? {}));
      }
      this.db.prepare('commit').run();
    } catch (err) {
      this.db.prepare('rollback').run();
      throw err;
    }
    return events.length;
  }

  async listEventsOn(date: string, timezone: string) {
    // Bound to a UTC window covering the local day (±1 day handles any offset),
    // then filter to the exact local date (SQLite has no timezone database).
    const start = new Date(`${date}T00:00:00Z`);
    const lo = new Date(start.getTime() - 86_400_000).toISOString();
    const hi = new Date(start.getTime() + 2 * 86_400_000).toISOString();
    const rows = this.db.prepare('select * from events where ts >= ? and ts < ? order by ts').all(lo, hi) as any[];
    return rows
      .filter((r) => localDate(r.ts, timezone) === date)
      .map((r): EventRow => ({ id: Number(r.id), groupId: r.group_id, type: r.type, ts: r.ts, meta: JSON.parse(r.meta) }));
  }

  async registerDevice(apnsToken: string) {
    const now = nowIso();
    this.db.prepare(
      `insert into devices (id, apns_token, last_seen_at) values (?, ?, ?)
       on conflict(apns_token) do update set last_seen_at = excluded.last_seen_at`,
    ).run(randomUUID(), apnsToken, now);
    return rowToDevice(this.db.prepare('select * from devices where apns_token = ?').get(apnsToken));
  }

  async listDevices() {
    return this.db.prepare('select * from devices order by last_seen_at desc').all().map(rowToDevice);
  }

  async ackDevice(apnsToken: string, appliedThrough: Date) {
    this.db.prepare('update devices set applied_through = ?, last_seen_at = ? where apns_token = ?')
      .run(iso(appliedThrough), nowIso(), apnsToken);
  }

  async changesSince(since: Date | null): Promise<SyncPayload> {
    const g = since
      ? this.db.prepare('select * from groups where updated_at > ?').all(iso(since))
      : this.db.prepare('select * from groups').all();
    const p = since
      ? this.db.prepare('select * from policies where updated_at > ?').all(iso(since))
      : this.db.prepare('select * from policies').all();
    const gr = since
      ? this.db.prepare('select * from grants where updated_at > ?').all(iso(since))
      : this.db.prepare('select * from grants').all();
    return {
      groups: g.map(rowToGroup),
      policies: p.map(rowToPolicy),
      grants: gr.map(rowToGrant),
      serverTime: nowIso(),
    };
  }
}
