# What If PMM's Built-in Nomad Were Used?

Today SEP dispatches jobs to a standalone `om-nomad` container that this workspace builds
itself. But PMM 3 can run Nomad on its own — server *and* a client inside every
pmm-agent. This doc shows what the topology would look like if we used that instead, what
PMM already does for you, and the three things that block it today.

**As of:** 2026-08-03
**Derived from:** `pmm/` — `managed/services/nomad/{nomad.go,server.hcl}`,
`managed/services/agents/{nomad.go,registry.go,state.go}`,
`managed/services/supervisord/supervisord.go`, `managed/testdata/supervisord.d/nomad-server.ini`,
`agent/agents/supervisor/supervisor.go`, `agent/config/config.go`, `version/features.go`,
`build/ansible/roles/nginx/files/conf.d/pmm.conf`; `SEP/` — `settings.yaml`,
`app/tasks/execution/executors/nomad/models.py`; plus live probing of the running
`omtest1` pmm-client containers on this machine.

**Status: this is a design exploration, not a plan.** Nothing here is implemented.
`pmm/.env` on this machine has `PMM_ENABLE_NOMAD=0`.

> **Superseded in part, as of 2026-08-06.** This *is* how the local stack now works:
> `pmm/.env` sets `PMM_ENABLE_NOMAD=1`, SEP's `TASKS.NOMAD.ENDPOINT` points at
> `https://admin:admin@127.0.0.1:8443/nomad`, and the `psmdb/` sandbox nodes each register
> a Nomad client with `raw_exec` healthy. Two of the three blockers below turned out to be
> narrower than stated: the missing `python3`/`pbm` was a property of the **stock
> pmm-client image**, not of the design — `psmdb/Dockerfile` installs them alongside
> pmm-client in the same container — and the cgroups "hard stop" is contradicted by
> measurement: the clients start and register given `cgroup: host` plus a writable
> `/sys/fs/cgroup` (see `psmdb/scripts/run-pmm-agent.sh`). Read
> [`topology.md`](topology.md) Parts 3 and 7 for the current shape; the reasoning below is
> still the best account of *how* PMM distributes the client and its certificates.

---

## 1. The short answer

If it worked, the executor fleet would stop being **one container you maintain** and
become **every host PMM already monitors** — with certificates issued and distributed for
you, automatically, over the connection the agents already hold open.

That is a genuinely better architecture, and PMM has already built most of it. Three
things block it today, and one of them is a hard stop on containerized agents.

---

## 2. Today, and the alternative

**Today** — one shared executor that has to be network-joined to everything it touches:

```mermaid
flowchart LR
    SEP["SEP backend<br/>on the host"]
    NOM["om-nomad container<br/>server + client in one<br/>we build this image"]
    subgraph CL["omtest1-mongo-terraform network"]
        M1["mongos00"]
        M2["shard00svr0"]
        M3["…"]
    end

    SEP -->|"http 127.0.0.1:4646"| NOM
    NOM -->|"raw_exec runs here,<br/>connects out by container name"| M1
    NOM --> M2
    NOM --> M3
```

**The alternative** — the job runs on the host that owns the database:

```mermaid
flowchart LR
    SEP["SEP backend"]

    subgraph P["pmm-server container"]
        NS["nomad-server<br/>http 4646 · rpc 4647<br/>mTLS on both"]
        NGX["nginx :8443<br/>proxies /nomad/"]
        MGD["pmm-managed<br/>issues the certs"]
    end

    subgraph H1["monitored host A"]
        A1["pmm-agent"]
        C1["nomad client<br/>raw_exec only"]
        D1[("database")]
        A1 --- C1
        C1 --> D1
    end

    subgraph H2["monitored host B"]
        A2["pmm-agent"]
        C2["nomad client"]
        D2[("database")]
        A2 --- C2
        C2 --> D2
    end

    SEP -->|"either mTLS to 4646<br/>or via /nomad/ on 8443"| NGX
    NGX --> NS
    MGD -->|"certs + config over the<br/>existing agent channel"| A1
    MGD --> A2
    C1 -->|"rpc 4647, mTLS"| NS
    C2 -->|"rpc 4647, mTLS"| NS
```

The difference that matters: in the first picture one container must be able to reach
every database, so it needs a network join per environment (`./om psmdb-link`). In the
second, the work happens **on the machine that already has the database**, so there is
nothing to join.

---

## 3. What PMM already builds for you

