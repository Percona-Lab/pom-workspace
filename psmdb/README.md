# PSMDB sandbox for the PMM + SEP stack

Four MongoDB topologies as Docker Compose profiles, sitting on the network PMM
already uses, with a **Nomad client on every database node** so SEP can dispatch
work onto the host that owns the data - including in-place `apt` upgrades. Plus a
pool of hosts that carry the Nomad client and **no database at all** (§8).

**As of:** 2026-08-13
**Verified against:** `pmm` @ `sep-combined-local` (PMM-15216 + PMM-15293 +
PMM-15238), `SEP` @ `pmm-mongo-status`, PSMDB 7.0.39-21, PBM 2.15.0,
pmm-client 3.9.0, Nomad from the pmm-client deb.

---

## 1. Why this exists rather than the Terraform sandbox

`mongo_terraform_ansible` deploys pmm-client as a **sidecar container** next to
each mongod. That is fine for monitoring and fine for anything that reaches the
database over TCP — but a Nomad client living in a sidecar can never restart,
reconfigure, or upgrade the mongod, because it is in a different container.

Since driving an in-place upgrade is the point here, each node in this sandbox is
**one container** running:

| Process | Supervised as | Why |
| --- | --- | --- |
| `mongod` / `mongos` | `mongo` | the database |
| `pbm-agent` | `pbm-agent` | backups, the way SEP's `backup_mongo` payloads expect |
| `pmm-agent` | `pmm-agent` | monitoring — and from ≥ 3.2.0 a **Nomad client** |
| bootstrap / registration | `cluster-init`, `register` | one-shots, see §5 |

The Nomad client is the piece that matters: pmm-managed creates a `nomad-agent`
for every connecting pmm-agent and pushes its config and mTLS material down the
existing gRPC stream, so the node appears in SEP's *Execution Host* dropdown with
no certificate handling of your own.

Because that client rides inside pmm-agent and not inside mongod, the bottom three
rows are optional - drop them and you have a SEP execution host with no database
on it at all, which is the `pmm-client` profile in §8.

Half the container count of the Terraform sandbox for the same topology — 11 vs
22 for the sharded cluster — because there are no sidecars.

---

## 2. Quick start

PMM and SEP are **not** defined here; they come from `./om`, so that PMM serves
the UI built from your working tree and SEP carries your working-tree apps. The
clusters are `./om` components too:

```bash
cd /home/plebioda/openmanager
./om start pmm sep replicaset-cluster     # PMM first — these nodes join its network
./om status                       # per-topology container counts
./om logs replicaset-cluster -f
./om stop replicaset-cluster              # containers down, data volumes kept
./om start pmm-client-node00              # a host with no database on it (§8)
```

`./om start` builds the node image and generates `secrets/keyfile` on first use,
and waits for every node to finish bootstrap rather than just reporting
"started". `clusters` (or `psmdb`) is the group for all four at once.

Compose directly works too, and is what `om` calls:

```bash
cd psmdb
./bootstrap.sh
docker build -t openmanager/psmdb-node:7.0 .
docker build --build-arg WITH_PSMDB=0 -t openmanager/pmm-client-node:3 .   # §8
docker compose --profile replicaset-cluster --profile replicaset-single up -d
COMPOSE_PROFILES=sharded-cluster docker compose up -d
docker compose --profile replicaset-cluster down -v         # containers *and* data
```

| Profile | Shape | Containers | PMM `cluster` |
| --- | --- | --- | --- |
| `standalone` | no replication | 1 | `standalone` |
| `replicaset-single` | 1-member replica set (has an oplog, so PBM works) | 1 | `replicaset-single` |
| `replicaset-cluster` | 3 data-bearing members | 3 | `replicaset-cluster` |
| `sharded-cluster` | 2 mongos, 3 config, 2 shards of svr0/svr1/arb0 | 11 | `sharded-cluster` |
| `pmm-client` | hosts with a PMM client and no database - §8 | 3 | none |

Nothing is published to the host — deliberately, since omtest1 and PMM already
contend for 9000 and 8443. Reach a node with `docker exec`.

The `cluster` column is not cosmetic. SEP's inventory has no cluster entity, only
a cluster *string* per service, set by `pmm-admin add mongodb --cluster=`. `pom_worker`
groups a run's services into cluster documents by matching it, so members of one
topology must share the value or the topology silently fragments.

---

## 3. The upgrade loop

This is what the image exists for, and it is verified working:

```bash
docker exec replicaset-cluster-node02 bash -c '
  percona-release enable-only psmdb-80 release
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
      percona-server-mongodb-server percona-server-mongodb-mongos percona-server-mongodb-shell
  supervisorctl restart mongo'
```

Measured result — a genuine mixed-version replica set, which is the state a
rolling upgrade passes through:

```
replicaset-cluster-node00  PRIMARY    health=1   v7.0.39-21
replicaset-cluster-node01  SECONDARY  health=1   v7.0.39-21
replicaset-cluster-node02  SECONDARY  health=1   v8.0.26-11
featureCompatibilityVersion: 7.0
```

As a SEP payload this becomes: pick the secondaries, run the three commands on
each through the node's own Nomad client, `rs.stepDown()` the primary, do it
last, then `setFeatureCompatibilityVersion: "8.0"`. FCV belongs in the payload,
not the image — it is part of what you are developing.

Three things the image does so this works non-interactively:

- **`policy-rc.d` returns 101**, so Debian maintainer scripts never try to start
  a service. There is no init system; supervisord owns lifecycle.
- **The generated config is `/etc/mongod-node.conf`, not `/etc/mongod.conf`.**
  The latter is a dpkg *conffile*; writing to it makes every upgrade stop at
  `configuration file '/etc/mongod.conf' … keep your currently-installed
  version?` and fail with `end of file on stdin at conffile prompt`. Found the
  hard way — see the comment at the top of `scripts/entrypoint.sh`.
- **`supervisorctl restart mongo`** is the container analogue of `systemctl
  restart mongod`, and it is the same command on every node regardless of role,
  so a payload can target nodes generically.

**The one place this will not mimic a VM**: there is no systemd, so a payload
written against `systemctl` will not port. If that matters for your app, drive
restarts through an abstraction you can swap.

---

## 4. What SEP sees

After `./om start pmm sep` and a topology up, with a PMM session exchanged for a
SEP bearer:

```
GET /api/sep/hosts/     → pmm-server, replicaset-cluster-node00, replicaset-cluster-node01, replicaset-cluster-node02
GET /v1/inventory/services
      replicaset-cluster-node00 | cluster: replicaset-cluster | env: sandbox
      replicaset-cluster-node01 | cluster: replicaset-cluster | env: sandbox
      replicaset-cluster-node02 | cluster: replicaset-cluster | env: sandbox
```

Credentials follow SEP's host-side model: `register.sh` writes
`/root/.mongodb_uri` in each container, which is the default `credentials_path`
for both `backup_mongo`'s payloads and `pom_worker`'s probe. Nothing ships a
credential with a job. `/root` because the Nomad client inherits pmm-agent's
user, which is root here.

---

## 5. How bootstrap works, and why it runs on a node

With keyfile internal auth on and no users yet, MongoDB's **localhost exception**
is the only way to create the first user — and it really is localhost-only, so a
separate init container could not do it. One member per replica set carries
`RS_BOOTSTRAP=1` and does `rs.initiate()`, the root user, and the PBM store
config from inside. Every other node's `register.sh` simply blocks until the root
user works, which orders the whole thing without `depends_on` gymnastics.

For the sharded cluster, `sharded-cluster-mongos00` additionally carries `SHARD_BOOTSTRAP=1`
and runs `sh.addShard` for each shard once that shard has elected a primary.

Everything is idempotent — containers get recreated onto existing data volumes.

---

## 6. Known rough edges

- **`cgroup: host` plus a writable `/sys/fs/cgroup`** are required on every node,
  or the Nomad client dies with `failed to create nomad cgroup: open
  /sys/fs/cgroup/cgroup.subtree_control: read-only file system`. Interestingly
  the Nomad client *inside pmm-server* starts without them; the difference is
  not explained.
- **Arbiters force an explicit default write concern.** A shard of
  `svr0/svr1/arb0` has three voting members but only two writable ones, so
  `sh.addShard` refuses until `setDefaultRWConcern` is set. `cluster-init.sh`
  does it unconditionally before adding shards; without it the sharded profile
  comes up with zero shards and a mongos that looks healthy.
- **Stale PMM inventory.** `--force` on `pmm-agent setup` replaces a node of the
  same name, but services from a torn-down topology linger until removed in PMM.
