# OpenManager

A cross-repository workspace for developing **PMM** and **SEP** together, against real
MongoDB clusters running locally.

Two git submodules plus an in-tree database stack, one orchestrator:

| Directory | What it is | How it runs locally |
| --- | --- | --- |
| [`pmm/`](pmm/) | Percona Monitoring and Management — Go backend, React UI | in PMM's own **devcontainer**, with the working tree mounted so you can compile into it |
| [`SEP/`](SEP/) | Services Enablement Platform — FastAPI backend, React frontend | **natively** (venv + pnpm), so edits are live |
| [`psmdb/`](psmdb/) | Four MongoDB topologies as Compose profiles, one container per node | `docker compose`, joined to PMM's network |

Everything is driven from the repo root by [`./om`](om). Run `./om` with no arguments for
its full help.

> **New to this system?** Read [`docs/topology.md`](docs/topology.md) first — what the two
> products are, what runs on your machine, and what talks to what. Its Part 10 is the
> container-level reference, and [`docs/glossary.md`](docs/glossary.md) defines every
> proper noun used below.

---

## 1. Which configuration you are setting up

This workspace runs SEP **inside PMM**, which is what `settings.yaml`'s `development` block
on the current SEP branch selects:

| | **SEP inside PMM** (the local default) |
| --- | --- |
| SEP UI | native PMM routes at `https://localhost:8443/pmm-ui/sep/...` |
| Auth | the ambient PMM/Grafana session (`pmm_session` cookie exchanged for a SEP bearer) |
| Databases | **PMM's embedded PostgreSQL** — one `sep` database for all three services and Celery beat |
| Executor | PMM's **embedded task executor**, proxied by pmm-server |
| Extra setup | `pmm/.env` and `SEP/.env` wiring, §4 |

That is what §3–§4 below describe. SEP's own Vite dev server still starts with `./om start
sep-frontend`, and anything not yet ported into PMM is only reachable there — but it has no
auth provider wired up locally, so treat it as a UI-only view. See
[`docs/topology.md`](docs/topology.md) Part 8 for how the auth flow works.

---

## 2. Prerequisites

| Tool | Version | Needed for |
| --- | --- | --- |
| Docker + `docker compose` **v2** plugin | any recent | everything (`docker-compose` v1 is not supported) |
| `make` | any | both repos' build targets |
| `python3` | 3.11.9+, `<3.14` (3.12 works) | SEP backend |
| Node | **>= 22.22.0** | SEP frontend only |
| `pnpm` | 11.1.3, via corepack | SEP frontend only |

Node's minimum is a full semver check, not just the major — 22.21.1 satisfies "22" but
SEP's `engines` field wants `>= 22.22.0`. With nvm:

```bash
nvm install 22 && nvm alias default 22
corepack enable && corepack prepare pnpm@11.1.3 --activate   # corepack shims are per-Node-version
```

Disk: the PMM dev image is several GB, the PSMDB node image ~1.6 GB. Both are pulled or
built on first use.

```bash
./om doctor      # check prerequisites at any time
```

---

## 3. Clone and initialise

```bash
git clone <this-repo> openmanager
cd openmanager
git submodule update --init
```

Both submodules point at the forks that carry the integration work, pinned to specific
commits on their `psmdb-openmanager` branches:

```
pmm  → git@github.com:plebioda/pmm.git   @ psmdb-openmanager
SEP  → git@github.com:plebioda/SEP.git   @ psmdb-openmanager
```

They check out **detached** at the pinned commit, which is what you want for a
reproducible setup. Check the branch out explicitly only if you intend to commit inside
one:

```bash
(cd pmm && git checkout psmdb-openmanager)
(cd SEP && git checkout psmdb-openmanager)
```

To move the workspace onto newer submodule commits, pull inside the submodule and commit
the new pointer here:

```bash
(cd SEP && git pull)
git add SEP && git commit -m "Bump SEP"
```

---

## 4. First-time setup

**Order matters.** SEP's migrations run against PostgreSQL *inside the PMM container*, so
PMM has to be configured and running before `./om setup` gets to them. Doing it in the
wrong order fails at `make migrate` with a connection error, and `./om setup` aborts
before it writes `pmm/.env`.

### 4.1 `pmm/.env`

`pmm/.env` is gitignored, so a fresh clone has none. Start from the dev example — the
release `.env.example` would give you a stock server with no toolchain inside, and the
mounted working tree would not be buildable:

```bash
cp pmm/.env.dev.example pmm/.env
```

Then set these. The first three are in the example with the wrong defaults; the last
two are **not in the example at all** and have to be added:

```ini
PMM_PORT_HTTPS=8443             # SEP pins PMM.ENDPOINT to https://127.0.0.1:8443
PMM_ENABLE_NOMAD=1              # PMM's own flag for the embedded task executor SEP
                                # dispatches to — keep the spelling, it is PMM's
