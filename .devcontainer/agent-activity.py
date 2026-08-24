#!/usr/bin/env python3
"""Render a delegated agent's activity from its session transcript.

Why this exists: `claude --print` emits nothing until it finishes. For a run that
takes hours that is not a log, it is a black box - so this reads the session
transcript Claude Code writes as it goes and turns it into a tool-by-tool feed.

Run inside the container (./delegate --activity does this for you):

    python3 .devcontainer/agent-activity.py            # everything so far, then follow
    python3 .devcontainer/agent-activity.py --tail 40  # last 40 actions, then follow
    python3 .devcontainer/agent-activity.py --no-follow

Reads only. Nothing here can disturb the run.
"""

import argparse
import glob
import json
import os
import sys
import time

HOME = os.path.expanduser("~")


def newest_transcript():
    """The most recently modified session file, across every project slug."""
    files = glob.glob(f"{HOME}/.claude/projects/*/*.jsonl")
    return max(files, key=os.path.getmtime) if files else None


def summarise(entry):
    """One line per interesting thing the agent did. None to skip."""
    msg = entry.get("message") or {}
    kind = entry.get("type")

    if kind == "assistant":
        for c in msg.get("content") or []:
            if not isinstance(c, dict):
                continue
            if c.get("type") == "tool_use":
                i = c.get("input") or {}
                # The field that actually says what happened varies by tool.
                detail = (
                    i.get("command")
                    or i.get("file_path")
                    or i.get("pattern")
                    or i.get("prompt")
                    or i.get("description")
                    or ""
                )
                yield f"  {c.get('name','?'):<12} {flat(detail, 160)}"
            elif c.get("type") == "text" and (c.get("text") or "").strip():
                yield f"* {flat(c['text'], 300)}"

    elif kind == "user":
        # Tool results, but only the failures - successes are noise here, and a
        # silent failure is the thing you most want to see in a run you cannot
        # interrupt.
        for c in msg.get("content") or []:
            if isinstance(c, dict) and c.get("type") == "tool_result" and c.get("is_error"):
                yield f"  {'ERROR':<12} {flat(content_text(c), 300)}"


def content_text(c):
    body = c.get("content")
    if isinstance(body, str):
        return body
    if isinstance(body, list):
        return " ".join(p.get("text", "") for p in body if isinstance(p, dict))
    return str(body)


def flat(s, n):
    s = " ".join(str(s).split())
    return s if len(s) <= n else s[: n - 1] + "…"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tail", type=int, default=0, help="show only the last N lines of history")
    ap.add_argument("--no-follow", action="store_true")
    args = ap.parse_args()

    path = newest_transcript()
    if not path:
        print("no session transcript yet - the agent has not started", file=sys.stderr)
        return 1
    print(f"# {path}\n", file=sys.stderr)

    history, offset = [], 0
    with open(path) as fh:
        for line in fh:
            offset += len(line)
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            history.extend(summarise(entry))

    for line in history[-args.tail :] if args.tail else history:
        print(line, flush=True)

    if args.no_follow:
        return 0

    # Follow. Re-open each time rather than holding the handle: the file is
    # appended to by another process and may be rotated between polls.
    while True:
        time.sleep(2)
        try:
            size = os.path.getsize(path)
        except OSError:
            return 0
        if size <= offset:
            continue
        with open(path) as fh:
            fh.seek(offset)
            for line in fh:
                offset += len(line)
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                for out in summarise(entry):
                    print(out, flush=True)


if __name__ == "__main__":
    sys.exit(main())
