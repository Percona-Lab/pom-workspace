# PSMDB sandbox node — one container per database host.
#
# Deliberately *not* percona/percona-server-mongodb: that image is RHEL 9 UBI
# with microdnf, it runs as uid 1001, and it carries mongod alone. This node has
# to be a stand-in for a real database host, which means four things in one
# container:
#
#   mongod / mongos   the database
#   pbm-agent         backups, the way the SEP backup_mongo payloads expect
#   pmm-agent         monitoring — and, from >= 3.2.0, a Nomad *client*, which is
#                     what lets SEP dispatch work onto the host that owns the data
#   python3 + venv    SEP's run-python payloads build a venv and pip-install into
#                     it at runtime (see the run-python job spec in SEP's seed.py)
#
# Ubuntu rather than Oracle Linux because the point of this image is that PSMDB
# is *package-managed and upgradable in place*: `apt-get install
# percona-server-mongodb-server=<newer>` + a supervisord restart is the rolling
# upgrade loop, run as a SEP payload through the Nomad client that lives here.
#
# Everything is installed from Percona's apt repos, pinned to a major series via
# PSMDB_REPO, so the upgrade target is a repo switch rather than a new image.

FROM ubuntu:24.04

# The major series this image is *built* on. An upgrade payload switches the repo
# (percona-release enable-only psmdb-80) and installs over the top; it does not
# need a rebuild.
ARG PSMDB_REPO=psmdb-70

# Debian maintainer scripts start services on install. There is no init system
# here and supervisord owns process lifecycle, so tell them not to: without this
# the postinst for percona-server-mongodb-server fails the build, and later an
# in-container upgrade would too.
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
    && chmod +x /usr/sbin/policy-rc.d

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg procps jq iproute2 \
        python3 python3-venv python3-pip \
        supervisor \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/percona-release.deb \
        https://repo.percona.com/apt/percona-release_latest.generic_all.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends /tmp/percona-release.deb \
    && rm -f /tmp/percona-release.deb \
    && rm -rf /var/lib/apt/lists/*

# enable-only pins the PSMDB series; pbm and pmm3-client are additive. Leaving
# these repo definitions in the image is the point — they are what makes an
# in-container `apt-get install` work later.
RUN percona-release enable-only "${PSMDB_REPO}" release \
    && percona-release enable pbm release \
    && percona-release enable pmm3-client release \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        percona-server-mongodb-server \
        percona-server-mongodb-mongos \
        percona-server-mongodb-shell \
        percona-mongodb-mongosh \
        percona-backup-mongodb \
        pmm-client \
    && rm -rf /var/lib/apt/lists/*

# The Nomad client the pmm-client deb ships (build/packages/deb/install:7 in the
# pmm repo). Asserted at build time: if a future pmm-client drops it, the image
# fails here rather than silently producing nodes SEP cannot dispatch to.
RUN test -x /usr/local/percona/pmm/tools/nomad

RUN mkdir -p /var/lib/mongo /var/log/mongo /var/lib/pbm /srv/scripts \
    && chown -R mongod:mongod /var/lib/mongo /var/log/mongo /var/lib/pbm

COPY supervisord.conf /etc/supervisor/conf.d/node.conf
COPY scripts/ /srv/scripts/
RUN chmod +x /srv/scripts/*.sh

EXPOSE 27017 27018 27019
ENTRYPOINT ["/srv/scripts/entrypoint.sh"]
CMD ["supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]
