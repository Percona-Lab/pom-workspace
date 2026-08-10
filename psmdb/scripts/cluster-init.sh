#!/usr/bin/env bash
# One-shot cluster bootstrap, run *on a node* rather than from an init container.
#
# That placement is forced, not stylistic. With keyfile internal auth on and no
# users yet, MongoDB's localhost exception is the only way in — and it is
# genuinely localhost-only, so a separate init container could not create the
# first user. Electing one member per replica set to do it from inside solves
# that with no chicken-and-egg and no temporarily-authless window.
#
# Two independent jobs, either of which may be off on a given node:
#
#   RS_BOOTSTRAP=1     rs.initiate() this member's set, create the root user,
#                      and (optionally) point PBM at its object store.
#   SHARD_BOOTSTRAP=1  on a mongos: wait for each shard's set to have a primary,
#                      then sh.addShard it.
#
# Everything is idempotent — re-running against an initiated set or an existing
# user is a no-op — because supervisord may restart this after a container
# recreate onto an existing data volume.

set -o errexit
set -o nounset
set -o pipefail

MONGO_PORT="${MONGO_PORT:-27017}"
REPLSET="${REPLSET:-}"
MONGO_ROOT_USER="${MONGO_ROOT_USER:-root}"
MONGO_ROOT_PASSWORD="${MONGO_ROOT_PASSWORD:-root-password}"
RS_BOOTSTRAP="${RS_BOOTSTRAP:-0}"
SHARD_BOOTSTRAP="${SHARD_BOOTSTRAP:-0}"
# host:port[:arbiter] entries, comma separated. The optional third field is what
# reproduces omtest1's arb0 members.
RS_MEMBERS="${RS_MEMBERS:-}"
# name/host:port,host:port;name/host:port,... — one group per shard.
SHARDS="${SHARDS:-}"

log() { printf '[cluster-init] %s\n' "$*" >&2; }

msh() { mongosh --quiet --port "$MONGO_PORT" "$@"; }
msh_auth() {
    mongosh --quiet --port "$MONGO_PORT" \
        -u "$MONGO_ROOT_USER" -p "$MONGO_ROOT_PASSWORD" \
        --authenticationDatabase admin "$@"
}

wait_local_server() {
    until msh --eval 'db.adminCommand({ping:1})' >/dev/null 2>&1 \
        || msh_auth --eval 'db.adminCommand({ping:1})' >/dev/null 2>&1; do
        log "waiting for local server on :${MONGO_PORT} ..."
        sleep 3
    done
}

# Build the rs.initiate() member array from RS_MEMBERS. Priority 0 on arbiters is
# implicit — arbiterOnly members cannot be primary — so only the flag is set.
members_json() {
    local id=0 out="" entry host_port kind
    IFS=',' read -ra entries <<< "$RS_MEMBERS"
    for entry in "${entries[@]}"; do
        host_port="${entry%%:arbiter}"
        kind=""
        [ "$entry" != "$host_port" ] && kind=', arbiterOnly: true'
        [ -n "$out" ] && out="${out}, "
        out="${out}{ _id: ${id}, host: \"${host_port}\"${kind} }"
        id=$((id + 1))
    done
    printf '[%s]' "$out"
}

initiate_replset() {
    [ -n "$REPLSET" ] || { log "no REPLSET set — standalone, nothing to initiate"; return 0; }

    if msh --eval 'rs.status().ok' 2>/dev/null | grep -q '^1$' \
        || msh_auth --eval 'rs.status().ok' 2>/dev/null | grep -q '^1$'; then
        log "${REPLSET} already initiated"
        return 0
    fi

    local cfg
    cfg="{ _id: \"${REPLSET}\", $( [ -n "${CLUSTER_ROLE:-}" ] && [ "${CLUSTER_ROLE}" = configsvr ] && printf 'configsvr: true, ' )members: $(members_json) }"
    log "rs.initiate ${cfg}"
    msh --eval "rs.initiate(${cfg})" >&2

    # The user can only be created on the primary, and the election takes a
    # moment after initiate returns.
    until msh --eval 'db.hello().isWritablePrimary' 2>/dev/null | grep -q true; do
        log "waiting to become primary ..."
        sleep 2
    done
}

