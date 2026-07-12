import { describe, it, expect } from 'vitest';
import { makeDb, SqliteRepo } from '../src/repoSqlite.js';

describe('SqliteRepo (in-memory)', () => {
  it('round-trips groups, policy replacement, grant lifecycle, goals, events, devices, earn rules, sync', async () => {
    const repo = new SqliteRepo(makeDb(':memory:'));

    const g = await repo.createGroup('Social');
    expect(g.hasSelection).toBe(false);
    expect(g.mode).toBe('quota');

    await repo.setGroupMode(g.id, 'strict', 5, 12);
    expect((await repo.listGroups())[0].mode).toBe('strict');
    expect((await repo.listGroups())[0].quotaPerDay).toBe(5);

    await repo.replacePolicy(g.id, 'limit', { minutesPerDay: 30 });
    const p2 = await repo.replacePolicy(g.id, 'limit', { minutesPerDay: 45 });
    const active = await repo.listPolicies(true);
    expect(active).toHaveLength(1);
    expect(active[0].id).toBe(p2.id);
    expect(active[0].minutesPerDay).toBe(45);
    expect(await repo.listPolicies(false)).toHaveLength(2);

    const sched = await repo.replacePolicy(g.id, 'schedule', {
      daysOfWeek: [1, 2, 3, 4, 5], startTime: '09:00', endTime: '17:00', timezone: 'America/Los_Angeles',
    });
    expect(sched.daysOfWeek).toEqual([1, 2, 3, 4, 5]);

    // idempotent grant by id
    const gr = await repo.createGrant(g.id, 15, 'bus', new Date(Date.now() + 900_000), 'device_quota', 'fixed-id');
    const gr2 = await repo.createGrant(g.id, 99, 'dup', new Date(Date.now() + 999_000), 'chat', 'fixed-id');
    expect(gr2.id).toBe(gr.id);
    expect(gr2.minutes).toBe(15); // no-op on conflict
    expect((await repo.listGrants()).length).toBe(1);

    const overdue = await repo.createGrant(g.id, 5, null, new Date(Date.now() - 1000), 'chat');
    expect(await repo.expireGrants(new Date())).toBe(1);
    expect((await repo.listGrants(['expired']))[0].id).toBe(overdue.id);
    expect(await repo.cancelGrants(g.id)).toBe(1); // the still-active fixed-id grant

    await repo.upsertEarnRule(g.id, 60, 15, 3, true);
    const rule = await repo.upsertEarnRule(g.id, 90, 20, 2, true);
    expect((await repo.listEarnRules()).length).toBe(1);
    expect(rule.thresholdMinutes).toBe(90);

    await repo.upsertGoal('2026-07-08', '3 focus hours', null);
    await repo.upsertGoal('2026-07-08', '4 focus hours', '4h');
    expect((await repo.getGoal('2026-07-08'))?.text).toBe('4 focus hours');

    await repo.insertEvents([
      { type: 'app_usage', groupId: null, ts: '2026-07-08T19:00:00.000Z', meta: { app: 'Xcode', seconds: 600 } },
      { type: 'shield_shown', groupId: g.id, ts: '2026-07-09T05:00:00.000Z' }, // still Jul 8 in LA
    ]);
    const events = await repo.listEventsOn('2026-07-08', 'America/Los_Angeles');
    expect(events).toHaveLength(2);
    expect(events[0].meta.app).toBe('Xcode');

    await repo.registerDevice('tok1');
    await repo.registerDevice('tok1'); // idempotent
    expect(await repo.listDevices()).toHaveLength(1);
    await repo.ackDevice('tok1', new Date('2026-07-08T12:00:00Z'));
    expect((await repo.listDevices())[0].appliedThrough).toBe('2026-07-08T12:00:00.000Z');

    const all = await repo.changesSince(null);
    expect(all.groups).toHaveLength(1);
    const none = await repo.changesSince(new Date(Date.now() + 60_000));
    expect(none.groups).toHaveLength(0);
  });

  it('createGroup throws on duplicate name', async () => {
    const repo = new SqliteRepo(makeDb(':memory:'));
    await repo.createGroup('Social');
    await expect(repo.createGroup('Social')).rejects.toThrow();
  });
});