Setting `PMM_ENABLE_NOMAD=1` flips `settings.Nomad.Enabled`, and then several things
happen without further configuration.

**A Nomad server appears inside the PMM container.** pmm-managed writes a supervisord
program and reloads:

```ini
[program:nomad-server]
priority = 5
command = /usr/local/percona/pmm/tools/nomad agent -config /srv/nomad/nomad-server-<pmm public address>.hcl
```

From `server.hcl`, the shape of that server:

| Setting | Value | Why it matters |
| --- | --- | --- |
| `ports.http` / `ports.rpc` | 4646 / 4647 | 4647 is what the clients dial |
| `advertise.rpc` | the **PMM public address** | so this must be set, and reachable from every monitored host |
| `server.bootstrap_expect` | 1 | single server, no HA |
| `tls.http` / `tls.rpc` | both `true` | everything is mTLS, with `verify_server_hostname = true` |
| plugins | **only `raw_exec`** | the same driver SEP already uses |
| `datacenter` / `name` | `PMM Deployment` / `PMM Server` | |
| `telemetry` | prometheus metrics on | allocation and node metrics scrape-able |

**PMM becomes its own certificate authority.** On enable, pmm-managed shells out to the
bundled Nomad binary and creates a CA plus a server and client certificate, valid 10000
days, into `/srv/nomad/certs/`:

```
nomad tls ca create -days 10000
nomad tls cert create -server -domain <pmm public address> -region global …
nomad tls cert create -client -region global …
```

**And here is the elegant part — the certificates ride the channel that already exists.**
No cert distribution to build, no secret to copy around:

```mermaid
sequenceDiagram
    participant A as pmm-agent on a host
    participant M as pmm-managed
    participant N as nomad-server

    A->>M: connect (the normal monitoring stream)
    M->>M: is this agent ≥ 3.2.0?<br/>create a "nomad-agent" for it if absent
    M->>A: SetStateRequest, type NOMAD_AGENT<br/>TextFiles: nomadConfig, caCert, certFile, keyFile
    A->>A: write files, start the nomad binary<br/>as a supervised child process
    A->>M: StateChanged — running, listen port N
    A->>N: rpc 4647, mTLS — "I am a client, give me work"
```

The client config pmm-managed generates is deliberately narrow:

| Setting | Value |
| --- | --- |
| `client.servers` | `<server_host>:4647` — filled in by PMM |
| `addresses.http` / `rpc` | `127.0.0.1` — the client's own API is not exposed |
| `ports.rpc` | 4649 |
| `driver.allowlist` | `raw_exec` |
| `driver.denylist` | `docker,qemu,java,exec,storage,podman,containerd` |
| `client.meta` | `pmm-agent = "1"` **plus every PMM label of that node** |
| `server.enabled` | `false` |
| GC thresholds | configurable from PMM (`GCInterval`, `GCDiskUsageThreshold`, `GCMaxAllocs`, …) |

That `meta` block deserves attention: **PMM's node labels become Nomad node metadata.**
A job could then be constrained to, say, `environment = prod` or a particular cluster,
using labels the operator already maintains in PMM. SEP's current "Execution Host"
dropdown is a flat list of one container.

**nginx already exposes it.** `location /nomad/` proxies to `https://127.0.0.1:4646`,
with a 319s read timeout and buffering off — deliberately set up for Nomad's blocking
queries and log streaming. Like every other location it inherits `auth_request`, so it is
gated on PMM authentication.

---

## 4. The fleet effect

The enrolment is automatic. In `registry.go`, every pmm-agent that connects gets a
`nomad-agent` created for it if one does not already exist, gated only on version:

```go
if !pmmAgentVersion.IsFeatureSupported(version.NomadAgentSupportVersion) {  // 3.2.0-0
    return nil
}
```

The sandbox's clients here run **pmm-agent 3.9.0**, so all 11 would qualify. Enabling the
flag would turn this:

```mermaid
flowchart LR
    subgraph AGENTS["the 11 omtest1-cl01 pmm-clients"]
        direction TB
        a1["mongos00 · nomad client"]
        a2["mongos01 · nomad client"]
        a3["cfg00-02 · 3 nomad clients"]
        a4["shard00 svr0/svr1/arb0 · 3"]
        a5["shard01 svr0/svr1/arb0 · 3"]
    end

    NS["nomad-server<br/>inside pmm-server"]
    SEP["SEP<br/>'Execution Host' dropdown<br/>would list 11 hosts, not 1"]

    a1 -->|"rpc 4647"| NS
    a2 --> NS
    a3 --> NS
    a4 --> NS
    a5 --> NS
    SEP --> NS
```

