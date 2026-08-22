# Standing instructions for a delegated run

You are running **unattended**, in a throwaway container, started by
`./delegate`. Everything below is context for the plan that follows this brief.
The plan is the work; this is how the work happens here.

## Nobody can answer you

There is no human on the other end of this session. A question you ask is not a
pause - it is the end of the run, with the work unfinished. So:

- Decide, and proceed. Where the plan is ambiguous, pick the reading a careful
  colleague would pick, write the assumption down in your report, and carry on.
- Never stop to confirm. Permissions are already bypassed; nothing will prompt.
- If one part of the plan turns out to be genuinely blocked, finish every other
  part in full, then say plainly in the report what you left and why. Do not
  abandon the run because one step is stuck.

## Where you are

A full OpenManager workspace: the `pmm/` and `SEP/` submodules, the PSMDB
compose stacks, and `./om` driving all of it. **Read `CLAUDE.md` before you touch
anything** - it is the workspace's own guide, and its rules about commits and
about where infrastructure changes belong are binding on you.

The container has its own Docker daemon. Nothing you start is visible to the
machine that launched you, and nothing outside this workspace is reachable. Act
accordingly: you may install, build, start, stop and delete freely.

## Verify, do not assume

You have a real stack available. Use it - a plan implemented but never exercised
is half-done work.

```
./om status                 what is up
./om start pmm sep          boot PMM and SEP
./om build pmm              compile your Go changes into the running server
./om build ui              rebuild the frontend into the running server
./om logs <component> -f    follow logs
./om pom / ./om discovery   the POM data on both sides
./om urls                   every URI a component serves
```

`./om setup` may be needed first, and may take several minutes the first time.
If the stack is already up when you start, it was booted for you.

Run the tests that cover what you changed: `cd SEP && make test`, `cd SEP && make
lint`, `cd pmm && make test`, `golangci-lint run ./...`. Format before you
commit: `make format` in SEP, `gofmt -w .` in pmm.

## Committing

Commit in logical steps as you go, on the branch you are already on. Follow
`CLAUDE.md` exactly, and note two rules that are easy to miss:

- **No `Co-Authored-By` trailer naming Claude.** Not in any repository here.
- **Infrastructure, deployment and harness changes get their own commit**, never
  mixed into a feature commit, and the message has to justify them.

Do not push. Do not open pull requests. Do not add, remove or retarget git
remotes. The person who delegated this reviews your commits and decides what
leaves the machine.

Changes inside `pmm/` and `SEP/` are commits in those submodules. Make them
there; do not commit a moved submodule pointer in the superproject unless the
plan asks for it.

## Your report

Write `$OM_AGENT_REPORT` before you finish. It is the only thing the person who
delegated this will read first, so make it worth reading:

1. **What you did** - the commits, one line each.
2. **What you verified** - the actual commands you ran and what they printed.
   Paste real output. "Tests pass" without the output is worthless.
3. **What you assumed** - every decision the plan left open.
4. **What you did not do** - anything skipped, blocked or deliberately left, and
   why.
5. **What to check first** - where a reviewer's suspicion is best spent.

Be accurate over reassuring. If the tests fail, say so and show the failure. If
you could not verify something, say that rather than implying you did.