- **Restarting `pmm-agent` used to de-register the node's database.** `setup
  --force` replaces the node, and replacing a node takes its services with it.
  `register.sh` is a supervisord one-shot that ran at container start, so nothing
  added the service back: the node returned healthy, its mongod kept running, and
  PMM simply stopped knowing there was a database on it. Nothing surfaced that -
  it was found only because POM reported a mongod it had no service for.
  `run-pmm-agent.sh` now re-asserts registration on every start, so a
  `supervisorctl restart pmm-agent` is safe again. If you meet a node in the old
  state, `supervisorctl start register` inside it puts the service back.
- **Restarting `pmm-agent` gives the node a new PMM node id**, because `--force`
  replaces rather than updates it. Anything keyed on that id - POM's `pom.host`,
  for one - gains a row and keeps the old one. Harmless here, worth knowing before
  you conclude an estate has twice the hosts it does.
- **Ubuntu, not RHEL.** Chosen for `apt`. The same Dockerfile works on
  `oraclelinux:9` with `dnf` if you need to match a RHEL estate — the official
  `percona/percona-server-mongodb` image is UBI 9 and its mongod is rpm-owned, so
  package upgrades work there too.
- **No host ports.** By design; see §2.

---

## 7. Files

| File | Role |
| --- | --- |
| `Dockerfile` | both node images - PSMDB 7.0 + PBM + pmm-client + python3 from Percona apt repos, or `WITH_PSMDB=0` for the client-only build |
| `compose.yaml` | four database profiles + `pmm-client`, MinIO, joins `pmm_default` |
| `bootstrap.sh` | generates `secrets/keyfile`, checks the network exists |
| `supervisord/pmm-agent.conf` | the one program both images run |
| `supervisord/psmdb.conf` | the four database programs, `WITH_PSMDB=1` only |
| `supervisord/client.conf` | the readiness one-shot, `WITH_PSMDB=0` only |
| `scripts/entrypoint.sh` | renders the mongod/mongos config from the environment |
| `scripts/run-mongo.sh` | mongod or mongos, one program either way |
| `scripts/run-pmm-agent.sh` | waits for PMM, `pmm-agent setup`, then the agent |
| `scripts/run-pbm-agent.sh` | pbm-agent, idle on mongos and arbiters |
| `scripts/cluster-init.sh` | `rs.initiate` + root user + PBM store; `sh.addShard` on a mongos |
| `scripts/register.sh` | `pmm-admin add mongodb --cluster=…`, writes `/root/.mongodb_uri` |
| `scripts/register-client.sh` | the same readiness marker, on a host with nothing to register |

---

## 8. Hosts with a PMM client and no database

`pmm-client` is not a topology. It is a pool of three unrelated machines that
carry a PMM client and nothing else - **no `mongod`, no `pbm-agent`, and not even
the PSMDB packages installed**. They come from this same Dockerfile built with
`WITH_PSMDB=0`, so the base, the libc, the python and the pmm-client are
identical to the database nodes standing beside them; only the database is
absent.

```bash
./om start pmm-client              # all three
./om start pmm-client-node01       # exactly one - each node is its own profile too
./om logs pmm-client-node01 -f
```

**Why it is useful.** The Nomad client rides inside pmm-agent, not inside mongod,
so a host with no database is still a full SEP execution host. That gives you:

- a place to develop a payload that has no database to talk to - anything that
  inspects the host, installs software, or calls out to something else;
- the *before* state of provisioning: the psmdb apt repos are enabled on these
  hosts and simply unused, so a payload can `apt-get install
  percona-server-mongodb-server` and turn one into a database host, through the
  same seam §3's in-place upgrade uses on a host that already has one;
- a control for anything that reasons about inventory - a node PMM knows about
  that exports no service at all.

**What SEP and PMM see.** The node itself, registered by `pmm-agent setup`, and
no service. There is no cluster string because a cluster string is a property of a
*service* in PMM's inventory, and these export none; there is no
`/root/.mongodb_uri` because there is no database whose credentials it would hold.
They appear in `GET /api/sep/hosts/` and in the *Execution Host* dropdown, and
nowhere in `/v1/inventory/services`.

**Readiness.** `register-client.sh` waits for `pmm-admin status` to succeed and
then writes `/run/om-node-ready` - the same marker `register.sh` writes on a
database node once it has registered. `./om start` waits on that one file for
every node in the sandbox, so it never has to ask which kind it is looking at.

**Adding a fourth.** Copy one three-line service block in `compose.yaml` (giving
it its own private profile alongside `pmm-client`) and bump `CLIENT_NODES` in
`../om` to match.

**MinIO does not come up with them.** It carries the four database profiles
rather than none, because a host with no database has nothing to back up.