…into an 11-node executor fleet, each node sitting next to the database it would act on,
each labelled with its PMM cluster and environment. No `psmdb-link`, no network joins, no
randomised-port problem.

That is the prize. Now the obstacles.

---

## 5. What SEP would need — mostly configuration

SEP looks like it was written in anticipation of this. Its Nomad settings already carry
everything an mTLS server needs:

```yaml
NOMAD:
  ENDPOINT: http://127.0.0.1:4646
  SECURE: False
  VERIFY_SSL: True
  SSL_KEYFILE: null
  SSL_CERTFILE: null
  SSL_CAFILE: null
  CERT_EXPIRY_WARN_DAYS: 7
  CHECK_CERT_EXPIRY_INTERVAL: "1 days"   # a Celery beat task watches PEM expiry
```

…and the client builder passes them straight through — `secure`, `verify` (the CA path),
and `cert=(certfile, keyfile)`. There is even a scheduled task that warns when the CA or
client PEM is nearing expiry. Nobody writes that for a plaintext local Nomad.

So there are two routes, with different costs:

| Route | How | SEP change needed |
| --- | --- | --- |
| **Direct mTLS** to `4646` | `ENDPOINT: https://<pmm>:4646`, `SECURE: True`, point the three `SSL_*` at PMM's client cert, key and CA | **None** — pure config. But you must obtain those three files; see blocker 3 |
| **Via nginx** `/nomad/` on 8443 | `ENDPOINT: https://<pmm>:8443/nomad/` — nginx terminates TLS and holds the client cert itself | **Small.** The path is behind PMM's `auth_request`, so requests need an `Authorization: Bearer` header. SEP's Nomad client has no setting for one — `python-nomad`'s `token` sets `X-Nomad-Token`, the wrong header. It does accept a `session`, so passing a pre-configured `requests.Session` would do it |

The second route is more appealing than it first looks: SEP **already holds a PMM service
account token** for inventory sync, and it would reuse that same credential for
dispatch. One secret instead of a certificate bundle.

---

## 6. What blocks it today

### Blocker 1 — the pmm-client image cannot run SEP's payloads

Verified on this machine, inside `omtest1-cl01-mongos00-pmm-client`:

```
python3    MISSING
pip3       MISSING
pbm        MISSING
mongodump  MISSING
/usr/local/percona/pmm/tools/nomad          ← present
```

So the fleet would happily accept jobs it cannot execute. SEP's run-python payloads
pip-install their requirements at runtime, and the Mongo backup payloads shell out to the
PBM CLI. This is precisely why [`../nomad/Dockerfile`](../nomad/Dockerfile) exists — it is
Oracle Linux 9 based specifically so `pbm`, which links against krb5/gssapi, installs
from Percona's el9 packages.

**Fixing this means changing what ships in the pmm-client image**, which is a PMM product
decision, not a config change.

### Blocker 2 — cgroups, on any containerized agent

This one is a hard stop, and also verified here:

```
$ grep " /sys/fs/cgroup " /proc/mounts        # inside a pmm-client container
cgroup /sys/fs/cgroup cgroup2 ro,nosuid,nodev,noexec,relatime 0 0
$ touch /sys/fs/cgroup/test
touch: cannot touch '/sys/fs/cgroup/test': Read-only file system
```

A Nomad client needs to manage its own cgroup subtree. pmm-agent knows this can fail and
handles it quietly — `supervisor.go` detects the failed initialization and calls
`handleNomadAgent`, which logs a warning, reports status `DONE`, and carries on:

```
WARN  Cannot start Nomad Agent: cgroups are not writable.
```

So on this machine, enabling the flag would create 11 `nomad-agent` entries in PMM's
inventory and **all 11 would fail to start**, with nothing louder than a log line. SEP's
host dropdown would be empty again.

Note what the workspace's own container does to avoid this — `cgroup: host` plus a
writable `/sys/fs/cgroup` bind mount, both documented as required in
[`../docker-compose.yml`](../docker-compose.yml). A package-installed pmm-agent on a real
VM has no such problem. **The blocker is containerized agents specifically** — which is
what the sandbox deploys, and a common way to run pmm-client generally.

### Blocker 3 — no supported way to get a client certificate

