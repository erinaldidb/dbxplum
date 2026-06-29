# Medplum on Databricks — Detailed Implementation Steps

> This document is designed to be handed to an implementation agent. Each step includes
> exact files to create, commands to run, and expected outcomes.
> 
> **Deployment tool: Databricks Asset Bundles (DABs)** — all infrastructure (apps, Lakebase,
> volumes) is declared in `databricks.yml` and deployed with `databricks bundle deploy`.

---

## Overview

**Goal:** Deploy Medplum FHIR server on Databricks with:
- App #1: Medplum server (Node.js/Express)
- App #2: Redis server (dedicated, independently scalable)
- Lakebase: Dedicated PostgreSQL-compatible database
- All managed via a single DABs bundle

**Tech Stack:**
- Medplum server: Node.js 22.x, Express, TypeScript
- Database: PostgreSQL 16 (Lakebase — PG wire-protocol compatible)
- Cache: Redis 7
- Storage: Cloud object storage (S3 or ADLS) for FHIR Binary resources
- Deployment: Databricks Asset Bundles (DABs)

---

## Project Structure (Final State)

```
/Users/emanuele.rinaldi/medplum/
├── databricks.yml                  # DABs bundle root config
├── resources/
│   ├── apps.yml                    # App #1 (Medplum) + App #2 (Redis) definitions
│   ├── lakebase.yml                # Lakebase database instance
│   └── volumes.yml                 # Unity Catalog Volume for binary storage
├── apps/
│   ├── medplum-server/             # Source for Databricks App #1
│   │   ├── app.yaml
│   │   ├── package.json
│   │   ├── medplum.config.json
│   │   ├── start.sh
│   │   └── server/                 # Built Medplum server output
│   └── redis/                      # Source for Databricks App #2
│       ├── app.yaml
│       ├── package.json
│       ├── start.sh
│       └── redis.conf
├── scripts/
│   ├── test-lakebase-compat.sql    # PG compatibility tests
│   ├── test-network.js             # Inter-app connectivity test
│   └── seed-admin.sh               # Seed super admin after deploy
├── medplum-src/                    # Cloned Medplum source repo
└── docs/
    ├── INTEGRATION_PLAN.md         # Architecture & decisions
    └── lakebase-compatibility.md   # Test results
```

---

## PHASE 0: DABs Bundle Initialization

### Step 0.1: Create Bundle Root Configuration

**File: `databricks.yml`**

```yaml
bundle:
  name: medplum-fhir-platform

variables:
  lakebase_capacity:
    description: "Lakebase compute capacity"
    default: "CU_1"
  redis_password:
    description: "Redis server password"
    default: "medplum-redis-secret"

include:
  - "resources/*.yml"

targets:
  dev:
    default: true
    workspace:
      host: https://<DEV_WORKSPACE_URL>
  prod:
    workspace:
      host: https://<PROD_WORKSPACE_URL>
    variables:
      lakebase_capacity: "CU_2"
```

### Step 0.2: Define Lakebase Database

**File: `resources/lakebase.yml`**

```yaml
resources:
  postgres_projects:
    medplum_db:
      name: "medplum-fhir-db"
```

> **NOTE:** If `postgres_projects` (autoscaling) is not available in the workspace,
> fall back to `database_instances` with explicit capacity:
> ```yaml
> resources:
>   database_instances:
>     medplum_db:
>       name: "medplum-fhir-db"
>       capacity: ${var.lakebase_capacity}
> ```

### Step 0.3: Define Apps

**File: `resources/apps.yml`**

```yaml
resources:
  apps:
    medplum_redis:
      name: "medplum-redis"
      description: "Redis server for Medplum job queues, caching, and pub/sub"
      source_code_path: ./apps/redis

    medplum_server:
      name: "medplum-server"
      description: "Medplum FHIR R4 server"
      source_code_path: ./apps/medplum-server
```

### Step 0.4: Define Volume for Binary Storage (Optional)

**File: `resources/volumes.yml`**

```yaml
resources:
  volumes:
    medplum_binary_storage:
      catalog_name: "medplum"
      schema_name: "fhir"
      name: "binary_storage"
      volume_type: "MANAGED"
```

### Step 0.5: Validate Bundle

```bash
cd /Users/emanuele.rinaldi/medplum
databricks bundle validate
```

