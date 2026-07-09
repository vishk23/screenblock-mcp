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
