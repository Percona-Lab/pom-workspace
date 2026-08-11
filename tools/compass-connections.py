#!/usr/bin/env python3
"""Manage MongoDB Compass connections for the workspace's PSMDB clusters.

Hand-saved Compass favourites go stale on every redeploy:
``psmdb/compose.yaml`` (``./om start sharded-cluster``) hands out fresh bridge
addresses and publishes no host ports at all. This regenerates the favourites
from the running containers instead of maintaining them by hand.

    ./tools/compass-connections.py add                 every running environment
    ./tools/compass-connections.py add sharded-cluster  just one
    ./tools/compass-connections.py envs                 what is running
    ./tools/compass-connections.py list                 show what is saved
    ./tools/compass-connections.py remove sharded-cluster
    ./tools/compass-connections.py hosts --apply        /etc/hosts, in place

An environment is named by the prefix its containers share, which is the compose
profile (``standalone``, ``replicaset-single``, ``replicaset-cluster``,
``sharded-cluster``).

Two kinds of entry are written, because they fail in different ways:

* ``(direct)``       one node, ``directConnection=true``, addressed the way that
                     needs no name resolution: ``127.0.0.1:<published port>``
                     where one is published, the container's bridge
                     address where it does not. Works with no ``/etc/hosts``:
                     nothing is rediscovered, so no container name is resolved.
* ``(replica set)``  container hostnames plus ``replicaSet=``. **Requires** the
                     ``hosts`` block. Replica set members advertise themselves by
                     container name and the driver reconnects to whatever they
                     advertise, so an address-only seed is not enough.

Credentials come from the containers themselves (``MONGO_ROOT_USER`` /
``MONGO_ROOT_PASSWORD``, which psmdb/compose.yaml sets on every node), with a
built-in fallback pair for a node that declares neither. ``--user`` /
``--password`` override either.

Ownership is tracked without touching Compass's schema: a connection is "ours"
only if its id equals ``uuid5(NAMESPACE, favourite-name)``. Hand-made connections
have random ids and can never collide, so ``remove`` cannot delete them even if
the names look similar.

Compass must be closed for add/remove. It holds this directory in memory and
rewrites it on exit, which would silently undo any change made underneath it.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import time
import uuid

from clusters import credentials, discover, environments  # tools/clusters.py

#: Namespace for deterministic connection ids. Changing it orphans every
#: previously written entry (``remove`` would no longer recognise them).
NAMESPACE = uuid.UUID("6f9619ff-8b86-d011-b42d-00c04fc964ff")

DEFAULT_DIR = pathlib.Path.home() / ".config/MongoDB Compass/Connections"

HOSTS_FILE = pathlib.Path("/etc/hosts")


def is_compass(comm: str) -> bool:
    """Whether a process name is Compass's.

    Separators are dropped before matching because the name varies by build and
    the difference is invisible in ``ps`` output: the packaged Linux app reports
    ``MongoDB Compass`` (a *space*), other builds ``mongodb-compass``. Matching
    the hyphenated spellings alone silently accepted every running Compass on
    this machine, which is how a "Compass must be closed" guard came to let a
    write through.

    ``comm`` is the executable name, not the command line, so this script's own
    process (``python3``) cannot match itself.
    """
    return re.sub(r"[^a-z]", "", comm.lower()).startswith("mongodbcompass")


def compass_running() -> bool:
    """Report whether a Compass process is alive."""
    out = subprocess.run(["ps", "-eo", "comm"], capture_output=True, text=True).stdout
    return any(is_compass(line) for line in out.splitlines())


def resolve_envs(requested: list[str]) -> list[str]:
    """Environments to act on: the ones asked for, or everything running."""
    if requested:
        return requested
    found = environments()
    if not found:
        sys.exit("no PSMDB cluster is running — start one with ./om start <topology>")
    return found


def address(node: dict) -> str:
    """Address a single node without relying on name resolution.

    A published port is preferred because it survives the container getting a
    different bridge address, which happens on every recreate; psmdb's nodes
    publish nothing (they only ever talk to each other and to PMM over the
    compose network), so there the bridge address is all there is. Both are
    reachable from the host on Linux.
    """
    if node["host_port"]:
        return f"127.0.0.1:{node['host_port']}"
    return f"{node['ip']}:{node['internal']}"


def build_entries(prefix: str, nodes: list[dict], user: str, password: str) -> list[tuple[str, str]]:
    """Compose the (label, connection string) pairs to save."""
    creds = f"{user}:{password}@"
    entries: list[tuple[str, str]] = []

    # Arbiters carry no user records, so authentication against them cannot
    # succeed and there is nothing to browse. Skip rather than save a broken one.
    for n in nodes:
        if n["arbiter"] or not n["ip"] and not n["host_port"]:
            continue
        entries.append((
            f"{n['name']} (direct)",
            f"mongodb://{creds}{address(n)}/?authSource=admin&directConnection=true",
        ))

    # Address-only seeds are safe here: a sharded topology keeps the seed list it
    # was given and never rediscovers peers, so no container name is ever
    # resolved. (A replica set does the opposite -- see below.) Selected by role,
    # not by "has no replica set": a standalone node has none either, and seeding
    # it as a router would produce an entry that fails on the first query.
    mongos = [n for n in nodes if n["role"] == "mongos"]
    if mongos:
        seeds = ",".join(address(m) for m in mongos)
        via = ", ".join(m["name"] for m in mongos)
        entries.append((f"{prefix} mongos (sharded cluster: {via})",
                        f"mongodb://{creds}{seeds}/?authSource=admin"))

    # These are the only entries that need /etc/hosts, and nothing can change
    # that: the driver runs `hello`, replaces the seeds with the member list held
    # in the replica set config -- container hostnames -- and reconnects to those.
    # Seeding with addresses does not help, so the requirement is in the name.
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


def managed_for(directory: pathlib.Path, env: str | None) -> list[tuple[pathlib.Path, str]]:
    """Return the (path, name) of every managed connection, optionally one env's."""
    found = []
    for path in sorted(directory.glob("*.json")):
        name = owned(path)
        if name and (env is None or name.startswith((f"{env}-", f"{env} "))):
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


