#!/usr/bin/env bash
#
# One-time setup after the dev container is created. Idempotent - `Rebuild
# Container` re-runs it and it should be a no-op the second time.
#
# Only the *interactive* half lives here. The toolchain (Docker, Node, pnpm, Go,
# gh, Claude Code) is in the image, because CI needs it too and CI never runs
# this script.
#
# Deliberately does NOT run `./om setup`: that pulls several GB into the inner
# Docker daemon and wants your PMM credentials, so it is yours to start when you
# are ready.

set -euo pipefail

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }

# Named volumes mount root-owned on first creation.
sudo chown -R vscode:vscode /home/vscode/.claude /home/vscode/.cache 2>/dev/null || true

# ---------------------------------------------------------------------------
# Claude Code state - same script a delegated run uses, so an interactive
# session and an unattended one behave identically.
# ---------------------------------------------------------------------------
/usr/local/bin/seed-claude.sh

# ---------------------------------------------------------------------------
# gh, when a token came in from the host environment
# ---------------------------------------------------------------------------
if [[ -n "${GH_TOKEN:-}" ]]; then
  gh auth status >/dev/null 2>&1 && say "gh authenticated from GH_TOKEN" \
    || warn "GH_TOKEN is set but gh rejected it"
fi

# ---------------------------------------------------------------------------
# Git - the workspace and both submodules come in over a bind mount
# ---------------------------------------------------------------------------
for d in "$PWD" "$PWD/pmm" "$PWD/SEP"; do
  git config --global --add safe.directory "$d" 2>/dev/null || true
done

cat <<'EOF'

  Ready. Inside this container:

    docker info          inner daemon, empty on first run
    ./om doctor          prerequisites
    ./om setup           bootstrap (pulls several GB into the inner daemon)
    ./om start           PMM + SEP + the remembered clusters
    ./om status          what is up, and on which ports

  Ports 8000 / 5174 / 8443 / 5173 are forwarded to the same numbers on your
  machine, so the URLs ./om status prints work in the host browser.

  Claude runs with permissions bypassed by default in here. Nothing it does
  reaches the host except through the workspace bind mount - which is your real
  git checkout, so commit or push anything you would hate to lose.

EOF
