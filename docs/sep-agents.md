# SEP Development Guide for AI Agents

> **Where this lives, and why.** Unlike [`pmm/AGENTS.md`](../pmm/AGENTS.md), which is
> committed upstream in PMM's own repository, this guide is kept **here** in the
> workspace. It was written for this setup and has never been part of SEP's tree, so
> keeping it in the submodule left it untracked — one `git clean` from gone, and absent
> on a fresh clone. If SEP upstream later adopts a guide of its own, prefer that one and
> reduce this to the workspace-specific parts.

## Maintaining This Document

This file is read by AI agents working on the Services Enablement Platform (SEP). Keep this file accurate whenever altering project structure, dependencies, toolchains, build targets, or development conventions.

---

## Product Overview

**SEP (Services Enablement Platform)** is an enterprise platform developed by Percona to enable management, automation, inventory synchronization, and service orchestration. It integrates directly with **PMM (Percona Monitoring & Management)** to pull infrastructure telemetry, node metrics, database facts, and execution jobs.

### Primary Tech Stack

- **Backend**: Python 3.11+ (FastAPI, SQLModel / SQLAlchemy 2.0, Alembic, Celery, Pydantic v2, Uvicorn)
- **Frontend**: TypeScript, React, PNPM Workspaces, Oxlint, Prettier
- **Job Orchestration**: Celery (with Redis / SQL backend), HashiCorp Nomad
- **Authentication**: Casdoor OAuth2 / OIDC integration
- **Linting & Formatting**: Ruff (Python linter & formatter), djLint (HTML/Jinja template formatter), Oxlint/Oxfmt (Frontend)
- **Type Checking**: Astral `ty` (local static type checker) & Pylance

---

## Workspace Structure & Architecture

```
SEP/
├── app/                        # Main FastAPI backend package
│   ├── api/                    # API endpoints and FastAPI routes
│   ├── core/                   # Core settings, db setup, auth, security
│   ├── inventory/              # Host & service inventory models & syncers (PMMSyncer, MySQLSyncer)
│   ├── sep/                    # SEP apps, backup syncers, system facts
│   ├── tasks/                  # Celery background task queue models & runners
│   ├── main.py                 # FastAPI application entrypoint
│   └── celery.py               # Celery app initialization
├── frontend/                   # React / TypeScript frontend (PNPM monorepo)
├── scripts/                    # Maintenance & sync scripts
├── tests/                      # Pytest test suite (asyncio, mock, fixtures)
├── pyproject.toml              # Dependencies (Poetry), Ruff, Ty, Pytest config
├── alembic.ini                 # DB Migration configuration
├── Makefile                    # Standard developer workflow targets
└── Dockerfile                  # Production container definition
```

---

## Key Development Commands

| Task | Command | Description |
|------|---------|-------------|
| **Setup Venv** | `make venv` | Create Python venv and install all dependencies via Poetry |
| **Lint & Check Format** | `make lint` | Runs `ruff check .` and `djlint .` |
| **Auto-Format Code** | `make format` | Runs `ruff format .` and `djlint . --reformat` |
| **Run Unit Tests** | `make test` | Runs Pytest with asyncio and coverage |
| **FastAPI Dev Server** | `make dev-backend` | Runs FastAPI server using venv Python |
| **Frontend Dev Server** | `make dev-frontend` | Runs `pnpm dev` in `frontend/` |
| **Database Migrations** | `make migrate` | Applies Alembic migrations across inventory, tasks, and sep DBs |
| **Create Migration** | `make makemigrations` | Generates new Alembic migration script |
| **Type Check** | `make typecheck` | Runs `ty check app` for static typing verification |

---

## Code Conventions & Standards

1. **Formatter & Linter**: Always use **Ruff** for Python files (`ruff check` and `ruff format`).
2. **Type Hints**: All function signatures must include Python standard type annotations.
3. **Database Operations**: Async SQLAlchemy 2.0 / SQLModel patterns are mandatory for database operations (`app/core/db.py`).
4. **Error Handling**: Use standard FastAPI `HTTPException` with structured details; avoid broad silent try/except blocks.
