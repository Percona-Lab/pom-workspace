# OpenManager Docs

Explanatory documentation for this workspace — written to be read start to finish by
someone who has not worked on PMM or SEP before.

## Contents

| Doc | What it answers |
| --- | --- |
| [topology.md](topology.md) | **Start here.** What the two products are, what runs on your machine, what talks to what, and how a job actually gets executed. Concepts and data flows. Plain-English first, detail after. |
| [containers.md](containers.md) | The same system at **container level** — real container names, Docker networks and subnets, the fan-out of many `pmm-client` containers, every connection with the address it uses, and the network-alias trick that ties it together. Read after `topology.md` Part 2. |
| [nomad-in-pmm.md](nomad-in-pmm.md) | **A design exploration**, not current state: what the topology would look like if SEP dispatched to PMM's *built-in* Nomad instead of the standalone `om-nomad` container. What PMM already builds, and the three things that block it. |
| [glossary.md](glossary.md) | Every proper noun and piece of jargon in one place — VictoriaMetrics, Nomad, Casdoor, `raw_exec`, syncers, and the rest. |

`topology.md` tells you *what the pieces are*; `containers.md` tells you *what is running
right now and how it is wired*. `containers.md` is a dated snapshot of one machine with
one sandbox environment deployed, and it ends with the commands to re-derive it.

## How this differs from the other docs in the workspace

| Place | Purpose |
| --- | --- |
| `docs/` (here) | **Explanation.** How the system works and why it is shaped that way. Stable — changes when the architecture changes. |
| [`../notes/`](../notes/) | **Working notes.** Task-shaped observations that span both repos: how to get a dev setup running, how to write a SEP app, the state of the unmerged integration branch. Dated, and expected to go stale. |
| [`../CLAUDE.md`](../CLAUDE.md) | **Agent instructions.** Conventions and command reference for AI agents in this workspace. |
| `pmm/AGENTS.md`, `SEP/AGENTS.md` | **Per-repo guides.** Authoritative for their own repository, maintained upstream. |

Rule of thumb: if it is true regardless of what you are doing today, it belongs here. If
it is "here is what I found while trying to get X working", it belongs in `notes/`.

## Keeping these accurate

Each doc carries an **As of** date and a list of what it was derived from. If you change
something a doc describes, update the doc and bump its date in the same change — a note
that lies is worse than no note.

Diagrams are [Mermaid](https://mermaid.js.org/) in fenced code blocks. They render in
VS Code's markdown preview and on GitHub with no extra tooling.
