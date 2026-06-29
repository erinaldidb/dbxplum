# Medplum on Databricks: Integration Plan

## Executive Summary

Deploy **Medplum** (open-source FHIR-compliant EHR platform) on **Databricks** using:
- **Databricks App #1** — Medplum server (Node.js/Express)
- **Databricks App #2** — Redis server (dedicated, independently scalable)
- **Lakebase** — dedicated PostgreSQL-compatible database

Apps can scale up to 4 vCPUs / 12GB RAM. Node.js is confirmed compatible with Databricks Apps.

---

## 1. Architecture Overview

```
┌───────────────────────────────────────────────────────────────────────┐
│                        Databricks Workspace                            │
│                                                                       │
│  ┌─────────────────────────┐       ┌─────────────────────────┐       │
│  │  App #1: Medplum Server │       │  App #2: Redis Server   │       │
│  │  (Node.js/Express)      │       │  (Dedicated)            │       │
│  │                         │       │                         │       │
│  │  - FHIR R4 REST API     │◀─────▶│  - Job queues (BullMQ)  │       │
│  │  - OAuth 2.0 / SMART    │ redis │  - Pub/sub              │       │
│  │  - GraphQL              │ proto │  - Session cache         │       │
│  │  - Subscriptions        │       │  - Rate limiting        │       │
│  │  - Bot execution        │       │                         │       │
│  └────────────┬────────────┘       └─────────────────────────┘       │
│               │                                                       │
│               │ PG wire protocol                                      │
│               ▼                                                       │
│  ┌───────────────────────────────────────────┐                       │
│  │  Lakebase (Dedicated PostgreSQL Database) │                       │
│  │                                           │                       │
│  │  - FHIR Resource Tables (Patient, etc.)   │                       │
│  │  - History Tables (versioning)            │                       │
│  │  - Auth / User / Project tables           │                       │
│  │  - Search parameter indexes               │                       │
│  │                                           │                       │
│  │  Change Data Feed ──▶ Delta Lake          │                       │
│  └───────────────────────────────────────────┘                       │
│                                                                       │
│  ┌───────────────────────────────────────────┐                       │
│  │  Unity Catalog Volumes                    │                       │
│  │  - FHIR Binary resources (images, PDFs)   │                       │
│  │  - Attachments & documents                │                       │
│  └───────────────────────────────────────────┘                       │
│                                                                       │
│  ┌───────────────────────────────────────────────────────────────┐   │
│  │  Unity Catalog + Delta Lake (Analytics Layer)                  │   │
│  │  - SQL/Spark analytics on FHIR data                           │   │
│  │  - ML/AI pipelines on clinical data                           │   │
│  │  - Governance, lineage, audit                                 │   │
│  └───────────────────────────────────────────────────────────────┘   │
└───────────────────────────────────────────────────────────────────────┘
```

---

## 2. Component Mapping

| Medplum Requirement | Standard Deployment | Databricks Equivalent | Risk |
|---|---|---|---|
| Application Server (Node.js) | EC2/ECS/Docker | Databricks App #1 (Node.js confirmed) | Low |
| PostgreSQL 16 | RDS/self-hosted | Lakebase (dedicated, PG wire-compatible) | Medium |
| Redis 7 (cache/jobs) | ElastiCache/self-hosted | Databricks App #2 (Redis server) | Low |
| Binary/File Storage (S3) | AWS S3 | Unity Catalog Volumes | Medium |
| HTTPS/TLS termination | ALB/Nginx | Databricks Apps built-in | Low |
| DNS/Domain | Route53 | Databricks Apps provides URL | Low |

---

## 3. Key Challenges & Risks

### 3.1 MEDIUM: Lakebase PostgreSQL Compatibility

**Medplum uses these PostgreSQL features:**
- `UUID` primary keys and `UUID[]` arrays
- `TEXT[]` arrays for denormalized search fields
- `TIMESTAMP WITH TIME ZONE`
- Advisory locks (`pg_try_advisory_lock`) for migration coordination
- `REPEATABLE READ` transaction isolation (default)
- `pg_stat_statements` / `auto_explain` (monitoring only, not required)

