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
  const repo = new FakeRepo(() => NOW);
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
  it('lists all 13 tools', async () => {
    const { repo, push } = { repo: new FakeRepo(), push: new FakePush() };
    const server = buildMcpServer({ repo, push, config, now: () => NOW });
    const client = new Client({ name: 't', version: '0' });
    const [ct, st] = InMemoryTransport.createLinkedPair();
    await Promise.all([server.connect(st), client.connect(ct)]);
    const { tools } = await client.listTools();
    expect(tools.map((t) => t.name).sort()).toEqual([
      'block_now', 'create_group', 'get_status', 'get_summary_range', 'get_today_summary',
      'grant_temp_access', 'list_groups', 'remove_policy', 'set_goal', 'set_group_mode',
      'set_limit', 'set_schedule', 'unblock',
    ]);
  });

  it('annotates read-only and destructive tools correctly', async () => {
    const { repo, push } = { repo: new FakeRepo(), push: new FakePush() };
    const server = buildMcpServer({ repo, push, config, now: () => NOW });
    const client = new Client({ name: 't', version: '0' });
    const [ct, st] = InMemoryTransport.createLinkedPair();
    await Promise.all([server.connect(st), client.connect(ct)]);
    const { tools } = await client.listTools();
    const byName = Object.fromEntries(tools.map((t) => [t.name, t]));
    expect(byName.get_status.annotations?.readOnlyHint).toBe(true);
    expect(byName.list_groups.annotations?.readOnlyHint).toBe(true);
    expect(byName.get_today_summary.annotations?.readOnlyHint).toBe(true);
    expect(byName.unblock.annotations?.destructiveHint).toBe(true);
    expect(byName.remove_policy.annotations?.destructiveHint).toBe(true);
  });

  it('create_group returns setup instruction, fires push + delivery; duplicate is an error', async () => {
    const { push, call } = await setup();
    const r = await call('create_group', { name: 'Social' });
    expect(r.json.group.name).toBe('Social');
    expect(r.json.note).toMatch(/open the ScreenCP iOS app/);
    expect(r.json.delivery).toBe('no_device_registered');
    expect(push.calls).toHaveLength(1);
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
    expect(push.calls).toHaveLength(2); // create_group + set_limit each push
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

  it('get_summary_range aggregates days and totals', async () => {
    const { repo, call } = await setup();
    const { json: created } = await call('create_group', { name: 'Social' });
    await repo.insertEvents([
      { type: 'shield_shown', groupId: created.group.id, ts: '2026-07-07T19:00:00Z' }, // Jul 7 LA
      { type: 'shield_shown', groupId: created.group.id, ts: '2026-07-08T19:00:00Z' }, // Jul 8 LA
      { type: 'shield_shown', groupId: created.group.id, ts: '2026-07-08T20:00:00Z' },
    ]);
    await call('grant_temp_access', { group: 'Social', minutes: 15, reason: 'bus' });
    const r = await call('get_summary_range', { start_date: '2026-07-07', end_date: '2026-07-08' });
    expect(r.json.daily).toHaveLength(2);
    expect(r.json.daily[0].shieldShown).toEqual({ Social: 1 });
    expect(r.json.daily[1].shieldShown).toEqual({ Social: 2 });
    expect(r.json.totals).toEqual({
      shieldShown: 3, shieldTaps: 0, thresholdsCrossed: 0, grantsUsed: 1, grantMinutes: 15,
    });
    const bad = await call('get_summary_range', { start_date: '2026-07-08', end_date: '2026-07-07' });
    expect(bad.isError).toBe(true);
    const big = await call('get_summary_range', { start_date: '2026-01-01', end_date: '2026-03-01' });
    expect(big.isError).toBe(true);
  });

  it('set_group_mode updates mode and quota and shows in list_groups', async () => {
    const { call } = await setup();
    await call('create_group', { name: 'Instagram' });
    const r = await call('set_group_mode', { group: 'Instagram', mode: 'strict' });
    expect(r.json.mode).toBe('strict');
    const q = await call('set_group_mode', { group: 'Instagram', mode: 'quota', quota_per_day: 3, quota_minutes: 5 });
    expect(q.json.quotaPerDay).toBe(3);
    expect(q.json.quotaMinutes).toBe(5);
    const l = await call('list_groups');
    expect(l.json.groups[0]).toMatchObject({ name: 'Instagram', mode: 'quota', quotaPerDay: 3, quotaMinutes: 5 });
  });

  it('block_now cancels an active grant — later intent wins', async () => {
    const { repo, call } = await setup();
    await call('create_group', { name: 'Social' });
    await call('grant_temp_access', { group: 'Social', minutes: 15, reason: 'bus' });
    expect(await repo.listGrants(['pending', 'active'])).toHaveLength(1);
    const r = await call('block_now', { group: 'Social' });
    expect(r.json.cancelled_grants).toBe(1);
    expect(await repo.listGrants(['pending', 'active'])).toHaveLength(0);
    expect((await repo.listGrants()).at(-1)?.status).toBe('cancelled');
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
    await call('set_schedule', {
      group: 'Social', days: ['mon', 'tue', 'wed', 'thu', 'fri'], start: '09:00', end: '17:00',
    });
    await call('block_now', { group: 'Social' });
    const r = await call('unblock', { group: 'Social' });
    expect(r.json.still_active).toEqual(expect.arrayContaining([
      { kind: 'limit', minutesPerDay: 30 },
      {
        kind: 'schedule', daysOfWeek: [1, 2, 3, 4, 5], startTime: '09:00', endTime: '17:00',
        timezone: 'America/Los_Angeles',
      },
    ]));
    expect(r.json.still_active).toHaveLength(2);
  });

  it('remove_policy deactivates by kind', async () => {
    const { repo, call } = await setup();
    await call('create_group', { name: 'Social' });
    await call('set_limit', { group: 'Social', minutes_per_day: 30 });
    const r = await call('remove_policy', { group: 'Social', kind: 'limit' });
    expect(r.json.removed).toBe(1);
    expect(await repo.listPolicies(true)).toHaveLength(0);
  });

  it('remove_policy errors when the group has no active policy of that kind', async () => {
    const { call } = await setup();
    await call('create_group', { name: 'Social' });
    const r = await call('remove_policy', { group: 'Social', kind: 'schedule' });
    expect(r.isError).toBe(true);
    expect(r.json.error).toMatch(/no active (schedule|limit|block) policy/i);
  });

  it('set_goal does not fire push or report delivery (not device-synced state)', async () => {
    const { push, call } = await setup();
    const before = push.calls.length;
    const r = await call('set_goal', { text: '3 focus hours' });
    expect(r.json).not.toHaveProperty('delivery');
    expect(push.calls).toHaveLength(before);
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
    expect(r.json.grantsUsed).toEqual([{ group: 'Social', minutes: 15, reason: 'bus', source: 'chat' }]);
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
