import { describe, it, expect } from 'vitest';
import { loadConfig } from '../src/config.js';

const base = {
  DATABASE_URL: 'postgres://x',
  MCP_BEARER_TOKEN: 't1',
  DEVICE_BEARER_TOKEN: 't2',
};

describe('loadConfig', () => {
  it('loads required values and applies defaults', () => {
    const c = loadConfig(base);
    expect(c.databaseUrl).toBe('postgres://x');
    expect(c.port).toBe(8080);
    expect(c.maxGrantMinutes).toBe(60);
    expect(c.timezone).toBe('America/Los_Angeles');
    expect(c.apns).toBeNull();
  });

  it('throws naming the missing env var', () => {
    expect(() => loadConfig({})).toThrow(/DATABASE_URL/);
  });

  it('throws naming the offending var on a malformed numeric env var', () => {
    expect(() => loadConfig({ ...base, PORT: 'abc' })).toThrow(/PORT/);
  });

  it('parses a valid numeric override', () => {
    const c = loadConfig({ ...base, PORT: '9000' });
    expect(c.port).toBe(9000);
  });

  it('parses APNs config and unescapes the key when APNS_TEAM_ID is set', () => {
    const c = loadConfig({
      ...base,
      APNS_TEAM_ID: 'TEAM',
      APNS_KEY_ID: 'KEY',
      APNS_KEY_P8: '-----BEGIN PRIVATE KEY-----\\nabc\\n-----END PRIVATE KEY-----',
      APNS_TOPIC: 'com.x.app',
      APNS_PRODUCTION: 'true',
    });
    expect(c.apns).toEqual({
      teamId: 'TEAM',
      keyId: 'KEY',
      key: '-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----',
      topic: 'com.x.app',
      production: true,
    });
  });
});