PMM_PUBLIC_ADDRESS=pmm-server   # the executor advertises this; must resolve from every
                                # client container, so the hostname — not "localhost"

# Expose the embedded PostgreSQL to attached Docker subnets and provision a
# non-superuser `sep` role owning a `sep` database. Consumed by the container's
# entrypoint, not by pmm-managed. Pick any password; SEP/.env must match it.
PMM_ENABLE_SEP=1
PMM_SEP_POSTGRES_PASSWORD=<pick a password>
```

`./om setup` will force `PMM_PORT_HTTPS=8443` for you if you forget, but not the rest.

### 4.2 Start PMM

```bash
./om start pmm
```

First start pulls several GB. When it is up, PMM is at **https://localhost:8443** with
**admin / admin**.

### 4.3 A PMM service account token

PMM 3 has no "API keys" page. In PMM, go to *Administration → Users and access → Service
accounts*, create one with the **Admin** role, and add a token. You need it twice — it
backs both SEP's Grafana auth provider and `PMMSyncer`.

### 4.4 `SEP/.env`

Also gitignored. Create it with the database password from §4.1 and the token from §4.3:

```ini
# PMM's embedded PostgreSQL. Host/port/name/user are already in settings.yaml's
# development block; only the password comes from here.
SEP__DATABASE__PASSWORD=<same as PMM_SEP_POSTGRES_PASSWORD>
INVENTORY__DATABASE__PASSWORD=<same>
TASKS__DATABASE__PASSWORD=<same>
CELERY__BEAT_DBURI=postgresql://sep:<same>@127.0.0.1:5432/sep