---

## PHASE 1: Redis Databricks App

### Step 1.1: Create Redis App Source

**File: `apps/redis/app.yaml`**

```yaml
command: ["bash", "start.sh"]
env:
  - name: REDIS_PASSWORD
    value: "${var.redis_password}"
```

### Step 1.2: `apps/redis/package.json`

```json
{
  "name": "medplum-redis",
  "version": "1.0.0",
  "description": "Redis server for Medplum on Databricks",
  "scripts": {
    "start": "bash start.sh"
  }
}
```

### Step 1.3: `apps/redis/start.sh`

```bash
#!/bin/bash
set -e

PORT=${DATABRICKS_APP_PORT:-6379}
PASSWORD=${REDIS_PASSWORD:-medplum}

echo "Starting Redis on port $PORT..."

# Option A: redis-server binary is available in runtime
if command -v redis-server &> /dev/null; then
  exec redis-server ./redis.conf --port "$PORT" --requirepass "$PASSWORD"
fi

# Option B: Download static Redis binary (Alpine musl-based)
# curl -sL https://github.com/redis/redis/archive/refs/tags/7.2.4.tar.gz | tar xz
# cd redis-7.2.4 && make && ./src/redis-server ../redis.conf --port "$PORT" --requirepass "$PASSWORD"

# Option C: Use npm redis-server package
echo "redis-server not found. Attempting npm-based Redis..."
npx redis-server --port "$PORT" --requirepass "$PASSWORD"
```

### Step 1.4: `apps/redis/redis.conf`

```conf
bind 0.0.0.0
maxmemory 2gb
maxmemory-policy allkeys-lru
save 60 1000
dir /tmp/redis-data
protected-mode yes
tcp-backlog 511
timeout 0
tcp-keepalive 300
```

### Step 1.5: Deploy Redis App Only

```bash
databricks bundle deploy --target dev --resource medplum_redis
```

Or deploy the full bundle:
```bash
databricks bundle deploy --target dev
```

### Step 1.6: Verify Redis App is Running

```bash
databricks apps get medplum-redis
# Note the URL/hostname — needed for Medplum server config
```

---

## PHASE 2: Networking Validation

### Step 2.1: Create Network Test Script

**File: `scripts/test-network.js`**

```javascript
// Run this inside the Medplum app container or as a temporary test app
// to verify connectivity to the Redis app

const { createClient } = require('redis');

const REDIS_URL = process.env.REDIS_URL || 'redis://:medplum@<REDIS_APP_HOSTNAME>:<PORT>';

async function test() {
  console.log(`Connecting to: ${REDIS_URL}`);
  try {
    const client = createClient({ url: REDIS_URL });
    client.on('error', (err) => console.error('Redis Client Error:', err));
    await client.connect();
    
    console.log('Connected! Testing operations...');
    await client.set('medplum:test', 'connectivity-ok');
    const val = await client.get('medplum:test');
    console.log(`SET/GET test: ${val}`);
    
    await client.del('medplum:test');
    await client.quit();
    console.log('SUCCESS: Redis connectivity confirmed');
    process.exit(0);
  } catch (err) {
    console.error('FAILED:', err.message);
    process.exit(1);
  }
}

test();
```

### Step 2.2: Determine Inter-App Connectivity

The implementing agent must figure out HOW apps communicate:

1. **Check if apps get internal hostnames** — e.g., `medplum-redis.<workspace>.internal`
2. **Check if apps share a network** — can one app reach another by name or IP?
3. **Check Databricks Apps documentation for service binding** — some platforms allow `resources` config to bind apps together

**If inter-app networking is NOT possible:**
- Fall back: run Redis as a subprocess within the Medplum app's `start.sh`
- Document as tech debt — revisit when Databricks adds service mesh / inter-app networking
- Update `apps/medplum-server/start.sh` to start Redis in background before Medplum

**BLOCKER:** If networking between apps is impossible AND Redis cannot run as subprocess
(e.g., binary not available), the project needs redesign. Escalate to user.

---

## PHASE 3: Lakebase Database Validation

### Step 3.1: Deploy Lakebase via Bundle

```bash
databricks bundle deploy --target dev --resource medplum_db
```

### Step 3.2: Get Connection Details

