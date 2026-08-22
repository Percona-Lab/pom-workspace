#!/usr/bin/env bash
#
# Give Claude Code a working home inside the container.
#
# Shared by the dev container (post-create.sh) and by delegated agent runs
# (./delegate), because both need exactly the same three things and neither should
# have its own opinion about them:
#
#   1. the workspace marked as trusted, so a session starts at all
#   2. bypassPermissions as the default mode, so nothing ever prompts
#   3. the global CLAUDE.md, so it follows the same house rules as your sessions
#
# Items 1 and 2 are what make an unattended run possible. `claude --print` cannot
# ask a question - there is nobody to answer - so both the trust dialog and a
# permission prompt are not pauses, they are dead runs. Item 1 is easy to miss
# because it is stored somewhere else entirely: credentials live in
# ~/.claude/.credentials.json, but trust is a per-directory flag in ~/.claude.json.
#
# WHAT THIS DELIBERATELY DOES NOT DO: copy your ~/.claude/.credentials.json.
#
# It used to, and it was wrong. Those are OAuth credentials with a *rotating*
# refresh token: when the copy inside the container refreshes, the server issues a
# new refresh token and invalidates the old one, and whichever of the two clients
# refreshes second is simply logged out. In practice the container's copy dies
# within hours and reports "OAuth session expired and could not be refreshed",
# which reads like a broken container rather than the shared-token conflict it is.
#
# So authentication has to be a credential that is *meant* to be shared:
#
#   CLAUDE_CODE_OAUTH_TOKEN   `claude setup-token` - the headless path
#   ANTHROPIC_API_KEY         API billing
#   an independent login      `claude login` inside the container; the ~/.claude
#                             volume keeps it, and it refreshes on its own
#
# Idempotent, and never writes outside $HOME.

set -euo pipefail

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
CLAUDE_CONFIG="${CLAUDE_CONFIG:-$HOME/.claude.json}"
HOST_CLAUDE="${HOST_CLAUDE:-/host-claude}"
HOST_CLAUDE_CONFIG="${HOST_CLAUDE_CONFIG:-/host-claude.json}"
# The directory to mark trusted. The workspace is mounted at its own host path,
# so this is that path.
WORKSPACE="${OM_WORKSPACE:-$PWD}"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }

mkdir -p "$CLAUDE_HOME"

# The house rules, so a container session follows the same conventions as yours.
# The mount is read-only, so this can only ever copy outwards - nothing here can
# corrupt your real ~/.claude.
if [[ -f "$HOST_CLAUDE/CLAUDE.md" && ! -f "$CLAUDE_HOME/CLAUDE.md" ]]; then
  cp "$HOST_CLAUDE/CLAUDE.md" "$CLAUDE_HOME/CLAUDE.md"
  say "copied your global CLAUDE.md"
fi

# A credentials file left behind by a failed refresh is worse than none: Claude
# Code prefers it over the environment and then reports an expired session. This
# is the wreckage of the copy-the-host's-credentials approach described above.
if [[ -f "$CLAUDE_HOME/.credentials.json" ]] \
   && ! grep -q '"accessToken":"[^"]' "$CLAUDE_HOME/.credentials.json" 2>/dev/null; then
  rm -f "$CLAUDE_HOME/.credentials.json"
  warn "removed an emptied credentials file (a failed token refresh leaves one behind)"
fi

# Trust, and the account identity that goes with the credentials. Built from a
# curated subset of the host's file rather than copied wholesale: that file
# carries the history of every project you have ever opened, and none of it
# belongs in here.
python3 - "$CLAUDE_CONFIG" "$WORKSPACE" "$HOST_CLAUDE_CONFIG" <<'PY'
import json, pathlib, sys

out, workspace, host = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3])

cfg = {}
if out.exists():
    try:
        cfg = json.loads(out.read_text() or "{}")
    except json.JSONDecodeError:
        cfg = {}

if host.exists():
    try:
        h = json.loads(host.read_text() or "{}")
    except json.JSONDecodeError:
        h = {}
    # Identity only. Not `projects`, not the caches.
    for k in ("oauthAccount", "userID", "installMethod"):
        if k in h and k not in cfg:
            cfg[k] = h[k]

# Without this the run dies on "this workspace has not been trusted", which
# an unattended session has no way to answer.
cfg.setdefault("projects", {}).setdefault(workspace, {})["hasTrustDialogAccepted"] = True
out.write_text(json.dumps(cfg, indent=2) + "\n")
print(f"trusted {workspace}")
PY

# User-level settings, inside the container only. Deliberately not the repo's
# .claude/settings.local.json: that file is shared with the host over the bind
# mount, and host sessions must keep asking you for permission.
python3 - "$CLAUDE_HOME/settings.json" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
cfg = {}
if p.exists():
    try:
        cfg = json.loads(p.read_text() or "{}")
    except json.JSONDecodeError:
        cfg = {}
cfg.setdefault("permissions", {})["defaultMode"] = "bypassPermissions"
p.write_text(json.dumps(cfg, indent=2) + "\n")
PY
say "permission mode: bypassPermissions (container-local)"

# Authentication, checked last and on purpose. Everything above is configuration
# that must exist even when there is no way to log in: `claude login` inside a
# --shell needs the trust flag already written, and bailing out before writing it
# is how you get a container that is authenticated but refuses to start a session.
if [[ -z "${ANTHROPIC_API_KEY:-}${CLAUDE_CODE_OAUTH_TOKEN:-}" \
      && ! -s "$CLAUDE_HOME/.credentials.json" ]]; then
  warn "no way to authenticate. Pick one, on the host:"
  warn "  claude setup-token   then export CLAUDE_CODE_OAUTH_TOKEN=... and re-run"
  warn "  export ANTHROPIC_API_KEY=...   (API billing)"
  warn "  ./delegate --shell   then 'claude login' inside it, once - the home"
  warn "                       volume keeps that login for later runs"
  exit 78   # EX_CONFIG. An unattended run cannot recover from this, so stop here.
fi
