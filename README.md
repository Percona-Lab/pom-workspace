# OpenManager

A cross-repository workspace for developing **PMM** and **SEP** together, against real
MongoDB clusters running locally.

Three git submodules, one orchestrator:

| Directory | What it is | How it runs locally |
| --- | --- | --- |
| [`pmm/`](pmm/) | Percona Monitoring and Management — Go backend, React UI | in PMM's own **devcontainer**, with the working tree mounted so you can compile into it |
| [`SEP/`](SEP/) | Services Enablement Platform — FastAPI backend, React frontend | **natively** (venv + pnpm), so edits are live |
| [`psmdb/`](psmdb/) | Four MongoDB topologies as Compose profiles, one container per node | `docker compose`, joined to PMM's network |
| [`mongo_terraform_ansible/`](mongo_terraform_ansible/) | The older Terraform-driven PSMDB sandbox + its Go web UI | optional, `go run` on :5001 |

Everything is driven from the repo root by [`./om`](om). Run `./om` with no arguments for
its full help.

> **New to this system?** Read [`docs/topology.md`](docs/topology.md) first — what the two
> products are, what runs on your machine, and what talks to what.
> [`docs/containers.md`](docs/containers.md) is the same picture at container level, and
> [`docs/glossary.md`](docs/glossary.md) defines every proper noun used below.

---

## 1. Which configuration you are setting up

There are **two** ways to run SEP locally, and they need different setup. `settings.yaml`'s
`development` block on the current SEP branch selects the first one.

| | **A — SEP inside PMM** (the local default) | **B — Standalone SEP** |
| --- | --- | --- |
| SEP UI | native PMM routes at `https://localhost:8443/pmm-ui/sep/...` | its own Vite dev server on `http://localhost:5174` |
| Auth | the ambient PMM/Grafana session (`pmm_session` cookie exchanged for a SEP bearer) | Casdoor password grant |
| Databases | **PMM's embedded PostgreSQL** — one `sep` database for all three services and Celery beat | four SQLite files |
| Executor | PMM's **embedded Nomad**, proxied at `/nomad` | standalone `om-nomad` on :4646 |
| Extra setup | `pmm/.env` and `SEP/.env` wiring, §4 | Casdoor seed data, which `./om setup` generates |

Path A is what this workspace targets, and it is what §3–§4 below describe. Path B still
works — `./om start sep-frontend` starts it, and everything not yet ported into PMM is
only reachable there. See [`notes/sep-dev-quickstart.md`](notes/sep-dev-quickstart.md) if
you want Path B on its own, and [`docs/topology.md`](docs/topology.md) Part 8 for how the
two auth flows differ.

---

## 2. Prerequisites

| Tool | Version | Needed for |
| --- | --- | --- |
| Docker + `docker compose` **v2** plugin | any recent | everything (`docker-compose` v1 is not supported) |
| `make` | any | both repos' build targets |
| `python3` | 3.11.9+, `<3.14` (3.12 works) | SEP backend |
| Node | **>= 22.22.0** | SEP frontend only |
| `pnpm` | 11.1.3, via corepack | SEP frontend only |
| `go`, `terraform` | 1.22+ / any | the Terraform sandbox only (§8) |

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

The submodules are pinned to specific commits and check out **detached**. `pmm/` and
`SEP/` track the unmerged integration work (`psmdb-openmanager` on both), so check the
branch out explicitly if you intend to commit inside one:

```bash
(cd pmm && git checkout psmdb-openmanager)
(cd SEP && git checkout psmdb-openmanager)
```

`mongo_terraform_ansible` pins `feature/local-deploy-fixes` in `.gitmodules`, so
`git submodule update --init --remote` follows it.

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

