import { buildApp } from './app.js';
import { loadConfig } from './config.js';
import { UnifiApi } from './unifi.js';

const config = loadConfig();
const app = buildApp(config, new UnifiApi(config));

try {
  await app.listen({ host: config.host, port: config.port });
} catch (error) {
  app.log.error(error);
  process.exit(1);
}
