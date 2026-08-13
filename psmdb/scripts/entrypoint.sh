#!/usr/bin/env bash
# Render this node's mongod/mongos config from the environment, then hand over to
# supervisord. Everything that needs a *running* server — replica set initiation,
# the root user, PMM registration, PBM config — happens elsewhere: register.sh as
# a supervisord one-shot on this node, cluster-init.sh as a per-topology init
# container. This script only has to make the process startable.
#
# Contract (compose sets these):
#   ROLE           mongod | mongos | client
#   MONGO_PORT     27017 shard/standalone · 27018 shardsvr · 27019 configsvr
#   REPLSET        replica set name; empty means standalone (no replication)
#   CLUSTER_ROLE   configsvr | shardsvr | empty
#   CONFIG_DB      mongos only: <cfgReplSet>/<host:port>,...
#   PMM_CLUSTER    the label SEP's inventory groups on — see register.sh

set -o errexit
set -o nounset
set -o pipefail

MONGO_PORT="${MONGO_PORT:-27017}"
ROLE="${ROLE:-mongod}"
REPLSET="${REPLSET:-}"
CLUSTER_ROLE="${CLUSTER_ROLE:-}"
KEYFILE_SRC="${KEYFILE_SRC:-/srv/secrets/keyfile}"
KEYFILE="/etc/mongo-keyfile"
# Deliberately NOT /etc/mongod.conf: that path is a dpkg conffile, so a locally
# written one makes every `apt-get install percona-server-mongodb-server`
# upgrade stop at an interactive "keep your currently-installed version?"
# prompt and fail with "end of file on stdin at conffile prompt". Generating
# our config beside it keeps the package's own copy pristine and the upgrade
# path non-interactive — which is the whole point of this image.
MONGOD_CONF="/etc/mongod-node.conf"
MONGOS_CONF="/etc/mongos-node.conf"

log() { printf '[entrypoint] %s\n' "$*" >&2; }

# The keyfile arrives as a read-only bind mount shared by every node. mongod
# refuses one that is group/world readable and refuses one it does not own, so
# copy rather than use it in place — a bind mount cannot be chowned.
install_keyfile() {
    [ -f "$KEYFILE_SRC" ] || return 0
    install -o mongod -g mongod -m 0400 "$KEYFILE_SRC" "$KEYFILE"
    log "keyfile installed for internal auth"
}

write_mongod_conf() {
    {
        echo "storage:"
        echo "  dbPath: /var/lib/mongo"
        echo "systemLog:"
        echo "  destination: file"
        echo "  path: /var/log/mongo/mongod.log"
        echo "  logAppend: true"
        echo "net:"
        echo "  port: ${MONGO_PORT}"
        echo "  bindIpAll: true"
        # Auth is always on — the whole point of the credentials-on-the-host
        # model is that payloads authenticate. A keyFile is additionally needed
        # wherever members talk to each other; a standalone has no peers, so it
        # gets authorization without one.
        echo "security:"
        echo "  authorization: enabled"
        if [ -f "$KEYFILE" ]; then
            echo "  keyFile: ${KEYFILE}"
        fi
        if [ -n "$REPLSET" ]; then
            echo "replication:"
            echo "  replSetName: ${REPLSET}"
        fi
        if [ -n "$CLUSTER_ROLE" ]; then
            echo "sharding:"
            echo "  clusterRole: ${CLUSTER_ROLE}"
        fi
    } > "$MONGOD_CONF"
    log "mongod.conf: port=${MONGO_PORT} replset=${REPLSET:-none} role=${CLUSTER_ROLE:-none}"
}

write_mongos_conf() {
    : "${CONFIG_DB:?mongos needs CONFIG_DB=<cfgReplSet>/<host:port>,...}"
    {
        echo "systemLog:"
        echo "  destination: file"
        echo "  path: /var/log/mongo/mongos.log"
        echo "  logAppend: true"
        echo "net:"
        echo "  port: ${MONGO_PORT}"
        echo "  bindIpAll: true"
        if [ -f "$KEYFILE" ]; then
            echo "security:"
            echo "  keyFile: ${KEYFILE}"
        fi
        echo "sharding:"
        echo "  configDB: ${CONFIG_DB}"
    } > "$MONGOS_CONF"
    log "mongos.conf: port=${MONGO_PORT} configDB=${CONFIG_DB}"
}

# ROLE=client is a host with a PMM client and nothing else, from the WITH_PSMDB=0
# build of this image. There is no server to configure, no keyfile to install
# (nothing here joins a replica set), and no mongod user to chown to - that user
# arrives with percona-server-mongodb-server, which this build does not carry.
# So hand straight over to supervisord, which will find only pmm-agent and
# register-client.sh in its conf.d.
if [ "$ROLE" = "client" ]; then
    log "pmm-client-only host: no database to configure"
    exec "$@"
fi

install_keyfile
if [ "$ROLE" = "mongos" ]; then
    write_mongos_conf
    # supervisord picks the program by role; the unused one stays stopped.
    touch /run/is-mongos
else
    write_mongod_conf
fi

chown -R mongod:mongod /var/lib/mongo /var/log/mongo

exec "$@"