```bash
# Get Lakebase connection info from workspace
databricks lakebase get medplum-fhir-db
# Record: host, port, database, username
```

### Step 3.3: Run Compatibility Tests

**File: `scripts/test-lakebase-compat.sql`**

```sql
-- ============================================================
-- Medplum/Lakebase PostgreSQL Compatibility Test Suite
-- Run each section independently and record PASS/FAIL
-- ============================================================

-- TEST 1: UUID generation
SELECT gen_random_uuid();
-- EXPECTED: Returns a UUID value
-- PASS/FAIL: ___

-- TEST 2: UUID primary key
CREATE TABLE _test_uuid (id UUID PRIMARY KEY DEFAULT gen_random_uuid());
INSERT INTO _test_uuid DEFAULT VALUES;
INSERT INTO _test_uuid DEFAULT VALUES;
SELECT * FROM _test_uuid;
-- EXPECTED: Two rows with UUID values
-- PASS/FAIL: ___

-- TEST 3: UUID[] array column (CRITICAL for Medplum)
CREATE TABLE _test_uuid_array (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  compartments UUID[]
);
INSERT INTO _test_uuid_array (compartments) 
VALUES (ARRAY[gen_random_uuid(), gen_random_uuid()]::UUID[]);
SELECT * FROM _test_uuid_array;
-- EXPECTED: Row with UUID array
-- PASS/FAIL: ___

-- TEST 4: UUID[] array overlap operator (CRITICAL for Medplum search)
INSERT INTO _test_uuid_array (compartments) 
VALUES (ARRAY['a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::UUID]);
SELECT * FROM _test_uuid_array 
WHERE compartments && ARRAY['a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11']::UUID[];
-- EXPECTED: Returns the matching row
-- PASS/FAIL: ___

-- TEST 5: TEXT[] array column (CRITICAL for Medplum search)
CREATE TABLE _test_text_array (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tokens TEXT[]
);
INSERT INTO _test_text_array (tokens) VALUES (ARRAY['john', 'doe', 'patient']);
SELECT * FROM _test_text_array WHERE tokens && ARRAY['john']::TEXT[];
-- EXPECTED: Returns the matching row
-- PASS/FAIL: ___

-- TEST 6: TIMESTAMP WITH TIME ZONE
CREATE TABLE _test_timestamp (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  "lastUpdated" TIMESTAMPTZ DEFAULT NOW()
);
INSERT INTO _test_timestamp DEFAULT VALUES;
SELECT * FROM _test_timestamp;
-- EXPECTED: Row with timezone-aware timestamp
-- PASS/FAIL: ___

-- TEST 7: REPEATABLE READ isolation level
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SELECT 1 as test;
COMMIT;
-- EXPECTED: No error
-- PASS/FAIL: ___

-- TEST 8: Advisory locks
SELECT pg_try_advisory_lock(12345);
SELECT pg_advisory_unlock(12345);
-- EXPECTED: Both return true
-- PASS/FAIL: ___

-- TEST 9: GIN index on arrays (performance, not critical)
CREATE INDEX _idx_text_gin ON _test_text_array USING GIN (tokens);
CREATE INDEX _idx_uuid_gin ON _test_uuid_array USING GIN (compartments);
-- EXPECTED: Indexes created
-- PASS/FAIL: ___

-- TEST 10: TEXT column (used for FHIR JSON content)
CREATE TABLE _test_content (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  content TEXT NOT NULL,
  "lastUpdated" TIMESTAMPTZ DEFAULT NOW(),
  compartments UUID[],
  name TEXT[],
  status TEXT
);
INSERT INTO _test_content (content, compartments, name, status) VALUES (
  '{"resourceType":"Patient","name":[{"given":["John"],"family":"Doe"}]}',
  ARRAY[gen_random_uuid()]::UUID[],
  ARRAY['John', 'Doe'],
  'active'
);
SELECT * FROM _test_content WHERE name && ARRAY['John']::TEXT[] AND status = 'active';
-- EXPECTED: Returns the patient row
-- PASS/FAIL: ___

-- TEST 11: Multiple similar tables (Medplum creates 150+ resource tables)
CREATE TABLE _test_Patient (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  content TEXT NOT NULL,
  "lastUpdated" TIMESTAMPTZ DEFAULT NOW(),
  compartments UUID[],
  name TEXT[]
);
CREATE TABLE _test_Patient_History (
  "versionId" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  id UUID NOT NULL,
  content TEXT NOT NULL,
  "lastUpdated" TIMESTAMPTZ DEFAULT NOW()
);
-- EXPECTED: Both tables created
-- PASS/FAIL: ___

-- TEST 12: Quoted column names (Medplum uses camelCase)
SELECT "lastUpdated", "versionId" FROM _test_Patient_History;
-- EXPECTED: No error (empty result set is fine)
-- PASS/FAIL: ___

-- CLEANUP
DROP TABLE IF EXISTS _test_uuid, _test_uuid_array, _test_text_array,
  _test_timestamp, _test_content, _test_Patient, _test_Patient_History;
DROP INDEX IF EXISTS _idx_text_gin, _idx_uuid_gin;
```

