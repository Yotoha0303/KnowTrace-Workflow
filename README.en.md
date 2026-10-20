# KnowTrace-Workflow

> AI-assisted knowledge workflow with traceable evidence, human verification, self-hosted deployment, and full-stack observability.

[中文 README](README.md)

## Project Positioning

KnowTrace-Workflow is a record-first knowledge workflow system for individuals and trusted small groups.

```text
Original Record → AI Assistance → Claim / Evidence → Source Check → Human Conclusion → Independent Review → Reliable Publication
```

AI suggestions are bound to specific record versions and cannot silently overwrite original records. Final conclusions, independent review, and reliable publication remain human-controlled.

The system ships as a **full-stack TypeScript application + an independent Go authentication service + a multi-engine data layer + a containerized observability stack**. It is designed for **lightweight, resource-constrained environments**: a single 2 vCPU server carries the application, authentication, monitoring, and logging stacks together, while the architecture keeps a clear path to horizontal scaling.

## Business Problems Addressed

| Problem | How it shows up elsewhere | This project's approach |
| --- | --- | --- |
| **Capture is interrupted by organization demands** | Titles, categories, and templates required before saving — ideas are lost at the entry point | One focused input box with no required fields; time and subject are optional |
| **Accumulated content cannot be placed** | Keywords, experiences, observations, and research questions blur together | Three orthogonal dimensions (category, content type, subject); one record can belong to many categories |
| **AI processing is not reproducible** | Only the final output is kept; nobody can say which source version, model, or prompt was used | Every call is persisted as an AI Run bound to an input snapshot and content hash; suggestions are tied to a record version and go stale on drift |
| **AI conclusions overstep** | AI rewrites authoritative data directly; human review becomes decorative | AI produces only `pending` candidates; acceptance is a second, independently authorized action that never writes authoritative data directly |

## System Capabilities

- Record-first data model and version-aware traceability
- Claim / Evidence / Conclusion workflow
- A **decidable release gate**: `evaluateReleaseReadiness()` runs eight checks — authority, source independence, and reviewer separation become booleans rather than slogans
- Workspace-level server-side data isolation
- Unified search across records, claims, evidence, conclusions, categories, objects, and timelines
- Excel data migration with validation and versioned fingerprints; imported "trusted" state is always safely downgraded
- An independent Go authentication and RBAC microservice using PostgreSQL + Redis
- Docker Compose orchestration for the application, PostgreSQL (business and auth instances), and Redis
- Health/readiness checks, database and upload backups, and isolated restore verification

## Architecture

```text
Browser / native clients
        │
        ▼
Edge        Caddy (TLS termination + security headers)
        │
        ▼
Proxy       Nginx (rate limiting, real-IP restoration, edge 404 on metrics)
        │
        ▼
Application Next.js (App Router + Server Actions + BFF)  ◄──►  Go auth service (JWT / Refresh / RBAC)
        │                                                             │
        ▼                                                             ▼
Data        PostgreSQL (business, claims, evidence chain)   PostgreSQL (accounts/roles) + Redis (sessions/limits)
        │
        ▼
Observability  Prometheus ──► Grafana ──► Alertmanager ──► Email alerts
               Loki ← Alloy ← edge and container logs
               Blackbox Exporter ｜ Node Exporter ｜ structured logs with request IDs
```

Four independent layers: **front-end interaction** (server-rendered App Router with client components limited to local interaction state), **back-end services** (business rules confined to Application Services across 13 `src/features/*` domains, decoupled from the framework; authentication is a separately deployed Go microservice), **data storage** (PostgreSQL for business, claims and the evidence chain as well as accounts and roles, Redis for sessions and rate limiting; 22 append-only versioned migrations), and **containerized observability** (12 resident containers, three independent collection paths for metrics, logs, and active probes — the private `/api/metrics` endpoint requires a bearer token — all bound to loopback and reached over SSH tunnels).

## Technology Stack

### Application

- Next.js App Router
- TypeScript / React / Tailwind CSS
- PostgreSQL / Drizzle ORM
- Zod
- OpenAI / DeepSeek provider adapters

> AI note: the runtime provider is DeepSeek (and OpenAI-compatible endpoints). The
> `claude-*` strings in the code are inbound protocol aliases required by CC-Switch
> routing — they do **not** mean this project uses Claude models. See `docs/22-团队视角-接手与协作.md` §3.3.

### Authentication

- Go / Gin / GORM
- PostgreSQL (ADR-0019)
- Redis
- JWT / Refresh Token / RBAC

### Delivery & Operations

