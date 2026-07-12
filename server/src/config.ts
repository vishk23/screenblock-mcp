export interface ApnsConfig {
  teamId: string;
  keyId: string;
  key: string;
  topic: string;
  production: boolean;
}

export interface Config {
  port: number;
  databaseUrl: string;
  sqlitePath: string | null;
  mcpBearerToken: string;
  deviceBearerToken: string;
  maxGrantMinutes: number;
  timezone: string;
  apns: ApnsConfig | null;
}

type Env = Record<string, string | undefined>;

export function loadConfig(env: Env = process.env): Config {
  const required = (k: string): string => {
    const v = env[k];
    if (!v) throw new Error(`Missing required env var: ${k}`);
    return v;
  };
  const num = (k: string, fallback: number): number => {
    const v = env[k];
    if (v === undefined) return fallback;
    const n = Number(v);
    if (!Number.isFinite(n)) throw new Error(`Invalid numeric env var: ${k}=${v}`);
    return n;
  };
  const sqlitePath = env.SQLITE_PATH ?? null;
  return {
    port: num('PORT', 8080),
    // DATABASE_URL only required when not using SQLite.
    databaseUrl: sqlitePath ? (env.DATABASE_URL ?? '') : required('DATABASE_URL'),
    sqlitePath,
    mcpBearerToken: required('MCP_BEARER_TOKEN'),
    deviceBearerToken: required('DEVICE_BEARER_TOKEN'),
    maxGrantMinutes: num('MAX_GRANT_MINUTES', 60),
    timezone: env.TIMEZONE ?? 'America/Los_Angeles',
    apns: env.APNS_TEAM_ID
      ? {
          teamId: env.APNS_TEAM_ID,
          keyId: required('APNS_KEY_ID'),
          key: required('APNS_KEY_P8').replace(/\\n/g, '\n'),
          topic: required('APNS_TOPIC'),
          production: env.APNS_PRODUCTION === 'true',
        }
      : null,
  };
}