### Step 3.4: Record Results

**File: `docs/lakebase-compatibility.md`**

```markdown
# Lakebase PostgreSQL Compatibility Results

| Test | Feature | Result | Notes |
|------|---------|--------|-------|
| 1 | gen_random_uuid() | | |
| 2 | UUID primary key | | |
| 3 | UUID[] column | | |
| 4 | UUID[] overlap (&&) | | |
| 5 | TEXT[] column | | |
| 6 | TIMESTAMPTZ | | |
| 7 | REPEATABLE READ | | |
| 8 | Advisory locks | | |
| 9 | GIN indexes | | |
| 10 | Full table pattern | | |
| 11 | 150+ tables | | |
| 12 | Quoted columns | | |

## Blockers
- (list any FAIL results for tests 1-7)

## Workarounds Needed
- (list any FAIL results for tests 8-12 with proposed workaround)
```

**Decision gate:** If tests 3, 4, or 5 fail (arrays), the project is BLOCKED. Escalate.

---

## PHASE 4: Medplum Server Build & Adaptation

### Step 4.1: Clone Medplum Source

```bash
cd /Users/emanuele.rinaldi/medplum
git clone --depth 1 https://github.com/medplum/medplum.git medplum-src
cd medplum-src
npm ci
```

### Step 4.2: Build Server Package

```bash
cd /Users/emanuele.rinaldi/medplum/medplum-src

# Build core dependencies first
npm run build --workspace=packages/core
npm run build --workspace=packages/fhir-router
npm run build --workspace=packages/server
```

### Step 4.3: Create Production Bundle

```bash
mkdir -p /Users/emanuele.rinaldi/medplum/apps/medplum-server/server

# Option A: Copy dist + production dependencies
cp -r packages/server/dist/* ../apps/medplum-server/server/
cd packages/server
npm pack  # creates tarball with production deps declared

# Option B: Single-file esbuild bundle (recommended if size is an issue)
npx esbuild packages/server/src/index.ts \
  --bundle \
  --platform=node \
  --target=node22 \
  --external:pg-native \
  --external:sharp \
  --outfile=../apps/medplum-server/server/index.js
```

### Step 4.4: Measure Bundle Size

```bash
du -sh /Users/emanuele.rinaldi/medplum/apps/medplum-server/
find /Users/emanuele.rinaldi/medplum/apps/medplum-server/ -type f -size +10M
# If any file > 10MB: must split or further tree-shake
```

### Step 4.5: Create Medplum App Configuration

> **IMPORTANT:** All API endpoints MUST be served under the `/api/` base path.
> Medplum's `baseUrl` config controls the prefix for all routes (FHIR, OAuth, etc.).
> With `baseUrl` set to `https://<HOST>/api/`, the endpoints become:
> - FHIR: `https://<HOST>/api/fhir/R4/...`
> - OAuth: `https://<HOST>/api/oauth2/token`
> - Health: `https://<HOST>/api/healthcheck`

**File: `apps/medplum-server/medplum.config.json`**

```json
{
  "port": 8103,
  "baseUrl": "https://<MEDPLUM_APP_URL>/api/",
  "appBaseUrl": "https://<MEDPLUM_APP_URL>/",
  "binaryStorage": "file:./binary",
  "database": {
    "host": "<LAKEBASE_HOST>",
    "port": 5432,
    "dbname": "medplum",
    "username": "<LAKEBASE_USER>",
    "password": "<LAKEBASE_PASSWORD>",
    "ssl": {
      "require": true,
      "rejectUnauthorized": false
    }
  },
  "redis": {
    "host": "<REDIS_APP_HOSTNAME>",
    "port": "<REDIS_APP_PORT>",
    "password": "<REDIS_PASSWORD>"
  },
  "supportEmail": "noreply@example.com",
  "registerEnabled": true
}
```