Then change these (the example's defaults are wrong for this workspace):

```ini
PMM_PORT_HTTPS=8443             # SEP pins PMM.ENDPOINT to https://127.0.0.1:8443
PMM_ENABLE_NOMAD=1              # the embedded Nomad server SEP dispatches to
PMM_PUBLIC_ADDRESS=pmm-server   # Nomad advertises this; must resolve from every client
                                # container, so the hostname — not "localhost"

# Expose the embedded PostgreSQL to attached Docker subnets and provision a
# non-superuser `sep` role owning a `sep` database. Consumed by the container's
# entrypoint, not by pmm-managed. Pick any password; SEP/.env must match it.
PMM_ENABLE_SEP=1
PMM_SEP_POSTGRES_PASSWORD=<pick a password>

# Only if you also use the Terraform sandbox: its MinIO wants 9000/8123.
PMM_PORT_CH_TCP=9900
PMM_PORT_CH_HTTP=8923
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

**Do not set the Casdoor variables** on this path. `settings.yaml` sets the `casdoor`
provider to `null` so Grafana is the single active provider, and any
`AUTH__PROVIDER__CASDOOR__*` env var resurrects the entry it dropped. `./om setup` writes
those two lines when it creates `.env` from scratch — comment them out afterwards, or
create `SEP/.env` yourself first (setup leaves an existing file untouched).

### 4.5 `./om setup`

```bash
./om setup
```

Idempotent and safe to re-run. In order:

1. **`./om doctor`** — reports missing prerequisites, then continues with what it can.
2. **SEP venv** — `make -C SEP venv`.
3. **Casdoor seed data** — runs `SEP/generate_casdoor_init_data.sh -p devpassword` if
   `SEP/data/casdoor_init_data.json` is absent. It **prints the `admin` and `sep`
   passwords, stored nowhere else — write them down.** Existing seed data is left alone,
   because re-running rotates the client secret. Only Path B uses this, but `./om start
   deps` refuses to start without the file.
4. **`SEP/.env`** — created from the generated `.env.docker` only if absent (see §4.4).
5. **Migrations** — `make -C SEP migrate`. Three Alembic tracks (`sep`, `inventory`,
   `tasks`) run in one pass; on this branch they share the one `sep` PostgreSQL database
   and coexist through distinct version tables.
6. **Celery beat schedule tables** — a known blocker on the SQLite path: Alembic does not
   create them, but SEP's startup writes into them, so a fresh checkout crashes with
   `no such table: main.celery_intervalschedule`. Setup starts the app once with Celery to
   let the beat scheduler create them. On the PostgreSQL path this step is skipped and the
   tables are created on the first real backend start instead (`./om` runs Celery by
   default).
7. **SEP frontend deps** — `pnpm install` in `SEP/frontend`; skipped with a warning if
   Node/pnpm are not ready. Only `sep-frontend` is blocked by that.
8. **`pmm/.env`** — created from `.env.dev.example` if absent, and `PMM_PORT_HTTPS` forced
   to 8443.

---

## 5. Start the stack

```bash
./om start          # = deps + pmm + sep-backend + sep-frontend
```

| Component | What starts | Where |
| --- | --- | --- |
| `deps` | Casdoor (root [`docker-compose.yml`](docker-compose.yml)) | http://localhost:9999 — Path B only |
| `pmm` | the PMM devcontainer, via `make -C pmm env-up` | https://localhost:8443 — **admin / admin** |
| `sep-backend` | uvicorn with reload, **plus** the Celery worker and beat | http://localhost:8000 |
| `sep-frontend` | Vite — the standalone SEP UI (Path B) | http://localhost:5174 |

On Path A you use SEP through PMM: **https://localhost:8443/pmm-ui/sep/atw** ("Collect
Diagnostic Data") and **/pmm-ui/sep/mysql-backups**. You are already logged in — the PMM
session is the identity. Apps that have not been ported into PMM are still reachable only
on :5174.

Name components to start a subset: `./om start pmm`, `./om start sep`, and so on.

```bash
./om status         # what is up, on which ports, and whether PMM is serving your UI
./om urls           # every URI each component serves — Grafana, vmui, Swagger, Nomad UI
./om logs sep-backend -f
./om stop           # or ./om restart
```

Note that `./om start pmm` runs the **image's** Go binaries; it deploys your working
tree's UI automatically but not your backend changes. See §7.

---

## 6. Start PSMDB clusters

The clusters in [`psmdb/`](psmdb/) join the Docker network PMM's compose stack creates
(`pmm_default`), so **PMM must be running first**. Each node is a single container running
`mongod`/`mongos` + `pbm-agent` + `pmm-agent` — and pmm-agent >= 3.2.0 carries a Nomad
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

## 7. Building your changes

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

### Inspecting the POM app

`pom_worker` (`SEP/app/sep/apps/pom_worker`) discovers the MongoDB estate from three
sources — SEP's inventory, VictoriaMetrics and a Nomad probe — and stores one
`environments -> clusters -> services` topology document per run. It has a dedicated
inspector that joins PostgreSQL, VictoriaMetrics and the tasks API. Every subcommand
defaults to the most recent run:

```bash
./om pom                # overview: status, counts, resolved services
./om pom run            # trigger a run, then show it
./om pom topology       # the run's topology document, flattened into a table
./om pom topology-raw   # the same document as stored JSON — pipe it to jq
./om pom nodes          # the service -> executor mapping, orphans included
./om pom probe          # per-node probe JSON
./om pom tasks          # dispatched Nomad runs and their status
./om pom token          # bearer token for SEP's /api/docs Authorize button, and for curl
```

---

## 8. The Terraform sandbox (optional, older path)

`mongo_terraform_ansible/ui-go` is a Go web UI that drives Terraform to deploy PSMDB
clusters. It predates `psmdb/` and deploys pmm-client as a **sidecar** container next to
each mongod — fine for monitoring, but a sidecar Nomad client can never restart or upgrade
the mongod, which is why `psmdb/` exists. Use it when you need what it deploys
specifically; otherwise prefer §6.

```bash
./om start sandbox            # UI on http://127.0.0.1:5001 (needs go + terraform)
./om start nomad              # the standalone om-nomad executor, on :4646
```

Deploy an environment in the UI with **zero PMM servers**, then point its agents at the
repo PMM:

```bash
./om psmdb-link <env-prefix>       # e.g. ./om psmdb-link test1
```

That attaches the repo `pmm-server` container to the environment's network under the alias
its agents already look for (`<prefix>-pmm-server`), attaches `om-nomad` to the same
network so it can resolve the cluster's container hostnames, lifts the PBM and MinIO
credentials into `nomad/secrets/`, and restarts the pmm-client containers so registration
re-runs. It refuses if the sandbox deployed its own PMM under that name rather than
creating a duplicate DNS alias.

---

## 9. Ports

```bash
./om ports      # the table below, plus what is actually listening
```

| Port | Owner |
| --- | --- |
| 8000 | SEP backend — bound to `0.0.0.0`, because PMM's nginx reaches it over the host gateway |
| 5174 | SEP frontend (Vite), standalone UI |
| 8443 | PMM HTTPS — the PMM UI, the SEP UI and API proxy, and `/nomad` all live here |
| 5432 | PMM PostgreSQL — holds the `sep` database |
| 9090 | PMM VictoriaMetrics |
| 9900 / 8923 | PMM ClickHouse TCP / HTTP, moved off 9000 / 8123 |
| 5173 / 2345 | PMM Vite HMR / delve |
| 9999 | Casdoor (opt-in) |
| 4646 | `om-nomad` (opt-in, Terraform sandbox only) |
| 5001 | PSMDB Sandbox UI (opt-in) |
| — | `psmdb/` clusters and their MinIO — **nothing published**, by design |

`./om ports` still lists ClickHouse at the 9000/8123 defaults and names the collision with
the sandbox's MinIO as something to fix; §4.1 has already fixed it.

---

## 10. Troubleshooting

**`make migrate` fails with a connection error during `./om setup`** — PMM is not running,
or `PMM_ENABLE_SEP` / `PMM_SEP_POSTGRES_PASSWORD` are missing from `pmm/.env`, or the
password in `SEP/.env` does not match. See §4 — the ordering is the usual cause.

**`no such table: main.celery_intervalschedule`** — the beat schedule tables were never
created. Re-run `./om setup`, or start the backend once with Celery
(`make -C SEP dev-backend START_CELERY=1`).

**Login redirects to Casdoor when you expected the PMM session** — an
`AUTH__PROVIDER__CASDOOR__*` variable in `SEP/.env` has resurrected the provider
`settings.yaml` set to `null`. Comment it out.

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

**A task sits at "running" with no output** — Nomad's client GC destroyed the allocation
because the disk crossed its 80% threshold, taking the logs with it. `PMM_NOMAD_GC_DISK_USAGE_THRESHOLD`
in `pmm/.env` raises it.

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
| [`docs/topology.md`](docs/topology.md) | **Start here.** The whole system: both products, all local stacks, data flows, diagrams |
| [`docs/containers.md`](docs/containers.md) | The same at container level — real names, networks, subnets, every connection |
| [`docs/nomad-in-pmm.md`](docs/nomad-in-pmm.md) | Dispatching to PMM's built-in Nomad instead of a standalone executor |
| [`docs/glossary.md`](docs/glossary.md) | VictoriaMetrics, Nomad, Casdoor, `raw_exec`, syncers, and the rest |
| [`psmdb/README.md`](psmdb/README.md) | The database nodes, the upgrade loop, bootstrap ordering |
| [`CLAUDE.md`](CLAUDE.md) | Conventions and command reference for AI agents in this workspace |
| `pmm/AGENTS.md`, `SEP/AGENTS.md` | Per-repo guides, maintained upstream |

`notes/` and `todo/` are personal working state and are deliberately untracked — they are
absent on a fresh clone, so the two links to `notes/` above will dangle there. `docs/` is
the committed documentation.
