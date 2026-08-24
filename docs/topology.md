# How OpenManager Fits Together

**As of:** 2026-08-18
**Derived from:** `pmm/` @ `sep-combined-local` (`v3.8.1-185-g5adae2f50` = PMM-15216 +
PMM-15293 + PMM-15238; `docker-compose.dev.yml`, `.env`,
`build/ansible/roles/{supervisord,nginx}/files/*`, `managed/services/supervisord/*`,
`ui/apps/pmm/*`), `SEP/` @ `psmdb-openmanager` (`6f89d1a3`) (`app/main.py`,
`settings.yaml`, `app/tasks/execution/**`, `app/sep/sync/syncers/pmm.py`,
`app/sep/apps/om_inventory/**`), the [`psmdb/`](../psmdb/) cluster stack
(`compose.yaml`, `Dockerfile`, `scripts/*`), plus the workspace's own [`om`](../om). Live
state cross-checked against a running stack (`./om status`, `docker ps`,
`GET /nomad/v1/nodes`).

**How to read this:** Parts 1–2 are the plain-English version — read those first and you
will know what is running and why. Parts 3 onward add detail, one layer at a time. Every
name in *italics* the first time it appears is explained in
[`glossary.md`](glossary.md).

> **What changed since 2026-08-12** - OM grew an **inventory of its own**. The
> `om_inventory` app now keeps upserted `om.host` and `om.service` tables rather than
> serving the last sweep's output, pmm-managed **proxies** that estate at
> `/v1/om/inventory/*`, and the PMM UI gained Services, Hosts and Inventory pages that
> reach it through PMM's own origin - so no OM page in the browser talks to SEP any
> more.

> **What changed since 2026-08-10** — one thing, and it is structural: **OM was split
> across the two products.** Deriving the MongoDB topology moved into pmm-managed, which
> already owns both inputs; SEP kept only the work that needs a process on a database
> host, as the `om_inventory` app. The whole of it is in
> [`architecture.md`](architecture.md); this doc carries the parts that touch the rest of
> the system.

> **What changed in the 2026-08-10 revision (from 2026-08-03)** — four things, and they
> are all structural:
> 1. There is a **new local database stack**, [`psmdb/`](../psmdb/): four MongoDB
>    topologies as Compose profiles, one container per node, joining PMM's network.
> 2. **The executor moved onto the database hosts.** PMM's *embedded* Nomad server is the
>    one SEP talks to, and the Nomad client comes from `pmm-agent` on each node. There is
>    no separate executor container any more.
> 3. **SEP's UI is served by PMM** on `:8443`, and SEP's databases are PMM's embedded
>    PostgreSQL. Locally, the integration described as "unmerged" in Part 9 is what you
>    are actually running.
> 4. **The login path is PMM's.** The browser mints a SEP token from its PMM session, so
>    SEP needs no separate login screen locally.

---

# Part 1 — The two products, in plain words

This workspace holds two separate Percona products that are being taught to work
together.

**PMM is the watcher.** You install a small program (an *agent*) next to each database.
The agent measures things — queries per second, slow queries, disk, memory — and ships
those numbers to a central PMM server. The server stores them and draws graphs. PMM also
keeps a list of everything it watches: which machines exist, which databases run on them.
PMM does not change your databases. It looks at them.

**SEP is the doer.** SEP takes actions: back up this MongoDB, collect diagnostics from
that server, upgrade this replica set. It shows a web form per action, you fill it in, and
SEP arranges for the work to run on a chosen machine. But SEP does not go hunting for your
databases itself — it asks PMM. PMM already has the list.

One supporting piece exists only because SEP needs it:

- **Nomad** — the arm that actually runs a command on a machine, and a part of PMM rather
  than of this workspace. This matters: **SEP never connects to a database itself.** It
  decides *what* should run and *where*, then hands that to Nomad, which runs it on the
  chosen host.

Logging in needs no separate piece: the browser already has a PMM session and trades it
for a SEP token. See Part 8.

The thing to internalise about Nomad: **its client lives on the database host, and
`pmm-agent` is what puts it there.** From version 3.2.0 the agent carries a Nomad client
binary, and `pmm-managed` hands it a config and mTLS material over the connection the
agent already has. So "PMM monitors this node" and "SEP can run a command on this node"
became the same fact.

So the whole loop, in one picture:

```mermaid
flowchart LR
    U(["You, in a browser"])
    SEP["SEP<br/>decides what to run, and where"]

    subgraph PMMS["PMM server"]
        PMM["inventory + metrics"]
        NS["Nomad <b>server</b><br/>PMM_ENABLE_NOMAD"]
    end

    subgraph HOST["A database host"]
        DB[("MongoDB · MySQL · PostgreSQL")]
        AG["pmm-agent<br/>measures the database"]
        NC["Nomad <b>client</b><br/>shipped by pmm-agent"]
    end

    U --> SEP
    PMM -->|"'here is what exists'"| SEP
    SEP -->|"dispatch this job"| NS
    NS -->|"allocate"| NC
    NC -->|"runs the command in place"| DB
    DB --> AG
    AG -->|"metrics + inventory"| PMM
    NS -.->|"config + mTLS<br/>over the agent's own stream"| AG
```

One sentence: **PMM knows what you have, SEP decides what to do about it, and a Nomad
client that PMM already installed is what actually does it — on the host itself.**

That last clause is the whole reason the `psmdb/` stack exists (Part 3): a command
that must restart or upgrade a `mongod` has to run *in the same container* as that
`mongod`. Part 7 walks the action path in detail.

---

# Part 2 — What actually runs on your machine

Locally this is **three independent stacks**. Nothing merges them; they share the same host,
one Docker network, and `localhost` ports. `./om` is a script in this workspace that
starts and stops them together.

