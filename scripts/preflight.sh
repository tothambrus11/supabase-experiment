#!/usr/bin/env bash
# Answers "will the Supabase devcontainer work in THIS environment?"
#
# Run it wherever you intend to develop - your laptop, a CI runner, a cloud
# sandbox. It probes the real Docker daemon rather than guessing from hostnames.
#
#   ./scripts/preflight.sh [workspace-dir] [--require dood|dind|any]
#
# Exit code: 0 if the required setup is usable, 1 if not - so it is safe to gate a
# CI job on it. Default requirement is "any" (fails only if neither works).
#
# It is self-contained: copy just this file into a sandbox and run it there. With
# no argument it probes $PWD, so it needs no repo around it.

set -uo pipefail

WS=""; REQUIRE="any"
while [ $# -gt 0 ]; do
  case "$1" in
    --require) REQUIRE="${2:-any}"; shift 2 ;;
    --require=*) REQUIRE="${1#*=}"; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) WS="$1"; shift ;;
  esac
done
if [ -z "$WS" ]; then
  # Prefer the repo root when we are clearly inside this repo; otherwise $PWD, so
  # the script still works when pasted somewhere on its own.
  _root="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd || true)"
  if [ -n "$_root" ] && [ -d "$_root/.devcontainer" ]; then WS="$_root"; else WS="$PWD"; fi
fi
PROBE_IMAGE="${PROBE_IMAGE:-alpine}"

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; }
info() { printf '        %s\n' "$1"; }

DOOD_OK=1; DIND_OK=1

echo "Workspace: $WS"
echo "Requiring:  $REQUIRE"
echo

# ---------------------------------------------------------------- 1. daemon
echo "1. Docker daemon"
if ! command -v docker >/dev/null 2>&1; then
  fail "no 'docker' client on PATH"
  echo; echo "VERDICT: neither DooD nor DinD is possible. Use a hosted Supabase project."
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  fail "docker client present but the daemon is unreachable"
  info "$(docker info 2>&1 | grep -iE 'cannot connect|permission denied' | head -1)"
  echo; echo "VERDICT: neither DooD nor DinD is possible. Use a hosted Supabase project."
  exit 1
fi
pass "daemon reachable ($(docker version --format '{{.Server.Version}}' 2>/dev/null))"

if [ -f /.dockerenv ] || grep -qE '(docker|containerd|kubepods)' /proc/1/cgroup 2>/dev/null; then
  warn "this shell is itself inside a container - nesting. Check 3 is the one that matters."
else
  info "running directly on the Docker host"
fi
echo

# ------------------------------------------------- 2. can we pull the probe
echo "2. Image pull"
if docker image inspect "$PROBE_IMAGE" >/dev/null 2>&1 || docker pull -q "$PROBE_IMAGE" >/dev/null 2>&1; then
  pass "can pull images (needed: ~2GB of Supabase images on first start)"
else
  fail "cannot pull '$PROBE_IMAGE' - registry egress is blocked?"
  info "Supabase pulls from public.ecr.aws; without egress neither option works."
  DOOD_OK=0; DIND_OK=0
fi
echo

# ------------------------------------ 3. THE decisive test: bind-mount paths
# The Supabase CLI runs inside the devcontainer but asks the daemon to bind-mount
# workspace paths. The daemon resolves them on ITS host. If this workspace path
# is not valid there, edge functions and Studio snippets mount as empty dirs.
echo "3. Bind mounts from this workspace path (decisive for DooD)"
SENTINEL=".preflight-$$-$RANDOM"
VALUE="sentinel-$$-$RANDOM-$(date +%s)"
if echo "$VALUE" > "$WS/$SENTINEL" 2>/dev/null; then
  GOT="$(docker run --rm -v "$WS:/probe" "$PROBE_IMAGE" cat "/probe/$SENTINEL" 2>&1)"
  rm -f "$WS/$SENTINEL"
  if [ "$GOT" = "$VALUE" ]; then
    pass "the daemon mounts this exact path and sees the real contents"
  else
    fail "the daemon does NOT see this workspace at '$WS'"
    info "got: ${GOT:-<empty>}"
    info "Empty output = daemon silently created an empty dir (plain dockerd)."
    info "'mounts denied' = Docker Desktop refused outright."
    info "Either way DooD breaks: edge functions mount empty. Fix by making the"
    info "workspace path identical on the host and in here, or use DinD."
    DOOD_OK=0
  fi
else
  fail "workspace is not writable, cannot probe"; DOOD_OK=0
fi
echo

# ------------------------------------------------------- 4. host gateway
echo "4. host.docker.internal (how the CLI reaches the services under DooD)"
GW="$(docker run --rm --add-host=host.docker.internal:host-gateway "$PROBE_IMAGE" \
      getent hosts host.docker.internal 2>&1 | awk '{print $1}' | head -1)"
if [ -n "$GW" ]; then
  pass "resolves to $GW"
else
  fail "--add-host=host.docker.internal:host-gateway did not resolve"
  info "Needs Docker >= 20.10. Without it, set SUPABASE_SERVICES_HOSTNAME to the"
  info "bridge gateway IP (usually 172.17.0.1) instead."
  DOOD_OK=0
fi
echo

# --------------------------------------------------------- 5. privileged
echo "5. Privileged containers (required by DinD, NOT by DooD)"
if docker run --rm --privileged "$PROBE_IMAGE" true >/dev/null 2>&1; then
  pass "privileged containers allowed"
else
  fail "privileged containers refused - docker-in-docker will not work here"
  DIND_OK=0
fi
echo

# ------------------------------------------------------------- verdict
echo "VERDICT"
[ "$DOOD_OK" = 1 ] && echo "  docker-outside-of-docker: SHOULD WORK" \
                   || echo "  docker-outside-of-docker: WILL NOT WORK as configured"
[ "$DIND_OK" = 1 ] && echo "  docker-in-docker:         SHOULD WORK" \
                   || echo "  docker-in-docker:         WILL NOT WORK here"
[ "$DOOD_OK" = 1 ] || [ "$DIND_OK" = 1 ] || \
  echo "  Neither. Point the app at a hosted Supabase project instead."

# Exit non-zero so CI can gate on this.
case "$REQUIRE" in
  dood) [ "$DOOD_OK" = 1 ] || { echo; echo "Required 'dood' is unusable here."; exit 1; } ;;
  dind) [ "$DIND_OK" = 1 ] || { echo; echo "Required 'dind' is unusable here."; exit 1; } ;;
  *)    [ "$DOOD_OK" = 1 ] || [ "$DIND_OK" = 1 ] || exit 1 ;;
esac
exit 0
