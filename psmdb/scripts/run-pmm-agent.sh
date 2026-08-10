#!/usr/bin/env bash
# Bring up pmm-agent, running setup once against PMM before the agent proper.
#
# The Nomad client rides along inside this process: pmm-managed creates a
# "nomad-agent" for every connecting pmm-agent >= 3.2.0 and pushes the config and
# mTLS material down the existing gRPC stream, and pmm-agent starts the bundled
# nomad binary as a supervised child. Nothing here configures that — the point is
# that this is what puts a Nomad *client on the database host*, which is how SEP
# is meant to reach it in production.
#
# Nomad's client wants to manage a cgroup subtree and /sys/fs/cgroup is read-only
# in a container. Measured on this stack: it starts and registers anyway. The
# workspace note claiming otherwise (docs/nomad-in-pmm.md) predates Nomad 2.x.

set -o errexit
set -o nounset

PMM_SERVER="${PMM_SERVER:-pmm-server:8443}"
PMM_USER="${PMM_USER:-admin}"
PMM_PASSWORD="${PMM_PASSWORD:-admin}"
CONFIG=/usr/local/percona/pmm/config/pmm-agent.yaml

log() { printf '[pmm-agent] %s\n' "$*" >&2; }

# pmm-agent setup fails outright if the server is not answering yet, and
# supervisord would then flap this program. Wait instead.
until curl -ksSf -o /dev/null "https://${PMM_SERVER}/v1/server/readyz" 2>/dev/null; do
    log "waiting for https://${PMM_SERVER} ..."
    sleep 5
done

mkdir -p "$(dirname "$CONFIG")"

# Node identity is positional — `setup [<node-address>] [<node-type>]
# [<node-name>]`, there is no --node-name flag. Address and name are both the
# container hostname, which is also what compose registers in the network's DNS,
# so PMM's inventory entry and the name SEP resolves stay the same string.
#
# --force re-registers cleanly when the container is recreated against an
# existing PMM, which otherwise still holds the old node under the same name.
pmm-agent setup \
    --config-file="$CONFIG" \
    --server-address="$PMM_SERVER" \
    --server-username="$PMM_USER" \
    --server-password="$PMM_PASSWORD" \
    --server-insecure-tls \
    --force \
    "$(hostname)" container "$(hostname)" >&2

log "setup complete, starting agent"
exec pmm-agent --config-file="$CONFIG"
