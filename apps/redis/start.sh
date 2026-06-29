#!/bin/bash
set -e

PORT=${DATABRICKS_APP_PORT:-6379}
PASSWORD=${REDIS_PASSWORD:-medplum}

echo "Starting Redis on port $PORT..."

# Option A: redis-server binary is available in runtime
if command -v redis-server &> /dev/null; then
  exec redis-server ./redis.conf --port "$PORT" --requirepass "$PASSWORD"
fi

# Option B: Use npm redis-server package
echo "redis-server not found. Attempting npm-based Redis..."
npx redis-server --port "$PORT" --requirepass "$PASSWORD"
