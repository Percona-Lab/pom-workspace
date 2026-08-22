#!/usr/bin/env bash
#
# Start this container's own Docker daemon, and wait until it answers.
#
# Shared by all three callers so there is exactly one definition of "docker is
# ready here": the dev container runs it from postStartCommand, CI and plain
# `docker run` reach it through entrypoint.sh.
#
# Idempotent: returns immediately if the daemon is already up.

set -euo pipefail

log() { printf '\033[1;34m[docker]\033[0m %s\n' "$*" >&2; }

# Already running? Nothing to do. This is the common case on dev container
# restarts and on the second call within a CI job.
if docker info >/dev/null 2>&1; then
  log "daemon already up"
  exit 0
fi

# dockerd needs root. Re-exec through sudo when we are not.
if [[ "$(id -u)" -ne 0 ]]; then
  exec sudo -n "$0" "$@"
fi

# A container that was committed or restarted can carry a stale pid file, which
# makes dockerd refuse to start with "pid file found".
rm -f /var/run/docker.pid

log "starting dockerd"
dockerd >/var/log/dockerd.log 2>&1 &

# Wait for the socket. 60s is generous: a cold daemon on a slow CI runner needs
# a few seconds, and failing fast here produces a much clearer error than
# whatever `docker compose` would say later.
for _ in $(seq 1 60); do
  if docker info >/dev/null 2>&1; then
    log "ready: $(docker --version)"
    exit 0
  fi
  sleep 1
done

log "dockerd did not become ready in 60s; last 40 lines of /var/log/dockerd.log:"
tail -40 /var/log/dockerd.log >&2 || true
log "if this is CI or a plain 'docker run', the container almost certainly needs --privileged"
exit 1
