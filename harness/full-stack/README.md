# PMM + SEP + OpenManager: standalone demo stack

One PMM server, the app-restricted SEP side-car, and six bare pmm-client
hosts (3 Ubuntu, 3 Rocky) for OpenManager's `om_bootstrap` app to dispatch
MongoDB replica-set bootstrap runs against.

Every image is public and pre-built. This directory - `compose.yaml` and
`start.sh` - is everything you need; no checkout of the rest of this repo
is required.

## Bring-up

```bash
./start.sh
```

First boot takes a couple of minutes: PMM provisions PostgreSQL, Grafana,
VictoriaMetrics and ClickHouse before SEP's side-car can even start, and each
client host then has to register with PMM in turn.

Then:

- PMM UI: <https://127.0.0.1:8443> (`admin` / `admin`)
- Settings → enable **OpenManager** (off by default, same as a real
  deployment - `start.sh` does not flip it for you)
- SEP APIs directly: `http://127.0.0.1:9000` (sep), `9001` (inventory),
  `9002` (tasks)

From the Hosts page, dispatch a bootstrap run against any of the six client
hosts (`pmm-client-node00`-`02`, `pmm-client-rocky-node00`-`02`).

## Starting over

```bash
./start.sh --fresh
```

Tears down every container **and volume** first, so PMM mints new secrets,
every client re-registers from nothing, and OpenManager is off again - a
genuine first-boot test rather than a restart of the previous one.

## Why not just `docker compose up -d`?

`compose.yaml` alone cannot wire OpenManager's PMM-side probe correctly.
Enabling it authenticates to SEP with `PMM_SEP_TOKEN`, which must equal
SEP's own derived internal token - an HMAC of a secret (`SECRET_KEY`) that
PMM itself mints on first boot and writes into the shared `pmm-extensions` volume.
That secret does not exist until pmm-server has already started once, so
`start.sh` brings pmm-server and sep-sidecar up first, reads the minted
secret back out, derives the matching token into `.env` (which compose
auto-loads on every subsequent `up`), and only then recreates pmm-server and
starts the client hosts.

Skipping this step is not silent: every OpenManager RPC fails with a 401,
which PMM's Settings page reports as "the OpenManager Inventory app is not
available in SEP" - a decidedly misleading message for a wrong bearer token.

## Tuning

- `PMM_FB_TAG` - repin the PMM image (default `PR-4571-1a75a83`).
- `SEP_INVENTORY_SYNC_MINUTES` - how often SEP's `PMMSyncer` pulls PMM's
  node/service inventory (default `1`; the shipped production profile
  defaults to 15).

```bash
SEP_INVENTORY_SYNC_MINUTES=15 ./start.sh --fresh
```

## Scaling the client pool

Copy a `pmm-client-node0N` (or `pmm-client-rocky-node0N`) block in
`compose.yaml`, bump the number and `hostname`, then `./start.sh` again -
compose only creates what is new.
