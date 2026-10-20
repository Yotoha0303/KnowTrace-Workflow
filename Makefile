POWERSHELL ?= powershell

.PHONY: help init up start down stop restart ps logs auth-logs test auth-test check build backup deploy

help:
	@echo KnowTrace-Workflow commands:
	@echo   make init       Generate local secrets and default administrator settings
	@echo   make up         Build and start KnowTrace-Workflow, go-user-system, PostgreSQL and Redis
	@echo   make down       Stop and remove containers while preserving data volumes
	@echo   make restart    Restart the complete stack
	@echo   make ps         Show unified service status
	@echo   make logs       Follow KnowTrace-Workflow and authentication logs
	@echo   make check      Run frontend (Next.js) and Go backend quality gates
	@echo   make backup     Back up KnowTrace-Workflow PostgreSQL and go-user-system PostgreSQL
	@echo   make deploy     Rebuild and redeploy the app on the VPS, then assert the running revision matches HEAD

init:
	$(POWERSHELL) -NoProfile -ExecutionPolicy Bypass -File scripts/init-env.ps1

up start:
	$(POWERSHELL) -NoProfile -ExecutionPolicy Bypass -File scripts/start-all.ps1

down stop:
	docker compose down

restart: down up

ps:
	docker compose ps -a

logs:
	docker compose logs -f app auth

auth-logs:
	docker compose logs -f auth auth-migrate auth-bootstrap auth-postgres auth-redis

test:
	pnpm test

auth-test:
	cd services/go-user-system && go test ./...

build:
	pnpm build

check:
	pnpm typecheck
	pnpm lint
	pnpm test
	pnpm build
	cd services/go-user-system && go test ./...

backup:
	$(POWERSHELL) -NoProfile -ExecutionPolicy Bypass -File scripts/backup-all.ps1

# 在 VPS 上以 root 执行（脚本会自己 sudo）。
# **不要手写 `docker compose up -d --build`** —— 必须同时给两个 --env-file
# 和三个 -f，否则 METRICS_BEARER_TOKEN / KNOWTRACE_APP_REVISION 不会注入，
# 指标端点会失效、版本核对会失去判据，而部署看起来仍然是成功的。
deploy:
	sudo bash scripts/linux/deploy-observability.sh --build-app