```mermaid
flowchart TB
    subgraph S1["1 · SEP — plain processes, no container"]
        BE["uvicorn backend<br/>0.0.0.0:8000"]
        FE["vite frontend :5174<br/>standalone UI, optional"]
        FE -->|"proxies /api, /sep_app, …"| BE
    end

    subgraph S2["2 · PMM — its own devcontainer, pmm/docker-compose.dev.yml"]
        PMMC["pmm-server<br/>https://localhost:8443<br/>serves the SEP UI too<br/>+ embedded Nomad server<br/>+ embedded PostgreSQL"]
    end

    subgraph S3["3 · PSMDB clusters — psmdb/compose.yaml (opt-in)"]
        N1["one container per node:<br/>mongod/mongos + pbm-agent<br/>+ pmm-agent (= Nomad client)"]
        MIO["psmdb-minio<br/>PBM store"]
    end

    PMMC -->|"proxies 5 prefixes to<br/>host.docker.internal:8000"| BE
    BE -->|"read inventory + metrics,<br/>dispatch via /nomad"| PMMC
    N1 -->|"agent stream :8443<br/>Nomad RPC :4647"| PMMC
    N1 --> MIO
```

Why each one is shaped the way it is:

| Stack | Where it is defined | Why it is separate |
| --- | --- | --- |
| SEP | run natively via `make dev-backend` / `make dev-frontend` in `SEP/` | Runs straight from the working tree, so your edits are live with no image rebuild. PMM's nginx proxies to it over the host gateway. |
| PMM | `pmm/docker-compose.dev.yml` | PMM ships its own devcontainer that mounts the repo, so `om build pmm` compiles *your* Go changes — and on `sep-combined-local` it also serves *your* SEP UI. A stock `percona/pmm-server:3` would run release binaries and fight over the name and port. |
| PSMDB clusters | [`psmdb/compose.yaml`](../psmdb/compose.yaml) | Real MongoDB with an executor client *inside* each node — so a payload can restart or upgrade the database it targets. Part 3. |

The commands:

```bash
./om setup                            # one-time bootstrap, safe to re-run
./om start                            # pmm + sep   (default group `all`)
./om start pmm sep replicaset-cluster # a full stack with a 3-node replica set
./om start clusters                   # all four PSMDB topologies
./om status                           # includes per-topology container counts
./om logs replicaset-cluster -f       # defers to docker compose for clusters
./om ports                            # what each stack publishes onto the host
./om stop replicaset-cluster          # containers down, data volumes kept
```

One `om` detail worth knowing before you type them: **the default `all` excludes the
clusters.** Everything database-shaped is opt-in, and `psmdb` is an alias for `clusters`,
the group of all four Compose topologies.

Full setup reasoning lives in [`../notes/sep-dev-quickstart.md`](../notes/sep-dev-quickstart.md).

> **Want the concrete version of this diagram?** Part 10 has the same picture as reference
> tables: host ports, what runs inside each container, and every connection with the exact
> address it uses.

---

# Part 3 — The database nodes: `psmdb/`

Everything above is infrastructure. This is the part with actual databases in it, and it
is new.

**The problem it solves.** Deploying `pmm-client` as a **sidecar container** next to each
`mongod` is fine for monitoring, and fine for anything that reaches the database over TCP.
But a Nomad client in a sidecar can never restart, reconfigure or upgrade the `mongod` — it
is in a different container, with a different filesystem and process table. Since driving
an in-place upgrade is the point of the current work, that shape does not survive.

So in `psmdb/`, **each node is one container** running four things under *supervisord*:

| Process | Supervised as | Why |
| --- | --- | --- |
| `mongod` / `mongos` | `mongo` | the database |
| `pbm-agent` | `pbm-agent` | backups, the way SEP's `backup_mongo` payloads expect |
| `pmm-agent` | `pmm-agent` | monitoring — and from ≥ 3.2.0 a **Nomad client** |
| bootstrap, registration | `cluster-init`, `register` | one-shots: `rs.initiate()`, root user, PBM store, `pmm-admin add mongodb` |

Plus `python3` and `venv` in the image, because SEP's `run-python` payloads build a venv
and `pip install` into it at runtime. That combination — pmm-client's Nomad binary *and*
`pbm` *and* `python3` in one filesystem — is what the stock `pmm-client` image does not
give you. The blocker was that image, not the design.

```mermaid
flowchart TB
    subgraph NODE["one node container — e.g. replicaset-cluster-node00"]
        SUP["supervisord"]
        MON["mongod :27017"]
        PBM["pbm-agent"]
        PA["pmm-agent"]
        NC["nomad client<br/>/usr/local/percona/pmm/tools/nomad"]
        CRED["/root/.mongodb_uri<br/>written by register.sh"]
        SUP --> MON
        SUP --> PBM
        SUP --> PA
        PA -->|"starts as a child"| NC
    end

    PMM["pmm-server<br/>on network pmm_default"]
    MIO[("psmdb-minio<br/>PBM S3 store")]

    PA -->|"gRPC :8443 — metrics, QAN,<br/>and the nomad-agent config"| PMM
    NC -->|"Nomad RPC :4647"| PMM
    PBM --> MIO
    NC -.->|"payloads read"| CRED
    NC -.->|"supervisorctl restart mongo"| MON
```

## The four topologies

| Profile | Shape | Containers | PMM `cluster` string |
| --- | --- | --- | --- |
| `standalone` | no replication (no oplog, so PBM does little) | 1 | `standalone` |
| `replicaset-single` | 1-member replica set — has an oplog, so PBM works | 1 | `replicaset-single` |
| `replicaset-cluster` | 3 data-bearing members | 3 | `replicaset-cluster` |
| `sharded-cluster` | 2 `mongos`, 3 config, 2 shards of `svr0`/`svr1`/`arb0` | 11 | `sharded-cluster` |

11 containers for the sharded cluster — one per node, no sidecars.

