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
