#!/usr/bin/env python3
"""Manage MongoDB Compass connections for a PSMDB sandbox environment.

The sandbox (``mongo_terraform_ansible``) randomises published host ports on every
deploy and gives containers fresh bridge IPs, so hand-saved Compass connections
go stale the moment an environment is rebuilt. This regenerates them from the
running containers instead.

    ./tools/compass-connections.py add omtest1        # create/refresh favourites
    ./tools/compass-connections.py list               # show what is saved
    ./tools/compass-connections.py remove omtest1     # delete them again
    ./tools/compass-connections.py hosts omtest1      # /etc/hosts block

Two kinds of entry are written, because they fail in different ways:

* ``(direct)``       ``127.0.0.1:<published port>`` with ``directConnection=true``.
                     Works with no ``/etc/hosts``: nothing is rediscovered, so no
                     container hostname is ever resolved.
* ``(replica set)``  container hostnames plus ``replicaSet=``. **Requires** the
                     ``hosts`` block below. Replica set members advertise
                     themselves by container name and the driver reconnects to
                     whatever they advertise, so a loopback seed is not enough.

Ownership is tracked without touching Compass's schema: a connection is "ours"
only if its id equals ``uuid5(NAMESPACE, favourite-name)``. Hand-made connections
have random ids and can never collide, so ``remove`` cannot delete them even if
the names look similar.

Compass must be closed. It holds this directory in memory and rewrites it on
exit, which would silently undo any change made underneath it.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import shutil
import subprocess
import sys
import time
import uuid

from sandbox import discover  # tools/sandbox.py, alongside this script

#: Namespace for deterministic connection ids. Changing it orphans every
#: previously written entry (``remove`` would no longer recognise them).
NAMESPACE = uuid.UUID("6f9619ff-8b86-d011-b42d-00c04fc964ff")

DEFAULT_DIR = pathlib.Path.home() / ".config/MongoDB Compass/Connections"


def compass_running() -> bool:
    """Report whether a Compass process is alive.

    Matches the packaged binary and the Electron main process, but not this
    script's own command line (which contains the word "compass" too).
    """
    out = subprocess.run(["ps", "-eo", "comm"], capture_output=True, text=True).stdout
    return any(line.strip().lower().startswith(("mongodb-compass", "mongodbcompass"))
               for line in out.splitlines())


def build_entries(prefix: str, nodes: list[dict], user: str, password: str) -> list[tuple[str, str]]:
    """Compose the (label, connection string) pairs to save."""
    creds = f"{user}:{password}@"
    entries: list[tuple[str, str]] = []

    # Arbiters carry no user records, so authentication against them cannot
    # succeed and there is nothing to browse. Skip rather than save a broken one.
    for n in nodes:
        if n["arbiter"]:
            continue
        entries.append((
            f"{n['name']} (direct)",
            f"mongodb://{creds}127.0.0.1:{n['host_port']}/?authSource=admin&directConnection=true",
        ))

    # Loopback seeds are safe here: a sharded topology keeps the seed list it was
    # given and never rediscovers peers, so no container name is ever resolved.
    # (A replica set does the opposite -- see below.)
    mongos = [n for n in nodes if not n["rs"]]
    if mongos:
        seeds = ",".join(f"127.0.0.1:{m['host_port']}" for m in mongos)
        via = ", ".join(m["name"] for m in mongos)
        entries.append((f"{prefix} mongos (sharded cluster: {via})",
                        f"mongodb://{creds}{seeds}/?authSource=admin"))

    # These are the only entries that need /etc/hosts, and nothing can change
    # that: the driver runs `hello`, replaces the seeds with the member list held
    # in the replica set config -- container hostnames -- and reconnects to those.
    # Seeding with IPs does not help, so the requirement is stated in the name.
    for rs in sorted({n["rs"] for n in nodes if n["rs"]}):
        seeds = ",".join(f"{n['name']}:{n['internal']}"
                         for n in nodes if n["rs"] == rs and not n["arbiter"])
        entries.append((f"{rs} (replica set, needs /etc/hosts)",
                        f"mongodb://{creds}{seeds}/?authSource=admin&replicaSet={rs}"))
    return entries


def owned(path: pathlib.Path) -> str | None:
    """Return the favourite name if this file is one we generated, else None."""
    try:
        doc = json.loads(path.read_text())
        info = doc["connectionInfo"]
        name = (info.get("favorite") or {}).get("name")
    except (OSError, ValueError, KeyError):
        return None
    if name and doc.get("_id") == str(uuid.uuid5(NAMESPACE, name)):
        return name
    return None


def managed_for(directory: pathlib.Path, env: str) -> list[tuple[pathlib.Path, str]]:
    """Return the (path, name) of every managed connection belonging to an env."""
    found = []
    for path in sorted(directory.glob("*.json")):
        name = owned(path)
        if name and name.startswith((f"{env}-", f"{env} ")):
            found.append((path, name))
    return found


def backup(directory: pathlib.Path) -> pathlib.Path:
    """Copy the connections directory aside before mutating it.

    The suffix is disambiguated because a remove immediately followed by an add
    lands inside the same second, and clobbering the first backup would defeat
    the point of taking one.
    """
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = directory.with_name(f"{directory.name}.bak-{stamp}")
    for n in range(1, 100):
        if not dest.exists():
            break
        dest = directory.with_name(f"{directory.name}.bak-{stamp}-{n}")
    shutil.copytree(directory, dest)
    return dest


def require_closed() -> None:
    if compass_running():
        sys.exit("Compass is running — close it first; it rewrites this directory on exit.")


def cmd_add(args, directory: pathlib.Path) -> int:
    require_closed()
    nodes = discover(args.env)
    if not nodes:
        sys.exit(f"no running mongo containers matching '{args.env}-' — is the environment up?")
    entries = build_entries(args.env, nodes, args.user, args.password)
    print(f"backup: {backup(directory)}")
    # Refresh, not merge. Ids are derived from the label, so a renamed or
    # departed node would otherwise linger forever as an unreachable duplicate.
    stale = {p for p, _ in managed_for(directory, args.env)} - {
        directory / f"{uuid.uuid5(NAMESPACE, label)}.json" for label, _ in entries
    }
    for path in sorted(stale):
        name = owned(path)
        path.unlink()
        print(f"  - {name}")
    for label, cs in entries:
        cid = str(uuid.uuid5(NAMESPACE, label))
        (directory / f"{cid}.json").write_text(json.dumps({
            "_id": cid,
            "connectionInfo": {
                "id": cid,
                "connectionOptions": {"connectionString": cs},
                "savedConnectionType": "favorite",
                "favorite": {"name": label},
            },
            "version": 1,
        }, indent=2))
        print(f"  + {label}")
    skipped = [n["name"] for n in nodes if n["arbiter"]]
    if skipped:
        print(f"  (skipped {len(skipped)} arbiter(s): {', '.join(skipped)} — no users to authenticate)")
    print(f"\n{len(entries)} favourite(s) saved. Replica-set entries need the /etc/hosts block:")
    print(f"  {sys.argv[0]} hosts {args.env} | sudo tee -a /etc/hosts")
    return 0


def cmd_remove(args, directory: pathlib.Path) -> int:
    require_closed()
    targets = managed_for(directory, args.env)
    if not targets:
        print(f"nothing to remove for '{args.env}'")
        return 0
    print(f"backup: {backup(directory)}")
    for path, name in targets:
        path.unlink()
        print(f"  - {name}")
    print(f"\n{len(targets)} favourite(s) removed.")
    return 0


def cmd_list(args, directory: pathlib.Path) -> int:
    rows = []
    for path in sorted(directory.glob("*.json")):
        name = owned(path)
        if name and (args.env is None or name.startswith((f"{args.env}-", f"{args.env} "))):
            cs = json.loads(path.read_text())["connectionInfo"]["connectionOptions"]["connectionString"]
            rows.append((name, re.sub(r"://[^@]*@", "://***@", cs)))
    if not rows:
        print("no managed connections" + (f" for '{args.env}'" if args.env else ""))
        return 0
    width = max(len(n) for n, _ in rows)
    for name, cs in rows:
        print(f"  {name:<{width}}  {cs}")
    print(f"\n{len(rows)} managed favourite(s) in {directory}")
    return 0


def cmd_hosts(args, directory: pathlib.Path) -> int:
    """Print an /etc/hosts block mapping container names to their bridge IPs.

    Containers on a Docker bridge are routable from the host on Linux, so this is
    what makes ``replicaSet=`` connections work: the names members advertise then
    resolve to something reachable.
    """
    nodes = discover(args.env)
    if not nodes:
        sys.exit(f"no running mongo containers matching '{args.env}-' — is the environment up?")
    print(f"# BEGIN {args.env}")
    for n in nodes:
        print(f"{n['ip']} {n['name']}")
    print(f"# END {args.env}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Manage Compass connections for a PSMDB sandbox environment.",
        epilog="Compass must be closed for add/remove.",
    )
    ap.add_argument("--dir", type=pathlib.Path, default=DEFAULT_DIR,
                    help="Compass connections directory (default: %(default)s)")
    sub = ap.add_subparsers(dest="command", required=True)

    p = sub.add_parser("add", help="create or refresh favourites for an environment")
    p.add_argument("env", help="environment prefix, e.g. omtest1")
    p.add_argument("--user", default="root", help="mongodb user (default: %(default)s)")
    p.add_argument("--password", default="percona", help="mongodb password (default: %(default)s)")
    p.set_defaults(func=cmd_add)

    p = sub.add_parser("remove", help="delete the favourites created for an environment")
    p.add_argument("env")
    p.set_defaults(func=cmd_remove)

    p = sub.add_parser("list", help="show managed favourites")
    p.add_argument("env", nargs="?", help="limit to one environment")
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("hosts", help="print the /etc/hosts block for an environment")
    p.add_argument("env")
    p.set_defaults(func=cmd_hosts)

    args = ap.parse_args()
    directory: pathlib.Path = args.dir
    if not directory.is_dir():
        sys.exit(f"no Compass connections directory at {directory}")
    return args.func(args, directory)


if __name__ == "__main__":
    sys.exit(main())
