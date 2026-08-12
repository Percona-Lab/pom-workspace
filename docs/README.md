# OpenManager Docs

Explanatory documentation for this workspace — written to be read start to finish by
someone who has not worked on PMM or SEP before.

## Contents

| Doc | What it answers |
| --- | --- |
| [topology.md](topology.md) | **Start here.** What the two products are, what runs on your machine, what talks to what, and how a job actually gets executed. Concepts and data flows. Plain-English first, detail after. |
| [`../psmdb/README.md`](../psmdb/README.md) | The **database nodes** — four MongoDB topologies as Compose profiles, one container per node, each carrying an executor client. The in-place upgrade loop, bootstrap ordering, and the rough edges. Lives next to the code rather than here because it documents one directory. |
| [architecture.md](architecture.md) | **POM specifically** — how the PSMDB Open Manager works today: what pmm-managed derives, what the SEP app probes, where each store lives, and the API and UI surfaces. Short, and expected to change. |
| [glossary.md](glossary.md) | Every proper noun and piece of jargon in one place — VictoriaMetrics, Nomad, `raw_exec`, syncers, and the rest. |

`topology.md` tells you *what the pieces are*, and its Part 10 is the reference layer —
host ports, what runs inside each container, and who talks to whom.

## How this differs from the other docs in the workspace

| Place | Purpose |
| --- | --- |
| `docs/` (here) | **Explanation.** How the system works and why it is shaped that way. Stable — changes when the architecture changes. |
| [`../notes/`](../notes/) | **Working notes.** Task-shaped observations that span both repos: how to get a dev setup running, how to write a SEP app, the state of the unmerged integration branch. Dated, and expected to go stale. |
| [`../CLAUDE.md`](../CLAUDE.md) | **Agent instructions.** Conventions and command reference for AI agents in this workspace. |
| `pmm/AGENTS.md` | **PMM's own guide.** Authoritative for that repository, maintained upstream. |
| `sep-agents.md` | **The SEP agent guide.** Kept here rather than in the submodule: SEP upstream has no such file, so in `SEP/` it was untracked and unshared. |

Rule of thumb: if it is true regardless of what you are doing today, it belongs here. If
it is "here is what I found while trying to get X working", it belongs in `notes/`.

## Keeping these accurate

Each doc carries an **As of** date and a list of what it was derived from. If you change
something a doc describes, update the doc and bump its date in the same change — a note
that lies is worse than no note.

Diagrams are [Mermaid](https://mermaid.js.org/) in fenced code blocks. They render in
VS Code's markdown preview and on GitHub with no extra tooling.
