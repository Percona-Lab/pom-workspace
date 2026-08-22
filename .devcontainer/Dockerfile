# The OpenManager workspace image.
#
# ONE image serves three callers, and that is the whole point of the layout:
#
#   * the VS Code dev container (.devcontainer/devcontainer.json)
#   * GitHub Actions jobs      (.github/workflows/*.yml)
#   * a plain `docker run` on any machine with a Docker daemon
#
# So everything is installed here rather than through devcontainer "features":
# features are layered on by the devcontainer builder only, and an image built
# with `docker build` would come out with no Docker, no Node and no gh - which is
# exactly what a CI job needs.
#
# Carries what runs *natively* in this workspace: SEP's Python backend, SEP's
# Node frontend, `./om` itself, and agent CLIs. PMM is not built here - `./om
# build pmm` compiles inside PMM's own container, which the inner Docker daemon
# runs.
#
#   docker build -t openmanager-dev .devcontainer

ARG BASE=mcr.microsoft.com/devcontainers/base:ubuntu-24.04
FROM ${BASE}

# Pinned to pmm/go.mod. Only needed so gopls can index pmm/ - the server binaries
# are built inside the PMM container.
ARG GO_VERSION=1.26.5
# om requires >= 22.22.0 for SEP's frontend.
ARG NODE_MAJOR=22
# om pins this through corepack.
ARG PNPM_VERSION=11.1.3
# Extra global npm packages, for agent CLIs other than Claude Code. Set at build
# time rather than baked in, because their package names are yours to choose:
#   docker build --build-arg EXTRA_NPM_PACKAGES="@some/agent-cli" .devcontainer
ARG EXTRA_NPM_PACKAGES=""

ENV DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# System packages
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
      # build toolchain: SEP has C extensions in its dependency tree
      build-essential g++ pkg-config make \
      # SEP backend: python3.12 on Ubuntu 24.04 satisfies pyproject's >=3.11.9,<3.14
      # python3-yaml is not optional: om renders harness/sep-settings.yaml with
      # the *system* interpreter on every invocation, before any venv exists,
      # so `./om doctor` fails at step one without it.
      python3 python3-venv python3-dev python3-pip python3-yaml \
      # SEP runtime libs, mirrored from SEP/Dockerfile
      libmagic1 libpango-1.0-0 libpangoft2-1.0-0 fontconfig fonts-dejavu shared-mime-info \
      libpq-dev \
      # what om, the agents and day-to-day debugging shell out to
      ca-certificates curl wget gnupg git jq ripgrep unzip file less vim sudo \
      netcat-openbsd iproute2 iputils-ping dnsutils postgresql-client \
      # dockerd's own requirements
      iptables uidmap \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Docker engine, CLI, compose and buildx.
#
# The engine, not just the client: this image runs its own daemon on its own
# /var/lib/docker, so containers it starts are invisible to whatever host it is
# running on. That is what makes it safe to hand an agent bypassed permissions,
# and it is what makes pmm/docker-compose.dev.yml's relative bind mounts resolve
# against this filesystem rather than the host's.
# ---------------------------------------------------------------------------
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
         docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && usermod -aG docker vscode

# Inner Docker's storage. Declared so `docker run` without an explicit -v still
# gets a fresh writable layer rather than fighting the image's overlay.
VOLUME /var/lib/docker

# ---------------------------------------------------------------------------
# GitHub CLI - the workspace pushes branches and opens PRs through it, and CI
# jobs authenticate it from GH_TOKEN.
# ---------------------------------------------------------------------------
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       -o /etc/apt/keyrings/githubcli.gpg \
    && chmod a+r /etc/apt/keyrings/githubcli.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Node, pnpm, and the agent CLIs
# ---------------------------------------------------------------------------
#
# pnpm comes from npm rather than `corepack prepare`. corepack caches its
# activation under $HOME, so a version prepared here as root is invisible to the
# unprivileged user the container actually runs as - and `corepack enable` would
# install a shim into the same /usr/bin that npm -g uses, shadowing whatever it
# resolved. A global npm install is version-pinned, user-independent and needs no
# network at run time.
RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && npm install -g "pnpm@${PNPM_VERSION}" @anthropic-ai/claude-code ${EXTRA_NPM_PACKAGES} \
    && npm cache clean --force

# ---------------------------------------------------------------------------
# Go toolchain, pinned to pmm/go.mod. Drop this block if you never open Go files.
# ---------------------------------------------------------------------------
RUN arch="$(dpkg --print-architecture)" \
    && curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${arch}.tar.gz" \
       | tar -C /usr/local -xz \
    && /usr/local/go/bin/go version

ENV GOPATH=/home/vscode/go
ENV PATH=/usr/local/go/bin:/home/vscode/go/bin:/home/vscode/.local/bin:${PATH}

# `./om hosts --write` edits /etc/hosts and the entrypoint bumps inotify limits.
# Passwordless because this container is disposable by design.
RUN echo 'vscode ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/vscode \
    && chmod 0440 /etc/sudoers.d/vscode

COPY start-docker.sh entrypoint.sh seed-claude.sh /usr/local/bin/
RUN chmod 0755 /usr/local/bin/start-docker.sh /usr/local/bin/entrypoint.sh \
                /usr/local/bin/seed-claude.sh

# The dev container overrides this and starts dockerd from postStartCommand
# instead; CI and plain `docker run` get it here. See entrypoint.sh.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
