"""Discover the MongoDB nodes of a PSMDB sandbox environment.

Shared by the ``tools/`` scripts that need to address every mongod/mongos of an
environment deployed by ``mongo_terraform_ansible``. Kept separate so there is
one definition of "what counts as a node" and one place to fix it when the
sandbox changes its container naming.

Nodes are identified by their **published container port** rather than by name,
so this keeps working for replset environments, renamed tags and arbiters, none
of which follow the sharded cluster's ``cfg``/``shard``/``mongos`` convention.
"""

from __future__ import annotations

import json
import re
import subprocess

#: Container ports that identify a mongod/mongos.
MONGO_PORTS = {"27017", "27018", "27019"}

#: Sidecars and infrastructure deployed under the same environment prefix.
NOT_MONGO = re.compile(
    r"pmm-client|pbm-agent|pbm-cli|pmm-server|minio|ycsb|renderer|watchtower|ldap"
)

#: Arbiter containers, named ``<cluster>-shard00arb0`` / ``<rs>-arb0``.
ARBITER = re.compile(r"arb\d*$")


def docker(*args: str) -> str:
    """Run a docker command, returning stripped stdout ("" on failure)."""
    p = subprocess.run(["docker", *args], capture_output=True, text=True)
    return p.stdout.strip() if p.returncode == 0 else ""


def discover(prefix: str) -> list[dict]:
    """Return the running mongod/mongos containers of an environment.

    :param prefix: Environment prefix, e.g. ``omtest1``.
    :return: One dict per node, sorted by container name, with keys:
        ``name``, ``internal`` (container port), ``host_port`` (published port),
        ``rs`` (replica set name; empty for mongos), ``ip`` (bridge address) and
        ``arbiter``.
    """
    nodes = []
    listing = docker("ps", "--filter", f"name={prefix}-", "--format", "{{.Names}}")
    for name in sorted(listing.splitlines()):
        if NOT_MONGO.search(name):
            continue
        raw = docker("inspect", name, "-f", "{{json .NetworkSettings.Ports}}")
        try:
            ports = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            continue
        internal = host = None
        for spec, bindings in (ports or {}).items():
            port = spec.split("/")[0]
            if port in MONGO_PORTS and bindings:
                internal, host = port, bindings[0]["HostPort"]
                break
        if internal is None:
            continue
        nodes.append({
            "name": name,
            "internal": internal,
            "host_port": host,
            "rs": docker("inspect", name, "-f", '{{index .Config.Labels "replsetName"}}'),
            "ip": docker("inspect", name, "-f", "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}"),
            "arbiter": bool(ARBITER.search(name)),
        })
    return nodes


def role(node: dict) -> str:
    """Classify a node as ``mongos``, ``arbiter``, ``config`` or ``shard``."""
    if not node["rs"]:
        return "mongos"
    if node["arbiter"]:
        return "arbiter"
    return "config" if node["internal"] == "27019" else "shard"
