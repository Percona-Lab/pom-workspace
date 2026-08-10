#!/usr/bin/env bash
# Generate the shared MongoDB keyfile every node mounts. Idempotent: an existing
# keyfile is kept, because regenerating it would lock the members out of each
# other's replica sets while their data volumes still expect the old one.
#
# The keyfile is the internal-auth shared secret, so it is gitignored. It is not
# a user credential — those live in each container at /root/.mongodb_uri, written
# by register.sh, which is the file SEP's payloads read.

set -o errexit
set -o nounset
set -o pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p secrets

if [ -f secrets/keyfile ]; then
    echo "ℹ Keeping existing secrets/keyfile" >&2
else
    # MongoDB requires 6-1024 base64 characters; 756 random bytes is the length
    # the server's own docs use.
    openssl rand -base64 756 > secrets/keyfile
    echo "✓ Generated secrets/keyfile" >&2
fi

# The container copies this to a mongod-owned 0400 file (a bind mount cannot be
# chowned), but keep the host copy tight regardless.
chmod 600 secrets/keyfile

if ! docker network inspect pmm_default > /dev/null 2>&1; then
    echo "✗ Network pmm_default does not exist — start PMM first:" >&2
    echo "    cd .. && ./om start pmm sep" >&2
    exit 1
fi

echo "✓ pmm_default present" >&2
echo "ℹ Next: docker compose --profile rs-cluster up -d" >&2
