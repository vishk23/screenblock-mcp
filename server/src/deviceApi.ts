import { Router, type Request, type Response, type NextFunction } from 'express';
import { z } from 'zod';
import type { Repo } from './repo.js';
import type { Config } from './config.js';

type AsyncHandler = (req: Request, res: Response) => Promise<void>;
const wrap = (fn: AsyncHandler) => (req: Request, res: Response, next: NextFunction) => {
  fn(req, res).catch(next);
};

export function makeDeviceRouter(deps: { repo: Repo; config: Config }): Router {
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
