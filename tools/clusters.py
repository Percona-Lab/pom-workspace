"""Discover the MongoDB nodes of a PSMDB cluster.

Shared by the ``tools/`` scripts that need to address every mongod/mongos of an
environment. Kept separate so there is one definition of "what counts as a node"
and one place to fix it when the stack changes its container naming.

The clusters come from ``psmdb/compose.yaml`` — ``./om start sharded-cluster``.
One container per node (mongod/mongos + pbm-agent + pmm-agent together), **no
published ports**, and every fact declared as an environment variable: ``ROLE``,
``MONGO_PORT``, ``REPLSET``, ``CLUSTER_ROLE``, ``RS_MEMBERS``.

An environment is addressed by the prefix all of its containers share, which is
the compose profile name (``sharded-cluster``). ``environments()`` lists what is
running.
"""

from __future__ import annotations

import json
import re
import subprocess

#: Container ports that identify a mongod/mongos.
MONGO_PORTS = {"27017", "27018", "27019"}

#: Sidecars and infrastructure deployed under the same environment prefix.
NOT_MONGO = re.compile(r"pbm-agent|pbm-cli|pmm-server|minio")

#: Arbiter containers, named ``<cluster>-shard00arb0`` / ``<rs>-arb0``.
ARBITER = re.compile(r"arb\d*$")

#: Compose project name of psmdb/compose.yaml (its ``name:`` key).
PSMDB_PROJECT = "psmdb-sandbox"

#: Credentials to assume when the containers do not declare their own.
FALLBACK_CREDENTIALS = ("root", "percona")

#: One line of compact JSON per container. Everything the discovery needs comes
#: from this single call -- inspecting four fields per container separately made
#: an 11-node environment noticeably slow.
INSPECT_FORMAT = (
    '{"name":{{json .Name}},'
    '"env":{{json .Config.Env}},'
    '"labels":{{json .Config.Labels}},'
    '"ports":{{json .NetworkSettings.Ports}},'
    '"networks":{{json .NetworkSettings.Networks}}}'
)


def docker(*args: str) -> str:
    """Run a docker command, returning stripped stdout ("" on failure)."""
    p = subprocess.run(["docker", *args], capture_output=True, text=True)
    return p.stdout.strip() if p.returncode == 0 else ""


def inspect(names: list[str]) -> dict[str, dict]:
    """Inspect containers in one call, keyed by container name.

    Keyed by the name docker reports rather than by input position: a container
    that stops between the ``ps`` and the ``inspect`` is skipped with a message
    on stderr, which would shift every later line onto the wrong container.
    """
    if not names:
        return {}
    records = {}
    for line in docker("inspect", *names, "-f", INSPECT_FORMAT).splitlines():
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        records[rec["name"].lstrip("/")] = rec
    return records


def _environ(rec: dict) -> dict[str, str]:
    """Container environment as a dict."""
    out = {}
    for item in rec.get("env") or []:
        key, _, value = item.partition("=")
        out[key] = value
    return out


def _published(rec: dict) -> tuple[str | None, str | None]:
    """The (container, host) mongo port pair, if one is published.

    Only bound ports are considered. The psmdb image exposes 27017-27019
    unconditionally, so an unfiltered scan would happily report a config server
    as running on 27017.
    """
    for spec, bindings in (rec.get("ports") or {}).items():
        port = spec.split("/")[0]
        if port in MONGO_PORTS and bindings:
            return port, bindings[0]["HostPort"]
    return None, None


def _address(rec: dict) -> str:
    """First bridge address of the container ("" if it has none)."""
    for net in (rec.get("networks") or {}).values():
        if net.get("IPAddress"):
            return net["IPAddress"]
    return ""


def _arbiter(name: str, env: dict[str, str]) -> bool:
    """Whether this node is an arbiter.

    ``RS_MEMBERS`` marks them explicitly (``<host>:<port>:arbiter``); the name
    pattern is the fallback for a node that does not declare its members.
    """
    for member in (env.get("RS_MEMBERS") or "").split(","):
        if member.split(":")[0] == name:
            return member.endswith(":arbiter")
    return bool(ARBITER.search(name))


def _role(env: dict[str, str], rs: str, arbiter: bool) -> str:
    """Classify a node: mongos, arbiter, config, shard, replica or standalone."""
    # psmdb/compose.yaml states all of this outright.
    if env.get("ROLE") == "mongos":
        return "mongos"
    if arbiter:
        return "arbiter"
    if env.get("CLUSTER_ROLE") == "configsvr":
        return "config"
    if env.get("CLUSTER_ROLE") == "shardsvr":
        return "shard"
    # A replica set member outside a sharded cluster, or no replication at all.
    return "replica" if rs else "standalone"


def discover(prefix: str) -> list[dict]:
    """Return the running mongod/mongos containers of an environment.

    :param prefix: Environment prefix — a compose profile name such as
        ``sharded-cluster``.
    :return: One dict per node, sorted by container name, with keys:
        ``name``, ``internal`` (the port mongod/mongos listens on),
        ``host_port`` (published port, ``None`` when nothing is published),
        ``rs`` (replica set name; empty for mongos and standalone), ``ip``
        (bridge address), ``arbiter``, ``role`` and ``env``.
    """
    listing = docker("ps", "--filter", f"name={prefix}-", "--format", "{{.Names}}")
    # The docker filter matches substrings, so anchor the prefix ourselves.
    names = [n for n in listing.splitlines()
             if n.startswith(f"{prefix}-") and not NOT_MONGO.search(n)]

    nodes = []
    for name, rec in sorted(inspect(names).items()):
        env = _environ(rec)
        container_port, host_port = _published(rec)
        # MONGO_PORT first: with nothing published there is no port to infer
        # from, and it is authoritative when both are available.
        internal = env.get("MONGO_PORT") or container_port
        if not internal:
            continue
        rs = env.get("REPLSET") or (rec.get("labels") or {}).get("replsetName") or ""
        arbiter = _arbiter(name, env)
        nodes.append({
            "name": name,
            "internal": internal,
            "host_port": host_port,
            "rs": rs,
            "ip": _address(rec),
            "arbiter": arbiter,
            "role": _role(env, rs, arbiter),
            "env": env,
        })
    return nodes


def role(node: dict) -> str:
    """Role of a node as classified by :func:`discover`."""
    return node["role"]


def credentials(nodes: list[dict]) -> tuple[str, str]:
    """Root credentials the containers declare, else :data:`FALLBACK_CREDENTIALS`."""
    for node in nodes:
        user = node["env"].get("MONGO_ROOT_USER")
        password = node["env"].get("MONGO_ROOT_PASSWORD")
        if user and password:
            return user, password
    return FALLBACK_CREDENTIALS


def environments() -> list[str]:
    """Return the prefixes of every PSMDB cluster currently running."""
    found = set()

    listing = docker("ps", "--filter", f"label=com.docker.compose.project={PSMDB_PROJECT}",
                     "--format", "{{.Names}}")
    names = [n for n in listing.splitlines() if not NOT_MONGO.search(n)]
    for name, rec in inspect(names).items():
        # PMM_CLUSTER is set to the compose profile name on every node. Stripping
        # the trailing role component of the container name gives the same answer
        # and covers a node that predates the label.
        found.add(_environ(rec).get("PMM_CLUSTER") or name.rsplit("-", 1)[0])

    return sorted(found)
