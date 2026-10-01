#!/usr/bin/env bash
# ensure-plane.sh — scrum-team hook: optionally bring up a local Plane stack.
# Triggered by hooks.json on SessionStart. Default noop; only acts when the
# current project opts in via .zcode/scrum-team.json (see schema below).
#
# .zcode/scrum-team.json schema (all keys optional):
# {
#   "plane": {
#     "enabled":    true,                      # default false → skip
#     "compose_dir":"plane-app",             # relative to project root
#     "env_marker": ".zcode/plane.env",      # marker file presence → already up
#     "env_file":   ".zcode/plane.env",      # (unused here, for plane-scribe)
#     "container":  "plane-app-api-1",       # container name for "running" check
#     "probe_url":  "http://localhost/api/v1/workspaces/_probe_/projects/",
#     "wait_sec":   180                       # cold-start budget
#   }
# }
set -uo pipefail

PROJ_DIR="${CLAUDE_PROJECT_DIR:-.}"
CONFIG="$PROJ_DIR/.zcode/scrum-team.json"

# Default: no config file → assume user is not running Plane from this project
[ -f "$CONFIG" ] || exit 0

# Parse JSON. jq is required by plane.sh anyway, so reuse it here.
read_json() { jq -r "$1" "$CONFIG" 2>/dev/null; }

ENABLED=$(read_json '.plane.enabled // false')
[ "$ENABLED" = "true" ] || exit 0

COMPOSE_DIR_REL=$(read_json '.plane.compose_dir // "plane-app"')
MARKER_REL=$(read_json '.plane.env_marker // ".zcode/plane.env"')
CONTAINER=$(read_json '.plane.container // "plane-app-api-1"')
PROBE_URL=$(read_json '.plane.probe_url // "http://localhost/api/v1/workspaces/_probe_/projects/"')
WAIT_SEC=$(read_json '.plane.wait_sec // 180')

COMPOSE_DIR="$PROJ_DIR/$COMPOSE_DIR_REL"
MARKER="$PROJ_DIR/$MARKER_REL"

# Already running? Fast path.
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^$CONTAINER$"; then
  echo "[ensure-plane] Plane already up"
  exit 0
fi

# Marker present but compose dir missing — warn but don't block session.
if [ ! -d "$COMPOSE_DIR" ] || [ ! -f "$COMPOSE_DIR/docker-compose.yaml" ]; then
  echo "[ensure-plane] $CONFIG opts in but $COMPOSE_DIR/ not present" >&2
  exit 0
fi

echo "[ensure-plane] Starting Plane stack..."
cd "$COMPOSE_DIR" || exit 0

if [ -f "$MARKER" ]; then
  docker compose -f docker-compose.yaml --env-file "$MARKER" up -d >/dev/null 2>&1 || {
    echo "[ensure-plane] docker compose up failed" >&2; exit 0; }
else
  docker compose -f docker-compose.yaml up -d >/dev/null 2>&1 || {
    echo "[ensure-plane] docker compose up failed" >&2; exit 0; }
fi

# Wait for API to become reachable. 401/403 on the probe = proxy→API routing up.
READY=0
WAIT_ITERS=$((WAIT_SEC / 2))
for i in $(seq 1 "$WAIT_ITERS"); do
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "$PROBE_URL" 2>/dev/null || echo "000")
  case "$code" in
    401|403) READY=1; break ;;
  esac
  sleep 2
done

if [ "$READY" -eq 1 ]; then
  echo "[ensure-plane] Plane API up (after $((i*2))s)"
else
  echo "[ensure-plane] Plane did not become healthy within ${WAIT_SEC}s" >&2
fi
exit 0