#!/usr/bin/env bash
# Execute a MongoDB Status task through the API, wait for it, print its JSON result.
#
#   ./run_mongo_status.sh "Entire cluster"
#
# The three surfaces involved, none of which are guessable from the app's own
# routes -- execution is a SEP app route, but waiting and reading the output are
# Tasks-API routes:
#
#   POST /api/oauth/token                              -> bearer (mandatory for
#                                                         every mutating call)
#   POST /api/apps/mongo_status/{name}/execute         -> starts a run
#   GET  /api/tasks/history/{id}                       -> status, for polling
#   GET  /api/tasks/history/{id}/logs/                 -> NDJSON log chunks
set -euo pipefail

TASK_NAME="${1:?usage: $0 <task-name>}"
SEP="${SEP:-http://localhost:8000}"
USERNAME="${SEP_USERNAME:-admin}"
# Deliberately not in SEP/snippets/: a Celery task rglobs SNIPPETS_DIR and
# publishes everything under it as a snippet operators can run against a database
# host (app/sep/apps/snippets/celery.py). This is a dev helper, not a snippet.
SEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../SEP" && pwd)"
# Local dev default: the plaintext password the Casdoor init fixture seeds. Only
# valid while the casdoor-data volume matches that fixture -- set SEP_PASSWORD
# otherwise, and never rely on this outside a dev box.
PASSWORD="${SEP_PASSWORD:-$(python3 -c '
import json, pathlib, sys
data = json.loads((pathlib.Path(sys.argv[1]) / "data/casdoor_init_data.json").read_text())
print(next(u["password"] for u in data["users"] if u["name"] == sys.argv[2]))
' "$SEP_DIR" "$USERNAME")}"

urlenc() { python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

TOKEN="$(curl -fsS -X POST "$SEP/api/oauth/token" \
  --data-urlencode "username=$USERNAME" \
  --data-urlencode "password=$PASSWORD" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')"

# The response field is named task_id but carries the *history* id -- the id of
# this run, which is what every polling and log route below takes.
HISTORY_ID="$(curl -fsS -X POST "$SEP/api/apps/mongo_status/$(urlenc "$TASK_NAME")/execute" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["task_id"])')"
echo "run $HISTORY_ID started" >&2

# pending/running are the only non-terminal states; the rest are outcomes.
for _ in $(seq 1 120); do
  STATUS="$(curl -fsS -H "Authorization: Bearer $TOKEN" "$SEP/api/tasks/history/$HISTORY_ID" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
  case "$STATUS" in
    pending | running) sleep 2 ;;
    *) break ;;
  esac
done
echo "run $HISTORY_ID finished: $STATUS" >&2

# The logs route streams NDJSON: one object per chunk, each {step, type, msg,
# offset}. The payload's JSON document is split across 128 KiB stdout chunks, so
# the run-script stdout msgs must be concatenated in offset order before parsing
# -- reading any single chunk gives invalid JSON.
curl -fsS -H "Authorization: Bearer $TOKEN" "$SEP/api/tasks/history/$HISTORY_ID/logs/" \
  | python3 -c '
import json, sys

chunks = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    entry = json.loads(line)
    if entry.get("step") == "run-script" and entry.get("type") == "stdout":
        chunks.append((entry.get("offset", 0), entry.get("msg", "")))
out = "".join(msg for _, msg in sorted(chunks))
print(json.dumps(json.loads(out[out.index("{"):]), indent=2))
'

[ "$STATUS" = "success" ]
