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
# percona-server-mongodb-server=<newer>` + `systemctl restart mongod` is the
# rolling upgrade loop, run as a SEP payload through the Nomad client that lives
# here - the same command a real, non-containerized host would use, because
# this image runs systemd as PID 1 (see below).
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
#
# BASE_OS additionally selects the distro, ubuntu (default) or rocky. This exists
# because SEP's om_bootstrap app (app/sep/apps/om_bootstrap/strategies/packages.py)
# already implements both apt/dpkg and dnf/rpm install paths - PMM-15347's
# bootstrap flow picks one per host from om_inventory's `os_id` probe fact - but
# until now nothing in this sandbox could ever report `os_id: rocky`, so that path
# had no host to actually run against. Scoped to WITH_PSMDB=0 client-only hosts:
# bootstrap's job is installing PSMDB *onto* a bare host, so that is the only
# variant that needs to exist per OS. The four pre-built database topologies
# (WITH_PSMDB=1) stay Ubuntu-only - they are already-configured infrastructure,
# not a bootstrap target, and PSMDB_REPO's in-place-upgrade story above is
# unaffected either way.
ARG BASE_OS=ubuntu
FROM ubuntu:24.04 AS base-ubuntu
FROM rockylinux:9 AS base-rocky
FROM base-${BASE_OS} AS base

# Redeclared: an ARG used only in a FROM line above this point is not otherwise
# visible to the instructions that follow it (Dockerfile scoping rule) - every
# `${BASE_OS}` branch below needs it live again.
ARG BASE_OS=ubuntu

# The major series this image is *built* on. An upgrade payload switches the repo
# (percona-release enable-only psmdb-80) and installs over the top; it does not
# need a rebuild.
ARG PSMDB_REPO=psmdb-70

# 1 for a database node, 0 for a pmm-client-only host. Everything that differs
# between the two is conditional on this single argument, so the client build
# cannot drift into being a different base image with a different libc, a
# different python or a different pmm-client than the nodes it sits beside.
ARG WITH_PSMDB=1

# Debian maintainer scripts start services on install, and this image wants
# package-install and service-start to stay two separate, individually
# observable steps even though systemd is present (see below) - so tell
# postinst scripts not to. Without this the postinst for
# percona-server-mongodb-server fails the build, and later an in-container
# upgrade or a bootstrap payload's own `apt-get install` would too, racing
# against whatever config that payload has not written yet.
#
# RPM scriptlets have no equivalent hazard here: percona-server-mongodb's spec
# guards its own `%systemd_post` with `[ -d /run/systemd/system ]` before calling
# systemctl, which is never true mid-`docker build` (no systemd is running yet),
# so `dnf install` on the rocky branch never races a service start the way dpkg's
# unconditional postinst does.
RUN if [ "${BASE_OS}" = "ubuntu" ]; then \
        printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
        && chmod +x /usr/sbin/policy-rc.d; \
    fi

# Tells systemd it is running in a container: since v183 it reads this to skip
# things a container cannot or should not do itself (mounting real filesystems,
# udev, hardware watchdogs, ...) rather than needing the elaborate unit-masking
# older systemd-in-Docker guides carry. Set here rather than only at `docker
# run` time so it is true for every consumer of this image, including `./om`.
ENV container=docker

