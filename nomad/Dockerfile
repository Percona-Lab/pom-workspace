# Nomad executor for SEP task dispatch.
#
# SEP submits jobs with Nomad's `raw_exec` driver (see app/tasks/db/seed.py:
# "Driver": "raw_exec"), which runs the command directly on the *client*. So the
# tooling SEP's payloads shell out to has to exist in THIS image:
#
#   python3 + pip  — run-python payloads install their `requirements` at runtime
#   pbm            — the backup_mongo app's payloads call the PBM CLI
#
# PMM's own pmm-agent already bundles a Nomad client
# (/usr/local/percona/pmm/tools/nomad), but the pmm-client image has neither
# python3 nor pbm, so it cannot execute those payloads. Hence this image.
#
# RHEL-compatible base on purpose: pbm is dynamically linked against
# krb5/gssapi, and Percona publishes el9 packages, so this avoids the fragile
# copy-a-binary-into-Debian route.
FROM oraclelinux:9

# Matches the Nomad that PMM 3.9 ships (v2.0.3) so the API surface SEP's
# python-nomad (>=2.0.0,<3.0.0) client talks to is the same major.
ARG NOMAD_VERSION=2.0.4

# Python 3.12, not OL9's default 3.9. SEP minifies run-python payloads
# (TASKS__NOMAD__MINIFY_PAYLOAD) and the minifier collapses quotes into f-string
# expressions, e.g.  f"{D.stdout or ""}".  That quote reuse is PEP 701, valid only
# on 3.12+; under 3.9 the payload dies with
#     SyntaxError: f-string: expecting '}'
# even though the unminified source compiles fine on 3.9. The job template runs
# `python3 -m venv`, so `python3` must BE 3.12 — hence the alternatives link
# below, rather than just installing the package alongside.
RUN dnf install -y --setopt=install_weak_deps=False \
      unzip curl ca-certificates procps-ng iproute \
      python3.12 python3.12-pip \
 && alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 100 \
 && dnf clean all

# PBM CLI, for the backup_mongo payloads.
RUN rpm -Uvh https://repo.percona.com/yum/percona-release-latest.noarch.rpm \
 && percona-release enable-only pbm release \
 && dnf install -y --setopt=install_weak_deps=False percona-backup-mongodb \
 && dnf clean all

RUN curl -fsSL -o /tmp/nomad.zip \
      "https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_linux_amd64.zip" \
 && unzip -o -d /usr/local/bin /tmp/nomad.zip \
 && rm -f /tmp/nomad.zip \
 && chmod +x /usr/local/bin/nomad

# Fail the build rather than ship an image missing what raw_exec payloads need.
# Assert the toolchain rather than discover a gap at task-execution time. The
# f-string check is the exact construct SEP's minifier emits: it is a SyntaxError
# before 3.12, so this fails the build if `python3` ever resolves to an older one.
RUN nomad version \
 && python3 -V \
 && python3 -c 'import sys; assert sys.version_info >= (3, 12), sys.version' \
 && python3 -c 'x="ok"; print(f"pep701 {x or ""}")' \
 && python3 -m venv --help >/dev/null \
 && python3 -m pip --version \
 && (pbm version || pbm --version)

RUN mkdir -p /nomad/data /etc/nomad.d

EXPOSE 4646
ENTRYPOINT ["/usr/local/bin/nomad"]
CMD ["agent", "-config=/etc/nomad.d/nomad.hcl"]
