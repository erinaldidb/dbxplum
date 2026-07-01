<p align="center">
  <img src="apps/medplum-server/logo.png" width="400" alt="dbxplum logo"/>
</p>

**Medplum FHIR R4 server running on Databricks Apps with Lakebase (PostgreSQL) and co-located Redis.**

A production-ready deployment of [Medplum](https://www.medplum.com/) on the Databricks platform, using:

- **Databricks Apps** — managed container runtime (LARGE compute)
- **Lakebase** — PostgreSQL-compatible database, provisioned by the bundle
- **Co-located Redis** — compiled from source at deploy time, running in-process
- **Databricks Asset Bundles (DABs)** — infrastructure-as-code deployment

## Architecture

```
┌──────────────────────────────────────────────────┐
│            Databricks App (LARGE)                │
│                                                  │
│  ┌────────────┐   ┌──────────┐   ┌────────────┐  │
│  │  Frontend  │   │  Medplum │   │   Redis    │  │
│  │   Proxy    │──▶│  Server  │──▶│  (local)   │  │
│  │  :8000     │   │  :8001   │   │  :6379     │  │
│  └────────────┘   └────┬─────┘   └────────────┘  │
│                        │                         │
└────────────────────────┼─────────────────────────┘
                         │ OAuth JWT (auto-refresh)
                         ▼
              ┌──────────────────────┐
              │   Lakebase (PG)      │
              │  Autoscaling Branch  │
              └──────────────────────┘
```

## Key Features

- **One-command deploy** — `./deploy.sh` handles everything: infrastructure, permissions, and app startup
- **No hardcoded secrets** — Redis password via Databricks secret scope; PG auth via OAuth client_credentials flow
- **Auto token refresh** — OAuth JWT refreshes 5 min before expiry (~every 55 min), so PG connections never go stale
- **Cookie-based auth relay** — Medplum frontend auth works through Databricks gateway via `HttpOnly` session cookies
- **Single-app deployment** — server, Redis, and frontend all run in one LARGE app for simplicity
- **FHIR R4 compliant** — full Medplum server with all resource types, search parameters, and subscriptions

## Prerequisites

1. [Databricks CLI](https://docs.databricks.com/dev-tools/cli/index.html) (v0.200+)
2. `jq` installed
3. `psql` installed (used by `deploy.sh` for schema grants; on macOS: `brew install libpq`)
4. A Databricks workspace with Apps and Lakebase enabled
5. A CLI profile configured (e.g., `fevm-medplum`)

## Building Medplum from source

The committed `apps/medplum-server/server/` and `public/` artifacts are pre-built snapshots. To rebuild them from upstream [medplum/medplum](https://github.com/medplum/medplum):

```bash
./build-medplum.sh                         # latest release
./build-medplum.sh --version v5.1.22       # exact tag
./build-medplum.sh --version v5.1            # latest tag matching prefix
```

The script clones into `medplum-src/` (gitignored), runs `npm ci` + `npm run build:fast`, bundles the server into `server/index.mjs`, copies FHIR definitions and the React app into `public/`, and patches `start.js` with the resolved version.

AWS, Azure, GCP, and Kubernetes SDKs are stubbed out at bundle time — this deployment uses `file:` binary storage (see `start.js`) and Databricks SSO for database auth, not cloud object stores or secret managers.

OpenTelemetry and pdfmake remain runtime dependencies (installed via `npm install` in `apps/medplum-server/`). `package-lock.json` and `.npmrc` are gitignored — do not commit them. Locally you can use the Databricks laptop npm proxy:

```bash
cd apps/medplum-server
npm install --omit=dev --registry=https://npm-proxy.cloud.databricks.com/
```

Databricks Apps resolves dependencies from `package.json` at deploy time (no lockfile). See `.npmrc.example` if you need a public-registry override.

## Quick Start

### 1. Create secret scope (one-time)

```bash
databricks secrets create-scope medplum-secrets
databricks secrets put-secret medplum-secrets redis-password --string-value "<your-redis-password>"
```

### 2. Configure bundle target

Edit `databricks.yml` — update the `workspace.host` and `workspace.profile` for your environment:

```yaml
targets:
  dev:
    default: true
    workspace:
      host: https://your-workspace.cloud.databricks.com
      profile: your-profile
```

### 3. Deploy

```bash
./deploy.sh
```

That's it. The script handles:

| Step | Action |
|------|--------|
| 1 | Pre-flight checks (`databricks`, `jq`, `psql`, bundle validation) |
| 2 | Destroy existing resources and wait for the app to be fully deleted |
| 3 | Deploy DABs bundle (`medplum-fhir-platform`: Lakebase project + app definition) with retry |
| 4 | Wait for Lakebase database branch to become `READY` |
| 5 | Grant `ALL` on `public` schema to the app's service principal |
| 6 | Start compute, deploy app code, and push source (`databricks bundle run`) |
| 7 | Verify the app is healthy and print the URL |

### Redeploy without destroying

```bash
./deploy.sh --no-destroy
```

Run `./deploy.sh --help` for usage.

## Project Structure

```
.
├── databricks.yml              # DABs bundle config (bundle name: medplum-fhir-platform)
├── build-medplum.sh            # Build server bundle + frontend from upstream Medplum source
├── deploy.sh                   # Full deployment script (destroy → deploy → grant → start)
├── resources/
│   ├── apps.yml                # App resource definition (compute, DB, secrets)
│   └── lakebase.yml            # Lakebase project definition
├── scripts/
│   └── test-lakebase-compat.sql  # Lakebase PostgreSQL compatibility checks
├── docs/                       # Deployment investigation notes
└── apps/medplum-server/
    ├── app.yaml                # App runtime config (command, env vars)
    ├── start.js                # Main entrypoint (OAuth, Redis, Medplum, proxy)
    ├── package.json            # Node.js metadata (Node 22+; `npm run build` compiles Redis)
    ├── scripts/build.js        # Build script (compiles Redis from source at deploy time)
    ├── bin/                    # Redis binary (gitignored; created by `npm run build`)
    ├── server/                 # Medplum server bundle (pre-built, v5.1.22)
    ├── public/                 # Medplum frontend (pre-built React SPA)
    └── logo.png                # App logo
```

## How It Works

### Deployment Flow (`deploy.sh`)

1. **Pre-flight** validates the CLI toolchain and bundle configuration
2. **Bundle destroy** removes the Terraform-managed resources (app + Lakebase project), then waits until the app is fully deleted (prevents "already exists" race)
3. **Bundle deploy** creates the Lakebase project/branch and app definition via Terraform
4. **Lakebase wait** polls until the database branch reaches `READY`
5. **Permission grant** fetches the app's auto-assigned service principal and runs `GRANT ALL ON SCHEMA public` (required for Medplum migrations)
6. **App deploy + start** runs `databricks bundle run medplum_server`, which pushes source, runs `npm run build` (Redis compile), and boots the container
7. **Health check** verifies the app is `RUNNING` and prints the URL

### Authentication Flow

1. **PG password**: At startup, `start.js` fetches an OAuth JWT via client_credentials grant using the auto-injected `DATABRICKS_CLIENT_ID` / `DATABRICKS_CLIENT_SECRET` env vars. This JWT is used as the PostgreSQL password.

2. **Token refresh**: A background loop refreshes the token 5 minutes before expiry, updating `process.env.PGPASSWORD` and the config file so new PG connections always use a valid token.

3. **Frontend auth**: The Databricks gateway replaces the browser's `Authorization` header with its own. To work around this, the proxy stores Medplum's access token in an `HttpOnly` cookie and injects it back on each request.

### Lakebase Connection

Lakebase auto-injects these env vars when a `postgres` resource is bound to the app:

| Env Var | Description |
|---------|-------------|
| `PGHOST` | Lakebase endpoint hostname |
| `PGDATABASE` | `databricks_postgres` |
| `PGPORT` | `5432` |
| `PGUSER` | Service principal client ID |
| `PGSSLMODE` | `require` |
| `PGAPPNAME` | `medplum-server` |

No connection strings or passwords in config files — everything is runtime-injected.

### Bundle Resources

The DABs bundle (`resources/`) defines:

- **`postgres_projects.medplum`** — Lakebase project with `purge_on_delete: true` (clean destroys)
- **`apps.medplum_server`** — LARGE compute app with:
  - `CAN_CONNECT_AND_CREATE` permission on the Lakebase branch
  - Read access to the `medplum-secrets` secret scope

## Operations

### View logs

```bash
databricks apps get-logs medplum-server
```

### Connect to database

```bash
databricks postgres connect projects/medplum/branches/production
```

### Check app status

```bash
databricks apps get medplum-server
```

### Full redeploy from scratch

```bash
./deploy.sh
```

## License

Licensed under the [DBXPlum / Databricks License](LICENSE).
