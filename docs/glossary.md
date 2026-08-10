# Glossary

Every proper noun and piece of jargon that shows up in this workspace, in plain words.
Ordered so that reading top to bottom builds up — not alphabetically.

**As of:** 2026-08-06

---

## The two products

**PMM — Percona Monitoring and Management.** Watches databases. Agents next to each
database measure things and send the numbers to a central server, which stores them and
draws graphs. It also keeps an inventory: which machines exist, which databases run on
them. PMM observes; it does not change anything.

**SEP — Services Enablement Platform.** Does things to databases: backups, diagnostics,
schema changes, checksums. Each capability is a small "app" with a web form. SEP gets its
list of databases from PMM.

**PMM 2 vs PMM 3.** This workspace is PMM 3. Enough changed between them that PMM 2 docs
actively mislead: PMM 2 had API keys and a standalone Alertmanager, PMM 3 has service
account tokens and Grafana alerting. If a doc mentions either PMM 2 thing, it is stale.

---

## PMM's parts

**pmm-agent.** The program installed next to a database. It supervises the exporters and
collectors, and holds one long-lived connection to the server. Crucially the *agent dials
the server*, so it works behind NAT and firewalls.

**exporter.** A tiny program that reads one thing's statistics and publishes them as
numbers over HTTP. There is one per subject: `node_exporter` for the machine,
`mysqld_exporter` for MySQL, and so on.

**vmagent.** Visits each exporter on a timer, collects the numbers, and pushes them to
the server. The "scraper".

**pmm-managed.** The server's brain, in Go. Owns the inventory, the settings, the REST
API under `/v1/`, and it tells agents what to run. It also generates config for several
of the other server processes at runtime.

**pmm-admin.** A command-line tool for registering databases with PMM by hand.

**qan-api2 / QAN.** Query Analytics. The half of PMM that is about individual queries —
which ones are slow, how often they run — rather than about machine-level numbers.
`qan-api2` ingests and serves that data.

**vmproxy.** Sits in front of VictoriaMetrics and filters what each user is allowed to
read. "LBAC" in PMM's docs means label-based access control — restricting by metric
labels.

**vmalert.** Evaluates alerting rule files against the metrics and records which alerts
are firing.

**Grafana.** The dashboard tool PMM embeds, served under `/graph`. In PMM 3 it also
provides the alerting UI and notification delivery.

**supervisord.** A small process babysitter. Inside the PMM container it starts and
restarts the dozen-odd programs that make up the server. It is why one container can hold
what looks like many services.

**nginx.** The web server at the front of the PMM container. It is the only thing
reachable from outside, and it decides which internal program handles each URL path.

**Node / Service / Agent.** PMM's core model. A **node** is a machine; a **service** is a
database running on it; an **agent** is a process watching a node or a service. SEP
borrows the same shape.

**service account token.** PMM 3's way of giving a program API access. Created under
*Administration → Users and access → Service accounts*. Sent as
`Authorization: Bearer <token>`. Replaces PMM 2's "API keys" page, which no longer
exists.

---

## Storage engines

**VictoriaMetrics.** A *time-series database* — built for "this number, at this moment,
over and over". Holds PMM's metrics. Fast at "show me CPU for the last 6 hours", useless
for anything else.

**ClickHouse.** A *column store* — built for scanning huge tables and aggregating. Holds
PMM's query analytics, because "group ten million queries by fingerprint" is exactly its
strength.

**PostgreSQL.** An ordinary relational database. PMM uses it for inventory, settings and
Grafana's own state. SEP uses it in production.

**SQLite.** A database that is just a file, with no server. SEP uses it in development —
`sep.db`, `inventory.db`, `tasks.db`, `schedule.db` — which is why local setup needs no
database installation.

---

## SEP's parts

**FastAPI.** The Python web framework SEP's backend is built on. Generates its own
OpenAPI documentation from the code.

**uvicorn.** The server process that actually runs a FastAPI app. `make dev-backend`
starts one on port 8000.

**mount / sub-app.** FastAPI can nest whole applications under a URL prefix. SEP mounts
`inventory` at `/api/inventory`, `tasks` at `/api/tasks`, and its main app at `/`. In
development they share one process; in production they can be split apart.

**SEP app.** One folder under `SEP/app/sep/apps/` exporting a single `TaskExecutionApp`
object. The framework derives the HTTP routes, the form schema and the validation from
that object's settings. Enabled by one line in `settings.yaml`.

**schema-driven UI.** Because the form is described by the backend, the React shell can
fetch `/api/apps/<name>/schema` and draw it. A new app therefore appears in the sidebar
with no frontend code and no rebuild.

**syncer.** A background job that fills SEP's inventory from somewhere else.
`PMMSyncer` pulls from PMM; `MySQLSyncer` connects to MySQL directly;
`SystemFactsSyncer` gathers host facts.

**`ServiceRef` / `SchemaRef` / `TableRef` / `HostRef`.** Form field types that point at
something real. Their dropdown options come from the inventory (or, for `HostRef`, from
the executor). If the source is empty, the form renders but cannot be submitted.

**Celery.** Python's standard background-job system. In SEP it runs the scheduled work
(syncers, periodic maintenance). **Celery beat** is the scheduler half — the clock.