# Package names split between apt's finer-grained tooling packages and dnf's
# coarser ones (systemd/dbus/python3-venv already ship inside rockylinux:9's own
# base packages, so rocky's list is shorter, not just renamed) - iproute2/iproute
# and gnupg/gnupg2 are the two that actually differ by name rather than presence.
# --allowerasing: rockylinux:9 ships curl-minimal, which the full curl package
# conflicts with by design (both provide /usr/bin/curl) - confirmed against a
# real build, which fails here without it.
RUN if [ "${BASE_OS}" = "ubuntu" ]; then \
        apt-get update \
        && apt-get install -y --no-install-recommends \
            ca-certificates curl gnupg procps jq iproute2 \
            python3 python3-venv python3-pip \
            systemd systemd-sysv dbus \
            sudo \
        && rm -rf /var/lib/apt/lists/*; \
    else \
        dnf install -y --allowerasing \
            ca-certificates curl gnupg2 procps-ng jq iproute \
            python3 python3-pip \
            sudo \
        && dnf clean all; \
    fi

# percona-release is the one component whose install mechanism genuinely differs
# (a fetched .deb vs. a fetched .rpm) - everything after this installs through it
# and is package-manager-agnostic from here on, mirroring SEP's own
# _configure_repository step (app/sep/apps/om_bootstrap/strategies/packages.py) so
# a bootstrap run does on a real host exactly what this image already did at
# build time.
RUN if [ "${BASE_OS}" = "ubuntu" ]; then \
        curl -fsSL -o /tmp/percona-release.deb \
            https://repo.percona.com/apt/percona-release_latest.generic_all.deb \
        && apt-get update \
        && apt-get install -y --no-install-recommends /tmp/percona-release.deb \
        && rm -f /tmp/percona-release.deb \
        && rm -rf /var/lib/apt/lists/*; \
    else \
        dnf install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm \
        && dnf clean all; \
    fi

# enable-only pins the PSMDB series; pbm and pmm3-client are additive. Leaving
# these repo definitions in the image is the point — they are what makes an
# in-container `apt-get install`/`dnf install` work later.
#
# All three are enabled in both builds, including the psmdb-* ones the client
# build installs nothing from. That is deliberate: it is what lets a payload turn
# a bare host into a database host with a package install, which is the same seam
# the in-place upgrade uses on a node that already has one.
#
# percona-server-mongodb is one meta-package on the yum side (unlike apt's four
# separate server/mongos/shell/mongosh packages) - the same name SEP's
# _install_package step installs for a rocky host, so this image's WITH_PSMDB=1
# build stays a true preview of what a bootstrap run does.
RUN percona-release enable-only "${PSMDB_REPO}" release \
    && percona-release enable pbm release \
    && percona-release enable pmm3-client release \
    && if [ "${BASE_OS}" = "ubuntu" ]; then \
        apt-get update \
        && apt-get install -y --no-install-recommends pmm-client \
        && if [ "${WITH_PSMDB}" = "1" ]; then \
            apt-get install -y --no-install-recommends \
                percona-server-mongodb-server \
                percona-server-mongodb-mongos \
                percona-server-mongodb-shell \
                percona-mongodb-mongosh \
                percona-backup-mongodb; \
        fi \
        && rm -rf /var/lib/apt/lists/*; \
    else \
        dnf install -y pmm-client \
        && if [ "${WITH_PSMDB}" = "1" ]; then \
            dnf install -y percona-server-mongodb percona-backup-mongodb; \
        fi \
        && dnf clean all; \
    fi

# The Nomad client the pmm-client package ships (build/packages/deb/install:7 in
# the pmm repo - the rpm carries the same path). Asserted at build time: if a
# future pmm-client drops it, the image fails here rather than silently
# producing nodes SEP cannot dispatch to.
RUN test -x /usr/local/percona/pmm/tools/nomad

# The mongod user is created by percona-server-mongodb-server's postinst, so it
# exists only in the database build - hence the guard rather than an
# unconditional chown that would fail the client build.
RUN mkdir -p /srv/scripts \
    && if [ "${WITH_PSMDB}" = "1" ]; then \
        mkdir -p /var/lib/mongo /var/log/mongo /var/lib/pbm \
        && chown -R mongod:mongod /var/lib/mongo /var/log/mongo /var/lib/pbm; \
    fi

# One unit file per program, so the process table is assembled from parts
# rather than switched between two whole copies: pmm-agent.service is the same
# on every node and is always enabled, and only the database units are
# conditional. "Enabling" a unit is just the symlink `systemctl enable` would
# create - done directly here so it works at build time with no systemd running
# yet, rather than depending on `systemctl` reaching a live daemon over D-Bus.
#
# -f on every ln: the pmm-client .deb's postinst already enables its own
# packaged pmm-agent.service (deb-systemd-helper runs regardless of
# policy-rc.d, which only blocks *starting* a service, not *enabling* one) -
# harmless, since our /etc/systemd/system/pmm-agent.service below overrides
# the package's /usr/lib/systemd/system/ copy by path precedence regardless of
# what the pre-existing symlink target says, but the symlink itself has to be
# forced or this step fails on a name dpkg got to first. The rpm's own
# %systemd_post scriptlet is a no-op at build time (see the policy-rc.d
# comment above), so -f is just a harmless no-op there rather than a fix for
# an equivalent race.
#
# WITH_PSMDB=1 additionally masks the *packaged* mongod.service.
# percona-server-mongodb-server's postinst enables it the same way pmm-client's
# postinst enables pmm-agent.service above - but this one is a live conflict,
# not just a build nuisance: at boot systemd starts every enabled unit
# automatically (policy-rc.d only blocks postinst-triggered starts, not
# systemd's own unit activation), so the packaged unit binds :27017 from
# /etc/mongod.conf a few seconds before mongo.service gets there with
# /etc/mongod-node.conf, and mongo.service then fails to bind with "Address
# already in use". Masking - a symlink to /dev/null, winning the same
# path-precedence race the pmm-agent.service override above relies on - makes
# systemd refuse to start it under any name, leaving mongo.service as this
# image's only owner of the mongod process. Not applied on the WITH_PSMDB=0
# build, where percona-server-mongodb-server is not installed at build time at
# all: a bootstrap payload installing it later is meant to get a live,
# controllable mongod.service, not a masked one.
COPY systemd/ /srv/systemd/
RUN mkdir -p /etc/systemd/system/multi-user.target.wants \
    && cp /srv/systemd/pmm-agent.service /etc/systemd/system/ \
    && ln -sf /etc/systemd/system/pmm-agent.service \
        /etc/systemd/system/multi-user.target.wants/pmm-agent.service \
    && if [ "${WITH_PSMDB}" = "1" ]; then \
        for unit in mongo pbm-agent cluster-init register; do \
            cp "/srv/systemd/${unit}.service" /etc/systemd/system/; \
            ln -sf "/etc/systemd/system/${unit}.service" \
                "/etc/systemd/system/multi-user.target.wants/${unit}.service"; \
        done \
        && ln -sf /dev/null /etc/systemd/system/mongod.service; \
    else \
        cp /srv/systemd/register-client.service /etc/systemd/system/ \
        && ln -sf /etc/systemd/system/register-client.service \
            /etc/systemd/system/multi-user.target.wants/register-client.service; \
    fi

COPY scripts/ /srv/scripts/
RUN chmod +x /srv/scripts/*.sh

EXPOSE 27017 27018 27019
# systemd's clean-shutdown signal, so `docker stop` (and compose's `down`) ask
# it to shut down properly - stopping every enabled unit in dependency order -
# instead of racing SIGTERM against whatever mongod itself does with it.
STOPSIGNAL SIGRTMIN+3
ENTRYPOINT ["/srv/scripts/entrypoint.sh"]
CMD ["/sbin/init"]
