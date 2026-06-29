import { spawn } from 'node:child_process';
import { existsSync, writeFileSync, mkdirSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { join, dirname, extname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';
import { createConnection } from 'node:net';
import { gunzipSync } from 'node:zlib';
import { createServer, request as httpRequest } from 'node:http';

const __dirname = dirname(fileURLToPath(import.meta.url));

const PORT = parseInt(process.env.DATABRICKS_APP_PORT || process.env.PORT || '8000', 10);
const INTERNAL_PORT = PORT + 1;
const REDIS_PORT = 6379;
const REDIS_PASSWORD = process.env.REDIS_PASSWORD || 'change-me-redis-secret';
const PUBLIC_DIR = join(__dirname, 'public');

const MIME_TYPES = {
  '.html': 'text/html',
  '.js': 'application/javascript',
  '.css': 'text/css',
  '.json': 'application/json',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.txt': 'text/plain',
  '.webp': 'image/webp',
  '.map': 'application/json',
};

function decompressFhirData() {
  const fhirDir = join(__dirname, 'server', 'fhir', 'r4');
  if (!existsSync(fhirDir)) {
    console.error('ERROR: FHIR data directory not found at', fhirDir);
    process.exit(1);
  }

  const gzFiles = readdirSync(fhirDir).filter(f => f.endsWith('.json.gz'));
  if (gzFiles.length === 0) return;

  console.log(`Decompressing ${gzFiles.length} FHIR definition files...`);
  for (const gz of gzFiles) {
    const gzPath = join(fhirDir, gz);
    const jsonPath = join(fhirDir, gz.replace('.gz', ''));
    if (!existsSync(jsonPath)) {
      const data = gunzipSync(readFileSync(gzPath));
      writeFileSync(jsonPath, data);
    }
  }
  console.log('FHIR definitions ready.');
}

async function startRedis() {
  const redisBin = join(__dirname, 'bin', 'redis-server');

  if (!existsSync(redisBin)) {
    console.error('ERROR: Redis binary not found at', redisBin);
    console.error('The build step should have downloaded it.');
    process.exit(1);
  }

  mkdirSync('/tmp/redis-data', { recursive: true });
  console.log(`Starting Redis on port ${REDIS_PORT}...`);

  const redisProc = spawn(redisBin, [
    '--port', String(REDIS_PORT),
    '--requirepass', REDIS_PASSWORD,
    '--dir', '/tmp/redis-data',
    '--daemonize', 'no',
    '--appendonly', 'yes',
    '--maxmemory', '256mb',
    '--maxmemory-policy', 'noeviction',
    '--save', '',
  ], { stdio: ['ignore', 'pipe', 'pipe'] });

  redisProc.stdout.on('data', (d) => process.stdout.write(`[redis] ${d}`));
  redisProc.stderr.on('data', (d) => process.stderr.write(`[redis] ${d}`));
  redisProc.on('exit', (code) => {
    console.error(`Redis exited with code ${code}`);
    process.exit(1);
  });

  for (let i = 0; i < 30; i++) {
    const ready = await new Promise((resolve) => {
      const sock = createConnection({ host: '127.0.0.1', port: REDIS_PORT }, () => {
        sock.write(`*2\r\n$4\r\nAUTH\r\n$${REDIS_PASSWORD.length}\r\n${REDIS_PASSWORD}\r\n*1\r\n$4\r\nPING\r\n`);
      });
      sock.on('data', (data) => {
        sock.destroy();
        resolve(data.toString().includes('+PONG'));
      });
      sock.on('error', () => { sock.destroy(); resolve(false); });
      sock.setTimeout(1000, () => { sock.destroy(); resolve(false); });
    });
    if (ready) {
      console.log('Redis is ready.');
      return redisProc;
    }
    await sleep(500);
  }

  console.error('ERROR: Redis failed to start within 15 seconds.');
  redisProc.kill();
  process.exit(1);
}

function generateConfig() {
  const baseUrl = process.env.DATABRICKS_APP_URL
    ? `${process.env.DATABRICKS_APP_URL}/`
    : `http://localhost:${PORT}/`;

  const config = {
    port: INTERNAL_PORT,
    baseUrl,
    appBaseUrl: baseUrl,
    storageBaseUrl: `${baseUrl}storage/`,
    binaryStorage: 'file:/tmp/medplum-binary',
    database: {
      host: process.env.LAKEBASE_HOST || 'your-lakebase-endpoint.database.region.cloud.databricks.com',
      port: parseInt(process.env.LAKEBASE_PORT || '5432', 10),
      dbname: process.env.LAKEBASE_DB || 'databricks_postgres',
      username: process.env.LAKEBASE_USER || 'medplum_svc',
      password: process.env.LAKEBASE_PASSWORD || 'change-me-db-password',
      runMigrations: true,
      ssl: { require: true, rejectUnauthorized: false },
    },
    redis: {
      host: '127.0.0.1',
      port: REDIS_PORT,
      password: REDIS_PASSWORD,
    },
    maxJsonSize: '16mb',
    shutdownTimeoutMilliseconds: 15000,
    allowedOrigins: '*',
  };

  const configPath = join(__dirname, 'medplum.config.json');
  writeFileSync(configPath, JSON.stringify(config, null, 2));
  console.log(`Config written to ${configPath}`);
  return configPath;
}

function tryServeStaticFile(pathname, res) {
  if (!existsSync(PUBLIC_DIR)) return false;

  const filePath = join(PUBLIC_DIR, pathname);

  // Prevent path traversal
  if (!filePath.startsWith(PUBLIC_DIR)) return false;

  try {
    const stat = statSync(filePath);
    if (stat.isFile()) {
      const ext = extname(filePath).toLowerCase();
      const contentType = MIME_TYPES[ext] || 'application/octet-stream';
      const content = readFileSync(filePath);
      res.writeHead(200, {
        'Content-Type': contentType,
        'Content-Length': content.length,
        'Cache-Control': ext === '.html' ? 'no-cache' : 'public, max-age=31536000, immutable',
      });
      res.end(content);
      return true;
    }
  } catch {
    // File doesn't exist or can't be read
  }
  return false;
}

function isApiPath(pathname) {
  const apiPrefixes = [
    '/api/',
    '/fhir/',
    '/auth/',
    '/oauth2/',
    '/admin/',
    '/.well-known/',
    '/scim/',
    '/storage/',
    '/webhook/',
    '/healthcheck',
    '/openapi.json',
    '/cds-services/',
    '/dicom/',
    '/email/',
    '/fhircast/',
    '/keyvalue/',
    '/shl/',
    '/mcp',
    '/ws/',
  ];
  return apiPrefixes.some(prefix => pathname.startsWith(prefix));
}

const COOKIE_NAME = '__medplum_token';
const IS_SECURE = (process.env.DATABRICKS_APP_URL || '').startsWith('https');

function parseCookies(cookieHeader) {
  const cookies = {};
  if (!cookieHeader) return cookies;
  for (const pair of cookieHeader.split(';')) {
    const idx = pair.indexOf('=');
    if (idx < 0) continue;
    const key = pair.slice(0, idx).trim();
    const val = pair.slice(idx + 1).trim();
    cookies[key] = decodeURIComponent(val);
  }
  return cookies;
}

function makeSetCookie(value, clear) {
  let cookie = `${COOKIE_NAME}=${encodeURIComponent(value)}; Path=/; HttpOnly; SameSite=Lax`;
  if (IS_SECURE) cookie += '; Secure';
  if (clear) cookie += '; Max-Age=0';
  return cookie;
}

function proxyRequest(req, res) {
  const headers = { ...req.headers, host: `127.0.0.1:${INTERNAL_PORT}` };

  // Debug: log what Authorization header the gateway forwards to us
  const url = new URL(req.url, `http://localhost:${PORT}`);
  if (url.pathname === '/auth/me' || url.pathname === '/oauth2/token') {
    const authHeader = headers['authorization'] || '(none)';
    console.log(`[proxy] ${req.method} ${url.pathname} | Auth header: ${authHeader.substring(0, 40)}...`);
  }

  // ALWAYS prefer cookie-based token over the Authorization header,
  // because the Databricks gateway REPLACES the original Authorization header
  // with its own internal token. The cookie carries the real Medplum token.
  const cookies = parseCookies(req.headers['cookie']);
  if (cookies[COOKIE_NAME]) {
    headers['authorization'] = 'Bearer ' + cookies[COOKIE_NAME];
    if (url.pathname === '/auth/me') {
      console.log('[proxy] Injecting auth from cookie (overriding gateway token)');
    }
  }

  const options = {
    hostname: '127.0.0.1',
    port: INTERNAL_PORT,
    path: req.url,
    method: req.method,
    headers,
  };

  const pathname = url.pathname;
  const isTokenEndpoint = pathname === '/oauth2/token';
  const isLogoutEndpoint = pathname === '/auth/logout';

  const proxyReq = httpRequest(options, (proxyRes) => {
    if (isTokenEndpoint && proxyRes.statusCode >= 200 && proxyRes.statusCode < 300) {
      const chunks = [];
      proxyRes.on('data', (chunk) => chunks.push(chunk));
      proxyRes.on('end', () => {
        const body = Buffer.concat(chunks);
        try {
          const json = JSON.parse(body.toString());
          if (json.access_token) {
            const setCookie = makeSetCookie(json.access_token, false);
            const resHeaders = { ...proxyRes.headers };
            resHeaders['set-cookie'] = setCookie;
            console.log(`[proxy] /oauth2/token response has access_token (${json.access_token.length} chars), setting cookie`);
            res.writeHead(proxyRes.statusCode, resHeaders);
            res.end(body);
            console.log('[proxy] Token cookie set for session');
            return;
          }
        } catch { /* not JSON, fall through */ }
        res.writeHead(proxyRes.statusCode, proxyRes.headers);
        res.end(body);
      });
    } else if (isLogoutEndpoint && proxyRes.statusCode >= 200 && proxyRes.statusCode < 300) {
      const resHeaders = { ...proxyRes.headers };
      resHeaders['set-cookie'] = makeSetCookie('', true);
      res.writeHead(proxyRes.statusCode, resHeaders);
      proxyRes.pipe(res, { end: true });
      console.log('[proxy] Token cookie cleared on logout');
    } else {
      res.writeHead(proxyRes.statusCode, proxyRes.headers);
      proxyRes.pipe(res, { end: true });
    }
  });

  proxyReq.on('error', (err) => {
    console.error('[proxy] Error:', err.message);
    if (!res.headersSent) {
      res.writeHead(502);
      res.end('Bad Gateway');
    }
  });

  req.pipe(proxyReq, { end: true });
}

function startFrontendProxy() {
  const server = createServer((req, res) => {
    const url = new URL(req.url, `http://localhost:${PORT}`);
    const pathname = decodeURIComponent(url.pathname);

    // 1. Try to serve static file (only GET)
    if (req.method === 'GET' && tryServeStaticFile(pathname, res)) {
      return;
    }

    // 2. API routes — proxy to Medplum internal server
    if (isApiPath(pathname)) {
      proxyRequest(req, res);
      return;
    }

    // 3. SPA fallback — serve index.html for GET requests to non-file, non-API routes
    if (req.method === 'GET') {
      const indexPath = join(PUBLIC_DIR, 'index.html');
      if (existsSync(indexPath)) {
        const content = readFileSync(indexPath);
        res.writeHead(200, {
          'Content-Type': 'text/html',
          'Content-Length': content.length,
          'Cache-Control': 'no-cache',
        });
        res.end(content);
        return;
      }
    }

    // 4. Any other request — proxy to Medplum
    proxyRequest(req, res);
  });

  // Handle WebSocket upgrades
  server.on('upgrade', (req, socket, head) => {
    const options = {
      hostname: '127.0.0.1',
      port: INTERNAL_PORT,
      path: req.url,
      method: req.method,
      headers: { ...req.headers, host: `127.0.0.1:${INTERNAL_PORT}` },
    };

    const proxyReq = httpRequest(options);
    proxyReq.on('upgrade', (proxyRes, proxySocket, proxyHead) => {
      const headers = Object.entries(proxyRes.headers)
        .map(([k, v]) => `${k}: ${v}`)
        .join('\r\n');
      socket.write(`HTTP/1.1 101 Switching Protocols\r\n${headers}\r\n\r\n`);
      if (proxyHead.length > 0) socket.write(proxyHead);
      proxySocket.pipe(socket);
      socket.pipe(proxySocket);
    });

    proxyReq.on('error', (err) => {
      console.error('[proxy] WebSocket upgrade error:', err.message);
      socket.end();
    });

    proxyReq.end();
  });

  server.listen(PORT, () => {
    console.log(`Frontend proxy listening on port ${PORT}`);
    console.log(`  Static files: ${PUBLIC_DIR}`);
    console.log(`  API proxy -> 127.0.0.1:${INTERNAL_PORT}`);
  });

  return server;
}

async function startMedplum() {
  generateConfig();

  console.log('Starting Medplum server...');
  console.log(`  Internal port: ${INTERNAL_PORT}`);
  console.log(`  Public port: ${PORT}`);
  console.log(`  Database: ${process.env.LAKEBASE_HOST || 'your-lakebase-endpoint.database.region.cloud.databricks.com'}`);
  console.log(`  Redis: 127.0.0.1:${REDIS_PORT}`);

  process.env.MEDPLUM_VERSION = '5.1.22';

  const { main } = await import('./server/index.mjs');
  await main('file:medplum.config.json');
}

async function waitForMedplum() {
  for (let i = 0; i < 120; i++) {
    const ready = await new Promise((resolve) => {
      const sock = createConnection({ host: '127.0.0.1', port: INTERNAL_PORT }, () => {
        sock.destroy();
        resolve(true);
      });
      sock.on('error', () => { sock.destroy(); resolve(false); });
      sock.setTimeout(1000, () => { sock.destroy(); resolve(false); });
    });
    if (ready) {
      console.log('Medplum server is ready on internal port.');
      return;
    }
    await sleep(500);
  }
  console.error('ERROR: Medplum server did not start within 60 seconds.');
  process.exit(1);
}

try {
  decompressFhirData();
  await startRedis();
  await startMedplum();
  await waitForMedplum();
  startFrontendProxy();
} catch (err) {
  console.error('Fatal startup error:', err);
  process.exit(1);
}
