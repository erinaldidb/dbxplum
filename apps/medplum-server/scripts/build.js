import { execSync } from 'node:child_process';
import { existsSync, mkdirSync, chmodSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const appDir = join(__dirname, '..');
const binDir = join(appDir, 'bin');

mkdirSync(binDir, { recursive: true });


const redisBin = join(binDir, 'redis-server');

if (existsSync(redisBin)) {
  console.log('Redis binary already exists, skipping.');
  process.exit(0);
}

// Compile Redis from source (container has build tools)
const REDIS_VERSION = '7.2.7';
const tarUrl = `https://github.com/redis/redis/archive/refs/tags/${REDIS_VERSION}.tar.gz`;
const srcDir = `/tmp/redis-${REDIS_VERSION}`;

console.log(`Compiling Redis ${REDIS_VERSION} from source...`);
try {
  execSync(`curl -fsSL --connect-timeout 30 "${tarUrl}" -o /tmp/redis-src.tar.gz`, { stdio: 'inherit' });
  execSync(`tar -xzf /tmp/redis-src.tar.gz -C /tmp`, { stdio: 'inherit' });
  execSync(`make -C "${srcDir}" -j$(nproc 2>/dev/null || echo 2) MALLOC=libc redis-server`, { stdio: 'inherit' });
  execSync(`cp "${srcDir}/src/redis-server" "${redisBin}"`);
  chmodSync(redisBin, 0o755);
  execSync(`"${redisBin}" --version`, { stdio: 'inherit' });
  console.log('Redis compiled successfully.');
} catch (err) {
  console.error('ERROR: Failed to compile Redis:', err.message);
  process.exit(1);
}
