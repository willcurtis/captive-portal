import { Agent, Headers, fetch } from 'undici';
import type { RequestInit as UndiciRequestInit } from 'undici';
import { z } from 'zod';
import type { AppConfig } from './config.js';

const clientSchema = z.object({
  id: z.string().min(1),
  macAddress: z.string(),
  ipAddress: z.string().optional(),
  ssid: z.string().optional(),
  access: z.object({
    type: z.string(),
    authorized: z.boolean()
  })
}).passthrough();

const listSchema = z.union([
  z.array(clientSchema),
  z.object({ data: z.array(clientSchema) })
]);

export type UnifiClient = z.infer<typeof clientSchema>;
export interface GuestAuthorizer {
  findClientByMac(mac: string): Promise<UnifiClient | undefined>;
  authorizeClient(clientId: string): Promise<void>;
  getClient(clientId: string): Promise<UnifiClient>;
}

export class UnifiApiError extends Error {
  constructor(message: string, readonly status?: number) {
    super(message);
    this.name = 'UnifiApiError';
  }
}

export class UnifiApi implements GuestAuthorizer {
  private readonly agent: Agent;

  constructor(private readonly config: AppConfig) {
    this.agent = new Agent({ connect: {
      rejectUnauthorized: true,
      ...(config.unifiCa ? { ca: config.unifiCa, allowPartialTrustChain: true } : {})
    } });
  }

  async findClientByMac(mac: string): Promise<UnifiClient | undefined> {
    const filter = buildMacAddressFilter(mac);
    const result = listSchema.parse(await this.request(
      `/sites/${encodeURIComponent(this.config.unifiSiteId)}/clients?filter=${encodeURIComponent(filter)}`
    ));
    const clients = Array.isArray(result) ? result : result.data;
    return clients.find((client) => normalizeMac(client.macAddress) === normalizeMac(mac));
  }

  async authorizeClient(clientId: string): Promise<void> {
    await this.request(`/sites/${encodeURIComponent(this.config.unifiSiteId)}/clients/${encodeURIComponent(clientId)}/actions`, {
      method: 'POST',
      body: JSON.stringify({
        action: 'AUTHORIZE_GUEST_ACCESS',
        timeLimitMinutes: this.config.authorizationMinutes,
        ...(this.config.dataLimitMBytes ? { dataUsageLimitMBytes: this.config.dataLimitMBytes } : {}),
        ...(this.config.rxRateLimitKbps ? { rxRateLimitKbps: this.config.rxRateLimitKbps } : {}),
        ...(this.config.txRateLimitKbps ? { txRateLimitKbps: this.config.txRateLimitKbps } : {})
      })
    });
  }

  async getClient(clientId: string): Promise<UnifiClient> {
    return clientSchema.parse(await this.request(
      `/sites/${encodeURIComponent(this.config.unifiSiteId)}/clients/${encodeURIComponent(clientId)}`
    ));
  }

  private async request(path: string, init: UndiciRequestInit = {}): Promise<unknown> {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 10_000);
    const headers = new Headers(init.headers);
    headers.set('accept', 'application/json');
    headers.set('content-type', 'application/json');
    headers.set('x-api-key', this.config.unifiApiKey);
    try {
      const response = await fetch(`${this.config.unifiApiBaseUrl}${path}`, {
        ...init,
        headers,
        signal: controller.signal,
        dispatcher: this.agent
      });
      const text = await response.text();
      if (!response.ok) {
        throw new UnifiApiError(`UniFi API request failed with HTTP ${response.status}`, response.status);
      }
      return text ? JSON.parse(text) : {};
    } catch (error) {
      if (error instanceof UnifiApiError) throw error;
      throw new UnifiApiError('UniFi API request failed');
    } finally {
      clearTimeout(timeout);
    }
  }
}

export function normalizeMac(mac: string): string {
  return mac.replace(/[:-]/g, '').toLowerCase();
}

export function buildMacAddressFilter(mac: string): string {
  return `macAddress.eq('${mac.toLowerCase()}')`;
}
