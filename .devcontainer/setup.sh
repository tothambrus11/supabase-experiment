#!/usr/bin/env bash
# postStartCommand - runs on every devcontainer start, so it must be idempotent.
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT_ID="$(sed -n 's/^project_id[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' supabase/config.toml | head -1)"
HOSTNAME_FOR_SERVICES="${SUPABASE_SERVICES_HOSTNAME:-127.0.0.1}"

# `supabase start` will not repair a partially-down stack - it just reports
# "already running". Cycle it instead. Plain `stop` keeps the data volumes.
if [ -n "$(docker ps -a --filter "name=supabase_.*_${PROJECT_ID}" --filter "status=exited" -q)" ]; then
  echo "==> Stopped containers found, cycling the stack"
  npx --yes supabase stop
fi

npx --yes supabase start

# The CLI creates the edge runtime with `restart: no` while the other services are
# `unless-stopped`, so after a reboot the stack returns without it and edge
# functions 5xx while everything looks healthy. Idempotent.
EDGE="supabase_edge_runtime_${PROJECT_ID}"
if [ "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$EDGE" 2>/dev/null)" = "no" ]; then
  docker update --restart unless-stopped "$EDGE" >/dev/null
fi

echo
echo "Inside this devcontainer:  http://${HOSTNAME_FOR_SERVICES}:54321"
echo "From your host browser:    http://localhost:54321   Studio: http://localhost:54323"
