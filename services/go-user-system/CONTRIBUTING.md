# Contributing

## Development setup

Required tools:

- Go version declared in `go.mod`
- Node.js 22.22.2 or newer and npm
- Docker with Docker Compose
- golangci-lint v2 for backend linting

Start the complete stack by following `docs/deploy/local-compose.md`. For backend-only development, configure `.env` and `.env.goose`, run migrations, then use `go run ./cmd`.

## Change workflow

1. Create a focused branch from `main`.
2. Add or update tests for behavior changes.
3. Keep API, configuration, migration, README, and deployment documentation synchronized.
4. Run the relevant local checks.
5. Open a pull request using the repository template.

Required checks before opening a pull request:

```bash
make lint
make test
make race-test
make vet
make security
make migrate-validate
```

Note: The legacy standalone React frontend has been deprecated and replaced by the outer Next.js application (PR #50). All authentication flows and browser end-to-end tests are maintained at the repository root level.

## Database changes

Create a new sequential Goose migration. Do not edit a migration that has already shipped in a release. Provide both `Up` and `Down` sections unless rollback is unsafe; document any unsafe rollback explicitly.

## Pull requests

Keep each pull request limited to one coherent change. Describe user-visible behavior, security impact, migration requirements, test evidence, and documentation changes. Never commit real `.env` files, Kubernetes secrets, passwords, JWT secrets, tokens, or user data.
