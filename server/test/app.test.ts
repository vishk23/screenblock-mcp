import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import http from 'node:http';
import request from 'supertest';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { makeApp } from '../src/app.js';
import { FakeRepo, FakePush } from './fakes.js';
import type { Config } from '../src/config.js';

const config: Config = {
  port: 0, databaseUrl: '', mcpBearerToken: 'mcp-secret', deviceBearerToken: 'device-secret',
  maxGrantMinutes: 60, timezone: 'America/Los_Angeles', apns: null,
};

describe('app wiring', () => {
  const repo = new FakeRepo();
  const app = makeApp({ repo, push: new FakePush(), config });
  let server: http.Server;
  let baseUrl: string;

  beforeAll(async () => {
    server = http.createServer(app);
    await new Promise<void>((r) => server.listen(0, r));
    const addr = server.address() as { port: number };
    baseUrl = `http://127.0.0.1:${addr.port}`;
  });

  afterAll(() => new Promise<void>((r) => server.close(() => r())));

  it('serves a health check', async () => {
    const r = await request(app).get('/healthz').expect(200);
    expect(r.body.ok).toBe(true);
  });

  it('rejects /mcp without the secret', async () => {
    await request(app).post('/mcp').send({}).expect(401);
    await request(app).post('/mcp/wrong-secret').send({}).expect(401);
  });

  it('rejects /mcp with an incorrect Bearer token', async () => {
    await request(app).post('/mcp')
      .set('Authorization', 'Bearer wrong')
      .send({}).expect(401);
  });

  it('completes a real MCP handshake and tool call via secret-in-path', async () => {
    await repo.createGroup('Social');
    const transport = new StreamableHTTPClientTransport(new URL(`${baseUrl}/mcp/mcp-secret`));
    const client = new Client({ name: 'e2e-test', version: '0.0.0' });
    await client.connect(transport);
    const { tools } = await client.listTools();
    expect(tools).toHaveLength(14);
    const result = await client.callTool({ name: 'list_groups', arguments: {} });
    const payload = JSON.parse((result.content as Array<{ text: string }>)[0].text);
    expect(payload.groups[0].name).toBe('Social');
    await client.close();
  });

  it('accepts /mcp with a Bearer header too', async () => {
    const transport = new StreamableHTTPClientTransport(new URL(`${baseUrl}/mcp`), {
      requestInit: { headers: { Authorization: 'Bearer mcp-secret' } },
    });
    const client = new Client({ name: 'e2e-test-2', version: '0.0.0' });
    await client.connect(transport);
    const { tools } = await client.listTools();
    expect(tools).toHaveLength(14);
    await client.close();
  });

  it('mounts the device API behind its own bearer', async () => {
    await request(app).post('/device/register')
      .set('Authorization', 'Bearer device-secret')
      .send({ apnsToken: 'tok1' }).expect(200);
  });

  it('GET and DELETE on /mcp are not allowed (stateless mode)', async () => {
    await request(app).get('/mcp/mcp-secret').expect(405);
    await request(app).delete('/mcp/mcp-secret').expect(405);
    // The bare /mcp GET/DELETE handlers are registered without mcpAuth,
    // so they 405 with no credentials at all rather than 401.
    await request(app).get('/mcp').expect(405);
    await request(app).delete('/mcp').expect(405);
  });

  it('does not hang or crash when a tool handler rejects', async () => {
    class RejectingRepo extends FakeRepo {
      async listGroups(): Promise<never> {
        throw new Error('boom: db unavailable');
      }
    }
    const rejectingApp = makeApp({ repo: new RejectingRepo(), push: new FakePush(), config });
    const rejectingServer = http.createServer(rejectingApp);
    await new Promise<void>((r) => rejectingServer.listen(0, r));
    const addr = rejectingServer.address() as { port: number };
    const rejectingBaseUrl = `http://127.0.0.1:${addr.port}`;

    try {
      const transport = new StreamableHTTPClientTransport(new URL(`${rejectingBaseUrl}/mcp/mcp-secret`));
      const client = new Client({ name: 'e2e-test-reject', version: '0.0.0' });
      await client.connect(transport);

      let httpStatus: number | undefined;
      let mcpErrored = false;
      try {
        const result = await client.callTool({ name: 'list_groups', arguments: {} });
        mcpErrored = result.isError === true;
      } catch (err) {
        // The MCP SDK client throws a StreamableHTTPError (code = HTTP
        // status) when the underlying HTTP request surfaces a non-2xx
        // status. Only accept errors that plainly indicate our error
        // middleware's HTTP 500 (status.code === 500, or "500" appearing
        // in the message the SDK builds from the response status/text);
        // anything else (e.g. an unrelated transport failure like
        // ECONNRESET) is unexpected and should fail the test loudly.
        const maybe = err as { code?: number } & { message?: string };
        const looksLike500 = maybe.code === 500 || /\b500\b/.test(maybe.message ?? '');
        if (!looksLike500) {
          throw err;
        }
        httpStatus = maybe.code;
        mcpErrored = true;
      }
      // Contract: no hang, no crash. Either the MCP layer surfaced the
      // rejection as a JSON-RPC error, or (if it slipped through) the
      // Express-level error middleware returned a 500.
      expect(mcpErrored || httpStatus === 500).toBe(true);
      await client.close();
    } finally {
      await new Promise<void>((r) => rejectingServer.close(() => r()));
    }
  });
});
