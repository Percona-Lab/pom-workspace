# Plan template

Copy this to `plans/<something>.md`, fill it in, hand it to `./delegate`. Delete
the guidance in italics as you go.

The whole skill is writing a plan an agent cannot misread while working alone.
`harness/agent-brief.md` already tells it *how* to work here - unattended, verify
everything, commit in steps, no questions. Your plan only has to say *what*, and
close the gaps a careful colleague would otherwise have to ask about.

---

# <Title: the change, in one line>

## Goal

*One paragraph. What is true after this that is not true now, and why anyone
cares. Not the steps - the outcome.*

## Scope

**In:** *the files, packages or components that may change.*

**Out:** *what must not change. Be explicit. "Do not touch the SEP frontend",
"do not modify pmm/docker-compose.dev.yml". This is the single most useful
section, because an agent with bypassed permissions will happily widen the
blast radius if nothing says otherwise.*

## Context

*What it needs to read before starting, and what it would otherwise waste turns
discovering. Point at files and line ranges, not just directories. Say which
`notes/` or `docs/` page is authoritative if there is one.*

- `path/to/file.py:120-180` - *why it matters*
- `docs/topology.md` Part 10 - *why it matters*

## Steps

*Numbered, each independently checkable. An agent can reorder or merge them if it
finds a better route; what it cannot do is invent the destination. If a step's
outcome is not observable, it is not a step - it is a wish.*

1. …
2. …

## How to verify

*The commands, and what counts as passing. This is where the container earns its
keep: name the ones that need the stack, because it can boot it.*

```
cd SEP && make lint && make test
./om start pmm sep
./om build pmm
./om pom topology              # expect: a row per service, no NULL versions
curl -sk https://localhost:8443/v1/pom | jq .services[0]
```

## Decisions already made

*Anything you have already settled, so it does not re-litigate it. Include the
rejected options and why - an agent that knows why you said no to something will
not quietly do it anyway.*

- *We store the fact on `pom.service`, not `pom.host`, because …*

## Decisions it may make

*Where you are genuinely happy either way. Being explicit here is what stops it
stalling on your behalf, and what makes its report's "assumptions" section
short and readable.*

- *Column naming, log wording, test file layout.*

## Out of bounds

*Standing prohibitions beyond the scope section. Usually:*

- Do not push, do not open PRs, do not touch git remotes.
- Do not change `pmm/` or `SEP/` upstream config to make a local problem go
  away - see `CLAUDE.md` §5 for where such a change belongs.
- Do not mix infrastructure changes into a feature commit.
