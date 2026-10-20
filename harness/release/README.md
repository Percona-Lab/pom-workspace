# Release stack: PMM and PMM Extensions from published images

The dev stack (`./om bootstrap`) compiles `pmm/` into PMM's dev container and runs
SEP natively from `SEP/`. The release stack runs what ships instead:

- `pmm-server` and `pmm-extensions` from the published images in `versions.env`
- every sandbox node on the client image pinned there, with all binaries copied
  from it, so the digest pins the client as exactly as it pins the server

Today `versions.env` pins 3.10.0 RC: server build rc3002, extensions rc1, and the
matching client. Everything is at pmm commit `b5463d651`, and Nomad is 2.0.7 on
both ends. Operations for MongoDB is on from boot. This is what the
operations-demo host runs.

## Run it

```bash
git clone git@github.com:Percona-Lab/pom-workspace.git && cd pom-workspace
git checkout PMM-15347-om-integration
./om bootstrap --release
./om start standalone replicaset-single replicaset-cluster pmm-client pmm-client-rocky
```

No submodules or toolchains are needed, only Docker with the compose plugin.
The nodes run systemd, and the full set above needs more than the default 128
`fs.inotify.max_user_instances`. Raise it to 1024 first, because a node that
cannot get one exits 255 with no output at all.

The first run downloads about 6 GB of images, plus the packages the three node
images install, so expect 20 to 30 minutes. With everything cached, a run took
10 minutes on operations-demo. PMM is then at <https://localhost:8443>
(`admin`/`admin`). The side-car's API is on `127.0.0.1:8000`, which is what
`./om inventory` and `./om sep-api` use.

`./om` remembers the choice in `.om/stack`, so `start`, `stop`, `status`, `logs`,
`reset` and `bootstrap` drive this stack from then on. `./om build`, `env` and
`setup` belong to the dev stack and say so.

Starting nodes also asks PMM Extensions to pull PMM's inventory right away.
Otherwise they would stay out of Operations until its 15-minute sync. Scans run
every 10 minutes, or on demand from the Operations pages.

## Switching stacks

Nodes register with one PMM server, so a switch starts PMM and every node from
scratch:

```bash
./om reset data && ./om bootstrap --release    # or --dev to go back
```

`./om bootstrap` refuses to switch while the other stack's PMM or registered nodes
are still around, and prints that command.

## Moving to the next RC or GA

Edit the pins in `versions.env`, then rerun `./om bootstrap --release` and
`./om start <the clusters>`. Containers on an older image are recreated, and
node images whose client does not match the pin are rebuilt. PMM's volumes are
kept, which is the upgrade path PMM supports.

## Without ./om

```bash
docker network create pmm_default
cd harness/release
printf 'PMM_EXTENSIONS_TOKEN=%s\n' "$(openssl rand -hex 32)" > .env
docker compose --env-file versions.env --env-file .env up -d --wait
```

Build the node images with `--build-arg PMM_CLIENT_OVERLAY=full`, plus
`PMM_CLIENT_FB_IMAGE` and `PMM_CLIENT_CHANNEL` from `versions.env`.
