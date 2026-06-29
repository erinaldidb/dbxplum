#!/bin/bash
set -e

echo "=== Medplum Server App (Phase 2 validated) ==="
echo "Architecture: Co-located Redis + Medplum Server"
echo "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo ""

PORT=${DATABRICKS_APP_PORT:-8000}

# --- Phase 2 Result: Redis must be co-located (inter-app TCP not possible) ---
# Start Redis as a background subprocess on localhost:6379
echo "--- Starting Redis (co-located, localhost:6379) ---"

REDIS_PASSWORD=${REDIS_PASSWORD:-medplum-redis-secret}
REDIS_PORT=6379
REDIS_DIR="/tmp/redis-bin"
REDIS_DATA="/tmp/redis-data"
mkdir -p "$REDIS_DIR" "$REDIS_DATA"

start_redis() {
  local redis_bin="$1"
  echo "Starting Redis: $redis_bin on port $REDIS_PORT"
  "$redis_bin" \
    --port "$REDIS_PORT" \
    --requirepass "$REDIS_PASSWORD" \
    --dir "$REDIS_DATA" \
    --daemonize no \
    --appendonly yes \
    --maxmemory 256mb \
    --maxmemory-policy allkeys-lru &
  REDIS_PID=$!
  echo "Redis started (PID: $REDIS_PID)"
}

# Try available Redis binaries
if command -v redis-server &> /dev/null; then
  start_redis "redis-server"
elif [ -x "$REDIS_DIR/redis-server" ]; then
  start_redis "$REDIS_DIR/redis-server"
else
  # Build from source (same approach as the Redis app)
  echo "Building Redis from source..."
  if command -v make &> /dev/null && command -v gcc &> /dev/null; then
    curl -sL "https://github.com/redis/redis/archive/refs/tags/7.2.7.tar.gz" -o /tmp/redis-src.tar.gz
    tar -xzf /tmp/redis-src.tar.gz -C /tmp
    cd /tmp/redis-7.2.7
    make -j$(nproc 2>/dev/null || echo 2) redis-server 2>&1 | tail -5
    cp src/redis-server "$REDIS_DIR/redis-server"
    cd "$(dirname "$0")" || cd /app
    start_redis "$REDIS_DIR/redis-server"
  else
    echo "ERROR: Cannot build Redis (no make/gcc). Checking for prebuilt..."
    curl -sL "https://github.com/redis/redis/releases/download/7.2.7/redis-7.2.7-linux-x86_64.tar.gz" \
      -o /tmp/redis-release.tar.gz 2>/dev/null
    if [ -f /tmp/redis-release.tar.gz ] && [ -s /tmp/redis-release.tar.gz ]; then
      tar -xzf /tmp/redis-release.tar.gz -C "$REDIS_DIR" --strip-components=1 2>/dev/null || true
      if [ -x "$REDIS_DIR/bin/redis-server" ]; then
        start_redis "$REDIS_DIR/bin/redis-server"
      fi
    fi
  fi
fi

# Wait for Redis to be ready
echo "Waiting for Redis..."
for i in $(seq 1 30); do
  if python3 -c "
import socket
s = socket.socket()
s.settimeout(1)
try:
    s.connect(('127.0.0.1', $REDIS_PORT))
    s.send(b'*2\r\n\$4\r\nAUTH\r\n\$${#REDIS_PASSWORD}\r\n${REDIS_PASSWORD}\r\n*1\r\n\$4\r\nPING\r\n')
    r = s.recv(64)
    if b'+PONG' in r: exit(0)
except: pass
exit(1)
" 2>/dev/null; then
    echo "Redis is ready (attempt $i)"
    break
  fi
  sleep 1
done

# --- Medplum Server (placeholder until Phase 4 build) ---
echo ""
echo "--- Medplum Server ---"
echo "Status: Placeholder (Phase 4 will build the actual server)"
echo "Redis: localhost:$REDIS_PORT (password protected)"
echo "Database: Lakebase (to be configured)"
echo "Listening on port: $PORT"
echo ""

# HTTP health endpoint
python3 -c "
import http.server, json, subprocess, sys

port = int('$PORT')
redis_port = int('$REDIS_PORT')

def check_redis():
    try:
        import socket
        s = socket.socket()
        s.settimeout(2)
        s.connect(('127.0.0.1', redis_port))
        s.send(b'*2\r\n\$4\r\nAUTH\r\n\$${#REDIS_PASSWORD}\r\n${REDIS_PASSWORD}\r\n*1\r\n\$4\r\nPING\r\n')
        r = s.recv(64)
        s.close()
        return b'+PONG' in r
    except:
        return False

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/api/health' or self.path == '/health':
            redis_ok = check_redis()
            status = 200 if redis_ok else 503
            body = {
                'status': 'ok' if redis_ok else 'degraded',
                'phase': 'phase2-validated',
                'redis': 'connected' if redis_ok else 'disconnected',
                'redis_host': 'localhost:$REDIS_PORT',
                'architecture': 'co-located',
                'note': 'Medplum server not yet built (Phase 4)'
            }
        else:
            status = 200
            body = {'status': 'placeholder', 'message': 'Medplum server Phase 4 pending'}
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(body, indent=2).encode())
    def log_message(self, format, *args):
        pass

print(f'Health endpoint listening on port {port}', flush=True)
http.server.HTTPServer(('0.0.0.0', port), Handler).serve_forever()
" 2>&1
