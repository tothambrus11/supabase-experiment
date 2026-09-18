#!/usr/bin/env bash
# postStartCommand: runs on every devcontainer start, so it must be idempotent.
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT_ID="$(sed -n 's/^project_id[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' supabase/config.toml | head -1)"
[ -n "$PROJECT_ID" ] || { echo "setup.sh: no project_id in supabase/config.toml" >&2; exit 1; }

HOSTNAME_FOR_SERVICES="${SUPABASE_SERVICES_HOSTNAME:-127.0.0.1}"

if ! getent hosts "$HOSTNAME_FOR_SERVICES" >/dev/null 2>&1; then
  echo "setup.sh: '$HOSTNAME_FOR_SERVICES' does not resolve." >&2
  echo "  On Linux this needs --add-host=host.docker.internal:host-gateway in runArgs." >&2
  exit 1
fi

# `supabase_edge_runtime_*` is the only container in the stack with `restart: no`;
# the other 11 are `unless-stopped`. So after a host reboot (or a Docker restart)
# the stack comes back *without* the edge runtime - and `supabase start` reports
# "already running" and does NOT repair it, leaving edge functions quietly 5xx-ing.
# If anything is down, cycle the stack. Plain `stop` keeps the data volumes.
DOWN="$(docker ps -a --filter "name=supabase_.*_${PROJECT_ID}" --filter "status=exited" --format '{{.Names}}')"
if [ -n "$DOWN" ]; then
  echo "==> Found stopped containers, cycling the stack to repair:"
  echo "$DOWN" | sed 's/^/     /'
  npx --yes supabase stop
fi

echo "==> Starting Supabase (project: $PROJECT_ID, services via $HOSTNAME_FOR_SERVICES)"
# Already-running is a no-op, so this is safe on every restart.
npx --yes supabase start

# Re-assert a sane restart policy on the edge runtime (the CLI creates it with
# `restart: no`, unlike the other 11 services). Without this, a host reboot brings
# the stack back minus the edge runtime, and `supabase start` will not repair it -
# edge functions then 5xx while everything looks healthy. Idempotent.
EDGE="supabase_edge_runtime_${PROJECT_ID}"
if docker ps -a --format '{{.Names}}' | grep -qx "$EDGE"; then
  if [ "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$EDGE")" != "unless-stopped" ]; then
    echo "==> Setting restart=unless-stopped on $EDGE (the CLI leaves it at 'no')"
    docker update --restart unless-stopped "$EDGE" >/dev/null
  fi
fi

echo
echo "==> Container status"
docker ps --filter "name=supabase_" --format '  {{.Names}}\t{{.Status}}'

echo
echo "URLs from INSIDE this devcontainer (SSR, scripts, tests):"
echo "  API    http://${HOSTNAME_FOR_SERVICES}:54321"
echo "  DB     postgresql://postgres:postgres@${HOSTNAME_FOR_SERVICES}:54322/postgres"
echo "URLs from your HOST browser:"
echo "  API    http://localhost:54321"
echo "  Studio http://localhost:54323"
echo "  Mail   http://localhost:54324"
echo
echo "(\`supabase status\` honours SUPABASE_SERVICES_HOSTNAME, so the URLs it"
echo " prints are already correct for wherever you run it.)"
