import express, { type Express, type Request, type Response, type NextFunction } from 'express';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { buildMcpServer, type Deps } from './mcp.js';
import { makeDeviceRouter } from './deviceApi.js';

export function makeApp(deps: Deps): Express {
  const app = express();
  app.use(express.json({ limit: '1mb' }));

  app.get('/healthz', (_req, res) => { res.json({ ok: true }); });

  app.use('/device', makeDeviceRouter(deps));

  const mcpAuth = (req: Request, res: Response, next: NextFunction) => {
    const bearer = (req.headers.authorization ?? '').replace(/^Bearer\s+/i, '');
    const pathSecret = req.params.secret;
    if (bearer === deps.config.mcpBearerToken || pathSecret === deps.config.mcpBearerToken) {
      next();
      return;
    }
    res.status(401).json({ error: 'unauthorized' });
  };

  // Stateless Streamable HTTP: fresh server + transport per request.
  const handleMcp = async (req: Request, res: Response) => {
    const server = buildMcpServer(deps);
    const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
    res.on('close', () => {
      void transport.close();
      void server.close();
    });
    await server.connect(transport);
    await transport.handleRequest(req, res, req.body);
  };

  app.post('/mcp', mcpAuth, (req: Request, res: Response, next: NextFunction) => {
    handleMcp(req, res).catch(next);
  });
  app.post('/mcp/:secret', mcpAuth, (req: Request, res: Response, next: NextFunction) => {
    handleMcp(req, res).catch(next);
  });
  // Stateless mode: no server->client stream or session to manage.
  const noSession = (_req: Request, res: Response) => { res.status(405).end(); };
  app.get(['/mcp', '/mcp/:secret'], noSession);
  app.delete(['/mcp', '/mcp/:secret'], noSession);

  // Express 4 does not forward rejections from async handlers to error
  // middleware automatically; handleMcp's rejections are funneled here via
  // the .catch(next) wrappers above. handleMcp may have already started
  // streaming a response by the time it rejects, so guard on headersSent.
  app.use((err: unknown, _req: Request, res: Response, next: NextFunction) => {
    if (res.headersSent) { next(err); return; }
    res.status(500).json({ error: 'internal error' });
  });

  return app;
}
