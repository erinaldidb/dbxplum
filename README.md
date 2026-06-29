# dbxplum

**Medplum FHIR R4 platform on Databricks** — an open-source, FHIR-compliant EHR server deployed as a native Databricks App with Lakebase (PostgreSQL) and co-located Redis.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Databricks Apps Runtime (Node.js 22)                       │
│                                                             │
│  ┌──────────────┐   ┌───────────────────┐   ┌──────────┐  │
│  │ Frontend     │   │ Medplum FHIR R4   │   │  Redis   │  │
│  │ (React SPA)  │──▶│ Server (port 8001)│──▶│ (6379)   │  │
│  │ (port 8000)  │   │ 146 resource types│   │ compiled │  │
│  └──────────────┘   └────────┬──────────┘   └──────────┘  │
│                               │                             │
└───────────────────────────────┼─────────────────────────────┘
                                │
                    ┌───────────▼───────────┐
                    │   Lakebase            │
                    │   (PostgreSQL)        │
                    │   databricks_postgres │
                    │   + CDF → Lakehouse   │
                    └───────────────────────┘
```

### Key Features

- **Full FHIR R4 compliance** — 146 resource types, CapabilityStatement, search, operations
- **Lakebase backend** — PostgreSQL-compatible with Change Data Feed for lakehouse sync
- **Single-app deployment** — frontend, backend, and Redis all in one Databricks App
- **Databricks OAuth integration** — cookie-based token relay through the gateway
- **DABs (Databricks Asset Bundles)** — infrastructure-as-code deployment
- **Redis compiled at deploy time** — no external dependencies needed

## Prerequisites

- [Databricks CLI](https://docs.databricks.com/dev-tools/cli/index.html) configured with a workspace profile
- A Databricks workspace with Apps and Lakebase enabled
- Node.js 22+ (for running the init script locally)

## Quick Start

### 1. Configure your workspace

Edit `databricks.yml` to point to your workspace:

```yaml
targets:
  dev:
    workspace:
      host: https://your-workspace.cloud.databricks.com
      profile: your-profile
```

### 2. Deploy with DABs

```bash
databricks bundle deploy --profile your-profile
```

This creates the Lakebase database instance and registers the app.

### 3. Deploy the app

```bash
# Upload source to workspace
databricks workspace import-dir apps/medplum-server \
  /Workspace/Users/you@company.com/medplum-server \
  --overwrite --profile your-profile

# Deploy
databricks apps deploy medplum-server \
  --source-code-path /Workspace/Users/you@company.com/medplum-server \
  --profile your-profile
```

### 4. Grant database permissions

Connect to Lakebase as your admin user and grant permissions to the app service user:

```sql
GRANT ALL ON SCHEMA public TO medplum_svc;
GRANT ALL ON ALL TABLES IN SCHEMA public TO medplum_svc;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO medplum_svc;
```

### 5. Enable Change Data Feed

Set `REPLICA IDENTITY FULL` on all tables for CDF support:

```sql
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT table_schema, table_name
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_type = 'BASE TABLE'
  LOOP
    EXECUTE format(
      'ALTER TABLE %I.%I REPLICA IDENTITY FULL;',
      r.table_schema, r.table_name
    );
  END LOOP;
END $$;
```

### 6. Initialize project data

```bash
node scripts/init-project.js \
  --base-url=https://your-app-url.aws.databricksapps.com \
  --profile=your-profile
```

This seeds:
- 1 Organization
- 3 Practitioners
- 5 Patients
- 7 Encounters
- 49 Observations (vital signs)
- 1 ClientApplication for API access

## Project Structure

```
dbxplum/
├── databricks.yml              # DABs bundle configuration
├── resources/
│   ├── apps.yml                # App resource definition
│   └── lakebase.yml            # Lakebase database instance
├── apps/
│   └── medplum-server/
│       ├── app.yaml            # Databricks App config (command, env vars)
│       ├── package.json        # Node.js manifest (triggers build step)
│       ├── start.js            # Entrypoint: proxy + Redis + Medplum server
│       ├── scripts/
│       │   └── build.js        # Compiles Redis from source at deploy time
│       ├── server/             # Bundled Medplum server (pre-built)
│       │   └── index.mjs       # Server bundle
│       └── public/             # React SPA + token relay script
│           └── index.html      # Frontend with cookie-based auth relay
└── scripts/
    └── init-project.js         # Project initialization / data seeding
```

## How It Works

### Token Relay Pattern

Databricks Apps gateway strips `Authorization` headers and `Set-Cookie` responses. This app uses a cookie-based relay:

1. **Client-side**: JavaScript intercepts `fetch()` calls, extracts the Bearer token, writes it to `document.cookie` as `__medplum_token`
2. **Proxy**: Reads `__medplum_token` cookie from incoming requests, injects it as `Authorization: Bearer` header before forwarding to Medplum server
3. **Result**: Medplum's standard OAuth flow works transparently through the gateway

### Redis at Deploy Time

The Databricks Apps build step compiles Redis 7.2 from source (`scripts/build.js`). The binary is cached across deploys — only the first deployment takes ~2 minutes for compilation.

### Lakebase + CDF

Using `databricks_postgres` as the database name enables Lakebase Change Data Feed, which automatically syncs table changes to the lakehouse as Delta tables. Combined with `REPLICA IDENTITY FULL`, all FHIR resource changes are captured for analytics.

## Configuration

Environment variables in `apps/medplum-server/app.yaml`:

| Variable | Description |
|----------|-------------|
| `LAKEBASE_HOST` | Lakebase endpoint hostname |
| `LAKEBASE_PORT` | PostgreSQL port (default: 5432) |
| `LAKEBASE_DB` | Database name (`databricks_postgres` for CDF) |
| `LAKEBASE_USER` | Service principal username |
| `LAKEBASE_PASSWORD` | Service principal password |
| `REDIS_PASSWORD` | Redis authentication password |
| `NODE_ENV` | Node environment (`production`) |

## CLI / Script Access

For programmatic access (scripts, CI):

```javascript
// Databricks token authenticates with the gateway
const gatewayHeaders = { Authorization: `Bearer ${databricksToken}` };

// Medplum token passed via cookie
const authHeaders = {
  Authorization: `Bearer ${databricksToken}`,
  Cookie: `__medplum_token=${medplumAccessToken}`,
};
```

## Admin Credentials (Dev)

| | Value |
|---|---|
| Email | `admin@example.com` |
| Password | `medplum_admin` |

## License

Apache-2.0