**Alembic.** Applies database schema migrations. SEP has three separate Alembic configs
(`sep`, `inventory`, `tasks`) that `make migrate` runs in one pass. Notably it does
*not* create Celery beat's tables.

**SQLModel / SQLAlchemy.** The libraries SEP uses to talk to its databases from Python.

**Casdoor.** An open-source login server. Standalone SEP has no user accounts of its own,
so it hands authentication to Casdoor, on port 9999 here. Not in the path when SEP runs
inside PMM — see *session exchange*.

**session exchange.** `POST /api/oauth/session/exchange`: the embedded SEP UI trades the
browser's existing `pmm_session` cookie for a short-lived SEP bearer. SEP validates the
session against Grafana and maps the org role, so no separate SEP login exists.

**OAuth2 password grant.** The simplest OAuth flow: send username and password, get
tokens back. SEP performs it *server-side*, so there is no browser redirect and no
redirect-URL configuration.

**HttpOnly cookie.** A cookie JavaScript cannot read. SEP puts the refresh token in one,
so a script on the page cannot steal it.

---

## Running jobs

**Nomad.** HashiCorp's job scheduler. You tell it "run this command", it picks a machine
and runs it. Two halves: a **server** that decides, and a **client** that executes.

**`raw_exec` driver.** The Nomad driver that runs a command *directly on the client
machine*, with no container around it. SEP uses this — which means the Nomad client's own
filesystem must contain every tool the jobs call (python3, pbm, …).

**nomad-agent.** The Nomad client `pmm-managed` creates for every connecting `pmm-agent`
≥ 3.2.0, pushing its config and mTLS material down the stream the agent already opened.
This is what makes a monitored database host a SEP execution host with no certificate
handling of your own, and no inbound port.

**parameterized job / dispatch.** A Nomad job registered once as a template, then
"dispatched" many times with different inputs. SEP registers a template per task type and
dispatches one run per submitted form.

**allocation.** One actual run of a job on one client. Its logs and exit code are what
SEP streams back into the UI.

**payload.** The script SEP hands to Nomad for a given task. Some pip-install their
requirements at runtime; the Mongo backup ones shell out to `pbm`.

**executor.** SEP's abstraction over "the thing that runs jobs". `NomadExecutor` is the
only one usable through the UI today; a `CeleryExecutor` exists in the code but nothing
selects it.

---

## Databases and tools being managed

**PSMDB.** Percona Server for MongoDB — Percona's MongoDB distribution.

**PBM.** Percona Backup for MongoDB. A command-line tool; SEP's Mongo backup app calls
it on the executor host.

**PSMDB Sandbox.** A separate Go web UI (`mongo_terraform_ansible/ui-go`, port 5001)
that drives Terraform to deploy real MongoDB clusters locally in Docker, with `pmm-client`
as a **sidecar** container per node. The older source of real databases to test against;
`./om start sandbox`.

**`psmdb/` clusters.** The newer source: four MongoDB topologies as Compose profiles in
[`psmdb/`](../psmdb/), where each node is **one** container running mongod/mongos +
pbm-agent + pmm-agent, so the Nomad client lives beside the database it manages. Started
per profile — `./om start replicaset-cluster` — or all at once with `./om start clusters`.
Since 2026-08-06 `psmdb` as an `om` argument means these, not the sandbox UI.

**MinIO.** S3-compatible object storage, used locally as a backup target. Defaults to
port 9000, which is why it collides with PMM's ClickHouse.

**Percona Toolkit.** Command-line database utilities. They run on the executor host, not
on your development machine.

---

## Workspace-specific

**`om`.** The orchestrator script at the workspace root. Starts, stops and links all five
local stacks. `./om setup`, `./om start`, `./om status`, `./om ports`.

**devcontainer.** A container that has the build toolchain inside and your source tree
mounted in, so you can compile and run your working copy inside it. PMM runs this way
here, which is what makes `./om build pmm` compile your Go changes.

**compose profile.** A way to mark a Compose service opt-in. Nomad is behind the `nomad`
profile, so a plain `docker compose up` skips it.

**`psmdb-link`.** `./om psmdb-link <env>` attaches the repo PMM and the Nomad executor to
a sandbox environment's Docker network, under the DNS name the sandbox's agents already
expect. It is a network alias trick, not a config change.

**inotify.** The Linux mechanism that lets a program watch files for changes. Its
per-user *instance* limit is low by default, and running out of them makes Vite die with
`ENOSPC` — which looks like a full disk but is not.

---

## Terms that appear in code and reviews

**gRPC.** A binary request protocol built on HTTP/2, supporting long-lived two-way
streams. PMM's agents and its internal services use it; REST is the outside surface.

**OpenAPI.** A machine-readable description of a REST API. Both products generate
clients and types from theirs — and one of the open questions on the integration branch is
that PMM hand-writes some of those types instead of generating them from SEP's spec.

**Vite.** The frontend development server and bundler. Serves the UI with hot reload and
proxies API paths to the backend.

**pnpm workspaces.** A way to keep many frontend packages in one repository with shared
dependencies. Both SEP's frontend and PMM's `ui/` (on the integration branch) use it.
