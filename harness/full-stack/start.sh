#!/usr/bin/env bash
# Bring up the whole stack (or bring it back up after --fresh wipes it),
# deriving PMM_EXTENSIONS_TOKEN from whatever SECRET_KEY this boot's pmm-server
# actually minted rather than needing one supplied ahead of time.
#
# compose.yaml alone cannot do this: PMM_EXTENSIONS_TOKEN must equal SEP's own
# derived EXTENSIONS_INTERNAL_TOKEN (HMAC-SHA256 of the SECRET_KEY PMM writes into
# the pmm-extensions volume on first boot, label b"extensions-internal-token" - see SEP's
# Settings.derive_internal_token), and that key does not exist until
# pmm-server has already started once. So this script starts pmm-server and
# sep-sidecar with the placeholder, waits for sep-sidecar to read the minted
# key, computes the matching token, and recreates pmm-server with it before
# bringing up the client hosts. Confirmed the hard way: skipping this step
# leaves every om.* RPC failing 401 "Could not validate credentials", which
# PMM's Settings page reports as "the OpenManager Inventory app is not
# available in SEP" - a decently misleading error for a wrong bearer token.
set -euo pipefail

usage() {
    cat << 'EOF'
start.sh [--fresh]

Bring the stack up. With no flag, an existing deployment is left alone and
only what compose would normally recreate (e.g. after an image change)
restarts. With --fresh, everything - including the pmm-data, pmm-extensions and
agent-state volumes - is torn down and recreated from nothing: a genuinely
first-boot test, with PMM minting new secrets and every client re-registering.
EOF
}

fresh=0
case "${1:-}" in
    --fresh) fresh=1 ;;
    -h | --help) usage; exit 0 ;;
    "") ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$dir"

if [[ $fresh -eq 1 ]]; then
    echo "==> --fresh: tearing down the stack and its volumes"
    docker compose down -v
fi

echo "==> Starting pmm-server + sep-sidecar (PMM_EXTENSIONS_TOKEN may still be the placeholder)"
docker compose up -d pmm-server sep-sidecar

echo "==> Waiting for sep-sidecar to report healthy"
until [[ "$(docker inspect -f '{{.State.Health.Status}}' om-demo-sep-sidecar-1 2> /dev/null)" == healthy ]]; do
    sleep 3
done

echo "==> Deriving PMM_EXTENSIONS_TOKEN from this boot's SECRET_KEY"
secret_key="$(docker exec om-demo-sep-sidecar-1 cat /run/secrets/extensions/SECRET_KEY)"
token="$(python3 -c "
import hmac, hashlib, sys
print(hmac.new(sys.argv[1].encode(), b'extensions-internal-token', hashlib.sha256).hexdigest())
" "$secret_key")"

echo "==> Writing PMM_EXTENSIONS_TOKEN to .env and recreating pmm-server"
# .env, not a one-off overlay: compose auto-loads it for every subsequent
# `up`, including the plain one below - an overlay used for only one `up`
# call gets silently reverted the next time compose reconciles against
# compose.yaml alone, right back to the placeholder.
grep -v '^PMM_EXTENSIONS_TOKEN=' .env 2> /dev/null > .env.tmp || true
printf 'PMM_EXTENSIONS_TOKEN=%s\n' "$token" >> .env.tmp
mv .env.tmp .env
docker compose up -d pmm-server

echo "==> Waiting for pmm-server to report healthy again"
until [[ "$(docker inspect -f '{{.State.Health.Status}}' om-demo-pmm-server-1 2> /dev/null)" == healthy ]]; do
    sleep 3
done

echo "==> Starting the 6 client hosts (3 Ubuntu, 3 Rocky)"
docker compose up -d

echo
echo "==> Done."
echo "PMM UI: https://127.0.0.1:8443 (admin / admin)"
echo "Enable OpenManager from Settings, then dispatch a bootstrap run from the Hosts page."
