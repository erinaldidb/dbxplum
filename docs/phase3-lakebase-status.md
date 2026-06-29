# Phase 3: Lakebase Database Status

**Date:** 2026-06-29

## Availability

| Check | Result |
|-------|--------|
| `databricks lakebase` CLI subcommand | NOT available (v1.2.1) |
| `databricks psql` CLI subcommand | AVAILABLE |
| Lakebase Provisioned instances | None in workspace |
| Lakebase Autoscaling projects | 1 found: `solution-builder-sm2hh3` |
| REST API (`/api/2.0/lakebase/*`) | 404 Not Found |
| SQL Warehouse (alternative) | 1 found: `Serverless Starter Warehouse` (STOPPED) |

## Existing Lakebase Endpoint

```
Project:  solution-builder-sm2hh3
Branch:   main
Endpoint: primary (read-write)
Host:     ep-orange-surf-d2rmx7xp.database.us-east-1.cloud.databricks.com
Port:     5432
Protocol: PostgreSQL wire protocol
Status:   idle (wakes up on connection)
```

## Connectivity from Apps

**Confirmed:** The Medplum server app CAN reach the Lakebase endpoint on port 5432 (TCP connect successful).

## Authentication Issue

The `databricks psql` command failed with:
```
password authentication failed for user 'emanuele.rinaldi@databricks.com'
```

This suggests the existing project was created by another user and our credentials don't have access. We need to either:
1. Create a NEW Lakebase Autoscaling project for Medplum (via UI — API not exposed)
2. Get access to the existing `solution-builder-sm2hh3` project
3. Use a Lakebase Provisioned instance (none exist yet — create via UI)

## Creating a Lakebase Database for Medplum

### Option A: Lakebase Autoscaling (Recommended)
- Create via workspace UI: Settings → Lakebase → New Autoscaling Project
- Name: `medplum-fhir-db`
- The CLI/API does not expose a create endpoint — UI provisioning required

### Option B: Lakebase Provisioned
- Create via workspace UI: Settings → Lakebase → New Provisioned Instance
- Name: `medplum-fhir-db`
- Capacity: CU_1 (smallest)
- The CLI/API does not expose a create endpoint — UI provisioning required

## Next Steps

1. **Create a Lakebase project via the workspace UI** — the REST API for creation is not available in CLI v1.2.1
2. **Run compatibility tests** — use `databricks psql medplum-fhir-db -- -f scripts/test-lakebase-compat.sql`
3. **Configure Medplum** — set `DATABASE_URL=postgres://<user>:<pass>@<host>:5432/<db>` in the app config

## SQL Warehouse (Fallback)

If Lakebase is not provisioned in time, a SQL Warehouse exists:
```
Name: Serverless Starter Warehouse
ID:   25175ec94b246376
JDBC: jdbc:spark://fevm-medplum.cloud.databricks.com:443/default;...
```
Note: SQL Warehouses speak Spark SQL over JDBC/ODBC, NOT PostgreSQL wire protocol — they cannot serve as a Medplum database backend.
