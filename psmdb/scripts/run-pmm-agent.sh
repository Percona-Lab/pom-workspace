#!/usr/bin/env bash
# Bring up pmm-agent, registering this node with PMM the first time and only the
# first time.
#
# The Nomad client rides along inside this process: pmm-managed creates a
# "nomad-agent" for every connecting pmm-agent >= 3.2.0 and pushes the config and
# mTLS material down the existing gRPC stream, and pmm-agent starts the bundled
# nomad binary as a supervised child. Nothing here configures that — the point is
# that this is what puts a Nomad *client on the database host*, which is how SEP
# is meant to reach it in production.
#
# Nomad's client wants to manage a cgroup subtree and /sys/fs/cgroup is read-only
# in a container. Measured on this stack: it starts and registers anyway, despite
# older notes claiming otherwise — those predate Nomad 2.x.
#
# Registration is an identity question, not a startup step
# -------------------------------------------------------
# `pmm-agent setup --force` does not re-assert anything: it mints a new node id
# and a new agent id, and pmm-managed *replaces* the node it finds under the same
# name, cascading into that node's services, its nomad-agent and its metrics
# history. Everything keyed on the old ids is then stale, and nothing prunes it:
# SEP's OM estate holds hosts under PMM's node id and only forgets one when
# someone calls DELETE /v1/om/inventory/hosts/{node_id} by hand, and Nomad keeps
# the previous client under the same name as a down node until it garbage
# collects it.
#
# This script used to run `setup --force` on every start, so every `./om stop &&
# ./om start` cycle silently replaced the whole estate with a fresh copy of
# itself and orphaned the old one. Restarting a node is not the same event as
# building a new one, and only the second is allowed to re-register:
#
#   this node's identity              $CONFIG, on a volume that outlives the
#                                     container (see psmdb/compose.yaml)
#   restart / recreate                identity is reused, no registration at all
#   fresh identity, deliberately      `./om reregister <node>`, which drops
#                                     $FORCE_MARKER and restarts this program
#   fresh identity, by accident       refused, loudly - see the last branch below

set -o errexit
set -o nounset

PMM_SERVER="${PMM_SERVER:-pmm-server:8443}"
PMM_USER="${PMM_USER:-admin}"
PMM_PASSWORD="${PMM_PASSWORD:-admin}"

# Under /srv/agent-state, which compose backs with a volume, rather than the
# package default under /usr/local/percona/pmm: the config file holds this node's
# agent id and service token, which is identity and belongs with the data, not
# with the container filesystem. The hostname subdirectory is what keeps that
# per-node while the volume itself is shared by every host.
#
# `./om reset data` removes the volume along with the databases, which is the one
# place a new identity is intended.
STATE_DIR="${AGENT_STATE_DIR:-/srv/agent-state}/$(hostname)"
CONFIG="$STATE_DIR/pmm-agent.yaml"

# Nomad's client id lives in its data directory, so that goes on the volume too:
# a recreated container then rejoins Nomad as the client it already was, rather
# than leaving a duplicate behind under the same name until the server garbage
# collects it. Exported rather than written into $CONFIG because pmm-agent reads
# it from the environment on every start, which keeps it true for `setup` and for
# the agent itself without either of them having to agree with a file.
export PMM_AGENT_PATHS_NOMAD_DATA_DIR="$STATE_DIR/nomad"

# Dropped by `./om reregister` and consumed here, once. A file rather than an
# environment variable because changing the environment means recreating the
# container - the very thing this script exists to make survivable.
FORCE_MARKER=/run/om-reregister

log() { printf '[pmm-agent] %s\n' "$*" >&2; }

api() { curl -ksS -u "${PMM_USER}:${PMM_PASSWORD}" "https://${PMM_SERVER}$1" 2>/dev/null; }

# The agent id this host claims to be, or empty. Written by `pmm-agent setup` as
# a top-level `id:` - a plain uuid in PMM 3, unquoted, but tolerate quotes.
agent_id() {
    [ -f "$CONFIG" ] || return 0
    sed -n 's/^id:[[:space:]]*//p' "$CONFIG" | tr -d "\"'" | head -1
}

