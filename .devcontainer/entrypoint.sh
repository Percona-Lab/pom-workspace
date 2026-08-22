#!/usr/bin/env bash
#
# Entrypoint for CI jobs and plain `docker run`. The VS Code dev container does
# not use this - it overrides the command and calls start-docker.sh from
# postStartCommand instead - so everything here is about making a *non*
# interactive run behave.
#
# Three jobs, in order:
#   1. start the inner Docker daemon (skippable: lint and agent jobs do not need it)
#   2. make the mounted workspace writable by the unprivileged user
#   3. drop from root to `vscode` and exec the command
#
# Step 3 matters more than it looks. Claude Code refuses `--dangerously-skip-
# permissions` when running as root, and every other agent is safer unprivileged
# too. Starting as root and dropping is the only way to get both a working
# dockerd and a non-root agent in one container.
#
# Knobs, all read from the environment:
#   OM_START_DOCKER=0        skip the daemon (no --privileged needed either)
#   OM_CHOWN_WORKSPACE=0     skip fixing ownership of /workspaces/openmanager
#   OM_USER=root             do not drop privileges
#   OM_WORKSPACE=<path>      workspace to chown (default: the working directory)
#   OM_UID / OM_GID          renumber `vscode` to this uid/gid before dropping to
#                            it, so files it writes into a bind-mounted workspace
#                            belong to you on the host

set -euo pipefail

OM_START_DOCKER="${OM_START_DOCKER:-1}"
OM_CHOWN_WORKSPACE="${OM_CHOWN_WORKSPACE:-1}"
OM_USER="${OM_USER:-vscode}"
# Defaults to the working directory, because the workspace is not always mounted
# at the same path: locally it is mounted at its own host path so that SEP/venv
# and the node_modules trees stay valid, while CI mounts the runner's checkout.
OM_WORKSPACE="${OM_WORKSPACE:-$PWD}"

log() { printf '\033[1;34m[entrypoint]\033[0m %s\n' "$*" >&2; }

if [[ "$OM_START_DOCKER" == "1" ]]; then
  /usr/local/bin/start-docker.sh
else
  log "OM_START_DOCKER=0, not starting dockerd"
fi

if [[ "$(id -u)" -eq 0 ]]; then
  # Renumber the unprivileged user to match whoever owns the workspace on the
  # host. Without this, a run by a host user who is not uid 1000 either writes
  # files they cannot edit afterwards, or - worse - a recursive chown below hands
  # their real checkout to a uid that is not theirs.
  if [[ -n "${OM_UID:-}" && "$OM_UID" != "$(id -u "$OM_USER" 2>/dev/null)" ]]; then
    log "renumbering $OM_USER to ${OM_UID}:${OM_GID:-$OM_UID}"
    groupmod -o -g "${OM_GID:-$OM_UID}" "$OM_USER" 2>/dev/null || true
    usermod -o -u "$OM_UID" -g "${OM_GID:-$OM_UID}" "$OM_USER" 2>/dev/null || true
  fi

  # The home directory, every time. A named volume mounted at ~/.claude arrives
  # root-owned on first use, and an unprivileged agent that cannot write its own
  # credentials file cannot authenticate - which shows up much later as a bare
  # "Not logged in" with no hint about why.
  chown -R "$(id -u "$OM_USER"):$(id -g "$OM_USER")" "/home/$OM_USER" 2>/dev/null || true

  # PMM's and SEP's dev servers exhaust the default watch limit. Namespaced per
  # container, so this never touches the host.
  sysctl -qw fs.inotify.max_user_watches=524288 2>/dev/null || true
  sysctl -qw fs.inotify.max_user_instances=512 2>/dev/null || true

  # A workspace bind-mounted by a CI runner arrives owned by the runner's uid,
  # which is not ours. Only the top level and the git metadata are touched by
  # default; a full recursive chown of this tree costs real time on a runner.
  if [[ "$OM_CHOWN_WORKSPACE" == "1" && -d "$OM_WORKSPACE" ]]; then
    log "granting $OM_USER ownership of $OM_WORKSPACE"
    chown -R "$OM_USER" "$OM_WORKSPACE" 2>/dev/null || \
      log "chown was incomplete; some paths stay owned by uid $(stat -c %u "$OM_WORKSPACE")"
  fi

  # git refuses to operate on a tree owned by somebody else. Belt and braces:
  # the chown above usually settles it, but a partial chown must not break git.
  for d in "$OM_WORKSPACE" "$OM_WORKSPACE/pmm" "$OM_WORKSPACE/SEP"; do
    git config --system --add safe.directory "$d" 2>/dev/null || true
  done
fi

if [[ "$OM_USER" != "root" && "$(id -u)" -eq 0 ]]; then
  uid="$(id -u "$OM_USER")"
  gid="$(id -g "$OM_USER")"

  # setpriv changes the uid and nothing else, so HOME would still say /root and
  # every tool that keeps per-user state under it - gh, npm, claude, git -
  # would fail on permissions or silently write somewhere the user cannot read.
  # Set it explicitly; this is the one piece of environment we must rewrite.
  export HOME USER LOGNAME
  HOME="$(getent passwd "$OM_USER" | cut -d: -f6)"
  USER="$OM_USER"
  LOGNAME="$OM_USER"

  log "dropping to $OM_USER ($uid:$gid), HOME=$HOME"
  # setpriv rather than sudo: it leaves the rest of the environment exactly as
  # it is, which matters when the caller passed ANTHROPIC_API_KEY and friends
  # in, and --init-groups picks up the docker group so the inner daemon is
  # reachable.
  exec setpriv --reuid="$uid" --regid="$gid" --init-groups -- "$@"
fi

exec "$@"