create_root_user() {
    if msh_auth --eval 'db.adminCommand({ping:1})' >/dev/null 2>&1; then
        log "${MONGO_ROOT_USER} already exists"
        return 0
    fi
    log "creating ${MONGO_ROOT_USER} via the localhost exception"
    msh admin --eval "db.createUser({
        user: \"${MONGO_ROOT_USER}\",
        pwd: \"${MONGO_ROOT_PASSWORD}\",
        roles: [
            { role: \"root\", db: \"admin\" },
            { role: \"userAdminAnyDatabase\", db: \"admin\" },
            { role: \"clusterAdmin\", db: \"admin\" }
        ]
    })" >&2
}

# PBM keeps its config in the database, so this only needs to run once per set —
# on whichever member bootstraps it.
configure_pbm_store() {
    [ -n "${PBM_S3_ENDPOINT:-}" ] || { log "no PBM store configured; skipping"; return 0; }
    local conf=/tmp/pbm-store.yaml
    cat > "$conf" <<EOF
storage:
  type: s3
  s3:
    endpointUrl: ${PBM_S3_ENDPOINT}
    bucket: ${PBM_S3_BUCKET:-pbm}
    prefix: ${REPLSET:-standalone}
    region: ${PBM_S3_REGION:-us-east-1}
    forcePathStyle: true
    credentials:
      access-key-id: ${PBM_S3_ACCESS_KEY:-minioadmin}
      secret-access-key: ${PBM_S3_SECRET_KEY:-minioadmin}
EOF
    PBM_MONGODB_URI="mongodb://${MONGO_ROOT_USER}:${MONGO_ROOT_PASSWORD}@127.0.0.1:${MONGO_PORT}/admin?authSource=admin" \
        pbm config --file "$conf" >&2 || log "pbm config failed (non-fatal); check the store"
    log "PBM store configured"
}

add_shards() {
    [ -n "$SHARDS" ] || return 0
    until msh_auth --eval 'db.adminCommand({ping:1})' >/dev/null 2>&1; do
        log "waiting for mongos to accept ${MONGO_ROOT_USER} ..."
        sleep 5
    done

    # A shard of svr0/svr1/arb0 — the omtest1 shape — has three voting members of
    # which only two can be written to, so the writable voting members are not
    # "strictly more than the voting majority" and addShard refuses outright:
    #
    #   Cannot add ... as a shard since the implicit default write concern on
    #   this shard is set to {w : 1}, because number of arbiters in the shard's
    #   configuration caused the number of writable voting members not to be
    #   strictly more than the voting majority.
    #
    # Setting the cluster-wide default explicitly is MongoDB's own prescribed
    # remedy. Harmless on arbiter-free shards, so it runs unconditionally.
    log "setting the cluster-wide default write concern (arbiters need it explicit)"
    msh_auth --eval 'db.adminCommand({setDefaultRWConcern: 1, defaultWriteConcern: {w: 1}})' \
        >/dev/null 2>&1 || log "setDefaultRWConcern failed; addShard may refuse"

    local group name hosts first_host
    IFS=';' read -ra groups <<< "$SHARDS"
    for group in "${groups[@]}"; do
        name="${group%%/*}"
        hosts="${group#*/}"
        first_host="${hosts%%,*}"

        # sh.addShard fails if the shard's own set has not elected a primary yet.
        until mongosh --quiet "mongodb://${MONGO_ROOT_USER}:${MONGO_ROOT_PASSWORD}@${first_host}/admin?authSource=admin" \
                --eval 'db.hello().isWritablePrimary' 2>/dev/null | grep -q true; do
            log "waiting for ${name} to elect a primary ..."
            sleep 5
        done

        if msh_auth --eval 'db.adminCommand({listShards:1}).shards.map(s => s._id).join(",")' \
            2>/dev/null | grep -qw "$name"; then
            log "${name} already added"
            continue
        fi
        log "sh.addShard ${name}/${hosts}"
        msh_auth --eval "sh.addShard(\"${name}/${hosts}\")" >&2
    done
}

if [ "$RS_BOOTSTRAP" != "1" ] && [ "$SHARD_BOOTSTRAP" != "1" ]; then
    log "not a bootstrap node; nothing to do"
    exit 0
fi

wait_local_server

if [ "$RS_BOOTSTRAP" = "1" ]; then
    initiate_replset
    create_root_user
    configure_pbm_store
fi

if [ "$SHARD_BOOTSTRAP" = "1" ]; then
    add_shards
fi

log "done"