# Whether pmm-managed still has that agent. A 404 means the identity is gone -
# PMM's /srv was wiped, or someone removed the node - and has to be established
# again. Only a clean 200 counts as "keep it", so an API that is up but unhappy
# lands in one of the branches below rather than in a false yes; the worst of
# those is a refusal or a failed setup, never a silent replacement.
agent_known() {
    [ -n "$1" ] || return 1
    local code
    code="$(curl -ksS -o /dev/null -w '%{http_code}' -u "${PMM_USER}:${PMM_PASSWORD}" \
        "https://${PMM_SERVER}/v1/inventory/agents/$1" 2>/dev/null || true)"
    [ "$code" = "200" ]
}

# Whether PMM already holds a node under this name. Registering into that without
# --force fails with 409; registering with it takes the name over and orphans
# whatever was there.
node_exists() {
    api /v1/inventory/nodes \
        | jq -e --arg n "$1" 'any(..|objects|.node_name? // empty; . == $n)' >/dev/null 2>&1
}

# Node identity is positional — `setup [<node-address>] [<node-type>]
# [<node-name>]`, there is no --node-name flag. Address and name are both the
# container hostname, which is also what compose registers in the network's DNS,
# so PMM's inventory entry and the name SEP resolves stay the same string.
register() {
    pmm-agent setup \
        --config-file="$CONFIG" \
        --server-address="$PMM_SERVER" \
        --server-username="$PMM_USER" \
        --server-password="$PMM_PASSWORD" \
        --server-insecure-tls \
        "$@" \
        "$(hostname)" container "$(hostname)" >&2
}

# pmm-agent setup fails outright if the server is not answering yet, and
# supervisord would then flap this program. Wait instead. The checks below need
# the API too, and a missing answer there would read as "unknown agent".
until curl -ksSf -o /dev/null "https://${PMM_SERVER}/v1/server/readyz" 2>/dev/null; do
    log "waiting for https://${PMM_SERVER} ..."
    sleep 5
done

mkdir -p "$STATE_DIR" "$PMM_AGENT_PATHS_NOMAD_DATA_DIR"

id="$(agent_id)"

if [ -f "$FORCE_MARKER" ]; then
    # Consumed before the attempt, not after: a marker that survived a failed
    # setup would silently re-register on the next restart, which is exactly the
    # behaviour this script is built to not have.
    rm -f "$FORCE_MARKER"
    log "re-registration requested explicitly; replacing $(hostname) in PMM"
    register --force
elif agent_known "$id"; then
    log "$(hostname) is already agent $id; keeping that identity"
elif node_exists "$(hostname)"; then
    log "REFUSING to register: PMM already has a node named $(hostname), and this"
    log "host has no usable identity for it ($CONFIG)."
    log "Registering now would replace that node and orphan its services, its"
    log "Nomad client and OM's estate rows, so it is left to you:"
    log "  ./om reregister $(hostname)   - take the name over, discarding the old node"
    log "  ./om pmm-inventory nodes   - what PMM holds under that name today"
    exit 1
else
    log "no identity on this host yet; registering $(hostname) with PMM"
    register
fi

# Publish readiness again, and on a database node re-assert the MongoDB service.
#
# Both scripts are supervisord one-shots that ran when the container started, so
# on a plain restart this is redundant. It is not redundant after `supervisorctl
# restart pmm-agent`: that runs this program alone, and the marker `./om start`
# waits on - plus, on a re-registration, the service that went with the replaced
# node - would otherwise never come back. Observed exactly that way: restarting
# this program to recover a Nomad client left a monitored database unmonitored,
# and the only thing that noticed was OM reporting a mongod it had no service for.
#
# Both names are tried because the database image supervises `register` and the
# pmm-client-only image supervises `register-client`; the absent one simply fails
# and is ignored. Backgrounded because both scripts wait for *this* agent to
# connect, which cannot happen until the exec below replaces this shell.
(
    sleep 5
    for program in register register-client; do
        supervisorctl start "$program" >/dev/null 2>&1 || true
    done
) &

log "starting agent with $CONFIG"
exec pmm-agent --config-file="$CONFIG"
