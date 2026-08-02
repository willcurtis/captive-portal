import { describe, expect, it } from 'vitest';
import { loadConfig } from '../src/config.js';

const valid = {
  NODE_ENV: 'test', PUBLIC_ORIGIN: 'https://wifi.example.com',
  UNIFI_API_BASE_URL: 'https://unifi.example.com/proxy/network/integration/v1',
  UNIFI_API_KEY: 'x'.repeat(32), UNIFI_SITE_ID: 'site-id', ALLOWED_SSIDS: 'Guest,Visitors',
  COOKIE_SECRET: 's'.repeat(32), COOKIE_SECURE: 'false', ENFORCE_CLIENT_IP: 'true'
};

describe('configuration', () => {
  it('parses and bounds security-sensitive settings', () => {
    const config = loadConfig({ ...valid, DATA_LIMIT_MBYTES: '0' });
    expect(config.allowedSsids).toEqual(new Set(['Guest', 'Visitors']));
    expect(config.authorizationMinutes).toBe(120);
    expect(config.dataLimitMBytes).toBeUndefined();
  });

  it('rejects insecure public origins', () => {
    expect(() => loadConfig({ ...valid, PUBLIC_ORIGIN: 'http://wifi.example.com' })).toThrow();
  });

  it('rejects weak cookie secrets', () => {
    expect(() => loadConfig({ ...valid, COOKIE_SECRET: 'weak' })).toThrow();
  });
});
