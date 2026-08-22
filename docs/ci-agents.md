# Running workspace jobs and agents on GitHub

The same image the dev container opens is what GitHub jobs run. That is the whole
design: `.devcontainer/Dockerfile` installs Docker, Node, pnpm, Go, `gh` and
Claude Code itself, so `docker build .devcontainer` yields an image that is
complete on its own, with no dependency on the devcontainer builder. A command
you debugged in your editor runs unchanged in a workflow.

See [docs/devcontainer.md](devcontainer.md) for the local half.

## What is here

| path | what it is |
|---|---|
| `.github/workflows/image.yml` | builds `.devcontainer/`, publishes `ghcr.io/<owner>/openmanager-dev`, smoke-tests it |
| `.github/actions/om-checkout` | checks out this repo **and** `pmm/` + `SEP/`, over HTTPS |
| `.github/actions/om-run` | runs a script inside the image, with the checkout mounted and the inner daemon up |
| `.github/workflows/agent.yml` | runs Claude (or another agent) against the workspace, optionally opening a PR |
| `.github/workflows/checks.yml` | ordinary CI, and the template for any non-agent job |

A job is three steps: `om-checkout`, a GHCR login, `om-run`. Everything else is
the script you pass to `om-run`.

## Secrets to set

Settings → Secrets and variables → Actions.

| secret | needed for | notes |
|---|---|---|
| `WORKSPACE_TOKEN` | **anything touching `pmm/` or `SEP/`** | PAT with `contents: read` on `plebioda/pmm` and `plebioda/SEP`. Add `contents: write` + `pull-requests: write` to let agent jobs push branches. |
| `ANTHROPIC_API_KEY` | Claude, API billing | or ↓ |
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude, subscription billing | generate with `claude setup-token` |
| `OPENAI_API_KEY`, `GEMINI_API_KEY` | other agents | optional, forwarded automatically |

`WORKSPACE_TOKEN` is the one people trip over. `.gitmodules` points at
`git@github.com:` URLs, and no GitHub-hosted runner can resolve those without a
deploy key; the built-in `GITHUB_TOKEN` is scoped to this repository alone and
cannot clone the submodules either. `om-checkout` rewrites the URLs to HTTPS with
this token, in the runner's *global* git config, so `.gitmodules` stays untouched
and no job produces a spurious diff.

## Running an agent

```
Actions → agent → Run workflow → type the task
```

or comment on any issue or PR:

```
/agent update the POM discovery notes to match the current estate API
```

The comment path is gated on `author_association` being `OWNER`, `MEMBER` or
`COLLABORATOR`. Do not loosen that. Anyone who can trigger this workflow can
spend your Claude credits, and - because the agent runs with permissions bypassed
and a GitHub token in its environment - can steer it with whatever text they put
in the comment. Treat issue and PR text as untrusted input to the agent, because
it is.

The agent commits only the superproject. If it edited `pmm/` or `SEP/`, the job
warns and leaves those changes uncommitted: recording a moved gitlink here would
point at objects nobody can fetch. Land submodule work in its own repository.

For plain "review this PR" or "reply to this issue" automation, use
[`anthropics/claude-code-action`](https://github.com/anthropics/claude-code-action)
instead. It is maintained and handles the GitHub side properly. This workflow is
for what that action cannot do: an agent that needs the whole OpenManager
toolchain, both submodules, and a Docker daemon.

## What actually fits on a hosted runner

`ubuntu-latest` is 4 vCPU, 16 GB RAM, and roughly 14 GB of free disk. Against
that:

| job | hosted runner? |
|---|---|
| lint, unit tests, agents editing code | **yes** - and pass `docker: false`, so the container is unprivileged with no inner daemon |
| `./om start pmm sep` | marginal. PMM plus ClickHouse plus VictoriaMetrics is most of the RAM, and the images are most of the disk |
| `./om start` with clusters | **no.** The images alone are 15-20 GB |

The `stack` job in `checks.yml` exists to show the shape, and is
`workflow_dispatch`-only for that reason. Point it at a larger runner or a
self-hosted one before expecting it to pass; `docs/devcontainer.md` covers the
resource story.

`docker: false` is worth using deliberately rather than by default-off: it drops
`--privileged`, and most jobs genuinely do not need a Docker daemon.

## Adding another agent

Two supported routes, neither of which needs this file to change:

**Build the CLI into the image.** `EXTRA_NPM_PACKAGES` is a build arg:

```bash
docker build --build-arg EXTRA_NPM_PACKAGES="@some/agent-cli" .devcontainer
```

Set it in `image.yml`'s `build-push-action` step to make it permanent.

**Run it as `agent: custom`.** `workflow_dispatch` takes a `custom_command`; the
task text arrives as `$OM_TASK`, and `OPENAI_API_KEY` / `GEMINI_API_KEY` are
already forwarded. Anything else you need forwarded goes in `om-run`'s
`forward-env` input.

## Why the agent runs unprivileged inside a privileged container

`entrypoint.sh` starts as root - `dockerd` requires it - then drops to `vscode`
before exec'ing your command. Both halves are load-bearing:

- Claude Code refuses `--dangerously-skip-permissions` when running as root, so
  the agent has to be unprivileged.
- The inner daemon has to be root, so the entrypoint has to start as root.

`setpriv` is used rather than `sudo` because it leaves the environment alone,
which matters when the job passed `ANTHROPIC_API_KEY` in. The one thing it does
rewrite is `HOME`: `setpriv` changes the uid and nothing else, and `gh`, `npm`,
`git` and `claude` all keep per-user state under `$HOME`, so leaving it as
`/root` makes every one of them fail on permissions.

The container also takes ownership of the mounted checkout so the unprivileged
user can write to it, and `om-run` hands it back to the runner afterwards -
otherwise every later step, down to `actions/checkout`'s own cleanup, fails.
