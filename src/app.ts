import { randomBytes } from 'node:crypto';
import { join } from 'node:path';
import Fastify from 'fastify';
import type { FastifyRequest } from 'fastify';
import cookie from '@fastify/cookie';
import formbody from '@fastify/formbody';
import helmet from '@fastify/helmet';
import rateLimit from '@fastify/rate-limit';
import fastifyStatic from '@fastify/static';
import { z } from 'zod';
import type { AppConfig } from './config.js';
import type { GuestAuthorizer } from './unifi.js';
import { normalizeMac } from './unifi.js';
import { policyView, resultView, welcomeView } from './views.js';

const redirectQuery = z.object({
  id: z.string().regex(/^([0-9a-f]{2}:){5}[0-9a-f]{2}$/i),
  ssid: z.string().min(1).max(64),
  ap: z.string().regex(/^([0-9a-f]{2}:){5}[0-9a-f]{2}$/i).optional(),
  t: z.coerce.number().int().positive().optional(),
  url: z.string().max(2048).optional()
});
const authorizeBody = z.object({ csrf: z.string().min(20), acceptTerms: z.literal('yes') });
const transactionSchema = z.object({
  mac: z.string(), ssid: z.string(), csrf: z.string(), issuedAt: z.number(),
  originalUrl: z.url().refine((url) => url.startsWith('http://') || url.startsWith('https://')).optional()
});
const transactionCookie = 'portal_transaction';

export function buildApp(config: AppConfig, unifi: GuestAuthorizer) {
  const app = Fastify({
    trustProxy: config.trustProxy,
    routerOptions: { ignoreTrailingSlash: true },
    logger: config.nodeEnv === 'test' ? false : {
      redact: ['req.headers.cookie', 'req.body.csrf'],
      serializers: { req: (request: FastifyRequest) => ({
        method: request.method,
        path: request.url.split('?')[0],
        remoteAddress: request.ip
      }) }
    },
    bodyLimit: 8 * 1024
  });

  app.register(cookie, { secret: config.cookieSecret, hook: 'onRequest' });
  app.register(formbody);
  app.register(helmet, {
    global: true,
    contentSecurityPolicy: { directives: { defaultSrc: ["'self'"], styleSrc: ["'self'"], imgSrc: ["'self'", 'data:'], scriptSrc: ["'none'"], frameAncestors: ["'none'"] } },
    hsts: config.nodeEnv === 'production'
  });
  app.register(rateLimit, { max: 30, timeWindow: '1 minute' });
  app.register(fastifyStatic, { root: join(process.cwd(), 'public'), prefix: '/assets/' });

  app.get('/health/live', async () => ({ status: 'ok' }));
  app.get('/health/ready', async (_request, reply) => reply.send({ status: 'ready' }));
  app.get('/terms', async (_request, reply) => reply.type('text/html').send(policyView('terms')));
  app.get('/privacy', async (_request, reply) => reply.type('text/html').send(policyView('privacy')));

  app.get('/guest/s/:site', async (request, reply) => {
    const site = z.object({ site: z.string() }).safeParse(request.params);
    const query = redirectQuery.safeParse(request.query);
    if (!site.success || site.data.site !== config.unifiSiteSlug || !query.success || !config.allowedSsids.has(query.data.ssid)) {
      return reply.code(400).type('text/html').send(resultView(false));
    }
    if (query.data.t && Math.abs(Date.now() / 1000 - query.data.t) > config.transactionTtlSeconds) {
      return reply.code(400).type('text/html').send(resultView(false));
    }
    const csrf = randomBytes(24).toString('base64url');
    let originalUrl: string | undefined;
    if (query.data.url) {
      try {
        const parsed = new URL(query.data.url);
        if (parsed.protocol === 'http:' || parsed.protocol === 'https:') originalUrl = parsed.toString();
      } catch { originalUrl = undefined; }
    }
    const transaction = Buffer.from(JSON.stringify({
      mac: query.data.id, ssid: query.data.ssid, csrf, issuedAt: Date.now(), originalUrl
    })).toString('base64url');
    reply.setCookie(transactionCookie, transaction, {
      path: '/authorize', httpOnly: true, secure: config.cookieSecure, sameSite: 'lax', signed: true,
      maxAge: config.transactionTtlSeconds
    });
    return reply.type('text/html').send(welcomeView(query.data.ssid, csrf));
  });

  app.post('/authorize', { config: { rateLimit: { max: 5, timeWindow: '1 minute' } } }, async (request, reply) => {
    const body = authorizeBody.safeParse(request.body);
    const rawCookie = request.cookies[transactionCookie];
    const unsigned = rawCookie ? request.unsignCookie(rawCookie) : undefined;
    let transaction: z.infer<typeof transactionSchema> | undefined;
    try {
      if (unsigned?.valid) transaction = transactionSchema.parse(JSON.parse(Buffer.from(unsigned.value, 'base64url').toString()));
    } catch { transaction = undefined; }
    if (!body.success || !transaction || body.data.csrf !== transaction.csrf || Date.now() - transaction.issuedAt > config.transactionTtlSeconds * 1000) {
      reply.clearCookie(transactionCookie, { path: '/authorize' });
      return reply.code(400).type('text/html').send(resultView(false));
    }

    try {
      let client;
      for (let attempt = 0; attempt < 5; attempt += 1) {
        client = await unifi.findClientByMac(transaction.mac);
        const validClient = client && normalizeMac(client.macAddress) === normalizeMac(transaction.mac)
          && client.access.type === 'GUEST'
          && (!client.ssid || client.ssid === transaction.ssid)
          && (!config.enforceClientIp || !client.ipAddress || client.ipAddress === request.ip);
        if (validClient) break;
        if (attempt < 4) await new Promise((resolve) => setTimeout(resolve, 500));
      }
      if (!client || normalizeMac(client.macAddress) !== normalizeMac(transaction.mac)
        || client.access.type !== 'GUEST'
        || (client.ssid && client.ssid !== transaction.ssid)
        || (config.enforceClientIp && client.ipAddress && client.ipAddress !== request.ip)) {
        request.log.warn({
          macSuffix: transaction.mac.slice(-5),
          clientFound: Boolean(client),
          accessType: client?.access.type,
          authorized: client?.access.authorized,
          clientIpMatches: client?.ipAddress ? client.ipAddress === request.ip : undefined,
          ssidMatches: client?.ssid ? client.ssid === transaction.ssid : undefined
        }, 'guest client validation failed');
        return reply.code(403).type('text/html').send(resultView(false));
      }

      if (!client.access.authorized) {
        await unifi.authorizeClient(client.id);
        const confirmed = await unifi.getClient(client.id);
        if (!confirmed.access.authorized) throw new Error('Authorization was not confirmed');
        request.log.info({ clientId: client.id, macSuffix: transaction.mac.slice(-5), ssid: transaction.ssid }, 'guest authorized');
      } else {
        request.log.info({ clientId: client.id, macSuffix: transaction.mac.slice(-5), ssid: transaction.ssid }, 'guest already authorized');
      }
      const redirectUrl = config.postAuthRedirectUrl ?? transaction.originalUrl;
      return reply.type('text/html').send(resultView(true, redirectUrl));
    } catch (error) {
      request.log.error({ err: error }, 'guest authorization failed');
      return reply.code(502).type('text/html').send(resultView(false));
    }
  });

  app.setNotFoundHandler(async (_request, reply) => reply.code(404).type('text/html').send(resultView(false)));
  return app;
}
