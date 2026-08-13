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
#
# Built twice, from this one file:
#
#   WITH_PSMDB=1  the database node above - openmanager/psmdb-node
#   WITH_PSMDB=0  a host with a PMM client and nothing else, no mongod, no
#                 pbm-agent, no PSMDB packages at all - openmanager/pmm-client-node
#
# The second is not a stripped-down curiosity: it is what a machine looks like
# before anyone puts a database on it. It still carries pmm-agent's Nomad client,
# so PMM lists it as a node and SEP will dispatch to it, which makes it the place
# to develop a payload that has no database to talk to - and the starting point
# for one that installs a database, since the psmdb repos are enabled either way.

FROM ubuntu:24.04

# The major series this image is *built* on. An upgrade payload switches the repo
# (percona-release enable-only psmdb-80) and installs over the top; it does not
# need a rebuild.
ARG PSMDB_REPO=psmdb-70

# 1 for a database node, 0 for a pmm-client-only host. Everything that differs
# between the two is conditional on this single argument, so the client build
# cannot drift into being a different base image with a different libc, a
# different python or a different pmm-client than the nodes it sits beside.
ARG WITH_PSMDB=1

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
#
# All three are enabled in both builds, including the psmdb-* ones the client
# build installs nothing from. That is deliberate: it is what lets a payload turn
# a bare host into a database host with an apt install, which is the same seam
# the in-place upgrade uses on a node that already has one.
RUN percona-release enable-only "${PSMDB_REPO}" release \
    && percona-release enable pbm release \
    && percona-release enable pmm3-client release \
    && apt-get update \
    && apt-get install -y --no-install-recommends pmm-client \
    && if [ "${WITH_PSMDB}" = "1" ]; then \
        apt-get install -y --no-install-recommends \
            percona-server-mongodb-server \
            percona-server-mongodb-mongos \
            percona-server-mongodb-shell \
            percona-mongodb-mongosh \
            percona-backup-mongodb; \
    fi \
    && rm -rf /var/lib/apt/lists/*

# The Nomad client the pmm-client deb ships (build/packages/deb/install:7 in the
# pmm repo). Asserted at build time: if a future pmm-client drops it, the image
# fails here rather than silently producing nodes SEP cannot dispatch to.
RUN test -x /usr/local/percona/pmm/tools/nomad

# The mongod user is created by percona-server-mongodb-server's postinst, so it
# exists only in the database build - hence the guard rather than an
# unconditional chown that would fail the client build.
RUN mkdir -p /srv/scripts \
    && if [ "${WITH_PSMDB}" = "1" ]; then \
        mkdir -p /var/lib/mongo /var/log/mongo /var/lib/pbm \
        && chown -R mongod:mongod /var/lib/mongo /var/log/mongo /var/lib/pbm; \
    fi

# supervisord's conf.d is a glob, so the process table is assembled from parts
# rather than switched between two whole copies: pmm-agent is the same program on
# every node and is declared once, and only the database programs are conditional.
COPY supervisord/ /srv/supervisord/
RUN cp /srv/supervisord/pmm-agent.conf /etc/supervisor/conf.d/ \
    && if [ "${WITH_PSMDB}" = "1" ]; then \
        cp /srv/supervisord/psmdb.conf /etc/supervisor/conf.d/; \
    else \
        cp /srv/supervisord/client.conf /etc/supervisor/conf.d/; \
    fi

COPY scripts/ /srv/scripts/
RUN chmod +x /srv/scripts/*.sh

EXPOSE 27017 27018 27019
ENTRYPOINT ["/srv/scripts/entrypoint.sh"]
CMD ["supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]
