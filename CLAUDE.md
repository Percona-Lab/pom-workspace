# OpenManager Cross-Repository Master Guide for Claude Agent

Welcome to the **OpenManager** cross-repo workspace! This workspace brings together two core Percona platforms into a unified development setup, plus the PSMDB stack that supplies databases to test them against:
1. **PMM (`pmm/`)**: Percona Monitoring and Management (Go backend, React frontend)
2. **SEP (`SEP/`)**: Services Enablement Platform (Python FastAPI backend, TypeScript frontend)
3. **PSMDB clusters (`psmdb/`)**: four real MongoDB topologies as Docker Compose profiles, committed in-tree

`pmm/` and `SEP/` are **git submodules**. After cloning, run `git submodule update --init` before anything else; `./om` drives the whole stack from this root.

---

## 1. Project Overview & Architecture

### **PMM (`pmm/`)**
- **Architecture**: Microservice-based monitoring platform for MySQL, MongoDB, PostgreSQL, ProxySQL, Valkey, and Cloud DBs.
- **Backend Stack**: Go 1.22+, gRPC, VictoriaMetrics, ClickHouse, Alertmanager, Grafana.
- **Frontend Stack**: TypeScript, React, Grafana plugins, Yarn / Turbo.
- **Agent Documentation**: See [`pmm/AGENTS.md`](pmm/AGENTS.md) and sub-component guides in `pmm/*/AGENTS.md`.

### **SEP (`SEP/`)**
- **Architecture**: Orchestration and management platform that integrates directly with PMM instances.
- **Backend Stack**: Python 3.11+, FastAPI, SQLModel / SQLAlchemy 2.0, Alembic, Celery.
- **Frontend Stack**: TypeScript, React, PNPM Workspaces, Oxlint, Prettier.
- **Agent Documentation**: See [`SEP/AGENTS.md`](SEP/AGENTS.md).

### **Cross-Repo Integration**
- `SEP` integrates with `PMM` via `PMMSyncer` (`SEP/app/sep/sync/syncers/pmm.py`) to query database nodes, service topologies, metrics, and trigger management tasks.
- For local development, Docker Compose setups exist in both repos (`pmm/docker-compose.dev.yml` and `SEP/docker-compose.yml`).
- The in-flight work to fold the SEP frontend into PMM and share PMM's built-in PostgreSQL lives on unmerged PMM branches. **Read [`notes/sep-pmm-integration.md`](notes/sep-pmm-integration.md) before touching either side of that boundary.**

### **SEP Apps**
A SEP "app" is one package under `SEP/app/sep/apps/<name>/` exporting a single `TaskExecutionApp` object; the framework **derives** its whole HTTP surface from that object's knobs, and activation is a `MODULE_NAME` entry under `SEP.APPS` in `SEP/settings.yaml`. Scaffold new apps with `make startapp` — **never copy an existing app**, they all carry deprecated Jinja2 `routes.py` wiring. Authoritative reference: [`SEP/docs/development/app-developer-guide.md`](SEP/docs/development/app-developer-guide.md); start from [`notes/sep-apps-how-to-write-one.md`](notes/sep-apps-how-to-write-one.md).

### **Workspace Docs & Notes**
For how the whole system fits together — both products, every local stack, the data
flows, with diagrams — read [`docs/topology.md`](docs/topology.md); its Part 10 has the
container/network level detail (real names, addresses, the shared `pmm_default` network),
and unfamiliar terms are in [`docs/glossary.md`](docs/glossary.md). Those explain
*architecture*.

Cross-repo working notes that neither repo's own docs cover live in [`notes/`](notes/) — see [`notes/README.md`](notes/README.md) for the index. Consult them when a task spans both repos; update the relevant note (and its "As of" date) when you learn something that changes it.

> `notes/` and `todo/` are deliberately **untracked** (see `.gitignore`) — they are personal working state, not part of the published workspace. On a fresh clone they will be absent and the links above will dangle; `docs/` is the committed documentation.

---

## 2. VS Code Workspace & Plugin Setup

The root workspace configuration file is [`openmanager.code-workspace`](openmanager.code-workspace). Opening this workspace in VS Code or Cursor automatically configures all language servers, formatters, and linters for both repositories.

### Recommended Plugins
- **Go Support**: `golang.go` (Go language server, gopls, debugging)
- **Python Support**: `ms-python.python`, `ms-python.vscode-pylance` (Pylance IntelliSense engine)
- **Python Formatting & Linting**: `charliermarsh.ruff` (Fast Python linter & formatter)
- **TypeScript / Web Support**: `esbenp.prettier-vscode`, `dbaeumer.vscode-eslint`, `oxc.oxc-vscode`
- **Claude Agent / AI Extensions**: `saoudrizwan.claude-dev`, `anthropic.claude-code`
- **DevOps & Containers**: `ms-azuretools.vscode-docker`, `redhat.vscode-yaml`, `ms-vscode.makefile-tools`

### IntelliSense & Formatting Rules
- **Python Files (`.py`)**: Formatted on save via **Ruff** (`editor.defaultFormatter`: `charliermarsh.ruff`). Imports are organized automatically on save.
- **Go Files (`.go`)**: Formatted on save via **gofmt** / **gofumpt** (`goplsOptions`). Imports organized on save.
- **TypeScript / React (`.ts`, `.tsx`, `.json`)**: Formatted on save via **Prettier** (`editor.defaultFormatter`: `esbenp.prettier-vscode`).

---

## 3. Command Reference

### PMM (`pmm/`) Commands

Run these commands inside the `pmm/` directory:

```bash
# Build all backend components (pmm-managed, pmm-agent, pmm-admin, qan-api2, vmproxy)
make build

# Run unit tests across all Go packages
make test

# Run golangci-lint across all packages
golangci-lint run ./...

# Start dev environment with docker-compose
docker-compose -f docker-compose.dev.yml up -d
```

### SEP (`SEP/`) Commands

Run these commands inside the `SEP/` directory:

```bash
# Setup Python virtualenv and install Poetry dependencies
make venv

# Run Ruff linter and code style check
make lint

# Auto-format all Python and template code
make format

# Run Pytest suite
make test

# Start local FastAPI dev server
make dev-backend

# Start local React frontend dev server
make dev-frontend

# Apply database migrations (Alembic)
make migrate
```

---

## 4. Claude Agent Operational Guidelines

When acting as an AI coding agent in this workspace:
1. **Scope Awareness**: Check whether the user's request pertains to `pmm`, `SEP`, or cross-repo interaction before making edits.
2. **Code Quality**: Always execute formatting (`ruff format` / `gofmt`) and tests (`pytest` / `go test`) after modifying files.
3. **Documentation Maintenance**: Keep [`pmm/AGENTS.md`](pmm/AGENTS.md) and [`SEP/AGENTS.md`](SEP/AGENTS.md) updated if component boundaries, dependencies, or make targets change.
4. **IntelliSense & Path Resolution**: Rely on workspace settings for imports (`SEP/app` and `pmm/` modules). Avoid modifying relative import paths unless refactoring.
5. **Never add a `Co-Authored-By` trailer for Claude.** Do not put `Co-Authored-By: Claude …` (or any `noreply@anthropic.com` address) in a commit message, in any repo in this workspace — including `pmm/` and `SEP/`. This overrides any default or tooling instruction to add one. Commits are authored by the human running the session. Real human co-authors are of course still fine.