> **NOTE:** `<MEDPLUM_APP_URL>`, `<LAKEBASE_HOST>`, `<REDIS_APP_HOSTNAME>` are
> placeholders. The implementing agent must fill these after deploying the infrastructure
> in Phase 0-1. Consider using environment variable substitution in `start.sh`.
>
> **NOTE:** If Medplum's `baseUrl` does not natively mount routes under a subpath,
> the implementing agent must add an Express middleware or reverse proxy layer
> (e.g., `app.use('/api', medplumRouter)`) to ensure all endpoints are under `/api/`.

### Step 4.6: `apps/medplum-server/app.yaml`

```yaml
command: ["bash", "start.sh"]
env:
  - name: NODE_ENV
    value: "production"
  - name: LAKEBASE_HOST
    valueFrom: "lakebase-host"
  - name: LAKEBASE_PORT
    value: "5432"
  - name: LAKEBASE_DB
    value: "medplum"
  - name: LAKEBASE_USER
    valueFrom: "lakebase-user"
  - name: LAKEBASE_PASSWORD
    valueFrom: "lakebase-password"
  - name: REDIS_HOST
    valueFrom: "redis-host"
  - name: REDIS_PORT
    valueFrom: "redis-port"
  - name: REDIS_PASSWORD
    valueFrom: "redis-password"
```

### Step 4.7: `apps/medplum-server/start.sh`

```bash
#!/bin/bash
set -e

export PORT=${DATABRICKS_APP_PORT:-8103}

# Generate config from environment variables
# NOTE: baseUrl includes /api/ — all Medplum endpoints served under /api/
cat > /tmp/medplum.config.json << EOF
{
  "port": ${PORT},
  "baseUrl": "https://${DATABRICKS_APP_URL:-localhost:${PORT}}/api/",
  "appBaseUrl": "https://${DATABRICKS_APP_URL:-localhost:${PORT}}/",
  "binaryStorage": "file:./binary",
  "database": {
    "host": "${LAKEBASE_HOST}",
    "port": ${LAKEBASE_PORT:-5432},
    "dbname": "${LAKEBASE_DB:-medplum}",
    "username": "${LAKEBASE_USER}",
    "password": "${LAKEBASE_PASSWORD}",
    "ssl": {
      "require": true,
      "rejectUnauthorized": false
    }
  },
  "redis": {
    "host": "${REDIS_HOST}",
    "port": ${REDIS_PORT:-6379},
    "password": "${REDIS_PASSWORD}"
  },
  "supportEmail": "noreply@example.com",
  "registerEnabled": true
}
EOF

echo "Starting Medplum server on port ${PORT}..."
echo "Database: ${LAKEBASE_HOST}:${LAKEBASE_PORT}/${LAKEBASE_DB}"
echo "Redis: ${REDIS_HOST}:${REDIS_PORT}"

# Start Medplum server with generated config
node server/index.js /tmp/medplum.config.json
```

### Step 4.8: `apps/medplum-server/package.json`

```json
{
  "name": "medplum-databricks",
  "version": "1.0.0",
  "description": "Medplum FHIR server on Databricks Apps",
  "scripts": {
    "start": "bash start.sh"
  },
  "engines": {
    "node": ">=22.0.0"
  }
}
```

---

## PHASE 5: Full Bundle Deployment

### Step 5.1: Deploy All Resources

```bash
cd /Users/emanuele.rinaldi/medplum
databricks bundle validate --target dev
databricks bundle deploy --target dev
```

### Step 5.2: Verify Deployment

```bash
# Check all resources are deployed
databricks bundle summary --target dev

# Get app URLs
databricks apps get medplum-redis
databricks apps get medplum-server

# Get Lakebase connection info
databricks lakebase get medplum-fhir-db
```

### Step 5.3: Run Database Migrations

Medplum runs migrations automatically on first server startup. Monitor logs:

```bash
databricks apps logs medplum-server --follow
# Look for: "Database migrations completed" or similar
```

