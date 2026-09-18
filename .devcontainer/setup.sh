#!/usr/bin/env bash
# postStartCommand - runs on every devcontainer start.
set -euo pipefail
cd "$(dirname "$0")/.."

# Restart the stack every time. `supabase start` on its own is a no-op against a
# running stack: it applies neither config.toml changes nor repairs stopped
# containers. Plain `stop` (never --no-backup) keeps the data volumes.
npx --yes supabase stop || true
npx --yes supabase start

echo
echo "Inside this devcontainer:  http://${SUPABASE_SERVICES_HOSTNAME:-127.0.0.1}:54321"
echo "From your host browser:    http://localhost:54321   Studio: http://localhost:54323"
