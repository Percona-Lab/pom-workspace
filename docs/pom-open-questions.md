# POM - open questions

**As of:** 2026-08-19
**Status:** the eleven-step build order is complete. Nothing below is a bug or missing
work; each is a decision that was made provisionally and should be confirmed, or
deliberately deferred and should be scheduled.

For what POM currently *is*, see [`architecture.md`](architecture.md).

Ordered by who needs to answer, then by cost of getting it wrong.

---

## 1. Authorization: who may configure and change POM

**Needs: the SEP team, and PMM.** The full write-up with code references is in
`PMM-15326/question-sep-service-account-and-admin-settings.md`.

SEP's settings API requires an admin. PMM talks to SEP with a shared deployment token
that resolves to the `sep-service` account, which is constructed with `is_admin` left at
its default - so PMM gets a 403 from that router, in every deployment, by construction.

Two ways out. **The second is implemented:**

1. Make the service principal an admin. One line, and every app's settings become
   reachable by PMM at once.
2. Let the app serve its own `/config`, not admin-gated.

(2) was chosen because that token is a deployment-level shared secret with no person
behind it, and in the default configuration it is *derived from `SECRET_KEY`*. Making it
an admin means a leaked `SECRET_KEY` grants administrative access to all of SEP rather
than to one app's settings.

**Confirm or push back on:**

- Is a per-app, non-admin config endpoint acceptable? The argument that it changes
  little: the same token can already trigger sweeps and delete estate rows on the same
  router. The counter-argument is that "already true" is not the same as "fine".
- Should the real gate be PMM's? Every POM page reaches SEP through pmm-managed with no
  browser-side bearer, so the user-facing authorization is a Grafana role in
  `auth_server.go` - which is where a PMM operator would look. Is "PMM gates the human,
  SEP trusts the service token" the right division?
- **Is `sep-service` the right identity for PMM→SEP calls at all?** Every call is one
  shared secret with one all-or-nothing identity. If config changes need an admin, the
  answer is probably a per-deployment credential with its own permissions - a SEP-wide
  design decision well outside this ticket.
- Are POM's role assignments right? `POST /inventory/runs` is **editor**; the deletes
  and `PATCH /config` are **admin**. Refreshing is editor rather than admin because it
  runs a fixed payload and is the button beside a row - requiring admin would put the
  routine question behind the rarest role.

**Isolated for review** in two commits that can be reverted without touching the rest:
pmm `9df3525ad` (the role rules) and the SEP commit that extracts the settings helpers.

---

## 2. The app's name: `pom_discovery` or `pom_inventory`

**Needs: whoever owns the ticket.** Gets more expensive with every step that ships.

The app is `pom_discovery`; the branch is `PMM-15326-pom-inventory`; the PMM proxy is
mounted at `/v1/pom/inventory`. So the two halves already disagree in the paths.

The argument for keeping `pom_discovery`: it is named for what it does, the tables are
named for what they hold (`pom.host`, `pom.service`), and "discovery" earns its keep -
the app finds mongods PMM has not registered and hosts with no database at all.

**Rename surface if it changes:** `MODULE_NAME` in `settings.yaml`; the settings section
`SEP.POM_DISCOVERY` and its prefix list; `@owned_by("pom_discovery")`; the migration
branch label; the API path; PMM's `probeAppPath`; the `./om discovery` command group;
`SettingClassEnum.POM_DISCOVERY_SETTINGS` and its three migrations; the test package.

---

## 3. Pagination, and what the counts count

**Needs: a decision before a real estate, not before merge.**

No list endpoint paginates except `/runs`. The tables sort client-side over everything.
That is correct at this sandbox's 20 hosts and 14 services, and wrong at a real estate's
thousands.

The cheap version is a bounded `limit` with a documented default, matching what `/runs`
already does. Coupled to it: `GET /hosts` should carry counts in the response envelope
rather than leaving the page to count rows it may have paginated - otherwise the two
decisions contradict each other the day pagination arrives.

Worth deciding deliberately rather than discovering.

---

## 4. Retention: what happens to an entity that vanishes

**Needs: a decision. Currently nothing happens.**

The estate is upserted and never pruned. A service PMM no longer has keeps its row
forever, and the only way to remove one is the delete action.

On this sandbox it is already the majority of the table. PMM has 20 hosts and 14
MongoDB services; POM holds **35 host rows and 24 service rows**, because container
restarts re-registered nodes under new ids and nothing pruned the old ones. The rows
are not wrong - each records something that was true - but nothing distinguishes
"gone" from "not seen this sweep", and the estate view is now more stale rows than
live ones.

Options, none chosen: a `vanished_at` column set when enumeration stops seeing an
entity; pruning after N sweeps without a sighting; or leaving it manual and making the
UI surface the count.

---

## 5. The trigger answers 200, not 202

**Needs: nothing, unless something starts reading status codes alone.**