There is a fifth profile, `pmm-client`, which is not a topology: three unrelated hosts
carrying a PMM client and **no database** - same Dockerfile built with `WITH_PSMDB=0`, so
no `mongod`, no `pbm-agent`, not even the PSMDB packages. The Nomad client rides inside
pmm-agent rather than inside mongod, so they are still full SEP execution hosts: a place
for a payload with no database to talk to, and the *before* state of provisioning one
(the Percona apt repos are enabled on them, just unused). They export no service, so they
have no `cluster` string and no `/root/.mongodb_uri`. Started individually -
`./om start pmm-client-node01` - because each node carries its own compose profile too.

**The `cluster` column is not cosmetic.** SEP's inventory has no cluster *entity*, only a
cluster *string* per service, set by `pmm-admin add mongodb --cluster=`. OM groups
services into clusters by matching that string (falling back to the replica set), so
members of one topology must share it or the topology silently fragments.

## Facts that shape it

- **It joins PMM's network, it does not define one.** `compose.yaml` declares
  `pmm_default` as `external: true`, so `./om start pmm` must come first — `start_psmdb`
  checks for the network and says so, rather than letting Compose fail with "external
  network not found".
- **Nothing is published to the host.** Deliberate: PMM already contends for 9000 and
  8443. Reach a node with `docker exec`.
- **Readiness means registered, not started.** `./om start <profile>` waits until every
  node has `/root/.mongodb_uri` — the credentials file both `backup_mongo` and
  `om_inventory`'s probe payload read by default. A node whose `pmm-agent` has not connected is not yet a
  usable execution host.
- **Bootstrap runs *on* a node**, because MongoDB's localhost exception is the only way to
  create the first user under keyfile auth, and it really is localhost-only. One member
  per replica set carries `RS_BOOTSTRAP=1`; every other node's `register.sh` blocks until
  the root user works, which orders the whole thing without `depends_on` gymnastics.
- **The privileges are real and are local-dev only.** Each node gets `cgroup: host`, a
  writable `/sys/fs/cgroup`, `CAP_SYS_ADMIN`, and `apparmor`/`seccomp` unconfined. Nomad
  bind-mounts `/secrets` and `/local` into a per-allocation task directory even under
  `raw_exec`, and without all four the task dies in its setup hook — surfacing in SEP as a
  run that produces no output at all. Narrower than full `privileged: true`, but a
  container that can mount can escape. Do not copy it anywhere shared.

## The upgrade loop this exists for

```bash
docker exec replicaset-cluster-node02 bash -c '
  percona-release enable-only psmdb-80 release
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
      percona-server-mongodb-server percona-server-mongodb-mongos percona-server-mongodb-shell
  supervisorctl restart mongo'
```

That is verified working, and it produces a genuine mixed-version replica set — the state
a rolling upgrade passes through. As a SEP payload it becomes: upgrade the secondaries,
`rs.stepDown()` the primary, do it last, then `setFeatureCompatibilityVersion`. Three
image details make it work non-interactively (`policy-rc.d` returning 101; a generated
config at `/etc/mongod-node.conf` rather than the dpkg conffile `/etc/mongod.conf`;
`supervisorctl restart mongo` as the stand-in for `systemctl restart mongod`) — all three
are explained in [`../psmdb/README.md`](../psmdb/README.md) §3, along with the one place
this will not mimic a VM: there is no systemd, so a payload written against `systemctl`
will not port.

`psmdb/` is a plain directory in the workspace root, **not** a submodule, and is not
committed yet.

---

# Part 4 — Inside PMM: one container, many programs

PMM Server looks like a single container, but inside it *supervisord* — a small process
babysitter — starts about a dozen programs. Half of them are written to disk at build
time; the rest are generated at runtime by `pmm-managed` itself, which is why the list
changes depending on your settings.

```mermaid
flowchart TB
    subgraph C["pmm-server container"]
        NG["nginx<br/>:8443 https · :8080 http<br/>the only door in"]

        subgraph APP["Application"]
            MG["pmm-managed<br/>:7771 gRPC · :7772 REST<br/>the brain"]
            GF["grafana :3000<br/>dashboards + alerting"]
            QAN["qan-api2<br/>:9911 gRPC · :9922 REST"]
            VMP["vmproxy :8430<br/>filters metric reads per user"]
            NOMS["nomad server :4646<br/>:4647 RPC for clients"]
        end

        subgraph ST["Storage"]
            PG[("PostgreSQL :5432<br/>inventory, settings, users<br/>+ the sep database")]
            VM[("VictoriaMetrics :9090<br/>time-series metrics")]
            CH[("ClickHouse :9000 / :8123<br/>query analytics")]
        end

        VMA["vmalert :8880<br/>evaluates alert rules"]
        AG["pmm-agent<br/>monitors the server itself"]
    end

    NG --> GF
    NG --> MG
    NG --> QAN
    NG --> VMP
    NG --> VMA
    NG --> NOMS
    MG --> PG
    MG --> VM
    MG --> NOMS
    QAN --> CH
    VMP --> VM
    VMA --> VM
    GF --> PG
    GF --> VM
    GF --> CH
    AG --> VM
```

**nginx is the only door.** Everything above listens on `127.0.0.1` inside the
container; nothing but nginx is reachable from outside. That is why one port — 8443 —
gets you the whole product, and why the URL path decides which program answers:

