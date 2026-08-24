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

---

## Quick start

From a fresh clone to PMM, SEP and four MongoDB topologies running against each other:

```bash
git clone <this-repo> openmanager && cd openmanager
./om doctor                  # check prerequisites first - see §2 if it complains
./om bootstrap               # submodules, both .env files, PMM, SEP's venv and
                             # migrations, then everything else. Idempotent.
./om start clusters          # the four PSMDB topologies
./om status                  # what came up, and on which ports
```

PMM is then at **<https://localhost:8443>** (`admin` / `admin`), with the SEP pages under
`/pmm-ui/sep/`. `./om urls` lists every address, including for components that are stopped.

`./om bootstrap` is also the way back when a workspace has drifted: it is safe to re-run,
and each step leaves existing state alone. Full detail in §3-§6.

Then, day to day:

| | |
| --- | --- |
| `./om status` | what is up, and on which ports |
| `./om urls [comp...]` | every address a component serves, running or not |
| `./om start <comp>` / `./om stop <comp>` | `pmm`, `sep-backend`, `sep-frontend`; groups `sep`, `clusters`, `all` |
| `./om build pmm` / `./om build ui` | compile your Go or UI changes into the running server |
| `./om logs <comp> [-f]` | logs |
| `./om inventory` | what OM has discovered about the estate (§7) |
| `./om doctor` | prerequisites and common misconfigurations |

Start only the topology the work needs - a sharded cluster costs real memory, and four of
them cost four times as much:

```bash
./om start standalone          # one mongod
./om start replicaset-single   # a single-node replica set
./om start replicaset-cluster  # three-node replica set
./om start sharded-cluster     # mongos + config servers + shards + arbiters
./om start pmm-client-node00   # a host with a PMM client and no database
```

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
./om bootstrap
```

`./om bootstrap` initialises the submodules itself, so `git submodule update --init` is
only needed if you want them checked out before reading anything else. Section 4 is what
bootstrap does.

Both submodules are pinned to specific commits on their integration branches:

```
pmm  → git@github.com:percona/pmm.git   @ PMM-15326-pom-inventory
SEP  → git@github.com:percona/SEP.git   @ PMM-15326-pom-inventory
```

They check out **detached** at the pinned commit, which is what you want for a
reproducible setup. Check the branch out explicitly only if you intend to commit inside
one:

```bash
(cd pmm && git checkout PMM-15326-pom-inventory)
(cd SEP && git checkout PMM-15326-pom-inventory)
```

> **Already had a clone before 2026-08-19?** The URLs above used to name personal forks,
> and git does not re-read `.gitmodules` on its own - an existing checkout keeps fetching
> from wherever it was first initialised and will not find the current commits. Run
> `git submodule sync --recursive && git submodule update --init` once.

To move the workspace onto newer submodule commits, pull inside the submodule and commit
the new pointer here:

```bash
(cd SEP && git pull)
git add SEP && git commit -m "Bump SEP"
```

---

## 4. First-time setup

```bash
./om bootstrap
```

That is all of it: submodules, both `.env` files, PMM, SEP's venv and migrations, then
the rest of the stack. First run pulls several GB. It is idempotent, so it is equally
the command for putting a drifted workspace back rather than only for a fresh clone.

When it finishes, PMM is at **https://localhost:8443** with **admin / admin**.

Everything below is what it does and why the order is what it is. You need it if a step
fails, or if you would rather drive the steps yourself:

```bash
./om env          # write pmm/.env and SEP/.env
./om start pmm    # first start pulls several GB
./om env          # again: mints the Grafana token, which needs PMM running
./om setup        # venv, migrations, frontend deps
./om start        # sep-backend, sep-frontend, and any remembered clusters
```

**The order is not a preference**, and neither half of it is guessable from the command
names.

`pmm/.env` has to be right before PMM is **created**, not merely before it is restarted:
compose interpolates the published port at create time, so a container made against a
wrong file stays wrong through every restart and only a recreate fixes it.

PMM has to be running before `./om setup`, because SEP's migrations run against the
PostgreSQL *inside the PMM container*. In the other order they fail with a connection
error that reads as a SEP problem.

`./om env` appears twice and is not redundant: the first run cannot mint a Grafana
service account token because Grafana does not exist yet, and `./om setup` re-runs
`./om env --create` as its second step to finish that one outstanding job. No ordering
avoids the two passes, since the token depends on the thing the token configures.

### 4.1 `./om env`

Both `.env` files are gitignored, so a fresh clone has neither. `./om env` writes them:

- **`pmm/.env`** is rendered as upstream's `pmm/.env.dev.example` with
  [`harness/pmm-env.example`](harness/pmm-env.example) overlaid. Only the keys this
  workspace needs differently are overridden, so an upstream change to any other key is
  picked up instead of being frozen at whatever it said the day someone copied the file.
- **`SEP/.env`** is rendered from [`harness/sep-env.example`](harness/sep-env.example).
  SEP ships no example upstream, so that template is the whole file.

If a file already exists you are asked before it is overwritten (`-y` skips the prompt,
`--create` skips existing files entirely). Both templates are readable and commented -
read them if you want to know what you are getting.

**Secrets are generated, not invented by you.** Between the two files there is one
database password, one bearer token and one Grafana token, and the password has to be
byte-identical in five places across both files. That is the single most reliable thing
to get wrong by hand, and the failure surfaces far from the cause: a mismatched
`CELERY__BEAT_DBURI` reads as a Celery-beat problem rather than a password one.

Re-running is safe. `PMM_SEP_POSTGRES_PASSWORD` is **reused, never regenerated**, because
it is baked into the `sep` role on the `/srv` volume at first start; a new one would leave
SEP presenting a password PostgreSQL no longer has.

> **The dev image is pinned by digest**, not by the `3-dev-container` tag. That tag is a
> moving bookmark Percona's CI repoints at a build of `main`, and PMM's ClickHouse
> configuration is split across the boundary - `users.xml` ships in the image,
> `dev/clickhouse-config.xml` is bind-mounted from the checkout. A tag that outruns the
> branch breaks the pair and ClickHouse refuses to start. The pin and the removal
> condition are documented in `harness/pmm-env.example`.

### 4.2 Start PMM

```bash
./om start pmm
```

First start pulls several GB. When it is up, PMM is at **https://localhost:8443** with
**admin / admin**.

The port matters: SEP pins `PMM.ENDPOINT` to `https://127.0.0.1:8443`, and compose
interpolates the published port when the container is **created**, not when it is
started. So a `pmm/.env` edited after the fact needs `./om stop pmm && ./om start pmm`,
not a restart.