§12 specified 202. SEP answers 202; grpc-gateway maps a successful unary call to 200,
and changing that needs a custom response-forwarding hook.

Accepted because the distinction is carried in the body - `status: "running"` and a
`run_id` to follow - and the UI reads the body. **But** a caller checking `resp.ok` and
nothing else will believe a tens-of-seconds refresh has already finished.

---

## 6. Facts still sit on the run row

**Needs: a cleanup, and it is safe to do late.**

The estate replaced the run row as the place observations live, and `facts_collected` is
gone from every API. But `pom.discovery_run.facts` is still written on every sweep and
still stores the whole fact set.

Nothing reads it. It is the last trace of the duplication the split existed to remove,
and it makes each run row far larger than it needs to be. Removing it is a column drop
and a line in `_finalise`.

---

## 7. Sweep cost

**Needs: someone to care about it before a real estate.**

A full sweep measures **90-101 seconds** across this sandbox's fifteen hosts; a scoped
refresh of one host measures **44 seconds**.

Almost all of that is the `run-python` job template building a virtualenv and
pip-installing `pymongo` on the host, per host, per sweep. The probe itself is
milliseconds. Scoping avoids paying it fifteen times; not paying it at all is a much
bigger win, and belongs to whoever owns the task templates.

---

## 8. Executor state is cheap but refreshed on the expensive path

**Needs: a decision on where to refresh it. Noticed by using the Hosts page.**

Starting a stopped host and watching the page is the reproduction. The executor client
registers with Nomad within seconds, but the Hosts page keeps saying "Agent down" for
up to eleven minutes: the row's `executor` sub-document is written only during a
sweep - default every ten minutes - and the page then polls every sixty seconds.

The mismatch is that those facts cost nothing to obtain. SEP reads them from the Tasks
API in milliseconds and never touches a host, unlike everything else on the row, which
needs a Nomad job per host and tens of seconds. A fact available instantly is being
refreshed on a schedule sized for facts that are not.

Options, none chosen, and the trade is real:

- **Refresh on read**, in the app's `GET /hosts`. Always current, but it puts a Tasks
  API call on every page load and makes the estate unreadable when Tasks is down -
  which is the failure the whole upserted design exists to survive.
- **A cheap periodic refresh** of just the executor block, on its own faster clock,
  separate from the sweep. Keeps the read path local; adds a second schedule.
- **Leave it, and say so in the UI.** The row already knows `last_attempt_at`; the
  executor cell could carry its age like the probe columns do, so "Agent down (11
  minutes ago)" reads as stale rather than as current.

The third is the cheapest and the least dishonest, and does not preclude the others.

---

## 9. Minification can break a payload on hosts you do not control

**Needs: someone to decide whether this is POM's problem or the Tasks layer's.**
POM's payload is fixed; the hazard is not POM-specific.

Every payload the Tasks layer dispatches goes through `python-minifier`, which
normalises inner string quotes to double. An f-string containing a method call on a
literal - `f"...{'&'.join(options)}"`, legal on every Python there has ever been -
comes out as `f"...{"&".join(E)}"`, which is PEP 701 and parses only on **Python 3.12
and later**.

Found because `pmm-server` had failed its probe 183 consecutive times with
`SyntaxError: f-string: expecting '}'` while every database host answered. The
containers carry Python 3.12.3; `pmm-server` carries 3.9.25.

What makes it worth recording rather than just fixing: **the bug exists only after
minification, and only on some hosts.** It is invisible in review, in a local run, and
on most of an estate. Any app whose payload touches a host with an older Python has
the same exposure, and nothing warns them.

POM now has a test that minifies its payload and rejects the construct. Options for
the general case, none chosen: minify with a target version if the library supports
one; run the same check over every payload in the Tasks layer's own tests; or
document a minimum Python for a monitored host and check it during the probe.

---

## 10. Process points, not design

Three things that are not about POM but will bite at PR time:

- **A flaky UI test.** `AlertStatusTable column filters > shows datetime pickers for
  Triggered at and no filter for State` in `apps/pmm` fails intermittently under
  `make test`'s parallel load and passes both in isolation and on a re-run. Nothing to
  do with POM - it is a datetime-picker test - but it costs a re-run often enough to be
  worth someone's attention.

- **Sign-off.** PMM's `AGENTS.md` requires `git commit -s`. The POM commits made before
  2026-08-18 do not carry a `Signed-off-by` trailer, though upstream commits on the same
  branch do. Fixing them needs a history rewrite, which should be a deliberate decision
  before this goes near a PR, since DCO is usually enforced there.
- **`make gen` in `pmm/`.** The full target rewrites 56 API files with a blank-line
  difference from a protoc-gen-go version that is not whatever produced the committed
  output. Use `buf generate --path pom/v1/pom.proto .` from `api/` to keep the diff to
  the package that changed. The same applies to `pnpm install` in `ui/`, which bumps two
  transitive versions and drops an `integrity` hash from `react-data-grid`.
