import { describe, it, expect } from 'vitest';
import express from 'express';
import request from 'supertest';
import { makeDeviceRouter } from '../src/deviceApi.js';
import { FakeRepo } from './fakes.js';
import type { Config } from '../src/config.js';

const config: Config = {
  port: 0, databaseUrl: '', mcpBearerToken: 'mcp-secret', deviceBearerToken: 'device-secret',
  maxGrantMinutes: 60, timezone: 'America/Los_Angeles', apns: null,
};

function makeApp(repo = new FakeRepo()) {
  const app = express();
  app.use(express.json());
  app.use('/device', makeDeviceRouter({ repo, config }));
  return { app, repo };
}

const auth = { Authorization: 'Bearer device-secret' };

describe('device API', () => {
  it('rejects missing/wrong bearer', async () => {
    const { app } = makeApp();
    await request(app).post('/device/register').send({ apnsToken: 't' }).expect(401);
    await request(app).post('/device/register')
      .set('Authorization', 'Bearer wrong').send({ apnsToken: 't' }).expect(401);
  });

  it('registers a device (idempotent) and acks progress', async () => {
    const { app, repo } = makeApp();
    const r1 = await request(app).post('/device/register').set(auth).send({ apnsToken: 'tok1' }).expect(200);
    expect(r1.body.device.apnsToken).toBe('tok1');
    await request(app).post('/device/register').set(auth).send({ apnsToken: 'tok1' }).expect(200);
    expect(await repo.listDevices()).toHaveLength(1);

    await request(app).post('/device/ack').set(auth)
      .send({ apnsToken: 'tok1', appliedThrough: '2026-07-08T12:00:00Z' }).expect(200);
    expect((await repo.listDevices())[0].appliedThrough).toBe('2026-07-08T12:00:00.000Z');
  });

  it('sync returns full payload without since, delta with since, and expires grants', async () => {
    const { app, repo } = makeApp();
    const g = await repo.createGroup('Social');
    await repo.replacePolicy(g.id, 'limit', { minutesPerDay: 30 });
    await repo.createGrant(g.id, 15, null, new Date(Date.now() - 1000)); // already overdue

    const full = await request(app).get('/device/sync').set(auth).expect(200);
    expect(full.body.groups).toHaveLength(1);
    expect(full.body.policies).toHaveLength(1);
    expect(full.body.grants[0].status).toBe('expired'); // sync expired it
    expect(full.body.serverTime).toBeTruthy();

    const future = new Date(Date.now() + 60_000).toISOString();
    const delta = await request(app).get('/device/sync').set(auth)
      .query({ since: future }).expect(200);
    expect(delta.body.groups).toHaveLength(0);
  });

  it('rejects an invalid since parameter', async () => {
    const { app } = makeApp();
    await request(app).get('/device/sync').set(auth).query({ since: 'not-a-date' }).expect(400);
  });

  it('accepts event batches and group selection updates', async () => {
    const { app, repo } = makeApp();
    const g = await repo.createGroup('Social');

    const r = await request(app).post('/device/events').set(auth).send({
      events: [
        { type: 'shield_shown', groupId: g.id, ts: '2026-07-08T11:00:00Z' },
        { type: 'threshold_crossed', groupId: g.id, meta: { thresholdMinutes: 30 } },
      ],
    }).expect(200);
    expect(r.body.inserted).toBe(2);

    await request(app).post(`/device/groups/${g.id}/selection`).set(auth)
      .send({ hasSelection: true }).expect(200);
    expect((await repo.listGroups())[0].hasSelection).toBe(true);
  });

  it('returns 500 (not a hang) when the repo rejects inside an async handler', async () => {
    const repo = new FakeRepo();
    const failingRepo = {
      ...repo,
      registerDevice: () => Promise.reject(new Error('db exploded')),
    };
    const app = express();
    app.use(express.json());
    app.use('/device', makeDeviceRouter({ repo: failingRepo as unknown as FakeRepo, config }));

    const res = await request(app).post('/device/register').set(auth).send({ apnsToken: 'tok1' });
    expect(res.status).toBe(500);
    expect(res.body).toEqual({ error: 'internal error' });
  });

  it('rejects invalid request bodies with 400', async () => {
    const { app, repo } = makeApp();
    const g = await repo.createGroup('Social');

    await request(app).post('/device/register').set(auth).send({}).expect(400);
    await request(app).post('/device/ack').set(auth).send({ apnsToken: 't' }).expect(400);
    await request(app).post('/device/events').set(auth).send({ events: [{}] }).expect(400);
    await request(app).post('/device/events').set(auth)
      .send({ events: Array.from({ length: 501 }, () => ({ type: 'x' })) }).expect(400);
    await request(app).post(`/device/groups/${g.id}/selection`).set(auth).send({}).expect(400);
  });

  it('rejects a repeated since query param (array) with 400', async () => {
    const { app } = makeApp();
    await request(app).get('/device/sync').set(auth).query('since=a&since=b').expect(400);
  });

  it('rejects a non-uuid group id in the selection route with 400', async () => {
    const { app } = makeApp();
    await request(app).post('/device/groups/not-a-uuid/selection').set(auth)
      .send({ hasSelection: true }).expect(400);
  });
});
