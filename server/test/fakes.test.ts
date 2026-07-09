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
