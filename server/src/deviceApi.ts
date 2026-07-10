import { Router, type Request, type Response, type NextFunction } from 'express';
import { z } from 'zod';
import type { Repo } from './repo.js';
import type { Config } from './config.js';
import type { Push, PushSender } from './push.js';
import { scheduleExpiryPoke } from './push.js';
import { todayInTz } from './domain.js';

type AsyncHandler = (req: Request, res: Response) => Promise<void>;
const wrap = (fn: AsyncHandler) => (req: Request, res: Response, next: NextFunction) => {
  fn(req, res).catch(next);
};

export function makeDeviceRouter(deps: { repo: Repo; config: Config; sender?: PushSender; push?: Push }): Router {
  const { repo, config } = deps;
  const router = Router();

  router.use((req: Request, res: Response, next: NextFunction) => {
    const token = (req.headers.authorization ?? '').replace(/^Bearer\s+/i, '');
    if (token !== config.deviceBearerToken) {
      res.status(401).json({ error: 'unauthorized' });
      return;
    }
    next();
  });

  /**
   * Self-serve unlock from the device ("the moment at the wall").
   * strict → always denied (chat-only). quota → counted against the group's
   * daily ration, duration fixed to quota_minutes, reason REQUIRED.
   * open → any duration up to the server grant cap.
   * The device applies the grant locally at once; this records + validates it.
   */
  router.post('/grants', wrap(async (req, res) => {
    const body = z.object({
      groupId: z.string().uuid(),
      reason: z.string().trim().min(1).max(200),
      minutes: z.number().int().min(1).optional(),
      // Shield-created grants upload after the fact: client id (idempotent
      // retries) + the actual unlock time, so expiry matches the device.
      id: z.string().uuid().optional(),
      startsAt: z.string().datetime({ offset: true }).or(z.string().datetime()).optional(),
    }).safeParse(req.body);
    if (!body.success) { res.status(400).json({ error: body.error.message }); return; }

    const group = (await repo.listGroups()).find((g) => g.id === body.data.groupId);
    if (!group) { res.status(404).json({ error: 'no such group' }); return; }
    if (group.mode === 'strict') {
      res.status(403).json({ error: 'strict_mode', message: 'This group is chat-only. Ask your coach in ChatGPT.' });
      return;
    }

    await repo.expireGrants(new Date());
    let minutes: number;
    let remainingToday: number | null = null;
    if (group.mode === 'quota') {
      const today = todayInTz(config.timezone);
      const usedToday = (await repo.listGrants()).filter((g) =>
        g.groupId === group.id
        && g.source === 'device_quota'
        && g.status !== 'cancelled'
        && todayInTz(config.timezone, new Date(g.startsAt)) === today,
      ).length;
      if (usedToday >= group.quotaPerDay) {
        res.status(403).json({
          error: 'quota_exhausted',
          message: `All ${group.quotaPerDay} unlocks used today. Ask your coach in ChatGPT.`,
          used_today: usedToday, quota_per_day: group.quotaPerDay,
        });
        return;
      }
      minutes = group.quotaMinutes;
      remainingToday = group.quotaPerDay - usedToday - 1;
    } else {
      minutes = Math.min(body.data.minutes ?? group.quotaMinutes, config.maxGrantMinutes);
    }

    const startsAt = body.data.startsAt ? new Date(body.data.startsAt) : new Date();
    const grant = await repo.createGrant(
      group.id, minutes, body.data.reason,
      new Date(startsAt.getTime() + minutes * 60_000), 'device_quota',
      body.data.id, startsAt,
    );
    if (deps.push) {
      scheduleExpiryPoke(deps.push, new Date(grant.expiresAt), `Time's up — re-locking ${group.name}`);
    }
    res.json({ grant, remaining_today: remainingToday });
  }));

  /** First-run starter groups: the app may create groups too (names only, as ever). */
  router.post('/groups', wrap(async (req, res) => {
    const body = z.object({ name: z.string().trim().min(1).max(60) }).safeParse(req.body);
    if (!body.success) { res.status(400).json({ error: body.error.message }); return; }
    const existing = await repo.listGroups();
    const dup = existing.find((g) => g.name.toLowerCase() === body.data.name.toLowerCase());
    if (dup) { res.json({ group: dup, existed: true }); return; }
    res.json({ group: await repo.createGroup(body.data.name), existed: false });
  }));

  /**
   * Shield "Request time" flow: the ShieldAction extension can't reliably post
   * local notifications, so it asks the server to send a real push instead.
   * Plain visible (no mutable-content) so the NSE doesn't rewrite it.
   */
  router.post('/nudge', wrap(async (req, res) => {
    const body = z.object({ body: z.string().trim().min(1).max(120) }).safeParse(req.body);
    if (!body.success) { res.status(400).json({ error: body.error.message }); return; }
    if (!deps.sender) { res.status(503).json({ error: 'push not configured' }); return; }
    const devices = await repo.listDevices();
    await Promise.all(devices.map((d) =>
      deps.sender!.sendNudge(d.apnsToken, 'ScreenCP', body.data.body).catch(() => {})));
    res.json({ sent: devices.length });
  }));

  router.post('/register', wrap(async (req, res) => {
    const body = z.object({ apnsToken: z.string().min(1) }).safeParse(req.body);
    if (!body.success) { res.status(400).json({ error: body.error.message }); return; }
    const device = await repo.registerDevice(body.data.apnsToken);
    res.json({ device });
  }));

  router.get('/sync', wrap(async (req, res) => {
    let since: Date | null = null;
    if (typeof req.query.since !== 'undefined' && req.query.since !== '') {
      if (typeof req.query.since !== 'string') {
        res.status(400).json({ error: 'invalid since (expect ISO-8601)' });
        return;
      }
      const parsed = new Date(req.query.since);
      if (Number.isNaN(parsed.getTime())) {
        res.status(400).json({ error: 'invalid since (expect ISO-8601)' });
        return;
      }
      since = parsed;
    }
    await repo.expireGrants(new Date());
    res.json(await repo.changesSince(since));
  }));

  router.post('/ack', wrap(async (req, res) => {
    const body = z.object({
      apnsToken: z.string().min(1),
      appliedThrough: z.string().datetime({ offset: true }).or(z.string().datetime()),
    }).safeParse(req.body);
    if (!body.success) { res.status(400).json({ error: body.error.message }); return; }
    await repo.ackDevice(body.data.apnsToken, new Date(body.data.appliedThrough));
    res.json({ ok: true });
  }));

  router.post('/events', wrap(async (req, res) => {
    const body = z.object({
      events: z.array(z.object({
        type: z.string().min(1),
        groupId: z.string().uuid().nullish(),
        ts: z.string().datetime({ offset: true }).or(z.string().datetime()).optional(),
        meta: z.record(z.unknown()).optional(),
      })).max(500),
    }).safeParse(req.body);
    if (!body.success) { res.status(400).json({ error: body.error.message }); return; }
    const inserted = await repo.insertEvents(body.data.events);
    res.json({ inserted });
  }));

  router.post('/groups/:id/selection', wrap(async (req, res) => {
    const params = z.object({ id: z.string().uuid() }).safeParse(req.params);
    if (!params.success) { res.status(400).json({ error: params.error.message }); return; }
    const body = z.object({ hasSelection: z.boolean() }).safeParse(req.body);
    if (!body.success) { res.status(400).json({ error: body.error.message }); return; }
    await repo.setGroupSelection(params.data.id, body.data.hasSelection);
    res.json({ ok: true });
  }));

  router.use((err: unknown, _req: Request, res: Response, _next: NextFunction) => {
    res.status(500).json({ error: 'internal error' });
  });

  return router;
}
