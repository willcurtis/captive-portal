import { describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import type { AppConfig } from '../src/config.js';
import type { GuestAuthorizer, UnifiClient } from '../src/unifi.js';

const config: AppConfig = {
  nodeEnv: 'test', host: '127.0.0.1', port: 3000, publicOrigin: 'https://wifi.example.com',
  unifiApiBaseUrl: 'https://unifi.example.com/proxy/network/integration/v1', unifiApiKey: 'x'.repeat(32),
  unifiSiteId: 'site-id', unifiSiteSlug: 'default', allowedSsids: new Set(['Guest WiFi']),
  authorizationMinutes: 120, transactionTtlSeconds: 300, cookieSecret: 's'.repeat(32),
  cookieSecure: true, trustProxy: false, enforceClientIp: true
};

class FakeUnifi implements GuestAuthorizer {
  authorized = false;
  client: UnifiClient = { id: 'client-id', macAddress: 'AA:BB:CC:DD:EE:FF', ipAddress: '127.0.0.1', ssid: 'Guest WiFi', access: { type: 'GUEST', authorized: false } };
  async findClientByMac() { return { ...this.client, access: { ...this.client.access, authorized: this.authorized } }; }
  async authorizeClient() { this.authorized = true; }
  async getClient() { return { ...this.client, access: { ...this.client.access, authorized: this.authorized } }; }
}

function extract(html: string, pattern: RegExp): string {
  const match = pattern.exec(html);
  if (!match?.[1]) throw new Error('Expected value not found');
  return match[1];
}

describe('portal authorization flow', () => {
  it('authorizes a validated guest using a signed transaction', async () => {
    const unifi = new FakeUnifi();
    const app = buildApp(config, unifi);
    const landing = await app.inject({ method: 'GET', url: '/guest/s/default/?id=AA:BB:CC:DD:EE:FF&ssid=Guest%20WiFi' });
    expect(landing.statusCode).toBe(200);
    const csrf = extract(landing.body, /name="csrf" value="([^"]+)"/);
    const cookie = landing.cookies.find((item) => item.name === 'portal_transaction');
    const result = await app.inject({ method: 'POST', url: '/authorize', cookies: { portal_transaction: cookie!.value }, headers: { 'content-type': 'application/x-www-form-urlencoded' }, payload: `csrf=${encodeURIComponent(csrf)}&acceptTerms=yes` });
    expect(result.statusCode).toBe(200);
    expect(result.body).toContain("You're connected");
    expect(unifi.authorized).toBe(true);
    await app.close();
  });

  it('offers the original URL without entering a captive-browser redirect loop', async () => {
    const unifi = new FakeUnifi();
    const app = buildApp(config, unifi);
    const originalUrl = 'http://captive.apple.com/hotspot-detect.html';
    const landing = await app.inject({
      method: 'GET',
      url: `/guest/s/default/?id=AA:BB:CC:DD:EE:FF&ssid=Guest%20WiFi&url=${encodeURIComponent(originalUrl)}`
    });
    const csrf = extract(landing.body, /name="csrf" value="([^"]+)"/);
    const cookie = landing.cookies.find((item) => item.name === 'portal_transaction');
    const result = await app.inject({
      method: 'POST', url: '/authorize', cookies: { portal_transaction: cookie!.value },
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      payload: `csrf=${encodeURIComponent(csrf)}&acceptTerms=yes`
    });
    expect(result.statusCode).toBe(200);
    expect(result.body).toContain("You're connected");
    expect(result.body).toContain(originalUrl);

    const duplicate = await app.inject({
      method: 'POST', url: '/authorize', cookies: { portal_transaction: cookie!.value },
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      payload: `csrf=${encodeURIComponent(csrf)}&acceptTerms=yes`
    });
    expect(duplicate.statusCode).toBe(200);
    expect(duplicate.body).toContain("You're connected");
    await app.close();
  });

  it('rejects an SSID outside the allowlist', async () => {
    const app = buildApp(config, new FakeUnifi());
    const response = await app.inject({ method: 'GET', url: '/guest/s/default?id=AA:BB:CC:DD:EE:FF&ssid=Staff' });
    expect(response.statusCode).toBe(400);
    await app.close();
  });

  it('rejects a forged authorization request', async () => {
    const unifi = new FakeUnifi();
    const app = buildApp(config, unifi);
    const response = await app.inject({ method: 'POST', url: '/authorize', payload: { csrf: 'x'.repeat(24), acceptTerms: 'yes' } });
    expect(response.statusCode).toBe(400);
    expect(unifi.authorized).toBe(false);
    await app.close();
  });
});
