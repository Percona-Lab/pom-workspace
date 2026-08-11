#!/usr/bin/env python3
"""Run a mongosh command against every MongoDB node of a PSMDB cluster.

    ./tools/mongo-eval.py sharded-cluster 'rs.status().myState'
    ./tools/mongo-eval.py replicaset-cluster 'db.serverStatus().connections'
    ./tools/mongo-eval.py sharded-cluster --role shard 'db.hello().isWritablePrimary'
    ./tools/mongo-eval.py sharded-cluster --rs sharded-cluster-shard00 'rs.status()'
    ./tools/mongo-eval.py replicaset-cluster --file check.js
    echo 'db.version()' | ./tools/mongo-eval.py replicaset-cluster -

The environment is a compose profile name (``standalone``,
``replicaset-single``, ``replicaset-cluster``, ``sharded-cluster``) -- see
``tools/clusters.py``.

Commands run **inside** each container via ``docker exec … mongosh``, not from
the host. That deliberately sidesteps the two things that make host-side access
awkward: no mongosh needs to be installed locally, and no ``/etc/hosts`` entries
or published ports are involved -- psmdb/compose.yaml publishes none at all, and
this keeps working after a redeploy renumbers everything.

Arbiters are skipped by default. They hold no user documents, so authenticating
against one cannot succeed -- pass ``--arbiters`` to attempt them anyway.

Exit status is 0 only if every node succeeded, so this is usable in a check:

    ./tools/mongo-eval.py sharded-cluster 'db.hello().ok' >/dev/null || echo "cluster sick"
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import subprocess
import sys

from clusters import credentials, discover, environments, role  # tools/clusters.py

C_RESET, C_BOLD, C_DIM = "\033[0m", "\033[1m", "\033[2m"
C_RED, C_GREEN, C_CYAN = "\033[31m", "\033[32m", "\033[36m"


def run_one(node: dict, js: str, user: str, password: str,
            db: str, timeout: int) -> dict:
    """Evaluate ``js`` on one node, returning a result record.

    :return: ``{node, role, ok, output}`` where ``output`` is stdout on success
        and the combined error text otherwise.
    """
    cmd = [
        "docker", "exec", "-i", node["name"],
        "mongosh", "--quiet",
        "--port", node["internal"],
        "-u", user, "-p", password,
        "--authenticationDatabase", "admin",
        db, "--eval", js,
    ]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"node": node["name"], "role": role(node), "ok": False,
                "output": f"timed out after {timeout}s"}
    out = (p.stdout or "").strip()
    err = (p.stderr or "").strip()
    if p.returncode != 0:
        # mongosh writes the useful part of a failure to stdout, so keep both.
        return {"node": node["name"], "role": role(node), "ok": False,
                "output": "\n".join(x for x in (out, err) if x) or f"exit {p.returncode}"}
    return {"node": node["name"], "role": role(node), "ok": True, "output": out}


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Run a mongosh command on every node of a PSMDB cluster.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Runs inside the containers, so no local mongosh or /etc/hosts is needed.",
    )
    ap.add_argument("env", help="environment prefix, e.g. sharded-cluster")
    ap.add_argument("command", nargs="?",
                    help="javascript to evaluate; '-' reads it from stdin")
    ap.add_argument("--file", metavar="PATH", help="read the javascript from a file")
    ap.add_argument("--role", action="append",
                    choices=("mongos", "config", "shard", "arbiter", "replica", "standalone"),
                    help="limit to a role (repeatable)")
    ap.add_argument("--rs", metavar="NAME", help="limit to one replica set")
    ap.add_argument("--node", metavar="SUBSTR", help="limit to nodes whose name contains SUBSTR")
    ap.add_argument("--arbiters", action="store_true",
                    help="include arbiters (they cannot authenticate; off by default)")
    # Default to whatever the containers declare (MONGO_ROOT_USER/PASSWORD), so
    # neither pair has to be remembered per environment.
    ap.add_argument("--user", help="override the user the containers declare")
    ap.add_argument("--password", help="override the password the containers declare")
    ap.add_argument("--db", default="admin", help="database context (default: %(default)s)")
    ap.add_argument("--timeout", type=int, default=30, help="per-node seconds (default: %(default)s)")
    ap.add_argument("--jobs", type=int, default=8, help="parallel nodes (default: %(default)s)")
    ap.add_argument("--json", action="store_true", help="emit one JSON array instead of text")
    ap.add_argument("--quiet", action="store_true", help="print only output, no per-node headers")
    # Intermixed parsing so the command can follow the flags. Plain parse_args
    # binds the single positional group before the options are seen, and then
    # rejects the trailing script as an unrecognised argument.
    args = ap.parse_intermixed_args()

    if args.file:
        js = open(args.file).read()
    elif args.command == "-":
        js = sys.stdin.read()
    elif args.command:
        js = args.command
    else:
        ap.error("give a command, --file PATH, or '-' to read stdin")

    nodes = discover(args.env)
    if not nodes:
        sys.exit(f"no running mongo containers matching '{args.env}-' — is the environment up?\n"
                 f"running environments: {', '.join(environments()) or 'none'}")
    user, password = credentials(nodes)
    user, password = args.user or user, args.password or password

    selected = [n for n in nodes if args.arbiters or not n["arbiter"]]
    if args.role:
        selected = [n for n in selected if role(n) in args.role]
    if args.rs:
        selected = [n for n in selected if n["rs"] == args.rs]
    if args.node:
        selected = [n for n in selected if args.node in n["name"]]
    if not selected:
        sys.exit("no nodes matched the given filters")

    # Ordered results from unordered completion: submit in order, read in order.
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        futures = [pool.submit(run_one, n, js, user, password, args.db, args.timeout)
                   for n in selected]
        results = [f.result() for f in futures]

    if args.json:
        print(json.dumps(results, indent=2))
        return 0 if all(r["ok"] for r in results) else 1

    colour = sys.stdout.isatty()
    for r in results:
        mark = "✓" if r["ok"] else "✗"
        if not args.quiet:
            head = f"{mark} {r['node']} ({r['role']})"
            if colour:
                head = f"{C_GREEN if r['ok'] else C_RED}{mark}{C_RESET} " \
                       f"{C_BOLD}{r['node']}{C_RESET} {C_DIM}({r['role']}){C_RESET}"
            print(head)
        body = r["output"] or "(no output)"
        print("\n".join(f"    {line}" for line in body.splitlines()) if not args.quiet else body)
        if not args.quiet:
            print()

    failed = [r["node"] for r in results if not r["ok"]]
    if failed and not args.quiet:
        # stdout is block-buffered when piped while stderr is not, so without
        # this the summary overtakes the results it is summarising.
        sys.stdout.flush()
        tail = f"{len(results) - len(failed)}/{len(results)} ok — failed: {', '.join(failed)}"
        print(f"{C_RED if colour else ''}{tail}{C_RESET if colour else ''}", file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
