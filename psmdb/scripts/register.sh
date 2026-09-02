#!/usr/bin/env bash
# Register this node's MongoDB service with PMM and drop the credentials file
# SEP's payloads read. Runs as register.service, a systemd one-shot unit,
# after cluster-init.service has created the root user.
#
# Two things here matter to SEP specifically:
#
#   --cluster=$PMM_CLUSTER   SEP's inventory has no cluster entity; it carries a
#                            cluster *string* per service, and that string comes
#                            from this flag. pmm-managed groups a run's services
#                            into cluster documents by matching it, so nodes that
#                            should be one cluster must pass the same value or the
#                            topology silently fragments.
#
#   /root/.mongodb_uri       the node-side credentials file. SEP never ships
#                            credentials with a job — payloads read a path on the
#                            host (backup_mongo's pbm_creds_common.py, and
#                            om_inventory's probe payload, both default here).
#                            $HOME is /root because the Nomad client inherits
#                            pmm-agent's user, which is root in this container.
#
# Last thing it does is publish $READY_MARKER, the one signal `./om start` waits
# on for every node in the sandbox. register-client.sh publishes the same marker
# on a host that has no database, so om never has to ask what kind of node it is
# looking at.

set -o errexit
set -o nounset

MONGO_PORT="${MONGO_PORT:-27017}"
PMM_CLUSTER="${PMM_CLUSTER:-psmdb}"
PMM_SERVICE_NAME="${PMM_SERVICE_NAME:-$(hostname)}"
MONGO_ROOT_USER="${MONGO_ROOT_USER:-root}"
MONGO_ROOT_PASSWORD="${MONGO_ROOT_PASSWORD:-root-password}"
REPLSET="${REPLSET:-}"
ROLE="${ROLE:-mongod}"
# See register-client.sh: /run rather than /root, because it is a fact about the
# running container and must not outlive it.
READY_MARKER="${READY_MARKER:-/run/om-node-ready}"

log() { printf '[register] %s\n' "$*" >&2; }

mark_ready() { : > "$READY_MARKER"; }

# Wait for the local server to answer. On a replica-set member this succeeds
# before rs.initiate(), which is fine — pmm-admin only needs to connect.
until mongosh --quiet --port "$MONGO_PORT" --eval 'db.adminCommand({ping:1})' \
        >/dev/null 2>&1 \
    || mongosh --quiet --port "$MONGO_PORT" \
        -u "$MONGO_ROOT_USER" -p "$MONGO_ROOT_PASSWORD" --authenticationDatabase admin \
        --eval 'db.adminCommand({ping:1})' >/dev/null 2>&1; do
    log "waiting for mongo on :${MONGO_PORT} ..."
    sleep 3
done

# Wait for the root user, created once per cluster by cluster-init.sh.
until mongosh --quiet --port "$MONGO_PORT" \
        -u "$MONGO_ROOT_USER" -p "$MONGO_ROOT_PASSWORD" --authenticationDatabase admin \
        --eval 'db.adminCommand({ping:1})' >/dev/null 2>&1; do
    log "waiting for the ${MONGO_ROOT_USER} user ..."
    sleep 5
done

umask 077
printf 'mongodb://%s:%s@127.0.0.1:%s/?authSource=admin\n' \
    "$MONGO_ROOT_USER" "$MONGO_ROOT_PASSWORD" "$MONGO_PORT" > /root/.mongodb_uri
chmod 600 /root/.mongodb_uri
log "wrote /root/.mongodb_uri"

# pmm-agent must be connected before pmm-admin can add anything.
until pmm-admin status >/dev/null 2>&1; do
    log "waiting for pmm-agent to connect ..."
    sleep 5
done

if pmm-admin list 2>/dev/null | grep -q "MongoDB[[:space:]]\+${PMM_SERVICE_NAME}\b"; then
    log "${PMM_SERVICE_NAME} already registered"
    mark_ready
    exit 0
fi

# --cluster is the SEP-visible grouping; --replication-set gives PMM's own
# dashboards their rs dimension. An arbiter holds no data, so no QAN there.
extra=()
[ -n "$REPLSET" ] && extra+=(--replication-set="$REPLSET")
[ "$ROLE" != "mongos" ] && extra+=(--query-source=profiler)

pmm-admin add mongodb \
    --username="$MONGO_ROOT_USER" \
    --password="$MONGO_ROOT_PASSWORD" \
    --authentication-database=admin \
    --cluster="$PMM_CLUSTER" \
    --environment="${PMM_ENVIRONMENT:-sandbox}" \
    --service-name="$PMM_SERVICE_NAME" \
    --host=127.0.0.1 \
    --port="$MONGO_PORT" \
    "${extra[@]}" >&2

mark_ready
log "registered ${PMM_SERVICE_NAME} in cluster ${PMM_CLUSTER}"
