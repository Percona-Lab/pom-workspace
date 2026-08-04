#!/usr/bin/env python3
"""Run a SEP run-python payload locally, under a debugger, without a cluster.

SEP payloads (``app/sep/apps/backup_mongo/pbm_logical_payload`` and friends) never
execute inside the SEP process: they are shipped to a Nomad client and run there by
``raw_exec``. So attaching the debugger to the FastAPI backend never hits a
breakpoint in them. This reproduces the executor's contract locally instead:

  NOMAD_META_CONFIG   the YAML config Nomad passes as job meta (see --config)
  NOMAD_TASK_DIR      the task dir the payload writes its pbm config file into
  HOME                so ``_creds_path()`` resolves ``$HOME/.mongodb_uri``
  PATH                prefixed with debug/bin, whose ``pbm`` stub records argv
                      instead of touching a real cluster

``runpy.run_path`` executes the payload with its real filename, so breakpoints set
in the payload file bind normally.

Usage:
    python debug/payload_runner.py SEP/app/sep/apps/backup_mongo/pbm_logical_payload
    python debug/payload_runner.py <payload> --config debug/example-backup-config.yaml
    python debug/payload_runner.py <payload> --real-pbm    # use the real pbm on PATH
"""

from __future__ import annotations

import argparse
import os
import pathlib
import runpy
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent


def main() -> int:
    """Set up the executor-like environment and run the payload."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("payload", type=pathlib.Path, help="path to the payload script")
    parser.add_argument(
        "--config",
        type=pathlib.Path,
        default=HERE / "example-backup-config.yaml",
        help="YAML file placed in NOMAD_META_CONFIG (default: example-backup-config.yaml)",
    )
    parser.add_argument(
        "--uri",
        default="pbmuser:percona@omtest1-cl01-cfg00:27019",
        help="value written to $HOME/.mongodb_uri",
    )
    parser.add_argument(
        "--real-pbm",
        action="store_true",
        help="do NOT shadow pbm with the stub (only useful inside om-nomad)",
    )
    args = parser.parse_args()

    payload = args.payload.resolve()
    if not payload.is_file():
        print(f"no such payload: {payload}", file=sys.stderr)
        return 2

    # A throwaway HOME and task dir, so a debug run never touches real credentials
    # and the payload's config file lands somewhere disposable.
    home = pathlib.Path(tempfile.mkdtemp(prefix="sep-payload-home-"))
    task_dir = pathlib.Path(tempfile.mkdtemp(prefix="sep-payload-task-"))
    (home / ".mongodb_uri").write_text(args.uri)
    (home / ".mongodb_uri").chmod(0o600)

    os.environ["HOME"] = str(home)
    os.environ["NOMAD_TASK_DIR"] = str(task_dir)
    os.environ["NOMAD_ALLOC_DIR"] = str(task_dir)
    os.environ["NOMAD_META_CONFIG"] = args.config.read_text() if args.config.is_file() else ""

    if not args.real_pbm:
        os.environ["PATH"] = f"{HERE / 'bin'}{os.pathsep}{os.environ.get('PATH', '')}"
        os.environ["SEP_PBM_STUB_LOG"] = str(task_dir / "pbm-invocations.log")

    print(f"payload : {payload}", file=sys.stderr)
    print(f"config  : {args.config}", file=sys.stderr)
    print(f"HOME    : {home}", file=sys.stderr)
    print(f"taskdir : {task_dir}", file=sys.stderr)
    print("-" * 60, file=sys.stderr)

    try:
        # run_path keeps the payload's real filename, so breakpoints bind.
        runpy.run_path(str(payload), run_name="__main__")
    except SystemExit as exc:
        # Payloads sys.exit() on error paths; surface the code rather than a traceback.
        code = exc.code if isinstance(exc.code, int) else 1
        print("-" * 60, file=sys.stderr)
        print(f"payload exited with {code}", file=sys.stderr)
        _dump_invocations(task_dir)
        return code

    print("-" * 60, file=sys.stderr)
    _dump_invocations(task_dir)
    return 0


def _dump_invocations(task_dir: pathlib.Path) -> None:
    """Print the pbm commands the stub recorded, if any."""
    log = task_dir / "pbm-invocations.log"
    if log.is_file():
        print("pbm commands the payload would have run:", file=sys.stderr)
        for line in log.read_text().splitlines():
            print(f"  {line}", file=sys.stderr)


if __name__ == "__main__":
    sys.exit(main())