def nodes_or_die(env: str) -> list[dict]:
    nodes = discover(env)
    if not nodes:
        sys.exit(f"no running mongo containers matching '{env}-' — is the environment up?\n"
                 f"running environments: {', '.join(environments()) or 'none'}")
    return nodes


def cmd_add(args, directory: pathlib.Path) -> int:
    require_closed()
    print(f"backup: {backup(directory)}")
    total = 0
    for env in resolve_envs(args.envs):
        nodes = nodes_or_die(env)
        user, password = credentials(nodes)
        entries = build_entries(env, nodes, args.user or user, args.password or password)
        print(f"{env} ({len(nodes)} node(s), user '{args.user or user}'):")
        # Refresh, not merge. Ids are derived from the label, so a renamed or
        # departed node would otherwise linger forever as an unreachable
        # duplicate -- and every psmdb node changes address when it is recreated.
        stale = {p for p, _ in managed_for(directory, env)} - {
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
            print(f"  ({len(skipped)} arbiter(s) skipped: {', '.join(skipped)} — no users to authenticate)")
        total += len(entries)
    print(f"\n{total} favourite(s) saved. Replica-set entries need the hosts block:")
    print(f"  {sys.argv[0]} hosts --apply")
    return 0


def cmd_remove(args, directory: pathlib.Path) -> int:
    require_closed()
    # No environment means every managed connection, including those of an
    # environment that has already been torn down -- which is the only way to
    # reach them, since discovery cannot see what is gone.
    targets = []
    for env in args.envs or [None]:
        targets += managed_for(directory, env)
    if not targets:
        print("nothing to remove" + (f" for '{', '.join(args.envs)}'" if args.envs else ""))
        return 0
    print(f"backup: {backup(directory)}")
    for path, name in targets:
        path.unlink()
        print(f"  - {name}")
    print(f"\n{len(targets)} favourite(s) removed.")
    return 0


def cmd_list(args, directory: pathlib.Path) -> int:
    rows = []
    for env in args.envs or [None]:
        for path, name in managed_for(directory, env):
            cs = json.loads(path.read_text())["connectionInfo"]["connectionOptions"]["connectionString"]
            rows.append((name, re.sub(r"://[^@]*@", "://***@", cs)))
    if not rows:
        print("no managed connections" + (f" for '{', '.join(args.envs)}'" if args.envs else ""))
        return 0
    width = max(len(n) for n, _ in rows)
    for name, cs in rows:
        print(f"  {name:<{width}}  {cs}")
    print(f"\n{len(rows)} managed favourite(s) in {directory}")
    return 0


def cmd_envs(args, directory: pathlib.Path) -> int:
    found = environments()
    if not found:
        print("no PSMDB cluster running")
        return 0
    for env in found:
        nodes = discover(env)
        roles = ", ".join(sorted({n["role"] for n in nodes}))
        print(f"  {env:<20} {len(nodes):>2} node(s)  {roles}")
    return 0


def hosts_block(env: str, nodes: list[dict]) -> str:
    """The /etc/hosts block for an environment, delimited so it can be replaced.

    Containers on a Docker bridge are routable from the host on Linux, so this is
    what makes ``replicaSet=`` connections work: the names members advertise then
    resolve to something reachable.
    """
    lines = [f"# BEGIN {env}"]
    lines += [f"{n['ip']} {n['name']}" for n in nodes if n["ip"]]
    lines.append(f"# END {env}")
    return "\n".join(lines) + "\n"


def strip_blocks(text: str, envs: list[str]) -> str:
    """Remove every ``# BEGIN <env>`` .. ``# END <env>`` block for these envs.

    Every block, not the first: appending with ``sudo tee -a`` (what this script
    used to tell you to do) leaves one stale copy per redeploy, and the earlier
    one wins name resolution.
    """
    markers = {f"# BEGIN {e}" for e in envs}
    ends = {f"# END {e}" for e in envs}
    out, skipping = [], False
    for line in text.splitlines():
        if line.strip() in markers:
            skipping = True
            continue
        if skipping:
            skipping = line.strip() not in ends
            continue
        out.append(line)
    return "\n".join(out).rstrip("\n") + "\n"


def write_hosts(path: pathlib.Path, text: str) -> None:
    """Write the hosts file, escalating with sudo only when necessary."""
    stamp = time.strftime("%Y%m%d-%H%M%S")
    dest = path.with_name(f"{path.name}.bak-{stamp}")
    if os.access(path, os.W_OK):
        shutil.copy2(path, dest)
        path.write_text(text)
    else:
        print(f"writing {path} needs root — sudo may prompt")
        if subprocess.run(["sudo", "cp", "-p", str(path), str(dest)]).returncode != 0:
            sys.exit(f"could not back up {path}")
        p = subprocess.run(["sudo", "tee", str(path)], input=text,
                           capture_output=True, text=True)
        if p.returncode != 0:
            sys.exit(f"could not write {path}: {p.stderr.strip()}")
    print(f"backup: {dest}")


def cmd_hosts(args, directory: pathlib.Path) -> int:
    if args.remove:
        # Named explicitly, never defaulted: the whole point is an environment
        # that is *gone*, so discovery cannot supply the list.
        if not args.envs:
            sys.exit("name the environments to remove, e.g. hosts --remove sharded-cluster")
        path: pathlib.Path = args.hosts_file
        before = path.read_text()
        after = strip_blocks(before, args.envs)
        if after == before:
            print(f"no block for {', '.join(args.envs)} in {path}")
            return 0
        write_hosts(path, after)
        dropped = len(before.splitlines()) - len(after.splitlines())
        print(f"  {', '.join(args.envs)}: {dropped} line(s) dropped")
        return 0

    envs = resolve_envs(args.envs)
    blocks = {env: hosts_block(env, nodes_or_die(env)) for env in envs}
    if not args.apply:
        for block in blocks.values():
            print(block, end="")
        print(f"\n# apply in place with: {sys.argv[0]} hosts --apply", file=sys.stderr)
        return 0
    path: pathlib.Path = args.hosts_file
    text = strip_blocks(path.read_text(), envs) + "".join(blocks.values())
    write_hosts(path, text)
    for env, block in blocks.items():
        names = [line.split()[1] for line in block.splitlines() if not line.startswith("#")]
        print(f"  {env}: {len(names)} name(s)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Manage Compass connections for the workspace's PSMDB clusters.",
        epilog="With no environment named, every running one is used. "
               "Compass must be closed for add/remove.",
    )
    ap.add_argument("--dir", type=pathlib.Path, default=DEFAULT_DIR,
                    help="Compass connections directory (default: %(default)s)")
    sub = ap.add_subparsers(dest="command", required=True)

    p = sub.add_parser("add", help="create or refresh favourites")
    p.add_argument("envs", nargs="*", help="environments, e.g. sharded-cluster")
    p.add_argument("--user", help="override the mongodb user the containers declare")
    p.add_argument("--password", help="override the password the containers declare")
    p.set_defaults(func=cmd_add)

    p = sub.add_parser("remove", help="delete managed favourites")
    p.add_argument("envs", nargs="*", help="limit to these environments")
    p.set_defaults(func=cmd_remove)

    p = sub.add_parser("list", help="show managed favourites")
    p.add_argument("envs", nargs="*", help="limit to these environments")
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("envs", help="show the PSMDB clusters that are running")
    p.set_defaults(func=cmd_envs)

    p = sub.add_parser("hosts", help="print or apply the /etc/hosts block")
    p.add_argument("envs", nargs="*", help="limit to these environments")
    p.add_argument("--apply", action="store_true",
                   help="rewrite the block in place (replaces any existing one)")
    p.add_argument("--remove", action="store_true",
                   help="delete the named environments' blocks (for a torn-down environment)")
    p.add_argument("--hosts-file", type=pathlib.Path, default=HOSTS_FILE,
                   help="file to rewrite (default: %(default)s)")
    p.set_defaults(func=cmd_hosts)

    args = ap.parse_args()
    directory: pathlib.Path = args.dir
    # `hosts` and `envs` only read docker, so do not make them fail on a machine
    # where Compass has never run.
    if args.command in ("add", "remove", "list") and not directory.is_dir():
        sys.exit(f"no Compass connections directory at {directory}")
    return args.func(args, directory)


if __name__ == "__main__":
    sys.exit(main())
