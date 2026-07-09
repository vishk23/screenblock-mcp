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
  return {
    port: Number(env.PORT ?? 8080),
    databaseUrl: required('DATABASE_URL'),
    mcpBearerToken: required('MCP_BEARER_TOKEN'),
    deviceBearerToken: required('DEVICE_BEARER_TOKEN'),
    maxGrantMinutes: Number(env.MAX_GRANT_MINUTES ?? 60),
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
