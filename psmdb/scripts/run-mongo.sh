#!/usr/bin/env bash
# Run whichever server this node is. One supervisord program rather than two
# conditional ones, so `supervisorctl restart mongo` is the same command on every
# node — which matters when a rolling-upgrade payload targets nodes generically.
#
# --fork is deliberately absent: supervisord must own a foreground process.
# Logging still goes to the file in the config; supervisord's stdout capture
# picks up the startup banner and any hard failure.

set -o errexit
set -o nounset

if [ -f /run/is-mongos ]; then
    exec setpriv --reuid=mongod --regid=mongod --init-groups \
        /usr/bin/mongos --config /etc/mongos-node.conf
fi

exec setpriv --reuid=mongod --regid=mongod --init-groups \
    /usr/bin/mongod --config /etc/mongod-node.conf
