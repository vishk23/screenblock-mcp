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
