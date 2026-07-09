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
    const trimmed = name.trim();
    const existing = await repo.listGroups();
    if (existing.some((g) => g.name.toLowerCase() === trimmed.toLowerCase())) {
      return fail(`A group named "${name}" already exists.`);
    }
    const group = await repo.createGroup(trimmed);
    const delivery = await afterMutation(`New group ${group.name}`, group.updatedAt);
    return ok({
      group: { id: group.id, name: group.name },
      note: 'Group created. Now open the ScreenCP iOS app and select which apps belong to this group — enforcement starts once apps are selected.',
      delivery,
    });
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
      'Shields a group right now — indefinitely, or until the given ISO-8601 time. Cancels any active temporary grant on the group (a block issued after a grant wins). Use unblock to lift it.',
    inputSchema: { group: z.string(), until: z.string().datetime().optional() },
  }, async ({ group: name, until }) => {
    const found = await findGroup(name);
    if ('error' in found) return found.error;
    // Later intent wins: an explicit block ends any grant currently in effect.
    const cancelledGrants = await repo.cancelGrants(found.group.id);
    const policy = await repo.replacePolicy(found.group.id, 'block', { until: until ?? null });
    const delivery = await afterMutation(`Block ${found.group.name} now`, policy.updatedAt);
    return ok({
      policy: policyView(policy), group: found.group.name, delivery,
      ...(cancelledGrants > 0 ? { cancelled_grants: cancelledGrants } : {}),
      ...setupNote(found.group),
    });
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
        const { id: _id, ...view } = policyView(p);
        return view;
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
    // No push/delivery here: goals are not device-synced state (changesSince
    // excludes goals) — they exist only for AI coaching via get_today_summary.
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

  server.registerTool('get_summary_range', {
    title: 'Get multi-day adherence summary',
    description:
      'Read-only. Per-day adherence summaries for a date range (max 31 days) plus range totals — for coaching on trends: shield hits per day, thresholds crossed, grants used with reasons, goals. Dates are YYYY-MM-DD in the user\'s home timezone.',
    inputSchema: {
      start_date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
      end_date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
    },
    annotations: { readOnlyHint: true },
  }, async ({ start_date, end_date }) => {
    const start = new Date(`${start_date}T00:00:00Z`);
    const end = new Date(`${end_date}T00:00:00Z`);
    const days = Math.round((end.getTime() - start.getTime()) / 86_400_000) + 1;
    if (Number.isNaN(days) || days < 1) return fail('end_date must be on or after start_date.');
    if (days > 31) return fail('Range too large — max 31 days.');

    await repo.expireGrants(now());
    const [allGrants, groups] = await Promise.all([repo.listGrants(), repo.listGroups()]);

    const daily = [];
    const totals = { shieldShown: 0, shieldTaps: 0, thresholdsCrossed: 0, grantsUsed: 0, grantMinutes: 0 };
    for (let i = 0; i < days; i++) {
      const date = new Date(start.getTime() + i * 86_400_000).toISOString().slice(0, 10);
      const [events, goal] = await Promise.all([
        repo.listEventsOn(date, config.timezone),
        repo.getGoal(date),
      ]);
      const dayGrants = allGrants.filter(
        (g) => todayInTz(config.timezone, new Date(g.startsAt)) === date && g.status !== 'cancelled',
      );
      const s = buildSummary({ events, grants: dayGrants, goal, groups });
      totals.shieldShown += Object.values(s.shieldShown).reduce((a, b) => a + b, 0);
      totals.shieldTaps += s.shieldTaps;
      totals.thresholdsCrossed += s.thresholdsCrossed.length;
      totals.grantsUsed += s.grantsUsed.length;
      totals.grantMinutes += s.grantsUsed.reduce((a, g) => a + g.minutes, 0);
      daily.push({ date, ...s });
    }
    return ok({ start: start_date, end: end_date, totals, daily });
  });

  return server;
}