# Grafana service account token — backs the auth provider and PMMSyncer alike.
AUTH__PROVIDER__GRAFANA__SERVICE_ACCOUNT_TOKEN=<glsa_...>
PMM__API_KEY=<glsa_...>
```

Grafana is the single active auth provider here: `settings.yaml` nulls the others out, and
setting their `AUTH__PROVIDER__*` env vars would resurrect the entries it dropped. `./om
setup` only creates `SEP/.env` when it is absent, and leaves an existing file untouched.

### 4.5 `./om setup`

```bash
./om setup
```

Idempotent and safe to re-run. In order:

1. **`./om doctor`** — reports missing prerequisites, then continues with what it can.
2. **SEP venv** — `make -C SEP venv`.
3. **`SEP/.env`** — created empty only if absent, so you can fill in §4.4 yourself.
4. **Migrations** — `make -C SEP migrate`. Three Alembic tracks (`sep`, `inventory`,
   `tasks`) run in one pass; on this branch they share the one `sep` PostgreSQL database
   and coexist through distinct version tables.
5. **Celery beat schedule tables** — a known blocker on the SQLite path: Alembic does not
   create them, but SEP's startup writes into them, so a fresh checkout crashes with
   `no such table: main.celery_intervalschedule`. Setup starts the app once with Celery to
   let the beat scheduler create them. On the PostgreSQL path this step is skipped and the
   tables are created on the first real backend start instead (`./om` runs Celery by
   default).
6. **SEP frontend deps** — `pnpm install` in `SEP/frontend`; skipped with a warning if
   Node/pnpm are not ready. Only `sep-frontend` is blocked by that.
7. **`pmm/.env`** — created from `.env.dev.example` if absent, and `PMM_PORT_HTTPS` forced
   to 8443.

---

## 5. Start the stack

```bash
./om start          # = pmm + sep-backend + sep-frontend
```

| Component | What starts | Where |
| --- | --- | --- |
| `pmm` | the PMM devcontainer, via `make -C pmm env-up` | https://localhost:8443 — **admin / admin** |
| `sep-backend` | uvicorn with reload, **plus** the Celery worker and beat | http://localhost:8000 |
| `sep-frontend` | Vite — SEP's own standalone UI | http://localhost:5174 |

Normally you use SEP through PMM: **https://localhost:8443/pmm-ui/sep/atw** ("Collect
Diagnostic Data") and **/pmm-ui/sep/mysql-backups**. You are already logged in — the PMM
session is the identity. Apps that have not been ported into PMM are still reachable only
on :5174.

Name components to start a subset: `./om start pmm`, `./om start sep`, and so on.

```bash
./om status         # what is up, on which ports, and whether PMM is serving your UI
./om urls           # every URI each component serves — Grafana, vmui, Swagger
./om logs sep-backend -f
./om stop           # or ./om restart
```

Note that `./om start pmm` runs the **image's** Go binaries; it deploys your working
tree's UI automatically but not your backend changes. See §8.

---

## 6. Start PSMDB clusters

The clusters in [`psmdb/`](psmdb/) join the Docker network PMM's compose stack creates
(`pmm_default`), so **PMM must be running first**. Each node is a single container running
`mongod`/`mongos` + `pbm-agent` + `pmm-agent` — and pmm-agent >= 3.2.0 carries an executor
client, so every database node is automatically a SEP execution host. No separate executor
and no certificate handling.

```bash
./om start pmm                      # first, always
./om start replicaset-cluster       # a 3-member replica set
```

| Component name | Shape | Containers |
| --- | --- | --- |
| `standalone` | no replication | 1 |
| `replicaset-single` | 1-member replica set (has an oplog, so PBM works) | 1 |
| `replicaset-cluster` | 3 data-bearing members | 3 |
| `sharded-cluster` | 2 mongos, 3 config, 2 shards of svr0/svr1/arb0 | 11 |

`clusters` (or `psmdb`) starts all four at once. On first use `./om` builds the node image
and generates `psmdb/secrets/keyfile`; it then waits for every node to finish bootstrap
and register with PMM, rather than just reporting "started".

```bash
./om status                          # per-topology container counts
./om logs replicaset-cluster -f
./om inventory                       # PMM's nodes/services/agents joined into one JSON doc
./om stop replicaset-cluster         # containers down, data volumes kept
cd psmdb && docker compose --profile replicaset-cluster down -v   # wipe data too
```

**Nothing is published to the host** — deliberately, since PMM already contends for 8443
and 9000. Reach a node with `docker exec`; `/root/.mongodb_uri` inside each container holds
its credentials, and is the same file SEP's `backup_mongo` and `pom_worker` payloads read:

```bash
docker exec -it replicaset-cluster-node00 sh -c 'mongosh "$(cat /root/.mongodb_uri)"'
```

One recurring gotcha: restarting PMM's compose stack destroys and recreates `pmm_default`
with a fresh network id, stranding cluster containers created before the restart
(`network …not found` on start). `./om start <profile>` detects this and recreates the
containers; data volumes are kept.

Full detail — the in-place upgrade loop, bootstrap ordering, and the rough edges — is in
[`psmdb/README.md`](psmdb/README.md).

---

## 7. Use POM

POM (PSMDB OpenManager) is what the rest of this setup exists to feed. It needs PMM up,
SEP up and at least one cluster registered. Nothing here needs compiling — but the page
is part of PMM's UI bundle, so if the sidebar has no SEP apps, run `./om build ui` once
(§10 has the symptom).

`pom_worker` (`SEP/app/sep/apps/pom_worker`) discovers the MongoDB estate from three
sources — SEP's inventory, PMM's VictoriaMetrics, and a probe dispatched to each node —
merges them by declared per-field precedence, and stores one
`environments -> clusters -> services` topology document per run.

```bash
./om start pmm                  # 1. PMM first, always
./om start clusters             # 2. all four topologies (or name one)
./om start sep                  # 3. SEP backend
./om pom sync                   # 4. pull PMM's inventory into SEP
./om pom run                    # 5. run discovery, then show the result
./om pom topology               # 6. the topology document, flattened
```

Step 4 matters and is easy to skip: SEP holds its own copy of PMM's inventory, and a
cluster started after the last sync is invisible to discovery until you refresh it.
Everything in a run would then come back orphaned.

In the browser the same snapshot is at
**https://localhost:8443/pmm-ui/sep/pom** — one table over the whole estate, with
environment and cluster as the leading columns.

Two conventions in the output are worth knowing before you read it as a fault:

- **`cpu_usage_percent` and `connections_free_percent` are `-1` when not measured**, never
  null and never `0` — zero CPU is a real reading, so the sentinel keeps "idle" and
  "unknown" apart.
- **`state`, `replication_lag_seconds` and `oplog_window_seconds` are null when they do
  not apply.** A router and a standalone have no replica set and no oplog at all, which is
  a different statement from "we could not measure it".

The rest of the inspector, every subcommand defaulting to the most recent run:

```bash
./om pom                # overview: status, counts, resolved services
./om pom topology-raw   # the document as stored JSON — pipe it to jq
./om pom nodes          # the service -> executor mapping, orphans included
./om pom probe          # per-node probe JSON
./om pom tasks          # dispatched probe task runs and their status
./om pom runs           # run history, newest first
./om pom token          # bearer token for SEP's /api/docs Authorize button, and for curl
```

The API behind all of it is `GET /api/apps/pom_api/topology`, plus
`/discovery/runs` for the history and the trigger.

---

## 8. Building your changes

```bash
./om build pmm      # compile the PMM working tree into the running container (minutes)
./om build ui       # rebuild pmm/ui and deploy it over the image's bundle
```

`build pmm` runs PMM's `run-all` inside the container: it rebuilds `pmm-managed`,
`pmm-agent`, `qan-api2` and `vmproxy` and restarts each under supervisord.

`build ui` is how UI edits reach the browser — this path deploys a static bundle, there is
no Vite in front of it. `./om start pmm` does it automatically **only** when the deployed
bundle carries no SEP routes at all, so after editing `pmm/ui` you need the explicit
command. Recreating the container resets the UI to the image's copy.

SEP needs no build step: the backend reloads and the frontend runs under Vite.

After a rebuild that changes inventory, refresh SEP's copy with `./om pom sync`.

## 9. Ports

```bash
./om ports      # the table below, plus what is actually listening
```

| Port | Owner |
| --- | --- |
| 8000 | SEP backend — bound to `0.0.0.0`, because PMM's nginx reaches it over the host gateway |
| 5174 | SEP frontend (Vite), standalone UI |
| 8443 | PMM HTTPS — the PMM UI and the SEP UI and API proxy all live here |
| 5432 | PMM PostgreSQL — holds the `sep` database |
| 9090 | PMM VictoriaMetrics |
| 9000 / 8123 | PMM ClickHouse TCP / HTTP |
| 5173 / 2345 | PMM Vite HMR / delve |
| — | `psmdb/` clusters and their MinIO — **nothing published**, by design |

---

## 10. Troubleshooting

**`make migrate` fails with a connection error during `./om setup`** — PMM is not running,
or `PMM_ENABLE_SEP` / `PMM_SEP_POSTGRES_PASSWORD` are missing from `pmm/.env`, or the
password in `SEP/.env` does not match. See §4 — the ordering is the usual cause.

**`no such table: main.celery_intervalschedule`** — the beat schedule tables were never
created. Re-run `./om setup`, or start the backend once with Celery
(`make -C SEP dev-backend START_CELERY=1`).

**Login does not use the PMM session** — an `AUTH__PROVIDER__*` variable in `SEP/.env` has
resurrected a provider `settings.yaml` set to `null`. Comment it out so Grafana is the only
active one.

**Vite dies with `ENOSPC` / `Emitted 'error' event on FSWatcher`** — this is the per-user
inotify *instance* limit, not a full disk. `./om start sep-frontend` detects it and falls
back to a polling watcher automatically. The permanent fix needs root:

```bash
sudo tee /etc/sysctl.d/99-inotify.conf <<'EOF'
fs.inotify.max_user_instances = 1024
fs.inotify.max_user_watches = 524288
EOF
sudo sysctl --system
```

**`node v… is too old` after installing Node 22** — a long-lived shell keeps whatever nvm
gave it at startup. `./om` activates a suitable nvm version for its own process; fix it
permanently with `nvm alias default 22`, then re-activate pnpm for that version.

**PMM has no SEP apps in the sidebar** — the container is serving the image's prebuilt
bundle; `./om status` says which. Run `./om build ui`. If the build succeeds but the
routes are still absent, the checked-out PMM branch does not carry them.

**`network pmm_default missing`** when starting a cluster — run `./om start pmm` first.

**`port 8000 is already in use by something om did not start`** — a previous backend
survived. `./om` tracks PIDs in `.om/pids/`; if that is stale, find and kill it yourself.

**A task sits at "running" with no output** — the executor's client GC destroyed the
allocation because the disk crossed its 80% threshold, taking the logs with it.
`PMM_NOMAD_GC_DISK_USAGE_THRESHOLD` in `pmm/.env` (PMM's own spelling) raises it.

Logs for every native component live in `.om/logs/`; `./om logs <comp> [-f]` is the
shortcut.

---

## 11. Editor setup

Open [`openmanager.code-workspace`](openmanager.code-workspace) in VS Code or Cursor — it
configures the Go, Python and TypeScript language servers, formatters and linters for both
repositories. Recommended extensions and the format-on-save rules are in
[`CLAUDE.md`](CLAUDE.md) §2.

---

## 12. Where to read more

| Doc | What it covers |
| --- | --- |
| [`docs/topology.md`](docs/topology.md) | **Start here.** The whole system: both products, all local stacks, data flows, diagrams — and Part 10's container-level reference |
| [`docs/glossary.md`](docs/glossary.md) | VictoriaMetrics, `raw_exec`, syncers, and the rest |
| [`psmdb/README.md`](psmdb/README.md) | The database nodes, the upgrade loop, bootstrap ordering |
| [`CLAUDE.md`](CLAUDE.md) | Conventions and command reference for AI agents in this workspace |
| `pmm/AGENTS.md`, `SEP/AGENTS.md` | Per-repo guides, maintained upstream |

`notes/` and `todo/` are personal working state and are deliberately untracked — they are
absent on a fresh clone, so the two links to `notes/` above will dangle there. `docs/` is
the committed documentation.
