#!/bin/bash
set -e

PORT=${DATABRICKS_APP_PORT:-6379}
PASSWORD=${REDIS_PASSWORD:-medplum}

echo "Starting Redis on port $PORT..."
echo "Checking available tools..."

# Check if redis-server is already available
if command -v redis-server &> /dev/null; then
  mkdir -p /tmp/redis-data
  exec redis-server ./redis.conf --port "$PORT" --requirepass "$PASSWORD"
fi

# Try pip-based Redis alternative (mini-redis or similar)
if command -v pip &> /dev/null; then
  echo "Installing redis-server via pip..."
  pip install redis-server 2>/dev/null || true
fi

# Try installing redis-server via apt if available
if command -v apt-get &> /dev/null; then
  echo "Installing redis-server via apt..."
  apt-get update -qq && apt-get install -y -qq redis-server 2>/dev/null || true
  if command -v redis-server &> /dev/null; then
    mkdir -p /tmp/redis-data
    exec redis-server ./redis.conf --port "$PORT" --requirepass "$PASSWORD"
  fi
fi

# Download a static redis-server binary (Alpine musl or glibc)
echo "Downloading static Redis binary..."
REDIS_DIR="/tmp/redis-bin"
mkdir -p "$REDIS_DIR" /tmp/redis-data

# Try downloading a prebuilt static binary from GitHub releases
curl -sL "https://github.com/redis/redis/releases/download/7.2.7/redis-7.2.7-linux-x86_64.tar.gz" -o /tmp/redis-release.tar.gz 2>/dev/null
if [ -f /tmp/redis-release.tar.gz ] && [ -s /tmp/redis-release.tar.gz ]; then
  tar -xzf /tmp/redis-release.tar.gz -C "$REDIS_DIR" --strip-components=1 2>/dev/null || true
  if [ -x "$REDIS_DIR/bin/redis-server" ]; then
    exec "$REDIS_DIR/bin/redis-server" ./redis.conf --port "$PORT" --requirepass "$PASSWORD"
  fi
fi

# Build from source as last resort
if command -v make &> /dev/null && command -v gcc &> /dev/null; then
  echo "Building Redis from source..."
  curl -sL "https://github.com/redis/redis/archive/refs/tags/7.2.7.tar.gz" -o /tmp/redis-src.tar.gz
  tar -xzf /tmp/redis-src.tar.gz -C /tmp
  cd /tmp/redis-7.2.7
  make -j$(nproc 2>/dev/null || echo 2) redis-server 2>&1 | tail -3
  cp src/redis-server "$REDIS_DIR/redis-server"
  cd "$(dirname "$0")" || cd /app
  exec "$REDIS_DIR/redis-server" ./redis.conf --port "$PORT" --requirepass "$PASSWORD"
fi

echo "ERROR: Could not install or build Redis. Available commands:"
which python3 pip node npm make gcc curl 2>/dev/null || true
echo "PATH=$PATH"
ls /usr/bin/ 2>/dev/null | head -30
exit 1
