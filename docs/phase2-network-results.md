# Phase 2: Network Connectivity Test Results

**Date:** 2026-06-29  
**Test Environment:** medplum-server app → medplum-redis app  
**Host:** ip-10-121-186-44.ec2.internal (AWS)

## Summary

| Test | Target | Port | Result |
|------|--------|------|--------|
| DNS Resolution | medplum-redis-*.aws.databricksapps.com | — | PASS (→ 192.168.200.10) |
| HTTPS Connectivity | Redis app external URL | 443 | PASS (302 OAuth redirect) |
| Raw TCP (Redis port) | Redis app hostname | 6379 | FAIL (No route to host) |
| Raw TCP (internal port) | Redis app hostname | 8000 | FAIL (No route to host) |
| Redis over TLS | Redis app hostname | 443 | FAIL (400 Bad Request) |
| Lakebase Postgres | ep-orange-surf-d2rmx7xp.database.us-east-1.cloud.databricks.com | 5432 | PASS (TCP connected) |

## Key Findings

### 1. Inter-App Networking: HTTP-ONLY

Databricks Apps can reach each other ONLY over HTTPS (port 443) through the platform's gateway. The gateway:
- Terminates TLS
- Enforces OAuth 2.0 authentication (302 redirect for unauthenticated requests)
- Only passes HTTP/2 traffic — no raw TCP passthrough
- Non-HTTP protocols on port 443 get `400 Bad Request`

### 2. Raw TCP Ports are NOT Routable

Ports 6379 (Redis standard) and 8000 (internal app port) return "No route to host". The platform network only exposes the HTTPS gateway — apps cannot communicate via arbitrary TCP ports.

### 3. Redis Protocol is INCOMPATIBLE with This Model

Medplum's Redis client (ioredis) needs the RESP protocol over raw TCP or TLS. Since the platform only allows HTTP traffic between apps, a separate Redis app CANNOT serve Medplum.

### 4. Lakebase IS Reachable

The Lakebase Postgres endpoint (`ep-orange-surf-d2rmx7xp.database.us-east-1.cloud.databricks.com:5432`) is fully reachable from apps over TCP. This means Medplum can connect to Lakebase as its database.

## Architecture Decision: Co-located Redis

**Decision:** Redis MUST run as a subprocess inside the Medplum server app.

**Reason:** The Databricks Apps platform does not support raw TCP communication between apps. Only HTTPS is routed. Redis requires the RESP binary protocol over TCP.

**Impact:**
- The separate `medplum-redis` app is no longer needed for production use (keep it for independent Redis testing only)
- The `medplum-server` app will run both Redis and Medplum as processes
- Redis binds to `localhost:6379` — no network exposure needed
- This is acceptable because Medplum's Redis usage is lightweight (job queues, caching, pub/sub) — a single node is sufficient

**Updated Architecture:**
```
┌─────────────────────────────────────────────┐
│  Databricks App: medplum-server             │
│                                             │
│  ┌──────────────────┐  ┌────────────────┐  │
│  │  Redis (bg proc) │  │ Medplum Server │  │
│  │  localhost:6379   │──│ Node.js        │  │
│  └──────────────────┘  └───────┬────────┘  │
│                                │            │
└────────────────────────────────┼────────────┘
                                 │ TCP:5432
                    ┌────────────▼────────────┐
                    │  Lakebase (Postgres)     │
                    │  ep-orange-surf-*        │
                    │  us-east-1               │
                    └─────────────────────────┘
```