**Validation needed:**
- Run Medplum DDL/migrations against Lakebase to discover gaps
- Array types are the primary concern — they're core to Medplum's search model
- Advisory locks can be worked around if unsupported (single-instance doesn't need them)

### 3.2 MEDIUM: Inter-App Networking (Medplum ↔ Redis)

**Problem:** The two Databricks Apps need to communicate. Medplum connects to Redis over TCP (port 6379).

**Questions to validate:**
- Can Databricks Apps reach each other via internal networking?
- Is there a service discovery mechanism or fixed internal hostname?
- Latency between apps (Redis is latency-sensitive)

**Fallback:** If inter-app networking is not possible, co-locate Redis as a subprocess within the Medplum app (sacrificing independent scaling).

### 3.3 MEDIUM: Binary Storage Adapter

**Problem:** Medplum expects S3-compatible storage (`s3:bucket-name` config).

**Options:**
1. **Unity Catalog Volumes** — governed, analytics-accessible, requires custom adapter
2. **Direct cloud storage (S3/ADLS)** — use Medplum's existing S3 adapter with credentials
3. **Filesystem** — Medplum supports `file:` prefix for local storage (ephemeral on Apps)

**Recommendation:** Direct cloud storage (S3/ADLS) for MVP since Medplum already supports it. Migrate to Volumes adapter later for unified governance.

### 3.4 LOW: App Bundle Size

**Concern:** Databricks Apps has a 10MB file limit per file.

**Mitigation:** Use `npm install --production` and exclude dev dependencies. The Medplum server package itself is lean — heavy dependencies (if any) can be bundled with esbuild.

---

## 4. What We Can Achieve

### Phase 1: Core FHIR Server (MVP)
- FHIR R4 REST API (CRUD on all resource types)
- OAuth 2.0 / SMART-on-FHIR authentication
- Patient, Practitioner, Organization, Encounter management
- FHIR Search across all resource types
- User management and access control
- Audit logging (AuditEvent resources)
- Background job processing (via Redis app)
- Real-time subscriptions

### Phase 2: Full Platform
- Binary/attachment storage
- Bot execution (custom automation)
- Email notifications (SMTP)
- HL7v2 integration (if needed)
- FHIR Bulk Data export

### Phase 3: Databricks-Native Analytics
- Lakebase CDF → Delta Lake sync (FHIR data available as tables)
- SQL/Spark analytics on clinical data
- ML models (risk scores, readmission prediction, etc.)
- AI agents with FHIR API access
- Dashboards and reporting
- Data quality monitoring

### Unique Value
- **Unified governance** — clinical data under Unity Catalog
- **Analytics-ready** — FHIR data queryable with SQL, Python, Spark
- **AI/ML native** — train models directly on clinical data
- **Scalable** — Redis and Medplum scale independently
- **Enterprise security** — workspace-level access controls

---

## 5. Implementation Plan

### Step 1: Environment Setup
- [ ] Provision dedicated Lakebase database
- [ ] Create Databricks App #2 (Redis server)
- [ ] Validate inter-app networking (can App #1 reach App #2 on port 6379?)
- [ ] Create Unity Catalog Volume for binary storage (or configure cloud storage)

### Step 2: Redis App
- [ ] Create minimal Redis app (`app.yaml` + redis-server binary or npm `redis-server` package)
- [ ] Configure password authentication
- [ ] Deploy and verify connectivity
- [ ] Test from a second app (network validation)

### Step 3: Lakebase Validation
- [ ] Connect to Lakebase with standard PG client (psql / node-postgres)
- [ ] Run Medplum schema migrations (v1 DDL)
- [ ] Test: UUID columns, UUID[] arrays, TEXT[] arrays
- [ ] Test: REPEATABLE READ transaction isolation
- [ ] Test: advisory locks (pg_try_advisory_lock)
- [ ] Document any incompatibilities and workarounds

### Step 4: Medplum Server Adaptation
- [ ] Clone Medplum repository
- [ ] Create Databricks-specific server config (`medplum.config.json`)
- [ ] Configure database connection → Lakebase
- [ ] Configure Redis connection → App #2 hostname
- [ ] Configure binary storage → cloud storage or Volumes
- [ ] Create `app.yaml` for Databricks Apps
- [ ] Build production bundle

### Step 5: Deploy & Validate
- [ ] Deploy Medplum server as App #1
- [ ] Run full migration against Lakebase
- [ ] Seed initial data (super admin, default project)
- [ ] Test FHIR CRUD: `POST /fhir/R4/Patient`, `GET`, `PUT`, `DELETE`
- [ ] Test search: `GET /fhir/R4/Patient?name=...`
- [ ] Test OAuth flow: client credentials + authorization code
- [ ] Test subscriptions (Redis pub/sub)
- [ ] Test background jobs (BullMQ via Redis)

### Step 6: Analytics Integration
- [ ] Enable Lakebase Change Data Feed
- [ ] Create Delta Lake tables from FHIR data
- [ ] Build example analytics queries
- [ ] Create sample dashboard

---

## 6. Technical Decisions

| # | Decision | Choice | Rationale |
|---|---|---|---|
| 1 | Redis hosting | Separate Databricks App | Independent scaling, isolation |
| 2 | Binary storage | Direct cloud storage (S3/ADLS) for MVP | Medplum already supports it natively |
| 3 | Server bundling | `npm install --production` | Keep it simple unless size is an issue |
| 4 | Auth | Medplum-native OAuth | Full SMART-on-FHIR support out of the box |
| 5 | App structure | Two apps (Medplum + Redis) | Clean separation of concerns |

---

## 7. Immediate Next Steps

1. **Deploy Redis app** — simplest validation; confirms app-to-app networking
2. **Test Lakebase DDL** — run Medplum's schema v1 to find PG compatibility gaps
3. **Build Medplum config** — create `medplum.config.json` pointing to Lakebase + Redis app

---

## 8. Risk Summary

| Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|
| Lakebase doesn't support UUID[]/TEXT[] arrays | Blocker | Medium | Test early; workaround with JOIN tables or JSONB |
| Inter-app networking blocked | Blocker | Low-Medium | Fall back to co-located Redis subprocess |
| Advisory locks unsupported | Low | Medium | Single-instance doesn't need them; guard in code |
| App bundle too large | Medium | Low | esbuild tree-shaking, split packages |
| Lakebase latency for FHIR search | Medium | Low | Read replicas, query optimization |

---

## References
- [Medplum Documentation](https://www.medplum.com/docs)
- [Medplum Self-Hosting Guide](https://www.medplum.com/docs/self-hosting)
- [Medplum GitHub Repository](https://github.com/medplum/medplum)
- [Medplum Server Config](https://www.medplum.com/docs/self-hosting/config-settings)
- [Databricks Apps Documentation](https://docs.databricks.com/en/dev-tools/databricks-apps/index.html)
- [Lakebase Product Page](https://www.databricks.com/product/lakebase)
