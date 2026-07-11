import type {
  Group, GroupMode, Policy, PolicyKind, Grant, GrantSource, Goal, EventRow, Device, NewEvent, SyncPayload, EarnRule,
} from './types.js';
import pg from 'pg';

export interface Repo {
  listGroups(): Promise<Group[]>;
  createGroup(name: string): Promise<Group>;
  setGroupSelection(id: string, hasSelection: boolean): Promise<void>;
  setGroupMode(id: string, mode: GroupMode, quotaPerDay?: number, quotaMinutes?: number): Promise<Group>;

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
  createGrant(groupId: string, minutes: number, reason: string | null, expiresAt: Date, source?: GrantSource, id?: string, startsAt?: Date): Promise<Grant>;
  /** Marks pending/active grants with expires_at <= now as expired. Returns count. */
  expireGrants(now: Date): Promise<number>;
  /** Cancels pending/active grants for a group (a later block overrides an earlier grant). */
  cancelGrants(groupId: string): Promise<number>;

  listEarnRules(activeOnly?: boolean): Promise<EarnRule[]>;
  /** One rule per reward group (upsert). */
  upsertEarnRule(rewardGroupId: string, thresholdMinutes: number, rewardMinutes: number, maxPerDay: number, active: boolean): Promise<EarnRule>;

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

export function makePool(databaseUrl: string): pg.Pool {
  return new pg.Pool({ connectionString: databaseUrl, max: 5 });
}

const isoOrNull = (v: Date | null): string | null => (v ? v.toISOString() : null);

const rowToGroup = (r: any): Group => ({
  id: r.id, name: r.name, hasSelection: r.has_selection,
  mode: r.mode, quotaPerDay: r.quota_per_day, quotaMinutes: r.quota_minutes,
  updatedAt: r.updated_at.toISOString(),
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
  status: r.status, source: r.source, updatedAt: r.updated_at.toISOString(),
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

  async createGrant(groupId: string, minutes: number, reason: string | null, expiresAt: Date, source: GrantSource = 'chat', id?: string, startsAt?: Date) {
    // Client-supplied id makes shield-created grant uploads idempotent (safe retries).
    const { rows } = await this.pool.query(
      `insert into grants (id, group_id, minutes, reason, starts_at, expires_at, source)
       values (coalesce($6::uuid, gen_random_uuid()), $1, $2, $3, coalesce($7::timestamptz, now()), $4, $5)
       on conflict (id) do update set updated_at = grants.updated_at
       returning *`,
      [groupId, minutes, reason, expiresAt, source, id ?? null, startsAt ?? null],
    );
    return rowToGrant(rows[0]);
  }

  async setGroupMode(id: string, mode: GroupMode, quotaPerDay?: number, quotaMinutes?: number) {
    const { rows } = await this.pool.query(
      `update groups set mode = $2,
         quota_per_day = coalesce($3, quota_per_day),
         quota_minutes = coalesce($4, quota_minutes),
         updated_at = now()
       where id = $1 returning *`,
      [id, mode, quotaPerDay ?? null, quotaMinutes ?? null],
    );
    return rowToGroup(rows[0]);
  }

  async expireGrants(now: Date) {
    const { rowCount } = await this.pool.query(
      `update grants set status = 'expired', updated_at = now()
       where status in ('pending','active') and expires_at <= $1`,
      [now],
    );
    return rowCount ?? 0;
  }

  async cancelGrants(groupId: string) {
    const { rowCount } = await this.pool.query(
      `update grants set status = 'cancelled', updated_at = now()
       where group_id = $1 and status in ('pending','active')`,
      [groupId],
    );
    return rowCount ?? 0;
  }

  async listEarnRules(activeOnly = true) {
    const { rows } = await this.pool.query(
      activeOnly ? 'select * from earn_rules where active' : 'select * from earn_rules',
    );
    return rows.map((r: any): EarnRule => ({
      id: r.id, rewardGroupId: r.reward_group_id, thresholdMinutes: r.threshold_minutes,
      rewardMinutes: r.reward_minutes, maxPerDay: r.max_per_day, active: r.active,
      updatedAt: r.updated_at.toISOString(),
    }));
  }

  async upsertEarnRule(rewardGroupId: string, thresholdMinutes: number, rewardMinutes: number, maxPerDay: number, active: boolean) {
    const { rows } = await this.pool.query(
      `insert into earn_rules (reward_group_id, threshold_minutes, reward_minutes, max_per_day, active)
       values ($1, $2, $3, $4, $5)
       on conflict (user_id, reward_group_id) do update set
         threshold_minutes = $2, reward_minutes = $3, max_per_day = $4, active = $5, updated_at = now()
       returning *`,
      [rewardGroupId, thresholdMinutes, rewardMinutes, maxPerDay, active],
    );
    const r = rows[0];
    return {
      id: r.id, rewardGroupId: r.reward_group_id, thresholdMinutes: r.threshold_minutes,
      rewardMinutes: r.reward_minutes, maxPerDay: r.max_per_day, active: r.active,
      updatedAt: r.updated_at.toISOString(),
    } as EarnRule;
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
