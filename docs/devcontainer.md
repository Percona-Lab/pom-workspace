# Running the whole workspace in a container

`.devcontainer/` builds one container that holds the entire OpenManager stack -
`./om`, SEP running natively, and an inner Docker daemon that runs PMM, PMM's
build container and the PSMDB clusters. You attach VS Code to it and work
normally. The point is that an agent running with permissions bypassed cannot
reach anything on your machine except the workspace itself.

## One image, three callers

The same image serves the dev container, GitHub Actions jobs
([docs/ci-agents.md](ci-agents.md)), and a plain `docker run` anywhere. That is
why the toolchain - Docker, Node, pnpm, Go, `gh`, Claude Code - is installed in
the Dockerfile rather than through devcontainer *features*: features are layered
on by the devcontainer builder alone, so a `docker build` of a feature-based
Dockerfile comes out with none of them, which is useless to CI. Keeping it in the
Dockerfile is what stops local and CI drifting apart.

```bash
docker build -t openmanager-dev .devcontainer     # works on its own, no devcontainer CLI
```

## What is isolated, and what is not

| | |
|---|---|
| host filesystem outside the workspace | **not visible** - only `${localWorkspaceFolder}` is mounted |
| host Docker daemon | **not visible** - the container runs its own `dockerd` on its own `/var/lib/docker` volume |
| host containers, images, volumes, networks | **not visible** - `docker ps` inside shows only what you started inside |
| host `/etc/hosts`, ports, packages | **not touched** - `./om hosts --write` edits the container's copy |
| your `~/.claude` | **read-only**, and only to seed the container's own copy once |
| **the workspace itself** | **shared, read-write.** This is your real checkout. |
| **the host kernel** | shared. The container is `--privileged`. |

Those last two are the honest limits.

`--privileged` is required by Docker-in-Docker, and a privileged container is not
a security boundary against something actively trying to escape. It is a very
good boundary against *mistakes* - a stray `rm -rf`, a `docker system prune`, a
migration pointed at the wrong database - which is the failure mode agents
actually produce. If you need the stronger property, run this on a throwaway VM,
or swap the runtime for [Sysbox](https://github.com/nestybox/sysbox), which gives
unprivileged Docker-in-Docker.

The workspace being shared is deliberate: `notes/`, `todo/`, `plans/`, `SEP/.env`
and the `harness/` state are all untracked and irreplaceable, and a container
that could not see them would be useless. **Commit or push before you let an
agent loose.** If you want the workspace isolated too, use VS Code's *Dev
Containers: Clone Repository in Container Volume* instead of opening this folder
- you get a fresh clone inside a volume and the host checkout is never mounted,
at the cost of re-doing `./om setup` and your local secrets.

## Why Docker-in-Docker rather than mounting the host socket

Bind-mounting `/var/run/docker.sock` is the usual shortcut, and it is wrong here
twice over:

- **It is not isolation.** Containers still run on the host daemon, so
  `docker run -v /:/host` reaches your real root filesystem. Access to the socket
  is equivalent to root on the host.
- **It breaks the mounts.** `pmm/docker-compose.dev.yml` mounts
  `./:/root/go/src/github.com/percona/pmm`, and `harness/pmm-compose.override.yml`
  mounts `../harness/pmm.conf`. The host daemon resolves those paths on the
  *host*, so they would point at nothing, or at the wrong copy. With an inner
  daemon they resolve inside the container, which is what `./om` assumes.

One happy side effect: the override's `host.docker.internal:host-gateway`, which
lets PMM's nginx reach a natively-running SEP backend, now resolves to the dev
container - exactly where `./om start sep-backend` puts it.

## First run

1. Install the **Dev Containers** VS Code extension (`ms-vscode-remote.remote-containers`).
2. Make sure submodules are present on the host: `git submodule update --init`.
3. `Dev Containers: Reopen in Container`. The image build plus features takes a
   few minutes.
4. Inside the container:

   ```bash
   rm -rf SEP/venv     # if you have ever run ./om setup on the host
   ./om doctor
   ./om setup          # pulls several GB into the inner daemon - first run only
   ./om start
   ./om status
   ```

`./om status` prints host URLs; VS Code forwards 8000, 5174, 8443, 5173, 9090,
9000, 8123 and 5432 to the same numbers on your machine, so those URLs work in
the host browser unchanged. Anything else - a MongoDB node's container IP, for
instance - is reachable from inside the container only; use `Forward a Port` in
the VS Code Ports panel, or `docker exec` as `./om status` suggests.

### Host-built artefacts

The workspace is mounted **at its own host path**, not under `/workspaces`, and
that one choice is what makes your existing `SEP/venv` and `node_modules` trees
work unchanged inside the container. Both bake absolute paths in - every shebang
in `venv/bin`, `bin/activate`, and pnpm's symlink farm - so mounting the tree
anywhere else breaks the host's copy inside the container and the container's copy
outside it, and every switch costs a `make venv`. Same path, one venv, no
bootstrap.

What does not come along is the image cache. Inner Docker starts empty regardless
of what your host daemon has, so the first `./om setup` re-pulls everything.
Budget disk: the `openmanager-dind` volume reaches roughly 15-20 GB with all four
PSMDB topologies and the PMM dev image.

## Claude Code in here

`post-create.sh` runs `seed-claude.sh`, which marks the workspace trusted, copies
your global `~/.claude/CLAUDE.md` in from the read-only host mount, and writes
`~/.claude/settings.json` with:

```json
{ "permissions": { "defaultMode": "bypassPermissions" } }
```

That is the container's **user-level** settings file, living in the
`openmanager-home` volume - not the repo's `.claude/settings.local.json`. Host
sessions on the same checkout keep asking you for permission as before.
`claude --dangerously-skip-permissions` also works; it refuses to run as root,
which is why the container runs as `vscode`.

**You have to log in once inside**: `claude login`. Your host credentials are
deliberately *not* copied - they are OAuth tokens with a rotating refresh token,
so two clients sharing them log each other out. The home volume keeps the
container's own login across rebuilds. See
[delegating-to-an-agent.md](delegating-to-an-agent.md#first-authentication) for
the full story and for the token-based alternative.

MCP servers that authenticate interactively (the claude.ai connectors - Atlassian,
Slack, and the rest) need re-authorising inside the container: only a curated
subset of `~/.claude.json` is copied, and their tokens are not part of it.

## Volumes

| volume | holds | safe to delete |
|---|---|---|
| `openmanager-dind` | inner Docker's images, containers, volumes | yes - costs a re-pull and a `./om setup` |
| `openmanager-home` | the container's `/home/vscode`: Claude login, history, caches | yes - costs a re-login |

`./delegate` uses its own pair, `openmanager-agent-dind` and
`openmanager-agent-home`, so an unattended run cannot disturb your editor's
container.

```bash
docker volume rm openmanager-dind openmanager-home
```

Run that on the **host** to reset the container's world without touching the
workspace.
