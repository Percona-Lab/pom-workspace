#!/usr/bin/env bash
# pbm-agent, or a quiet no-op on nodes that must not run one.
#
# PBM belongs on data-bearing mongod nodes and on config-server members. It must
# NOT run on a mongos (no local storage to back up) and there is nothing useful
# for it to do on an arbiter, which holds no data. Rather than making the
# pbm-agent.service unit conditional, this idles on those nodes instead of
# exiting - see the sleep below.

set -o errexit
set -o nounset

ROLE="${ROLE:-mongod}"
PBM_ENABLED="${PBM_ENABLED:-1}"
MONGO_PORT="${MONGO_PORT:-27017}"

log() { printf '[pbm-agent] %s\n' "$*" >&2; }

if [ "$ROLE" = "mongos" ] || [ "$PBM_ENABLED" != "1" ]; then
    log "not applicable on this node (role=${ROLE} enabled=${PBM_ENABLED}); idling"
    # Sleep rather than exit: pbm-agent.service is Type=simple with
    # Restart=always, so a quick exit reads as a crash loop and systemd logs a
    # failure on every node that skips PBM.
    exec sleep infinity
fi

# The URI file is written by register.sh once the root user exists, so wait for
# it rather than racing cluster init.
until [ -f /root/.mongodb_uri ]; do
    sleep 3
done

PBM_MONGODB_URI="$(sed -e 's|/?|/admin?|' /root/.mongodb_uri)"
export PBM_MONGODB_URI
log "starting against localhost:${MONGO_PORT}"
exec pbm-agent