### 4.3 `./om env`, again

```bash
./om env
```

The second run mints a Grafana service account token (name `sep-local`, role **Admin**)
and writes it into `SEP/.env`. It needs PMM running, which is why the first run skipped
it with a warning.

The Admin role is not overreach: the token does two jobs, backing SEP's Grafana auth
provider, which reads users, and authenticating `PMMSyncer` when it asks PMM to run
management tasks. It is one token in two keys on purpose - two would be two things to
rotate for no benefit.

If you would rather do it by hand, PMM 3 has no "API keys" page: go to *Administration →
Users and access → Service accounts*, create one with the Admin role, add a token, and
put the same `glsa_…` value in both `AUTH__PROVIDER__GRAFANA__SERVICE_ACCOUNT_TOKEN` and
`PMM__API_KEY`.

Grafana is the single active auth provider here: `settings.yaml` nulls the others out, and
setting their `AUTH__PROVIDER__*` env vars would resurrect the entries it dropped.

One trap survives hand-editing: **write each key once.** python-dotenv takes the **last**
occurrence, so a second `PMM__API_KEY` further down silently wins, and every PMM request
then comes back empty or unauthorized with nothing else looking wrong. `./om` reads it
with `tail -1` for exactly this reason.

### 4.4 `./om setup`

```bash
./om setup
```

Idempotent and safe to re-run. In order:

1. **`./om doctor`** — reports missing prerequisites, then continues with what it can.
2. **`./om env --create`** - writes either `.env` if it is missing, and completes a
   `SEP/.env` still waiting on its Grafana token. Existing, complete files are untouched.