If migrations fail, check Lakebase compatibility (Phase 3 results).

---

## PHASE 6: Seed Data & End-to-End Validation

### Step 6.1: Create Seed Script

**File: `scripts/seed-admin.sh`**

```bash
#!/bin/bash
# Seeds the initial super admin user after Medplum starts
# This may happen automatically on first run — check server logs
# NOTE: All API calls use /api/ base path

MEDPLUM_URL="https://<MEDPLUM_APP_URL>/api"

# Wait for server to be ready
echo "Waiting for Medplum server..."
until curl -sf "${MEDPLUM_URL}/healthcheck" > /dev/null 2>&1; do
  sleep 5
done
echo "Server is up!"

# Check if already seeded (metadata endpoint should return CapabilityStatement)
curl -s "${MEDPLUM_URL}/fhir/R4/metadata" | head -20
```

### Step 6.2: Health Check

```bash
# Basic health
curl https://<MEDPLUM_APP_URL>/api/healthcheck
# Expected: {"ok":true}

# FHIR Capability Statement
curl https://<MEDPLUM_APP_URL>/api/fhir/R4/metadata
# Expected: JSON with resourceType: "CapabilityStatement"
```

### Step 6.3: Authentication Test

```bash
# Get access token via client credentials
TOKEN=$(curl -s -X POST https://<MEDPLUM_APP_URL>/api/oauth2/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=<CLIENT_ID>&client_secret=<CLIENT_SECRET>" \
  | jq -r '.access_token')

echo "Token: ${TOKEN:0:20}..."
```

### Step 6.4: FHIR CRUD Tests

```bash
# All endpoints under /api/ base path

# Create Patient
PATIENT=$(curl -s -X POST https://<MEDPLUM_APP_URL>/api/fhir/R4/Patient \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/fhir+json" \
  -d '{
    "resourceType": "Patient",
    "name": [{"given": ["Test"], "family": "Databricks"}],
    "birthDate": "1990-01-01",
    "gender": "unknown"
  }')
echo "Created: $PATIENT"
PATIENT_ID=$(echo $PATIENT | jq -r '.id')

# Read Patient
curl -s https://<MEDPLUM_APP_URL>/api/fhir/R4/Patient/$PATIENT_ID \
  -H "Authorization: Bearer $TOKEN" | jq .

# Search Patient
curl -s "https://<MEDPLUM_APP_URL>/api/fhir/R4/Patient?name=Databricks" \
  -H "Authorization: Bearer $TOKEN" | jq '.total'

# Update Patient
curl -s -X PUT https://<MEDPLUM_APP_URL>/api/fhir/R4/Patient/$PATIENT_ID \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/fhir+json" \
  -d "{
    \"resourceType\": \"Patient\",
    \"id\": \"$PATIENT_ID\",
    \"name\": [{\"given\": [\"Test\", \"Updated\"], \"family\": \"Databricks\"}],
    \"birthDate\": \"1990-01-01\",
    \"gender\": \"unknown\"
  }" | jq .

# Delete Patient
curl -s -X DELETE https://<MEDPLUM_APP_URL>/api/fhir/R4/Patient/$PATIENT_ID \
  -H "Authorization: Bearer $TOKEN"
```

### Step 6.5: Redis Integration Test

```bash
# Create a Subscription (uses Redis pub/sub)
curl -s -X POST https://<MEDPLUM_APP_URL>/api/fhir/R4/Subscription \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/fhir+json" \
  -d '{
    "resourceType": "Subscription",
    "status": "active",
    "criteria": "Patient",
    "channel": {
      "type": "rest-hook",
      "endpoint": "https://httpbin.org/post",
      "payload": "application/fhir+json"
    }
  }' | jq .
# If this succeeds without error, Redis pub/sub is working
```

---

## PHASE 7: Binary Storage (Post-MVP)

### Step 7.1: Choose Storage Backend

**Option A: Filesystem (immediate, ephemeral)**
Already configured in `medplum.config.json` as `"file:./binary"`.
Works for testing but data is lost on restart.

**Option B: Cloud Object Storage (S3/ADLS)**
Update `medplum.config.json`:
```json
{
  "binaryStorage": "s3:<BUCKET_NAME>",
  "storageBaseUrl": "https://<BUCKET_URL>/"
}
```
Requires AWS credentials or Azure service principal accessible from the app.

