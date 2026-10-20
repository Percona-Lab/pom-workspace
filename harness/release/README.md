# Release stack: PMM and PMM Extensions from published images

`compose.yaml` runs `pmm-server` and the `pmm-extensions` side-car from their
published images, pinned to 3.10.0 RC. Nothing is built from `pmm/` or `SEP/`.
This is what the operations-demo host runs. The dev loop (`./om start pmm sep`)
runs the same pair from source instead.

The sandbox nodes in `psmdb/compose.yaml` attach unchanged. They still find
`pmm-server` on `pmm_default` with `admin`/`admin`, so `./om start <cluster>`
works as usual.

## Bring-up

From the workspace root, with the dev stack stopped (see below):

```bash
docker network inspect pmm_default >/dev/null 2>&1 || docker network create pmm_default
cd harness/release
[ -f .env ] || printf 'PMM_EXTENSIONS_TOKEN=%s\n' "$(openssl rand -hex 32)" > .env
docker compose up -d --wait
```

`.env` holds the bearer token pmm-managed and the side-car share. Keep it: a new
token means recreating both containers.

Operations for MongoDB is on from the start (`PMM_ENABLE_OM=1`). PMM's
`PMMSyncer` pulls inventory into the side-car every 15 minutes, the shipped
default, so nodes registered after boot are missing from Operations for up to
15 minutes. To pull now (202 means queued):

```bash
T=$(sed -n 's/^PMM_EXTENSIONS_TOKEN=//p' harness/release/.env)
docker exec pmm-server curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  -H "Authorization: Bearer $T" http://pmm-extensions:9000/api/apps/inventory/sync/
```

`docker exec pmm-extensions python ...` does not work for this: the side-car's
minted keys reach its supervised programs only, not an exec'd shell.

## Node images on the RC client

The node images normally carry the released pmm-client. For the RC, rebuild all
three from `psmdb/` before starting any nodes. Nomad has to match on both ends,
and that is why the bare-client overlay comes from the RC client image:

```bash
cd psmdb
RC_CLIENT=docker.io/perconalab/pmm-client:3.10.0-rc@sha256:5fc2d8f1af16469209a5bdf686b5ec6b99904b9c9160619ca2085adfc02bf13c
docker build --build-arg PMM_CLIENT_CHANNEL=testing -t openmanager/psmdb-node:7.0 .
docker build --build-arg PMM_CLIENT_CHANNEL=testing --build-arg WITH_PSMDB=0 \
  --build-arg PMM_CLIENT_FB_IMAGE=$RC_CLIENT -t openmanager/pmm-client-node:3 .
docker build --build-arg PMM_CLIENT_CHANNEL=testing --build-arg WITH_PSMDB=0 --build-arg BASE_OS=rocky \
  --build-arg PMM_CLIENT_FB_IMAGE=$RC_CLIENT -t openmanager/pmm-client-node-rocky:3 .
```

Then `./om start standalone replicaset-single replicaset-cluster pmm-client pmm-client-rocky`.
Check the result with `pmm-admin --version` on a node and `tools/nomad version` on both sides.

## Living next to ./om

Both stacks use the container name `pmm-server` and port 8443, so only one can
run at a time. Their volumes are separate (`om-release_*` here, `pmm-data` for
the dev stack), so switching leaves the other one's data alone.

- **Dev to release:** `./om stop sep pmm` keeps the dev container, so rename it
  out of the way (`docker rename pmm-server pmm-server-dev`). Stop the nodes and
  empty the `psmdb-sandbox_agent-state` volume, since those identities belong to
  the dev server. Then do the bring-up above, and the nodes register afresh on
  their next start.
- **Release to dev:** `docker compose down` here, then `./om start pmm sep`.
  Nodes registered with this server need `./om reregister`.
- `./om start` with no arguments, `./om start pmm` and `./om bootstrap` all
  start the dev server, so do not run them while this stack is up.
- `./om status` still describes the dev server, so ignore its Delve, PostgreSQL
  and "working tree UI" lines. Nothing here publishes more than 8443.
- `./om reset all` deletes the node images. The next `./om start <cluster>`
  rebuilds them on the released client, so rebuild them as above afterwards.

## Moving to the next RC or GA

Change the two image pins (or set `PMM_SERVER_IMAGE` / `PMM_EXTENSIONS_IMAGE` in
`.env`) and run `docker compose up -d --wait`. Keep the volumes, because that
is the upgrade path PMM supports. Rebuild the node images if the client moved too.