`GetCACert()`, `GetClientCert()` and `GetClientKey()` exist in pmm-managed, but nothing
exposes them over the API — `agents.proto` is the only place in `api/` that mentions
Nomad at all, and only for the agent *type*. The files live at `/srv/nomad/certs/` inside
the container.

For a dev experiment you can `docker cp` them out. There is no production path, and the
files are a CA-signed client identity for the whole region — not something to hand around
casually. This is the strongest argument for the nginx route in §5.

### Blocker 4 — reachability and public address

The server advertises its RPC endpoint as PMM's **public address** — the config filename
itself is keyed on it (`nomad-server-<address>.hcl`). So `PMM_PUBLIC_ADDRESS` must be set
correctly, and **port 4647 must be reachable from every monitored host**. That inverts
PMM's usual security story, where agents only ever dial *out* to 8443 and PMM never needs
a route back in. Now every agent needs a second outbound path, on a second port.

Locally, `pmm/docker-compose.dev.yml` publishes neither 4646 nor 4647, so you would add
those — and note the host's 4646 is already taken by `om-nomad`.

### And one thing that is not a blocker but is a decision

`raw_exec` runs commands with the privileges of the Nomad client process, which is
pmm-agent's. Enabling this turns a monitoring agent into a general-purpose command
executor on every database host in the estate. The narrow `driver.allowlist` limits *how*
work runs, not *what* it can do. That is a security conversation to have deliberately.

---

## 7. The trade

| | `om-nomad` container (today) | PMM's built-in Nomad |
| --- | --- | --- |
| Executor hosts | 1 | every monitored host, automatically |
| Enrolment | manual — build image, join networks | automatic on agent connect (≥ 3.2.0) |
| Certificates | none, plaintext HTTP on localhost | PMM-issued mTLS, distributed over the agent channel |
| Host targeting | one entry in a dropdown | Nomad node `meta` carries PMM labels |
| Reaching the database | executor must join each Docker network | job runs on the host that owns it |
| Payload dependencies | we control the image — python3, pbm present | **missing from pmm-client** |
| Works with containerized agents | yes, with `cgroup: host` | **no — cgroups read-only** |
| SEP changes | none, it is the default | none for direct mTLS; small for the nginx route |
| Network exposure | localhost only | agents need outbound 4647 to PMM |
| Ships today | yes | no |

---

## 8. If you want to try it

Expect it to fail at blocker 2 — the point of trying is to see *where* it stops.

```bash
# 1. enable it and give PMM a public address it can advertise
#    in pmm/.env:
#      PMM_ENABLE_NOMAD=1
#      PMM_PUBLIC_ADDRESS=<address the agents can reach>
./om restart pmm

# 2. confirm the server came up inside the container
docker exec pmm-server supervisorctl status nomad-server
docker exec pmm-server ls /srv/nomad/certs/
docker exec pmm-server tail /srv/logs/nomad-server.log

# 3. watch the clients try, and fail
docker logs omtest1-cl01-mongos00-pmm-client 2>&1 | grep -i nomad
#   expect: "Cannot start Nomad Agent: cgroups are not writable."

# 4. the inventory entries will exist regardless
#    (11 nomad-agent rows, one per pmm-agent)
```

To get past step 3 you would need pmm-client containers started with `cgroup: host` and a
writable `/sys/fs/cgroup` — which means changing the sandbox's Terraform, not PMM. A
package-installed pmm-agent on a VM would be the cleaner test bed. And even then, blocker
1 means only payloads that need nothing but a shell would actually run.

---

## 9. Where this leaves things

PMM has built the hard parts — the server, its own CA, automatic per-agent enrolment,
cert distribution over an existing channel, an authenticated proxy path, and PMM labels
surfacing as Nomad node metadata. SEP, for its part, already has the mTLS settings and a
certificate-expiry watchdog. The two halves were clearly built toward each other.

What is missing is unglamorous and entirely outside SEP: **the pmm-client image needs the
tools the payloads call, containerized agents need writable cgroups, and a third party
needs a supported way to authenticate.** Until then the standalone `om-nomad` container is
not a workaround for a missing feature — it is the only thing that can actually execute a
SEP payload.

**Related:** [topology.md §6](topology.md#part-6--how-a-job-actually-runs) for how
dispatch works today · [containers.md §5](containers.md#5-the-link-trick) for the network
join this would make unnecessary · [`../notes/sep-dev-quickstart.md`](../notes/sep-dev-quickstart.md)
for the executor's setup as it stands.
