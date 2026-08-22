# Delegating a plan to an agent

Write a plan as markdown. Hand it to `./delegate`. An agent implements it inside
a container, with permissions bypassed and nobody to ask, and can boot PMM and
SEP with `./om` to test its own work. You read the report afterwards.

```bash
claude setup-token                                # once, ever
export CLAUDE_CODE_OAUTH_TOKEN=<the token>        # once per shell (put it in your rc)

cp docs/agent-plan-template.md plans/my-thing.md  # write the plan
./delegate plans/my-thing.md --stack              # hand it over
```

That is the whole loop. The rest of this page is what is happening and how to
steer it.

## The three ways to run this workspace in a container

They are the same image, deliberately, so behaviour cannot diverge between them.

| you want | use | see |
|---|---|---|
| to work in an isolated editor yourself | the dev container | [devcontainer.md](devcontainer.md) |
| an agent to implement a plan unattended | `./delegate` | this page |
| CI, or an agent triggered from GitHub | the workflows | [ci-agents.md](ci-agents.md) |

`docker build -t openmanager-dev:local .devcontainer` builds it. `./delegate`
does that for you the first time.

## First, authentication

This is the one thing you must set up, and the one thing that is not obvious.

`./delegate` will **not** reuse your interactive Claude login, because it cannot
safely. Those are OAuth credentials with a *rotating* refresh token: when the
copy inside the container refreshes, the server issues a new refresh token and
invalidates the old one, so whichever of the two clients refreshes second is
logged out. An earlier version of this harness did copy them, and the symptom was
a container that worked once and then reported `OAuth session expired and could
not be refreshed` - which reads like a broken container rather than the
shared-token conflict it actually is.

So use a credential meant to be shared. Any one of:

```bash
claude setup-token && export CLAUDE_CODE_OAUTH_TOKEN=<token>   # recommended
export ANTHROPIC_API_KEY=<key>                                 # API billing
./delegate --shell     # then `claude login` in there, once; the home volume keeps it
```

With none of them, a run stops immediately with exit 78 and prints these three
options rather than failing somewhere confusing later.

## Running it

```bash
./delegate plans/my-thing.md                    # implement, no stack
./delegate plans/my-thing.md --stack            # boot pmm + sep first
./delegate plans/my-thing.md --clusters replicaset-cluster
                                                # ...and a 3-node replica set
./delegate plans/my-thing.md --branch pom/xyz   # commit onto a new branch
./delegate plans/my-thing.md --detach           # do not sit and watch
```

Ctrl-C only detaches you; the run continues.

```bash
./delegate --list              # every run, newest first
./delegate --logs last         # follow a running one, or page a finished one
./delegate --stop last         # kill it
```

To watch it work, or to poke at what it built:

```bash
./delegate plans/my-thing.md --stack --publish --keep
```

`--publish` maps 8443, 8000, 5174 and 5173 onto your machine, skipping any that
are already busy - so PMM is at https://localhost:8443 while the agent works.
`--keep` holds the container open after the agent finishes, so the stack stays
up:

```bash
./delegate --attach last        # a shell in the still-running container
```

## What you get back

Every run leaves `.om/agent/<run-id>/` (gitignored):

| file | what it is |
|---|---|
| `report.md` | the agent's own account: what it did, verified, assumed, skipped |
| `log.txt` | everything it printed, complete for `--detach` runs too |
| `commits.txt`, `diff.patch` | the superproject, against the commit the run started from |
| `commits-pmm.txt`, `diff-pmm.patch` | same for each submodule |
| `prompt.md` | exactly what it was told: the brief, then your plan |
| `plan.md`, `start-ref` | the plan as given, and where it started |
| `body.sh`, `run.sh` | the script the container ran, re-runnable by hand |

Read `report.md` first, then `git log`. Treat the report as a claim to check, not
a result: the brief tells it to paste real command output, so verify against
`log.txt` when something matters.

Undo everything:

```bash
git reset --hard $(cat .om/agent/<run-id>/start-ref)
```

`./delegate` prints that command with the ref filled in when the run ends.

## What is protected, and what is not

**Protected.** Everything on your machine outside this directory. Your Docker
daemon - the container runs its own, so `docker ps` inside shows only what the
agent started, and the agent cannot see or stop your containers. Your
`~/.claude`, mounted read-only. The host `/etc/hosts`, packages and ports.

**Not protected: this working tree.** The agent edits it directly, because that
is the job. Three things blunt that:

- `./delegate` refuses to start on a dirty tree. With `--dirty` it takes a
  recoverable snapshot first (`git stash create`) and tells you the sha.
- It records the starting commit and prints the undo command.
- The brief forbids pushing, opening PRs and touching remotes, so nothing leaves
  the machine without you.

None of that survives an agent that deletes `.git`. Push anything you would hate
to lose. If you want the tree isolated too, run the agent against a git worktree
instead - it costs a submodule checkout, and two stacks no longer collide
because each container has its own daemon and its own network.

**Also not a security boundary:** the container is `--privileged`, which
Docker-in-Docker requires. It stops accidents, not a determined escape. For that,
a throwaway VM or [Sysbox](https://github.com/nestybox/sysbox).

## How it works

`./delegate` does six things:

1. **Checks you can authenticate**, and that the tree is clean.
2. **Builds the image** if it is missing (`.devcontainer/Dockerfile`).
3. **Renders the prompt** into `.om/agent/<id>/prompt.md`: `harness/agent-brief.md`
   first, then your plan. The brief is the standing half - unattended, verify
   with `./om`, commit in steps, no `Co-Authored-By`, write a report - so plans
   stay about the work.
4. **Generates `body.sh`**, the script the container runs. Left on disk, so a
   failed run is readable and re-runnable.
5. **Starts the container** detached, with its own Docker daemon, the workspace
   bind-mounted **at its own host path**, and a persistent home volume.
6. **Follows the log**, then collects commits, diffs and the exit code.

Inside, `entrypoint.sh` starts as root because `dockerd` needs root, then drops
to `vscode` before running anything - Claude Code refuses
`--dangerously-skip-permissions` as root, so both halves are necessary.
`seed-claude.sh` then marks the workspace trusted, sets `bypassPermissions` as
the default mode, and copies your global `CLAUDE.md` in.

### Two details that look cosmetic and are not

**The workspace is mounted at its own host path**, not under `/workspaces`.
`SEP/venv` bakes absolute paths into every shebang and into `bin/activate`, and
pnpm's `node_modules` are full of absolute symlinks. Mount the tree anywhere else
and the host's venv is broken inside the container and the container's is broken
outside it, so every switch costs a `make venv`. Same path means one venv serves
host, dev container and agent alike.

**Trust and credentials live in different files.** Credentials are in
`~/.claude/.credentials.json`; whether a directory is trusted is a flag in
`~/.claude.json`, one level up. A container missing the second starts and then
refuses to run, saying the workspace has not been trusted - which no unattended
session can answer. That is also why the home volume covers all of
`/home/vscode` rather than just `~/.claude`.

## Writing a plan that works

Start from [agent-plan-template.md](agent-plan-template.md). The parts that earn
their keep:

- **Scope, especially "out".** An agent with bypassed permissions widens the
  blast radius if nothing says otherwise. Naming what must not change is the
  highest-value line in the file.
- **How to verify, with commands.** This is what the container is for. A plan
  with no verification section gets work that compiles and was never run.
- **Decisions already made, and decisions it may make.** The first stops it
  re-litigating what you settled; the second stops it stalling. Both show up as a
  shorter "assumptions" section in the report.

Then keep the loop tight: first run, `--timeout 20` and no `--stack`, and read
the report. A plan that produces a good 20-minute run produces a good
three-hour one. A vague plan just produces three hours of confident wrong work.
