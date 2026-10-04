# KnowTrace-Workflow

> AI-assisted knowledge workflow with traceable evidence, human verification, self-hosted deployment, observability, and reliability engineering.

[中文 README](README.md)

## Project Positioning

KnowTrace-Workflow is a record-first knowledge workflow system for individuals and trusted small groups.

```text
Original Record → AI Assistance → Claim / Evidence → Source Check → Human Conclusion → Independent Review → Reliable Publication
```

AI suggestions are bound to specific record versions and cannot silently overwrite original records. Final conclusions, independent review, and reliable publication remain human-controlled.

The project also serves as an engineering research environment for AI application delivery, multi-service deployment, observability, backup/recovery, fault handling, and reliability engineering.

## Current Capabilities

- Record-first data model and version-aware traceability
- Claim / Evidence / Conclusion workflow
- Workspace-level server-side data isolation
- Unified search across records, claims, evidence, conclusions, categories, objects, and timelines
- Excel data migration with validation and versioned fingerprints
- Independent Go authentication and RBAC service using MySQL + Redis
- Docker Compose multi-service deployment
- Health/readiness checks
- PostgreSQL / MySQL / Redis / upload backups
- SHA-256 integrity manifests and isolated restore verification
- VPS deployment and bounded load testing
- Prometheus / Grafana / Alertmanager
- Loki / Alloy
- OpenTelemetry / OTLP / Tempo
- Blackbox Exporter
- Runbooks, incident records, and postmortems
- Shell / Python / Ansible automation

## Technology Stack

### Application

- Next.js App Router
- TypeScript / React / Tailwind CSS
- PostgreSQL / Drizzle ORM
- Zod
- OpenAI / DeepSeek provider adapters

### Authentication

- Go / Gin / GORM
- MySQL
- Redis
- JWT / Refresh Token / RBAC

### Delivery & Operations

- Linux / Ubuntu
- Docker / Docker Compose
- Nginx / Caddy
- GitHub Actions / GHCR
- Makefile / Shell / Python
- Backup / Restore / SHA-256 verification

### Observability

The current VPS stage uses a lightweight PLG logging stack instead of ELK because of the resource constraints of the current ~1.8 GiB VPS.

```text
Prometheus → Grafana → Alertmanager
Loki ← Alloy ← Caddy / Nginx / Docker Logs
```

The project also uses Blackbox Exporter, OpenTelemetry/Tempo, request IDs, trace context, health/readiness checks, and bounded P50/P95/P99 load testing.

## Deployment

```bash
sudo bash scripts/install.sh --domain knowtrace.example.org
```

A dry-run mode is available before execution. High-risk operations such as SSH hardening, UFW changes, and external credentials remain explicit manual steps to reduce the risk of locking the administrator out of the server.

## Reliability Engineering

The project currently practices backup and restore verification, SHA-256 integrity verification, isolated restore drills, retention planning, health and bounded business-read load tests, Blackbox failure drills, runbooks, incident/postmortem records, release verification gates, deployment health checks, and rollback gates.

These results represent the current single-VPS environment and current verification window. They do not claim high availability, long-term capacity, a formal SLA, or multi-node production readiness.

## Explicit Scope Boundaries

The project currently does not focus on RAG/vector retrieval/knowledge graphs, automatic web evidence supplementation, AI making final truth judgments without human review, large-scale team permissions and billing, or mobile application UI.

The priority is validating whether the existing system and workflow actually work.

## Documentation

See [docs/README.md](docs/README.md) for the complete documentation index.

## License

MIT License.