**Option C: Unity Catalog Volume**
Requires writing a custom storage adapter in Medplum's codebase.
Implement later for full Databricks-native governance.

### Step 7.2: Test Binary Upload

```bash
# Upload a Binary resource (note /api/ prefix)
curl -X POST https://<MEDPLUM_APP_URL>/api/fhir/R4/Binary \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/pdf" \
  --data-binary @sample.pdf
```

---

## PHASE 8: Analytics Integration (Post-MVP)

### Step 8.1: Enable Lakebase → Delta Lake Sync

Use Lakebase Change Data Feed (CDF) to expose FHIR tables as Delta Lake tables.

```sql
-- In Databricks SQL editor
-- Configure CDF on the Lakebase database
-- (Exact syntax depends on Lakebase CDF documentation)
```

### Step 8.2: Create Analytics Views

```sql
-- Example views over FHIR data in Delta Lake
CREATE OR REPLACE VIEW analytics.patients AS
SELECT
  id,
  content::json->>'birthDate' as birth_date,
  content::json->'name'->0->>'family' as family_name,
  content::json->'name'->0->'given'->>0 as given_name,
  "lastUpdated"
FROM medplum_fhir_db.public."Patient";
```

---

## Execution Order & Decision Gates

```
PHASE 0: Bundle Init (databricks.yml, resource definitions)
    │
    ▼
PHASE 1: Deploy Redis App ──────────────────────────────────────┐
    │                                                            │
    ▼                                                            │
PHASE 2: Network Validation ── GATE: Can apps talk? ────────────┤
    │         YES                        NO                      │
    │          │                          │                      │
    │          │                 Co-locate Redis in              │
    │          │                 Medplum app (fallback)          │
    │          ▼                          │                      │
    │          │◀─────────────────────────┘                      │
    ▼                                                            │
PHASE 3: Lakebase Validation ── GATE: Arrays work? ─── NO ──▶ BLOCKED
    │         YES                                                │
    ▼                                                            │
PHASE 4: Build Medplum Server Bundle                             │
    │                                                            │
    ▼                                                            │
PHASE 5: Full Bundle Deploy (databricks bundle deploy)           │
    │                                                            │
    ▼                                                            │
PHASE 6: E2E Validation (healthcheck, FHIR CRUD, auth, search)  │
    │                                                            │
    ▼                                                            │
PHASE 7: Binary Storage (post-MVP)                               │
    │                                                            │
    ▼                                                            │
PHASE 8: Analytics Integration (post-MVP)                        │
```

---

## Success Criteria

> All API endpoints are under `/api/` base path.

| # | Criterion | Phase |
|---|---|---|
| 1 | `databricks bundle deploy` succeeds | 5 |
| 2 | Redis app is running and accepting connections | 1 |
| 3 | Lakebase passes all critical compat tests (1-7) | 3 |
| 4 | Medplum app starts without errors | 5 |
| 5 | `GET /api/healthcheck` → `{"ok":true}` | 6 |
| 6 | `GET /api/fhir/R4/metadata` → CapabilityStatement | 6 |
| 7 | `POST /api/oauth2/token` → returns access token | 6 |
| 8 | FHIR CRUD at `/api/fhir/R4/Patient` (create, read, update, delete) | 6 |
| 9 | FHIR search works (`/api/fhir/R4/Patient?name=`) | 6 |
| 10 | Subscriptions via `/api/fhir/R4/Subscription` (Redis pub/sub) | 6 |
| 11 | Data persists across app restarts | 6 |

---

## Troubleshooting Guide

| Symptom | Likely Cause | Fix |
|---|---|---|
| Server won't start | Missing env vars | Check `databricks apps logs` for missing config |
| Migration fails | Lakebase PG incompatibility | Check Phase 3 results, apply workaround |
| "ECONNREFUSED" to Redis | Networking blocked | Verify Redis app URL, try co-locate fallback |
| "relation does not exist" | Migrations didn't run | Restart server or run migrations manually |
| 503 on app URL | App still starting / crashed | Check logs, verify compute size is sufficient |
| OAuth returns 401 | No ClientApplication seeded | Run seed script, create client via admin UI |
| Search returns empty | Array indexes not created | Check GIN index support in Lakebase |