- Linux / Ubuntu
- Docker / Docker Compose
- Nginx / Caddy
- GitHub Actions (four gate jobs; images are built on the deployment host, not pushed via a registry)
- Makefile / Shell / Python / Ansible
- Backup / Restore / SHA-256 verification

### Observability

The lightweight **PLG** logging path runs resident alongside the monitoring stack, which suits resource-constrained hosts:

```text
Prometheus → Grafana → Alertmanager
Loki ← Alloy ← Caddy / Nginx / Docker Logs
```

The project also uses Blackbox Exporter (internal and public probing), structured logging with request IDs threaded through error paths, health/readiness checks, and bounded P50/P95/P99 load testing. Loki carries no JVM — measured combined resident memory is roughly 140 MiB.

## Measured Outcomes

Every figure below is measured and can be checked in the linked source:

| Dimension | Measured result |
| --- | --- |
| Application size | ~26.3k lines under `src/`, 13 business domains, 22 versioned migrations |
| Orchestration | **12 resident containers**, health-gated startup ordering |
| Data-layer restore | Isolated restore verification in **36 seconds** |
| Application baseline | nginx-fronted **1000 requests / concurrency 20**: 100% success, p50 65.8 ms, p95 161.0 ms, p99 542.9 ms |
| Low-concurrency baseline | nginx-fronted **200 requests / concurrency 5**: 211.4 RPS, p50 18.3 ms, p95 37.8 ms |
| Resource usage | Load-test peak app memory 154 MB / 1.8 GB limit, CPU 1.23%, database 0% throughout |
| CI gates | **4 jobs**: type-check, lint, unit tests, coverage baseline, production build, Go tests, auth-frontend build, and end-to-end (unauthenticated and authenticated) |
| Test assets | 43 co-located unit tests, 18 Playwright end-to-end specs, 26 Go test files, plus an independent auth-frontend suite |
| Decision record | **18 ADRs** (with superseded relationships) plus a pre-change record mechanism |

Two of these are worth calling out, because both fix "looks healthy" failure modes:

- **Runtime identity assertion**: four layers of health checks, 12 scrape targets, and 29 alert rules can all be green while the running image is 37 commits behind. The deploy script therefore asserts the runtime revision and distinguishes "application code changed" from "only docs fell behind", so the alert is not trained into being ignored.
- **Delivery, not firing**: the fault drill originally asserted only that Alertmanager received the alert. Because of `group_wait`, the whole group was cleared before first delivery, **no email was ever sent**, and the drill still reported PASS. The criterion now rests on the increment of `alertmanager_notifications_total{integration="email"}`.

## Deployment

```bash
sudo bash scripts/install.sh --domain knowtrace.example.org
```

A dry-run mode is available before execution. High-risk operations such as SSH hardening, UFW changes, and external credentials remain explicit manual steps to reduce the risk of locking the administrator out of the server.

Monitoring, logging, and database endpoints stay bound to `127.0.0.1` and are reached over SSH tunnels; only the reverse proxy and SSH are exposed publicly.

## Reliability Engineering

The project operates backup classes (PostgreSQL business & auth, Redis, uploads) with SHA-256 manifests, isolated restore verification (`RESTORE_VERIFY=PASS` gates releases), an encrypted offsite channel, scheduled backup windows with retention, bounded health and business-read load tests, Blackbox fault drills with recoverable alert-path verification, runbooks, incident/postmortem records, and deployment health checks with rollback gates.

> **Evidence boundary (for reviewers and teams taking over)**: the results above were
> collected on a **single-region, single-node topology** covering the current sample and
> test window. The application layer is stateless and session/data layers are externalized,
> so horizontal scaling is an available path rather than a rewrite; multi-AZ deployment,
> cross-region disaster recovery, formal SLAs, and capacity modelling are the next
> evolution stage and are not claimed as verified today.
> Per-capability evidence grading lives in [`docs/21-path-to-100-percent.md`](docs/21-path-to-100-percent.md).

## Explicit Scope Boundaries

The following are deliberate product decisions, not missing capability: RAG/vector retrieval/knowledge graphs, automatic web evidence supplementation, AI making final truth judgments without human review, large-scale team permissions and billing, and mobile application UI (the `/api/v1` contract is delivered for future clients).

The priority is validating whether the existing system and workflow actually work. The current deployment targets **trusted small groups or protected networks**; exposing it to anonymous public traffic requires additional hardening and capacity validation — see [`SECURITY.md`](SECURITY.md).

## Documentation

See [docs/README.md](docs/README.md) for the complete documentation index.

## License

Apache License 2.0.