| URL path | Goes to | What it is |
| --- | --- | --- |
| `/graph` | grafana `:3000` | dashboards, and PMM 3's alerting UI |
| `/pmm-ui`, `/` | static files | the React frontend from `pmm/ui` — which now contains the SEP UI |
| `/v1/` | pmm-managed `:7772` | the main REST API — inventory, settings, backups |
| `/v1/qan` | qan-api2 `:9922` | query analytics API |
| `/prometheus/api/v1`, `/victoriametrics/` | vmproxy `:8430` | metric queries, filtered per user — OM's PromQL among them; `/import/prometheus` is the write path |
| `/prometheus/rules`, `/prometheus/alerts` | vmalert `:8880` | rule and alert state |
| `/nomad/` | nomad server `:4646` | **on**, via `PMM_ENABLE_NOMAD=1` — this is SEP's executor endpoint |
| `/api`, `/sep_app`, `/files`, `/stream-logs`, `/execution-events` | `host.docker.internal:8000` | **SEP**, running natively on the host. `auth_request off`, dev only |
| `/auth_request` | pmm-managed | nginx asks "is this request allowed?" before serving anything |

Defined in `build/ansible/roles/nginx/files/conf.d/pmm.conf`. The five SEP prefixes are
`sep-combined-local` only, mirror the vite dev proxy in `ui/apps/pmm/vite.config.ts`, and
deliberately sit outside `/v1` and `/graph` so nothing shadows a PMM route. `auth_request`
is off there because SEP authenticates the request itself (Part 8) — which also means
anything that can reach 8443 can call the SEP API. Local testing only.

**Started at build time** (`build/ansible/roles/supervisord/files/pmm.ini`, `grafana.ini`):
`pmm-init`, `postgresql`, `clickhouse`, `nginx`, `pmm-managed`, `pmm-agent`, `grafana`.

**Written at runtime by pmm-managed** (`managed/services/supervisord/supervisord.go`):
`victoriametrics`, `vmalert`, `vmproxy`, `qan-api2`, `nomad-server`. pmm-managed renders
these config files and tells supervisord to reload — that is how a settings change can
add or reconfigure a process without rebuilding the image.

**What this workspace's `pmm/.env` turns on**, because two of them change the topology:

| Variable | Effect |
| --- | --- |
| `PMM_ENABLE_NOMAD=1` | runs the embedded Nomad server and proxies `/nomad/`. SEP dispatches here. |
| `PMM_ENABLE_SEP=1` | exposes the embedded PostgreSQL to attached Docker subnets and provisions a non-superuser `sep` role + `sep` database. SEP's three services and Celery beat all live in it. |
| `PMM_ENABLE_ACCESS_CONTROL=1`, `PMM_ENABLE_INTERNAL_PG_QAN=1` | access control; QAN for PMM's own PostgreSQL |
| `PMM_PORT_CH_TCP`, `PMM_PORT_CH_HTTP` | move ClickHouse off its 9000/8123 defaults, should anything else on the host want them |

