#!/usr/bin/env bash
# Readiness one-shot for a pmm-client-only node.
#
# register.sh, its counterpart on a database node, has real work to do:
# `pmm-admin add mongodb`, and the credentials file the SEP payloads read. A host
# with no database has neither. There is no service to add - the node itself is
# already in PMM's inventory, registered by `pmm-agent setup` - and no credentials
# belong here, because nothing on this host holds data.
#
# What is left is the readiness question, and it is the same question on both
# kinds of node: can SEP dispatch to this host yet? It can once pmm-agent has
# connected, because that connection is what makes pmm-managed create the
# nomad-agent and push its config and mTLS material down the existing gRPC
# stream. So publish the same marker register.sh publishes, and `./om start`
# needs to know nothing about which kind of node it is waiting for.

set -o errexit
set -o nounset

# /run, not /root: this is a fact about the *running* container, and it should not
# survive a restart the way a credentials file must.
READY_MARKER="${READY_MARKER:-/run/om-node-ready}"

log() { printf '[register-client] %s\n' "$*" >&2; }

until pmm-admin status >/dev/null 2>&1; do
    log "waiting for pmm-agent to connect ..."
    sleep 5
done

: > "$READY_MARKER"
log "$(hostname) connected to PMM; no database on this host, nothing to register"
