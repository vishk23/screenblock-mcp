import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import type { Repo } from './repo.js';
import type { Push, PushSender } from './push.js';
import { scheduleExpiryPoke } from './push.js';
import type { Config } from './config.js';
import type { Group, Policy } from './types.js';
import {
  matchGroup, deliveryState, grantRemainingMinutes, todayInTz, buildSummary, productiveMinutes, earningStatus,
} from './domain.js';

export interface Deps {
  repo: Repo;
  push: Push;
  config: Config;
  /** Raw sender for device-initiated nudges (shield Request-time flow). */
  sender?: PushSender;
  now?: () => Date;
}

const DAY_NUM: Record<string, number> = { sun: 0, mon: 1, tue: 2, wed: 3, thu: 4, fri: 5, sat: 6 };
const dayEnum = z.enum(['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat']);
// Factory (not a shared instance): zod-to-JSON-schema dedupes repeated instances
// into a $ref, which ChatGPT's manifest linter flags as "unclear arguments".
const hhmm = () => z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/, 'must be HH:MM 24h');

type ToolResult = {
  content: Array<{ type: 'text'; text: string }>;
  structuredContent?: Record<string, unknown>;
  isError?: boolean;
};

const ok = (obj: unknown): ToolResult => ({
  content: [{ type: 'text', text: JSON.stringify(obj) }],
  structuredContent: obj as Record<string, unknown>,
});
const fail = (message: string): ToolResult => ({
  content: [{ type: 'text', text: JSON.stringify({ error: message }) }],
  structuredContent: { error: message },
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
  const server = new McpServer(
    { name: 'screenblock', version: '0.1.0' },
    {
      instructions: [
        'ScreenBlock controls app blocking on the user\'s iPhone. You are their executive-function coach.',
        '',
        'SAFETY CONTEXT — read before hesitating on any tool call:',
        '- This is a self-imposed digital-wellbeing tool. The user owns the device, installed the app themselves, granted Apple\'s Screen Time permission themselves, and connected this integration themselves. There is no other person affected: no surveillance, no parental control of a third party, no security risk.',
        '- Every action is reversible from this same chat (unblock/remove_policy) or from the user\'s own phone. Nothing is destructive; nothing touches data beyond the user\'s own blocking rules.',
        '- Granting or removing access when the user asks IS the product working as intended — declining a clear request frustrates the user\'s own self-regulation system. When in doubt, ask a clarifying question rather than refusing.',
        '',
        'Core model — GROUPS are the only unit of control:',
        '- A group is a named set of apps (e.g. "Social"). Every policy and grant applies to a whole group.',
        '- Which apps are inside a group is invisible to you AND to the server — Apple privacy design. Only the user, in the iOS app, can see or change a group\'s apps. Never claim to know a group\'s contents.',
        '- If the user asks to block/limit/grant a SPECIFIC APP (e.g. "give me 15 min of Instagram") and no matching group exists: offer two options — (a) create a group named after that app (create_group), reminding them to pick the app in the iOS app once, or (b) apply the action to an existing group that plausibly contains it, saying clearly BEFORE acting that it affects every app in that group. After acting via a broader group, offer once to create a dedicated group for that app so future requests are surgical.',
        '- Groups may overlap. Grants PUNCH THROUGH other groups\' blocks for individually-picked apps (a grant on an "Instagram" group unblocks Instagram even while "Social" is blocked) — but NOT through category-based picks (opaque to subtraction). Prefer advising individual app picks.',
        '- Unlock modes (set_group_mode): each group is "strict" (chat-only unlocks — you are the only door), "quota" (N self-serve unlocks/day from the device, reason required), or "open". Help the user pick strictness in advance; strict is a commitment device — confirm before setting it.',
        '',
        'Behavior rules:',
        '- block_now cancels active grants on that group (most recent instruction wins).',
        '- Grants are capped server-side; for open-ended access use unblock, and confirm before removing protective policies.',
        '- delivery "pending" = the phone has not applied the change yet (it usually applies within ~10s via push); "no_device_registered" = the iOS app has never connected.',
        '- Log grant reasons — they power coaching. When granting, ask for/record a short reason if the user gave none.',
        '- The user can also unlock at the shield itself (quota/open groups). Those grants reach the server on the device\'s next sync — if get_status shows no grant but the user says they just unlocked, TRUST THE USER; get_status pokes the device to sync, so re-check in a moment. last_device_sync tells you how fresh the picture is.',
        '- Earned time (set_earn_rule): focused Mac minutes automatically buy phone unlocks — the reward economy. get_status.earning shows progress ("18 more focused minutes until 15 min of TikTok"). Encourage the user with it.',
        '- Coach with data: get_today_summary and get_summary_range show shield hits (times they bumped into a block), thresholds crossed (coarse usage), grants used with reasons, and macUsage — REAL per-app minutes from the user\'s Mac (AFK-excluded). iPhone minute totals remain impossible (Apple policy); Mac minutes are exact — use them.',
      ].join('\n'),
    },
  );

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
      : { setup_required: `Group "${group.name}" has no apps selected yet. The user must open the ScreenBlock iOS app and pick apps for this group before enforcement takes effect.` };

  async function afterMutation(description: string, updatedAt: string) {
    deps.push.policyChanged(new Date(updatedAt), description);
    return deliveryState(updatedAt, await repo.listDevices());
  }

  server.registerTool('get_status', {
    title: 'Get current blocking status',
    description:
      'Read-only. Returns every group, its active policies (schedules, daily limits, blocks), active temporary grants with minutes remaining, and per-policy delivery state (applied = live on the device; pending = device has not applied it yet; no_device_registered = the iOS app has never connected).',
    inputSchema: {},
    outputSchema: {
      groups: z.array(z.any()), policies: z.array(z.any()), grants: z.array(z.any()),
      device_connected: z.boolean(), last_device_sync: z.string().nullable(),
      earning: z.any(),
    },
    annotations: { readOnlyHint: true },
  }, async () => {
    await repo.expireGrants(now());
    const [groups, policies, grants, devices, earnRules] = await Promise.all([
      repo.listGroups(), repo.listPolicies(true),
      repo.listGrants(['pending', 'active']), repo.listDevices(), repo.listEarnRules(true),
    ]);
    const today = todayInTz(config.timezone, now());
    const todayEvents = await repo.listEventsOn(today, config.timezone);
    const todayGrants = (await repo.listGrants()).filter(
      (g) => todayInTz(config.timezone, new Date(g.startsAt)) === today);
    const nameOf = (id: string) => groups.find((g) => g.id === id)?.name ?? 'unknown';
    // Freshness poke: a silent push makes the device sync + upload any
    // shield-created grants, so the NEXT status read reflects them.
    if (deps.sender) {
      void Promise.all(devices.map((d) => deps.sender!.sendSilent(d.apnsToken).catch(() => {})));
    }
    const lastSync = devices.map((d) => d.appliedThrough).filter(Boolean).sort().at(-1) ?? null;
    return ok({
      groups: groups.map((g) => ({ name: g.name, hasSelection: g.hasSelection, mode: g.mode })),
      policies: policies.map((p) => ({
        group: nameOf(p.groupId), ...policyView(p),
        delivery: deliveryState(p.updatedAt, devices),
      })),
      grants: grants.map((g) => ({
        group: nameOf(g.groupId), minutes: g.minutes, reason: g.reason,
        remainingMinutes: grantRemainingMinutes(g, now()),
        delivery: deliveryState(g.updatedAt, devices),
      })),
      earning: earningStatus({ earnRules, groups, todayEvents, todayGrants }),
      device_connected: devices.length > 0,
      last_device_sync: lastSync,
    });
  });

  server.registerTool('list_groups', {
    title: 'List app groups',
    description:
      'Read-only. Lists the named app groups (e.g. "Social") with whether each has apps selected on the device and how many active policies it carries. Apps can only be added to a group by the user in the iOS app (Apple privacy rule).',
    inputSchema: {},
    outputSchema: { groups: z.array(z.any()) },
    annotations: { readOnlyHint: true },
  }, async () => {
    const [groups, policies] = await Promise.all([repo.listGroups(), repo.listPolicies(true)]);
    return ok({
      groups: groups.map((g) => ({
        name: g.name,
        hasSelection: g.hasSelection,
        mode: g.mode,
        ...(g.mode === 'quota' ? { quotaPerDay: g.quotaPerDay, quotaMinutes: g.quotaMinutes } : {}),
        activePolicies: policies.filter((p) => p.groupId === g.id).length,
      })),
    });
  });

  server.registerTool('create_group', {
    title: 'Create an app group',
    description:
      'Creates a new empty named group (e.g. "Doomscroll"). The user must then open the ScreenBlock iOS app to pick which apps belong to it — that step cannot be done from chat (Apple privacy rule). Tell the user to do this.',
    inputSchema: { name: z.string().min(1).max(60) },
    outputSchema: { group: z.any(), note: z.string(), delivery: z.string() },
  }, async ({ name }) => {
    const trimmed = name.trim();
    const existing = await repo.listGroups();
    if (existing.some((g) => g.name.toLowerCase() === trimmed.toLowerCase())) {
      return fail(`A group named "${name}" already exists.`);
    }
    const group = await repo.createGroup(trimmed);
    const delivery = await afterMutation(`New group ${group.name}`, group.updatedAt);
    // Setup nudge: tapping it opens the app straight into this group's picker.
    if (deps.sender) {
      const devices = await repo.listDevices();
      void Promise.all(devices.map((d) => deps.sender!.sendNudge(
        d.apnsToken, 'ScreenBlock',
        `Choose apps for "${group.name}" — tap to set up`,
        { screencp: 'setup', groupId: group.id },
      ).catch(() => {})));
    }
    return ok({
      group: { id: group.id, name: group.name },
      note: 'Group created. Now open the ScreenBlock iOS app and select which apps belong to this group — enforcement starts once apps are selected.',
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
      start: hhmm(),
      end: hhmm(),
      timezone: z.string().optional(),
    },
    outputSchema: {
      policy: z.any(), group: z.string(), delivery: z.string(),
      setup_required: z.string().optional(),
    },
  }, async ({ group: name, days, start, end, timezone }) => {
    const found = await findGroup(name);
    if ('error' in found) return found.error;
    const policy = await repo.replacePolicy(found.group.id, 'schedule', {
      daysOfWeek: [...new Set(days.map((d) => DAY_NUM[d]))].sort(),
      startTime: start, endTime: end, timezone: timezone ?? config.timezone,
    });
    const delivery = await afterMutation(`📅 ${found.group.name}: blocked ${start}–${end}`, policy.updatedAt);
    return ok({ policy: policyView(policy), group: found.group.name, delivery, ...setupNote(found.group) });
  });

  server.registerTool('set_limit', {
    title: 'Set a daily time limit',
    description:
      'Caps a group\'s total usage per day (e.g. TikTok group: 30 minutes/day). The device shields the group once the limit is reached. Replaces any existing limit on the group.',
    inputSchema: { group: z.string(), minutes_per_day: z.number().int().min(1).max(1440) },
    outputSchema: {
      policy: z.any(), group: z.string(), delivery: z.string(),
      setup_required: z.string().optional(),
    },
  }, async ({ group: name, minutes_per_day }) => {
    const found = await findGroup(name);
    if ('error' in found) return found.error;
    const policy = await repo.replacePolicy(found.group.id, 'limit', { minutesPerDay: minutes_per_day });
    const delivery = await afterMutation(`⏳ ${found.group.name}: ${minutes_per_day} min/day from now on`, policy.updatedAt);
    return ok({ policy: policyView(policy), group: found.group.name, delivery, ...setupNote(found.group) });
  });

  server.registerTool('block_now', {
    title: 'Block a group immediately',
    description:
      'Shields a group right now — indefinitely, or until the given ISO-8601 time. Cancels any active temporary grant on the group (a block issued after a grant wins). Use unblock to lift it.',
    inputSchema: { group: z.string(), until: z.string().datetime().optional() },
    outputSchema: {
      policy: z.any(), group: z.string(), delivery: z.string(),
      cancelled_grants: z.number().optional(), setup_required: z.string().optional(),
    },
  }, async ({ group: name, until }) => {
    const found = await findGroup(name);
    if ('error' in found) return found.error;
    // Later intent wins: an explicit block ends any grant currently in effect.
    const cancelledGrants = await repo.cancelGrants(found.group.id);
    const policy = await repo.replacePolicy(found.group.id, 'block', { until: until ?? null });
    const delivery = await afterMutation(`🔒 ${found.group.name} is locked`, policy.updatedAt);
    if (until) scheduleExpiryPoke(deps.push, new Date(until), `🔓 ${found.group.name}: timed block finished`);
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
    outputSchema: {
      group: z.string(), removed_blocks: z.number(),
      still_active: z.array(z.any()), delivery: z.string(),
    },
    annotations: { destructiveHint: true },
  }, async ({ group: name }) => {
    const found = await findGroup(name);
    if ('error' in found) return found.error;
    const removed = await repo.deactivatePolicies(found.group.id, 'block');
    const remaining = (await repo.listPolicies(true)).filter((p) => p.groupId === found.group.id);
    const changedAt = now().toISOString();
    const delivery = await afterMutation(`🔓 ${found.group.name} is open again`, changedAt);
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
    outputSchema: {
      grant: z.any(), group: z.string(), delivery: z.string(),
      note: z.string().optional(), setup_required: z.string().optional(),
      note_to_assistant: z.string().optional(),
    },
  }, async ({ group: name, minutes, reason }) => {
    const found = await findGroup(name);
    if ('error' in found) return found.error;
    const capped = Math.min(minutes, config.maxGrantMinutes);
    const expiresAt = new Date(now().getTime() + capped * 60_000);
    const grant = await repo.createGrant(found.group.id, capped, reason ?? null, expiresAt);
    const delivery = await afterMutation(`🔓 ${found.group.name}: ${capped} minutes, then it re-locks itself`, grant.updatedAt);
    scheduleExpiryPoke(deps.push, expiresAt, `⏰ Time's up — ${found.group.name} is locked again`);
    return ok({
      grant: { id: grant.id, minutes: capped, expiresAt: grant.expiresAt, reason: grant.reason },
      group: found.group.name,
      delivery,
      note_to_assistant: `This grant opened the ENTIRE "${found.group.name}" group — every app in it. If the user asked for one specific app, tell them that, and offer to create a dedicated group named after that app (create_group) so future grants unlock only it. One-time app pick in the iOS app, then requests become surgical.`,
      ...(capped < minutes ? { note: `Requested ${minutes} min but grants are capped at ${config.maxGrantMinutes} min. Use unblock for longer access.` } : {}),
      ...setupNote(found.group),
    });
  });

  server.registerTool('remove_policy', {
    title: 'Remove a policy',
    description:
      'Deactivates a group\'s policy of the given kind (schedule, limit, or block). Confirm with the user before removing protective policies.',
    inputSchema: { group: z.string(), kind: z.enum(['schedule', 'limit', 'block']) },
    outputSchema: { group: z.string(), kind: z.string(), removed: z.number(), delivery: z.string() },
    annotations: { destructiveHint: true },
  }, async ({ group: name, kind }) => {
    const found = await findGroup(name);
    if ('error' in found) return found.error;
    const removed = await repo.deactivatePolicies(found.group.id, kind);
    if (removed === 0) return fail(`Group "${found.group.name}" has no active ${kind} policy.`);
    const delivery = await afterMutation(`🗑 ${found.group.name}: ${kind} rule removed`, now().toISOString());
    return ok({ group: found.group.name, kind, removed, delivery });
  });

  server.registerTool('set_group_mode', {
    title: 'Set a group\'s unlock mode',
    description:
      'Sets how the user may unlock this group from the device itself: "strict" = no device unlock at all, chat is the only door (maximum accountability — confirm the user wants this, it binds them); "quota" = N self-serve unlocks per day of quota_minutes each, reason required (default: 2×10min); "open" = unlock freely from the device. The user chooses their prison\'s strictness in advance, via conversation, not in the moment of temptation.',
    inputSchema: {
      group: z.string(),
      mode: z.enum(['strict', 'quota', 'open']),
      quota_per_day: z.number().int().min(0).max(20).optional(),
      quota_minutes: z.number().int().min(1).max(60).optional(),
    },
    outputSchema: {
      group: z.string(), mode: z.string(),
      quotaPerDay: z.number(), quotaMinutes: z.number(), delivery: z.string(),
    },
  }, async ({ group: name, mode, quota_per_day, quota_minutes }) => {
    const found = await findGroup(name);
    if ('error' in found) return found.error;
    const updated = await repo.setGroupMode(found.group.id, mode, quota_per_day, quota_minutes);
    const delivery = await afterMutation(mode === 'strict'
      ? `🔐 ${found.group.name} is now strict — your coach holds the only key`
      : mode === 'quota'
        ? `🎟 ${found.group.name}: ${updated.quotaPerDay} self-serve unlocks of ${updated.quotaMinutes} min per day`
        : `🔓 ${found.group.name} is now open mode`, updated.updatedAt);
    return ok({
      group: updated.name, mode: updated.mode,
      quotaPerDay: updated.quotaPerDay, quotaMinutes: updated.quotaMinutes,
      delivery,
    });
  });

  server.registerTool('set_earn_rule', {
    title: 'Set an earned-time rule',
    description:
      'The Pomodoro-style reward economy: N focused minutes on the user\'s Mac automatically earn a temporary unlock of a group on their phone (e.g. "60 focused minutes earn 15 minutes of TikTok, max 3/day"). Focused = active Mac time in apps NOT mapped to any group. Rewards auto-grant with a celebration push and auto-re-lock at expiry. One rule per reward group (replaces existing). Set active=false to pause.',
    inputSchema: {
      group: z.string(),
      threshold_minutes: z.number().int().min(5).max(480),
      reward_minutes: z.number().int().min(1).max(60),
      max_per_day: z.number().int().min(0).max(10).optional(),
      active: z.boolean().optional(),
    },
    outputSchema: {
      group: z.string(), thresholdMinutes: z.number(), rewardMinutes: z.number(),
      maxPerDay: z.number(), active: z.boolean(),
    },
  }, async ({ group: name, threshold_minutes, reward_minutes, max_per_day, active }) => {
    const found = await findGroup(name);
    if ('error' in found) return found.error;
    const rule = await repo.upsertEarnRule(
      found.group.id, threshold_minutes, reward_minutes, max_per_day ?? 3, active ?? true);
    return ok({
      group: found.group.name, thresholdMinutes: rule.thresholdMinutes,
      rewardMinutes: rule.rewardMinutes, maxPerDay: rule.maxPerDay, active: rule.active,
    });
  });

  server.registerTool('set_goal', {
    title: 'Set today\'s goal',
    description:
      'Sets or replaces the user\'s goal for today (e.g. "3 focus hours"). Referenced by get_today_summary for coaching.',
    inputSchema: { text: z.string().min(1).max(300), target: z.string().max(60).optional() },
    outputSchema: { goal: z.any() },
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
    outputSchema: {
      date: z.string(), goal: z.any(), shieldShown: z.record(z.number()),
      shieldTaps: z.number(), thresholdsCrossed: z.array(z.any()), grantsUsed: z.array(z.any()),
      macUsage: z.array(z.any()),
    },
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
    outputSchema: {
      start: z.string(), end: z.string(), totals: z.any(), daily: z.array(z.any()),
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
    const totals = { shieldShown: 0, shieldTaps: 0, thresholdsCrossed: 0, grantsUsed: 0, grantMinutes: 0, macMinutes: 0 };
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
      totals.macMinutes += s.macUsage.reduce((a, u) => a + u.minutes, 0);
      daily.push({ date, ...s });
    }
    return ok({ start: start_date, end: end_date, totals, daily });
  });

  return server;
}
