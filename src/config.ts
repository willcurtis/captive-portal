import { readFileSync } from 'node:fs';
import { z } from 'zod';

const booleanValue = z.enum(['true', 'false']).transform((value) => value === 'true');
const optionalLimit = z.coerce.number().int().min(0).optional().transform((value) => value === 0 ? undefined : value);

const environmentSchema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('production'),
  HOST: z.string().min(1).default('0.0.0.0'),
  PORT: z.coerce.number().int().min(1).max(65535).default(3000),
  PUBLIC_ORIGIN: z.url().refine((url) => url.startsWith('https://'), 'PUBLIC_ORIGIN must use HTTPS'),
  UNIFI_API_BASE_URL: z.url().refine((url) => url.startsWith('https://'), 'UNIFI_API_BASE_URL must use HTTPS'),
  UNIFI_API_KEY: z.string().min(16).optional(),
  UNIFI_API_KEY_FILE: z.string().min(1).optional(),
  UNIFI_SITE_ID: z.string().min(1),
  UNIFI_SITE_SLUG: z.string().regex(/^[a-zA-Z0-9_-]+$/).default('default'),
  UNIFI_CA_FILE: z.string().min(1).optional(),
  ALLOWED_SSIDS: z.string().min(1),
  AUTHORIZATION_MINUTES: z.coerce.number().int().min(1).max(10080).default(120),
  DATA_LIMIT_MBYTES: optionalLimit,
  RX_RATE_LIMIT_KBPS: optionalLimit,
  TX_RATE_LIMIT_KBPS: optionalLimit,
  TRANSACTION_TTL_SECONDS: z.coerce.number().int().min(60).max(900).default(300),
  COOKIE_SECRET: z.string().min(32).optional(),
  COOKIE_SECRET_FILE: z.string().min(1).optional(),
  COOKIE_SECURE: booleanValue.default(true),
  TRUST_PROXY: booleanValue.default(false),
  ENFORCE_CLIENT_IP: booleanValue.default(true),
  POST_AUTH_REDIRECT_URL: z.union([z.literal(''), z.url()]).default('')
});

export type AppConfig = {
  nodeEnv: 'development' | 'test' | 'production';
  host: string;
  port: number;
  publicOrigin: string;
  unifiApiBaseUrl: string;
  unifiApiKey: string;
  unifiSiteId: string;
  unifiSiteSlug: string;
  unifiCa?: Buffer;
  allowedSsids: ReadonlySet<string>;
  authorizationMinutes: number;
  dataLimitMBytes?: number;
  rxRateLimitKbps?: number;
  txRateLimitKbps?: number;
  transactionTtlSeconds: number;
  cookieSecret: string;
  cookieSecure: boolean;
  trustProxy: boolean;
  enforceClientIp: boolean;
  postAuthRedirectUrl?: string;
};

export function loadConfig(environment: NodeJS.ProcessEnv = process.env): AppConfig {
  const value = environmentSchema.parse(environment);
  const unifiCa = value.UNIFI_CA_FILE ? readFileSync(value.UNIFI_CA_FILE) : undefined;
  const unifiApiKey = value.UNIFI_API_KEY_FILE
    ? readFileSync(value.UNIFI_API_KEY_FILE, 'utf8').trim()
    : value.UNIFI_API_KEY;
  if (!unifiApiKey || unifiApiKey.length < 16) throw new Error('A valid UniFi API key is required');
  const cookieSecret = value.COOKIE_SECRET_FILE
    ? readFileSync(value.COOKIE_SECRET_FILE, 'utf8').trim()
    : value.COOKIE_SECRET;
  if (!cookieSecret || cookieSecret.length < 32) throw new Error('A cookie secret of at least 32 characters is required');
  return {
    nodeEnv: value.NODE_ENV,
    host: value.HOST,
    port: value.PORT,
    publicOrigin: value.PUBLIC_ORIGIN.replace(/\/$/, ''),
    unifiApiBaseUrl: value.UNIFI_API_BASE_URL.replace(/\/$/, ''),
    unifiApiKey,
    unifiSiteId: value.UNIFI_SITE_ID,
    unifiSiteSlug: value.UNIFI_SITE_SLUG,
    ...(unifiCa ? { unifiCa } : {}),
    allowedSsids: new Set(value.ALLOWED_SSIDS.split(',').map((item) => item.trim()).filter(Boolean)),
    authorizationMinutes: value.AUTHORIZATION_MINUTES,
    ...(value.DATA_LIMIT_MBYTES ? { dataLimitMBytes: value.DATA_LIMIT_MBYTES } : {}),
    ...(value.RX_RATE_LIMIT_KBPS ? { rxRateLimitKbps: value.RX_RATE_LIMIT_KBPS } : {}),
    ...(value.TX_RATE_LIMIT_KBPS ? { txRateLimitKbps: value.TX_RATE_LIMIT_KBPS } : {}),
    transactionTtlSeconds: value.TRANSACTION_TTL_SECONDS,
    cookieSecret,
    cookieSecure: value.COOKIE_SECURE,
    trustProxy: value.TRUST_PROXY,
    enforceClientIp: value.ENFORCE_CLIENT_IP,
    ...(value.POST_AUTH_REDIRECT_URL ? { postAuthRedirectUrl: value.POST_AUTH_REDIRECT_URL } : {})
  };
}