3. **SEP venv** — `make -C SEP venv`.
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
7. **`pmm/.env` check** - warns if `PMM_PORT_HTTPS` is not 8443 rather than silently
   rewriting it, since by this point the container has already been created with whatever
   it said.

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
./om pmm-inventory                       # PMM's nodes/services/agents joined into one JSON doc
./om stop replicaset-cluster         # containers down, data volumes kept
cd psmdb && docker compose --profile replicaset-cluster down -v   # wipe data too
```

**Nothing is published to the host** — deliberately, since PMM already contends for 8443
and 9000. Reach a node with `docker exec`; `/root/.mongodb_uri` inside each container holds
its credentials, and is the same file SEP's `backup_mongo` and `om_inventory` payloads read:

```bash
docker exec -it replicaset-cluster-node00 sh -c 'mongosh "$(cat /root/.mongodb_uri)"'
```

One recurring gotcha: a PMM compose stack that is torn down destroys and recreates
`pmm_default` with a fresh network id, stranding cluster containers created before that
(`network …not found` on start). `./om stop pmm` stops the container instead of removing
it, so the ordinary cycle strands nothing; a stack that really is recreated (a reset, an
image bump) still does, and `./om start <profile>` detects it and recreates the
containers. Data volumes and PMM identity are kept either way - see below.

### A node keeps the identity it has

A node registers with PMM once, the first time it has none, and keeps it through every
`./om stop`/`./om start` and every container recreate: its agent id and service token live
on the `agent-state` volume, and [`psmdb/scripts/run-pmm-agent.sh`](psmdb/scripts/run-pmm-agent.sh)
registers only when there is nothing usable there.

That matters because `pmm-agent setup --force` does not refresh a registration, it
*replaces* it: pmm-managed removes the node it holds under that name - with its services,
its nomad-agent and its metrics history - and creates a new one with new ids. Everything
keyed on the old ids is then stale, and nothing prunes it: OM's estate holds hosts under
PMM's node id and only forgets one when told to. Every stop/start cycle used to do exactly
that, quietly, to the whole estate.

So a new identity is a command of its own:

```bash
./om reregister sharded-cluster      # every node of one topology
./om reregister pmm-client-node01    # one host
./om reregister                      # every running sandbox node
./om inventory sync                  # afterwards, or every service maps as orphaned
```

A node that has lost its identity while PMM still holds its name refuses to start rather
than taking the name over on its own. `docker logs <node>` says so, and names the command.

### Hosts with a PMM client and no database

`pmm-client` is a pool of three hosts built from the same Dockerfile with
`WITH_PSMDB=0`: `pmm-agent` and the executor client it carries, and no `mongod`,
no `pbm-agent`, none of the PSMDB packages. PMM lists them as nodes and SEP will
dispatch to them, so they are where a payload with no database to talk to gets
developed - and, since the Percona apt repos are still enabled on them, the
starting point for a payload that *installs* a database on a bare machine.

```bash
./om start pmm-client               # all three
./om start pmm-client-node01        # just that one
./om logs pmm-client-node01 -f
```

They export no service to PMM's inventory, so they carry no cluster string and no
credentials file, and nothing about them appears in `./om status` beyond which of
them are up.

Full detail — the in-place upgrade loop, bootstrap ordering, and the rough edges — is in
[`psmdb/README.md`](psmdb/README.md).

---

## 7. Use OM

OM (OpenManager) is what the rest of this setup exists to feed. It needs PMM up, SEP up
and at least one cluster registered. Nothing here needs compiling - but the pages are part
of PMM's UI bundle, so if the sidebar has no SEP apps, run `./om build ui` once (§10 has
the symptom).

OM is split across both products, and the split is worth holding in your head before you
read any of its output:

- **pmm-managed** derives the topology document - `environments -> clusters -> services` -
  from PMM's own inventory and VictoriaMetrics, in about a tenth of a second. It never
  touches a database host.
- **SEP's `om_inventory` app** (`SEP/app/sep/apps/om_inventory`) does the half that needs
  a process *on* a host: every 10 minutes it dispatches a Nomad job per host and upserts
  what it finds into an estate of `om.host` and `om.service` rows. That takes tens of
  seconds.
- **pmm-managed proxies that estate** at `/v1/om/inventory/*`, so every OM page in the
  browser reads PMM's own origin and none of them talks to SEP directly.

```bash
./om start pmm                  # 1. PMM first, always
./om start clusters             # 2. all four topologies (or name one)
./om start sep                  # 3. SEP backend
./om inventory sync             # 4. pull PMM's inventory into SEP
./om inventory run              # 5. sweep the hosts
./om inventory estate           # 6. what the sweep found
```

Step 4 matters and is easy to skip: SEP holds its own copy of PMM's inventory, and a
cluster started after the last sync is invisible to the sweep until you refresh it. Every
service comes back orphaned - mapped to no executor host - and on the Services page the
probe columns read "not in the inventory yet".

Step 5 is the only slow one. Step 6 never waits for it: the estate is upserted, so a row
answers with what it last reported and how old that is, even if the newest sweep never
reached it.

### The pages

In the browser at **https://localhost:8443/pmm-ui/om**, four entries under *OpenManager*:

| Page | Shows |
| --- | --- |
| **Overview** | a table per environment, a row per cluster; unfold one for its services |
| **Services** | one row per service - PMM's view over the wire **joined to** what the probe found on the host |
| **Hosts** | one row per host, **including hosts with no database on them** |
| **Inventory** | two tabs: *Runs* (refresh history, and a button) and *Settings* (the app's configuration) |

Four conventions in that output are worth knowing before you read any of it as a fault:

- **`version` and `installed_version` are deliberately two columns.** The first is what the
  running mongod reports over the wire; the second is what the package database on the host
  says. They disagree exactly when a package has been upgraded and the process not
  restarted - which is a state OM exists to find.
- **"Is there a database here" has three answers, not two.** PMM cannot tell a bare
  pmm-client host from an arbiter - same node type, same agents, no services - so the Hosts
  page reports *Monitored*, *Unregistered mongod*, or *No database*. The middle one is a
  host running a mongod that PMM has no service for, and calling it empty would invite an
  install over a port already in use.
- **"Nothing can run here" also has three answers**: *Not onboarded*, *Agent down*, and
  *Driver unhealthy*. They need three different people to fix them.
- **`cpu_usage_percent` and `connections_free_percent` are `-1` when not measured**, never
  null and never `0` — zero CPU is a real reading, so the sentinel keeps "idle" and
  "unknown" apart. `state`, `replication_lag_seconds` and `oplog_window_seconds` are null
  when they do not *apply*: a router and a standalone have no replica set and no oplog at
  all, which is a different statement from "we could not measure it".

### The inspector

One command group per side of the split - `topology` is PMM's document, `inventory` is SEP's
estate:

```bash
./om topology                # overview: the document, plus a row per service
./om topology raw            # the document as stored JSON — pipe it to jq
./om topology runs           # collection history (PMM's own, ~130 ms each)
./om topology run            # rebuild the document now - does NOT probe anything
./om topology sql | api      # pmm-managed's tables / any /v1/om path

./om inventory          # how much of the estate is probed, failing, unreachable
./om inventory estate   # hosts and services, straight from the tables
./om inventory facts    # what was observed per service, through SEP's API
./om inventory config   # the app's settings and where each value came from
./om inventory runs     # refresh history, newest first
./om inventory run      # queue a sweep (tens of seconds)
./om inventory sync     # refresh SEP's copy of PMM's inventory
./om inventory sql <q>  # SQL against the om schema: host, service, inventory_run
./om inventory api <p>  # any /api/apps/om_inventory path
./om inventory token    # bearer for SEP's /api/docs Authorize button, and for curl
```

`estate` reads the tables and `facts` reads the API on purpose: they should never
disagree, so a disagreement is a serialisation bug rather than two views of different
things. `./om topology api inventory/hosts` is the third route - the same rows as the UI sees
them, through PMM's proxy.

The full API surface, the `om` schema with its freshness columns, and who calls what are
in [`docs/architecture.md`](docs/architecture.md).

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

After a rebuild that changes inventory, refresh SEP's copy with `./om topology sync`.

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

**`pmm-server` is `unhealthy` and Query Analytics is empty** - ClickHouse is failing to
start while everything else runs, so the container's internal readiness probe never
passes. Confirm with `docker exec pmm-server tail -50 /srv/logs/clickhouse-server.log`.

If it says `Setting changeable_in_readonly for max_execution_time is not allowed`, the
image has outrun the checkout: `users.xml` comes from the image and
`dev/clickhouse-config.xml` from your branch, and the two no longer agree. `./om env`
pins the image by digest for this reason - if you overrode the pin, put it back. OM
itself is unaffected, since it reads PostgreSQL and VictoriaMetrics.

**`container pmm-server exited (1)` within a second, with no supervisord output** - the
entrypoint died before supervisord started. `docker logs pmm-server` shows where. If it
is `rm: cannot remove '/srv/grafana/plugins/…': Permission denied`, the `/srv` volume
holds files written by a *different* image version that this one cannot clean up, and the
entrypoint runs under `set -o errexit`. Clear the volume:

```bash
./om stop pmm
./om reset data      # includes pmm-data, PMM's /srv
./om start pmm
```

**PMM answers on 443 instead of 8443** - `docker ps` shows `0.0.0.0:443->8443/tcp`.
Compose interpolates the published port when the container is **created**, so editing
`PMM_PORT_HTTPS` and restarting changes nothing. Recreate it with `./om stop pmm && ./om
start pmm`.

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
| `pmm/AGENTS.md` | PMM's own agent guide, maintained upstream |
| [`docs/sep-agents.md`](docs/sep-agents.md) | The SEP agent guide, kept here — SEP upstream has none |

`notes/` and `todo/` are personal working state and are deliberately untracked — they are
absent on a fresh clone, so the two links to `notes/` above will dangle there. `docs/` is
the committed documentation.