> Note: there is **no Alertmanager** anywhere in this tree. PMM 2 had one; PMM 3 uses
> Grafana's built-in alerting instead. The root [`CLAUDE.md`](../CLAUDE.md) still lists
> it — see [Known drift](#known-drift).

## The two data pipelines

Metrics and query analytics travel completely different roads. Do not confuse them.

```mermaid
flowchart LR
    subgraph H["A monitored host"]
        EX["exporters<br/>node · mysqld · mongodb ·<br/>postgres · proxysql · valkey"]
        VMAG["vmagent<br/>scrapes them"]
        QA["QAN collectors<br/>perfschema · slowlog ·<br/>pg_stat_statements · mongo profiler"]
        PA["pmm-agent<br/>supervises all of the above"]
    end

    EX --> VMAG
    VMAG -->|"metrics push"| VM[("VictoriaMetrics")]
    QA --> PA
    PA -->|"QanCollect over gRPC"| MG["pmm-managed"]
    MG --> QAN["qan-api2"] --> CH[("ClickHouse")]
    VM --> GRAF["Grafana / PMM UI"]
    CH --> GRAF
    VM --> VMA["vmalert"]
    VM -.->|"PromQL, read-only"| OM["pmm-managed services/om<br/>derives the MongoDB topology"]
```

- **Metrics** — numbers over time. `vmagent` scrapes the exporters and pushes into
  VictoriaMetrics. Grafana reads it back.
- **Query analytics (QAN)** — individual query fingerprints and timings. Collected by
  pmm-agent, relayed through pmm-managed to qan-api2, stored in ClickHouse. ClickHouse is
  a *column store*, which is the right shape for "group millions of queries by
  fingerprint"; VictoriaMetrics would be the wrong tool, and vice versa.
- **A third reader**: OM queries VictoriaMetrics from inside pmm-managed to derive the
  MongoDB topology — see [`architecture.md`](architecture.md). It only reads. SEP *can*
  write to VM directly (`/prometheus/api/v1/import/prometheus` with the PMM credentials it
  holds), and the `.prom` textfile route the backup payloads use is the other write path,
  but nothing in OM uses either today.

## How agents connect

One long-lived, two-way *gRPC* stream per agent, and — this is the important part — the
**agent dials the server**, not the other way round. So agents work behind NAT and
firewalls, and PMM never needs a route back into your network.

```mermaid
sequenceDiagram
    participant A as pmm-agent (on a DB host)
    participant M as pmm-managed (server)

    A->>M: connect, authenticate
    Note over A,M: one stream, stays open
    M->>A: SetStateRequest — "you should be running these exporters"
    A->>M: StateChanged — "done, here is what I'm running"
    M->>A: nomad-agent config + mTLS material
    Note over A: starts the bundled nomad binary as a child
    M->>A: StartAction / StartJob — "explain this query" / "take a backup"
    A->>M: ActionResult / JobResult
    A->>M: QanCollect — query analytics batches
    M->>A: Ping
    A->>M: Pong
```

The `nomad-agent` line is the one that changed the topology. `pmm-managed` creates a
`nomad-agent` for every connecting `pmm-agent` ≥ 3.2.0 and pushes its config and
certificates down the stream the agent already opened — so a database node becomes a SEP
execution host with **no certificate handling of your own**, and no inbound port.

PMM's own domain model is three nested things — worth learning, because SEP borrows it:

- **Node** — a machine.
- **Service** — a database running on a node.
- **Agent** — a process that watches a node or a service.

A node has many services; a service belongs to one node; an agent runs on a node and may
be attached to a service.

---

# Part 5 — Inside SEP: one process wearing four hats

SEP is a *FastAPI* application. In development it is **one** Python process that mounts
three sub-applications underneath the main one, so everything answers on port 8000. In
the production compose those same sub-apps can be split onto their own ports — same
code, different packaging.

From [`SEP/app/main.py`](../SEP/app/main.py):

```python
app.mount("/api/inventory", inventory_app)
app.mount("/api/tasks", tasks_app)
app.mount("/", sep_app)
```

```mermaid
flowchart TB
    UI["The UI — two ways in:<br/>PMM at :8443/…/sep/*<br/>or standalone vite :5174"]

    subgraph P["one uvicorn process on 0.0.0.0:8000"]
        CORE["core app<br/>/api/oauth, /api/users"]
        INV["inventory app<br/>/api/inventory"]
        TSK["tasks app<br/>/api/tasks"]
        SEPA["sep app<br/>mounted at /<br/>apps, schemas, files, logs"]
    end

    PGSEP[("PMM's embedded PostgreSQL<br/>database sep, role sep<br/>127.0.0.1:5432")]

    UI -->|"proxy"| CORE
    UI -->|"proxy"| SEPA
    CORE --> PGSEP
    INV --> PGSEP
    TSK --> PGSEP
    SEPA --> PGSEP
    SEPA -->|"needs hosts + dispatch"| TSK
    SEPA -->|"needs services"| INV
```

**The databases moved.** The old picture was four SQLite files (`sep.db`, `inventory.db`,
`tasks.db`, `schedule.db`). On this branch the `development` block of `settings.yaml`
points all three services *and* the Celery beat store at **one PostgreSQL database
`sep`** — the one `PMM_ENABLE_SEP` provisions inside the PMM container. The three Alembic
tracks coexist there by using distinct version tables. `UVICORN_HOST` is `0.0.0.0` for the
same reason: `127.0.0.1` is unreachable from inside the PMM container, which proxies to
`host.docker.internal:8000`.

The four hats:

| Sub-app | Path | Job |
| --- | --- | --- |
| core | `/api/oauth`, `/api/users` | login, accounts, and the PMM session exchange |
| inventory | `/api/inventory` | the list of nodes, services, schemas, tables — filled by syncers |
| tasks | `/api/tasks` | the job queue and the executors that run jobs |
| sep | `/` | the apps themselves: their forms, schemas, results, log streams |

Each publishes its own OpenAPI document (`/api/inventory/openapi.json`,
`/api/tasks/openapi.json`, `/api/sep/openapi.json`), and `/api/openapi.json` serves a
merged view. The top-level `/openapi.json` is core-only.

## SEP apps — the actual features

An "app" is one folder under [`SEP/app/sep/apps/`](../SEP/app/sep/apps/) exporting a
single `TaskExecutionApp` object. The framework reads that object's settings and
**derives** the whole HTTP surface from it — routes, schema, validation. Turning an app
on is one line under `SEP.APPS` in `settings.yaml`.

Currently enabled there: `inventory`, `snippets`, `atw`, `alters`, `archives`,
`mysql_backups`, `checksums`, `backup_mongo`, `backup_pg`, `dipper`, `alerts`,
`alert_troubleshooting`, `report`, and the two MongoDB newcomers below. `topology` is
present but `ENABLED: false`.

The payoff of schema-derived apps: for the `task` and `script` flavors, **the frontend
needs no code**. The React shell fetches `/api/apps/<name>/schema` and renders the form
from it, so a brand-new app appears in the sidebar with no rebuild. Only the `base`
flavor (`custom_ui=True`) needs a real React component.

**`om_inventory`** — not a UI app at all: `sidebar=False`, no page, registered so its
Celery task is discoverable and it can be switched off. It is the clearest example of the
current execution shape, and of the split that shape now serves.

OM's *derivation* lives in pmm-managed - it reads PMM's own inventory and
VictoriaMetrics, and reconstructing the MongoDB topology is a gap in PMM rather than a
SEP feature. What is left in SEP is the half that genuinely needs a process on a database
host. `om_inventory` is that half:

1. enumerate **hosts** from SEP's inventory nodes, crossed with the executor list - not
   from services, because a host with no database has no service to be found through, and
   that host is the point: it is where a database can be installed;
2. match each to the executor host its probe must run on - strictly, so an unmatched
   host is recorded as orphaned rather than probed somewhere wrong;
3. dispatch the probe payload **once per executor host** via the pre-seeded system
   `run-python` task, and collect NDJSON back over the task-log chunk store rather than
   the 16 KB result file;
4. **upsert** what it found into `om.host` and `om.service`, keyed on PMM's own node
   and service ids - the only keys the consumer can join on;
5. serve the estate at `GET /api/apps/om_inventory/{hosts,services}`, which **never
   probes**: it answers from stored rows, each carrying its own age.

That last point is the load-bearing one. A sweep dispatches Nomad jobs and takes tens of
seconds; pmm-managed assembles its document in about a tenth of a second and reads these
rows on the way. The endpoint being a stored-row read is what keeps the two apart. The
sweep runs on its own 10-minute clock, and can be scoped to named hosts.

Because the rows are upserted rather than replaced per sweep, a service the newest sweep
failed to reach still answers with what it last reported and how old that is. Serving the
last sweep's output instead would drop it, making an unreachable host look like a host
with nothing installed on it.

What the probe contributes is what no metric carries: the **installed** package version
as against the running one - their divergence is the upgraded-but-not-restarted case -
the config path, the command line, the OS pair, whether the host can reach Percona's
repository, and any mongod running that PMM has no service for.

`om_inventory` reads its `credentials_path` from the `/root/.mongodb_uri` that
`register.sh` writes, the same file `backup_mongo` uses.

It also carries the executor-mapping and Nomad fan-out machinery (`mapping.py`,
`dispatch.py`, `payload/`). The upgrade and restart apps will want exactly those, so
expect them to move to a shared home once there is a second caller.

The full picture, including the document's conventions and the traps behind them, is in
[`architecture.md`](architecture.md).

To write an app, start with [`../notes/sep-apps-how-to-write-one.md`](../notes/sep-apps-how-to-write-one.md).
Scaffold with `make startapp` and never copy an existing app — the in-tree ones carry
deprecated wiring.

## Syncers — how the inventory gets filled

SEP's inventory starts empty. *Syncers* fill it on a schedule. Configured under
`SEP.SYNCERS` in `settings.yaml`: `PMMSyncer`, `MySQLSyncer`, `SystemFactsSyncer`.

`PMMSyncer` ([`SEP/app/sep/sync/syncers/pmm.py`](../SEP/app/sep/sync/syncers/pmm.py)) is
the cross-repo one, and the whole reason these two repos share a workspace.

## Celery — the background clock

*Celery* runs the scheduled work: syncers, periodic maintenance, and jobs like
`om_inventory`'s probe sweep. One trap worth knowing up front: on a fresh checkout the backend **will
not start** until Celery's beat scheduler has created its own tables once. `./om setup`
does that for you; the reasoning is in
[`../notes/sep-dev-quickstart.md`](../notes/sep-dev-quickstart.md) §3.3b.

---

# Part 6 — How SEP learns about your databases

```mermaid
sequenceDiagram
    participant C as Celery beat
    participant S as PMMSyncer
    participant P as PMM at 127.0.0.1:8443
    participant DB as SEP inventory in database sep
    participant F as A SEP app form

    C->>S: time to sync
    S->>P: GET /v1/inventory/...<br/>Authorization: Bearer service-account-token
    P-->>S: nodes, services, agents
    S->>DB: upsert nodes + services
    F->>DB: what can I target?
    DB-->>F: MongoDB service "replicaset-cluster-node00"<br/>cluster: replicaset-cluster
```

Three things must be true for this to work:

1. **A token.** PMM 3 has no "API keys" page — that was PMM 2. Create a *service account
   token* under *Administration → Users and access → Service accounts*, then put it in
   `SEP/.env` as `PMM__API_KEY`. SEP sends it as `Authorization: Bearer <token>`, which
   is exactly how PMM 3 consumes that token.
2. **The syncer enabled** in `SEP/settings.yaml` under `SEP.SYNCERS`.
3. **TLS tolerance** — already handled: `FASTAPI_ENV` defaults to `development`, whose
   settings block sets `PMM.VERIFY_SSL: false`, so PMM's self-signed certificate is
   accepted.

Skip this and SEP still runs — forms render, but any dropdown that points at a real
database (`ServiceRef`, `SchemaRef`, `TableRef`) is empty and cannot be submitted.

One wart visible in a long-lived dev stack: services from a torn-down topology linger in
PMM's inventory until removed, and Nomad keeps `down` nodes in its node list. Expect
stale names alongside the live ones.

---

# Part 7 — How a job actually runs

This is the part with the most moving pieces, so here it is end to end. **This is the path
that changed most** — compare it with the previous revision, where the executor was a
standalone container that had to be network-linked to the database by hand.

```mermaid
sequenceDiagram
    participant U as You
    participant FE as SEP UI inside PMM :8443
    participant SEP as sep app
    participant T as tasks app
    participant N as Nomad server in pmm-server, via /nomad
    participant CL as Nomad client in the database node
    participant DB as mongod in that same container

    U->>FE: open "Backup MongoDB"
    FE->>SEP: GET /api/apps/backup_mongo/schema
    SEP-->>FE: field list, incl. "Execution Host"
    FE->>SEP: GET /api/sep/hosts/
    SEP->>T: GET /hosts/
    T->>N: which clients are ready with raw_exec?
    N-->>T: pmm-server, replicaset-cluster-node00, node01, node02
    T-->>FE: host options
    U->>FE: pick the node that owns the data, submit
    FE->>SEP: POST the task
    SEP->>T: queue it
    T->>N: register parameterized job
    T->>N: dispatch job with this payload
    N->>CL: allocate
    CL->>CL: raw_exec — run pbm / python in the node container
    CL->>DB: back up / probe / apt-get install + supervisorctl restart
    T->>N: poll allocation status + logs
    T-->>FE: stream to /stream-logs, /execution-events
```

Five consequences that trip people up:

**SEP dispatches to PMM's Nomad, over HTTPS, with credentials in the URL.**
`settings.yaml`'s `development` block sets
`TASKS.NOMAD.ENDPOINT: https://admin:admin@127.0.0.1:8443/nomad`. That location keeps
nginx's `auth_request` on, and `python-nomad` has no setting for a Basic or Bearer header
of its own — hence credentials in the URL. `VERIFY_SSL: false` for the self-signed cert.

**Nomad is required for *any* task form, not just for running tasks.** Every task app
inherits an "Execution Host" field whose options come from `executor.get_hosts()`. With
no Nomad, the form shows *"Failed to get a response from Nomad"* and cannot be submitted
at all. `TaskBackendEnum` does contain a `CELERY` value, but nothing in the UI path
selects it — so Nomad is the only route today.

**The `raw_exec` driver runs commands directly on the Nomad client.** No container
wraps the payload. So the client's own filesystem must carry whatever the payloads call.
That is a requirement on the *node image*, and `psmdb/Dockerfile` satisfies it with
`python3` + `venv` (for `run-python`) and `percona-backup-mongodb` (for the PBM CLI). It
also asserts `/usr/local/percona/pmm/tools/nomad` exists at build time, so a future
pmm-client that drops the Nomad binary fails the build instead of silently producing nodes
SEP cannot dispatch to.

**Being on the database host is the point.** The payload can read
`/root/.mongodb_uri` from the local filesystem — SEP never ships a credential with a job —
and it can `supervisorctl restart mongo`, which a sidecar executor could never do.

**There is no separate executor container.** PMM's embedded server plus the per-node client
that `pmm-agent` starts is the whole executor story locally, which is why a `psmdb/` node
needs no extra wiring to become an execution host.

---

# Part 8 — Logging in

Locally there is one login path, and it is PMM's own session.

**SEP inside PMM (the local default).** The browser already holds a
`pmm_session` cookie. The embedded SEP UI POSTs `/api/oauth/session/exchange`, which is
same-origin through nginx and therefore carries that cookie; SEP validates it against
Grafana, maps the org role, and mints its own short-lived bearer. Enabled by
`SEP.AMBIENT_SESSION_SSO_ENABLED: true`.

```mermaid
sequenceDiagram
    participant B as Browser (PMM UI :8443)
    participant NG as nginx in pmm-server
    participant SEP as SEP backend :8000
    participant GF as Grafana in pmm-server

    B->>NG: POST /api/oauth/session/exchange<br/>Cookie: pmm_session
    NG->>SEP: proxied, auth_request off
    SEP->>GF: is this session valid? what role?
    GF-->>SEP: user + org role
    SEP-->>B: short-lived SEP bearer
    Note over B,SEP: every later SEP call carries that bearer
```

Why the proxy deliberately injects **no** token: doing so would authenticate everything as
SEP's internal service principal, which hardcodes `is_admin = False` — exactly the 403s
PMM-15293 exists to remove.

**SEP has no user table of its own.** Upstream it delegates to an external identity
provider, and `settings.yaml` nulls those entries out on this branch so Grafana is the one
active provider. Setting any `AUTH__PROVIDER__*` env var in `SEP/.env` resurrects an entry
it dropped, which is the usual reason a login stops using the PMM session.

The standalone frontend on `:5174` therefore has no login of its own locally — reach the
SEP apps through PMM instead.

---

# Part 9 — The part that is currently changing

Upstream, SEP is still a **separate website** from PMM. Locally, it is not: the
integration branches are merged in `pmm/` as `sep-combined-local`, and everything Parts
4–8 describe is that merged state.

```mermaid
flowchart LR
    subgraph NOW["Upstream main branches"]
        U1(["User"]) --> P1["PMM UI<br/>localhost:8443"]
        U1 --> S1["SEP UI<br/>localhost:5174"]
    end

    subgraph LOCAL["What you are running — pmm @ sep-combined-local"]
        U2(["User"]) --> P2["PMM UI only :8443"]
        P2 --> R1["/sep/atw/*"]
        P2 --> R2["/sep/mysql-backups/*"]
        R1 --> B2["SEP backend :8000<br/>via nginx"]
        R2 --> B2
        B2 --> PG2[("PMM's embedded PostgreSQL")]
    end
```

Three tracks, all present on that branch:

- **Track A — frontend port** (`PMM-15216`): SEP's React packages moved into PMM's `ui/`
  workspace so SEP apps render as native PMM routes. Only `atw` exists as a real ported
  package (`SEP_ATW_PATH`); `mysql_backups` rides the generic `SchemaDrivenPlugin`
  (`SEP_MYSQL_BACKUPS_PATH`). Everything else is still SEP-only, reachable on `:5174`.
- **Track B — shared PostgreSQL** (`PMM-15238`): the embedded PostgreSQL exposed to
  attached Docker subnets behind `PMM_ENABLE_SEP`, with a non-superuser `sep` role and its
  own database. Nothing new is published on the host beyond the 5432 the devcontainer
  already publishes.
- **Track C — session exchange** (`PMM-15293`): mint the SEP bearer from the PMM session,
  Part 8. This is what replaced the earlier dev-only proxy shim that authenticated
  everything as a service principal.

Each SEP frontend change still has to be hand-ported onto the branch. **Read
[`../notes/sep-pmm-integration.md`](../notes/sep-pmm-integration.md) before touching
either side of this boundary** — it has the branch state, the quirks, and the open
questions. That note's own "As of" predates Track C landing.

---

# Part 10 — Reference

## Host ports

As configured by this workspace's `pmm/.env` and `om`:

| Port | Owner | Notes |
| --- | --- | --- |
| 8000 | SEP backend (uvicorn) | `0.0.0.0` — PMM's nginx reaches it over the host gateway |
| 5174 | SEP frontend (vite) | the standalone UI; optional now |
| 8443 | PMM HTTPS | the SEP UI, the SEP API proxy, and `/nomad` all live here too |
| 5432 | PMM PostgreSQL | published by `pmm/docker-compose.dev.yml`; holds the `sep` database |
| 9090 | PMM VictoriaMetrics | |
| 9000 | PMM ClickHouse TCP | `PMM_PORT_CH_TCP` moves it if something else wants 9000 |
| 8123 | PMM ClickHouse HTTP | `PMM_PORT_CH_HTTP` likewise |
| 5173 | PMM vite HMR | distinct from SEP's 5174 |
| 2345 | PMM delve | debugger |
| 35729–35730 | PMM livereload | |
| — | `psmdb/` clusters and MinIO | **nothing published**, by design |

`./om ports` prints this table plus what is actually listening.

## Inside the PMM container

| Program | Port | Started by |
| --- | --- | --- |
| nginx | 8443 / 8080 | build-time `pmm.ini` |
| pmm-managed | 7771 gRPC, 7772 REST | build-time `pmm.ini` |
| postgresql | 5432 | build-time `pmm.ini` |
| clickhouse | 9000, 8123 (container-internal) | build-time `pmm.ini` |
| pmm-agent | — | build-time `pmm.ini` |
| grafana | 3000 | build-time `grafana.ini` |
| victoriametrics | 9090 | pmm-managed at runtime |
| vmalert | 8880 | pmm-managed at runtime |
| vmproxy | 8430 | pmm-managed at runtime |
| qan-api2 | 9911 gRPC, 9922 REST | pmm-managed at runtime |
| nomad-server | 4646 HTTP, 4647 RPC | pmm-managed at runtime, `PMM_ENABLE_NOMAD=1` |

## Inside a `psmdb/` node container

| Program | Supervised as | Notes |
| --- | --- | --- |
| `mongod` / `mongos` | `mongo` | port per role: 27017 mongod/mongos, 27018 shardsvr, 27019 configsvr |
| `pbm-agent` | `pbm-agent` | idle on `mongos` and arbiters (`PBM_ENABLED=0`) |
| `pmm-agent` | `pmm-agent` | dials `pmm-server:8443`; starts the Nomad client as a child |
| nomad client | (child of pmm-agent) | `/usr/local/percona/pmm/tools/nomad`, RPC to `pmm-server:4647` |
| `cluster-init.sh` | `cluster-init` | one-shot on the `RS_BOOTSTRAP` member |
| `register.sh` | `register` | one-shot: `pmm-admin add mongodb`, writes `/root/.mongodb_uri` |

## Who talks to whom

| From | To | How |
| --- | --- | --- |
| pmm-agent | pmm-managed | outbound gRPC stream, agent dials server; carries the nomad-agent config |
| node's nomad client | pmm-server `:4647` | Nomad RPC, mTLS with certs pushed over that stream |
| vmagent | VictoriaMetrics | metrics push |
| SEP `PMMSyncer` | PMM `/v1/inventory` | REST + Bearer service account token |
| SEP tasks app | PMM `/nomad` on `:8443` | REST over HTTPS, credentials in the URL — register, dispatch, poll, stream logs |
| pmm-managed `services/om` | SEP `/api/apps/om_inventory/services` | REST + Bearer, reads the estate's on-host facts; `PMM_SEP_URL` |
| SEP (all three services + beat) | PMM's embedded PostgreSQL `:5432` | database `sep`, role `sep` |
| SEP core app | Grafana in pmm-server | validates a `pmm_session` cookie, maps the org role |
| PMM nginx | SEP `:8000` | proxies `/api`, `/sep_app`, `/files`, `/stream-logs`, `/execution-events` via `host.docker.internal` |
| Nomad client | target database | `raw_exec`, commands run directly on the client — in `psmdb/`, in the same container as `mongod` |
| pbm-agent | `psmdb-minio:9000` | PBM S3 store, network-internal |

## The files that define all this

| File | Defines |
| --- | --- |
| [`../om`](../om) | how all three stacks start and stop |
| [`../psmdb/compose.yaml`](../psmdb/compose.yaml) | the four topologies, MinIO, and the `pmm_default` join |
| [`../psmdb/Dockerfile`](../psmdb/Dockerfile) | the node image, and why it is Ubuntu + apt |
| [`../psmdb/README.md`](../psmdb/README.md) | the cluster stack in depth: upgrade loop, bootstrap ordering, rough edges |
| `pmm/.env` | which PMM features this workspace turns on |
| `pmm/docker-compose.dev.yml` | the PMM devcontainer, its published ports and host-gateway alias |
| `pmm/build/ansible/roles/nginx/files/conf.d/pmm.conf` | PMM's URL routing, incl. the five SEP prefixes |
| `pmm/build/ansible/roles/supervisord/files/pmm.ini` | PMM's build-time processes |
| `pmm/managed/services/supervisord/supervisord.go` | PMM's runtime-generated processes |
| `pmm/ui/apps/pmm/src/router.tsx`, `lib/constants.ts` | where SEP apps mount as PMM routes |
| `SEP/app/main.py` | the four-hats mount layout |
| `SEP/settings.yaml` | apps, syncers, and the `development` block that points SEP at PMM's Postgres and Nomad |
| `SEP/app/api/routes/oauth.py` | `/session/exchange` — the PMM session → SEP bearer swap |
| `SEP/app/sep/sync/syncers/pmm.py` | the SEP→PMM inventory pull |
| `SEP/app/sep/apps/om_inventory/{service,dispatch,mapping}.py` | the current end-to-end execution example |
| `SEP/app/tasks/execution/executors/nomad/models.py` | job register, dispatch, log streaming |

## Known drift

Recorded rather than silently fixed, because each needs its own change:

1. The root [`CLAUDE.md`](../CLAUDE.md) lists **Alertmanager** in PMM's backend stack.
   There is no Alertmanager anywhere in `pmm/` — PMM 3 uses Grafana alerting.
2. The root [`CLAUDE.md`](../CLAUDE.md) points `PMMSyncer` at
   `SEP/app/sep/sync/syncers/pmm.py` — correct — but an older path
   (`SEP/app/inventory/syncers/pmm.py`) still circulates in other docs. Also tracked in
   [`../notes/sep-pmm-integration.md`](../notes/sep-pmm-integration.md) §7.
3. SEP's own `README.md` carries several stale sections — PMM 2 instructions, a
   superseded `PLUGINS:` block, a setting that exists nowhere in the code. The full list
   is in [`../notes/sep-dev-quickstart.md`](../notes/sep-dev-quickstart.md) §6.

---

## Where to go next

- Want *real MongoDB to act on*? [`../psmdb/README.md`](../psmdb/README.md)
- Want the *container-level* wiring? Part 10 above
- Want to *run* this? [`../notes/sep-dev-quickstart.md`](../notes/sep-dev-quickstart.md)
- Want to *write a SEP app*? [`../notes/sep-apps-how-to-write-one.md`](../notes/sep-apps-how-to-write-one.md)
- Want to work on the *merge*? [`../notes/sep-pmm-integration.md`](../notes/sep-pmm-integration.md)
- Hit an unfamiliar word? [`glossary.md`](glossary.md)
