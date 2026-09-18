# supabase-experiment

A Supabase project that develops inside a **devcontainer**, with the Supabase stack
running as sibling containers on the host Docker daemon.

## Quick start

Open the folder in VS Code and "Reopen in Container". Or, headless:

```bash
npx @devcontainers/cli up --workspace-folder .        # build + start + supabase start
npx @devcontainers/cli exec --workspace-folder . npm run smoke
```

Then, from your host browser:

| Service | URL |
| --- | --- |
| API (Kong) | http://localhost:54321 |
| Studio | http://localhost:54323 |
| Mail (Mailpit) | http://localhost:54324 |
| Postgres | `postgresql://postgres:postgres@localhost:54322/postgres` |

From **inside** the devcontainer, substitute `host.docker.internal` for `localhost`.

**Shutting down** (see "Lifecycle" below for why the order matters):

```bash
npx @devcontainers/cli exec --workspace-folder . npx supabase stop
docker rm -f $(docker ps -q --filter "label=devcontainer.local_folder=$PWD")
```

`supabase stop` keeps your data ("backed up to docker volume").
`supabase stop --no-backup` **deletes the volumes** — your database is gone.

---

## The problem

Supabase's local stack is not a `docker-compose.yml` you control — `supabase start`
is the CLI reaching out to a Docker daemon and starting ~12 containers itself. Put
that CLI inside a devcontainer and two things break:

1. **Networking.** The CLI talks to the services over their *published host ports*
   and hard-codes `127.0.0.1`. Inside a devcontainer, `127.0.0.1` is the
   devcontainer. `supabase start` dies at the first step:
   `failed to connect to postgres: dial error (connect ECONNREFUSED 127.0.0.1:54322)`.
2. **Paths.** The CLI runs *inside* the devcontainer but issues bind mounts to the
   *host* daemon (`supabase/functions` → edge runtime, `supabase/snippets` → Studio).
   The host resolves those sources against **host** paths. A container-only path
   like `/workspaces/supabase-experiment/...` doesn't exist there.

## Options considered

| | Approach | Verdict |
| --- | --- | --- |
| **A** | Docker-outside-of-Docker (share the host socket); Supabase runs as siblings | **Chosen.** |
| **B** | Devcontainer with `network_mode: host` | Reported working; Linux-only; **not verified here**. |
| **C** | Docker-in-Docker | **Prototyped and measured** in [`supabase-dind`](https://github.com/tothambrus11/supabase-dind). Viable; different trade-offs. |
| **D** | Supabase on the host, devcontainer for app code only | Defeats the purpose. |

**B** (`--network=host`, reported working in
[supabase/cli#1939](https://github.com/supabase/cli/issues/1939) — not tested in
this repo) makes `127.0.0.1` inside the container *be* the host loopback, so the
networking problem vanishes entirely. It's the smallest diff, but host networking
is a Linux nicety — it does not behave the same on Docker Desktop for Mac/Windows or in
Codespaces, and it drops the container's network isolation. Fine as a local
fallback; bad as the config you commit for a team. (The path problem remains
either way.)

**C** (docker-in-docker) turned out to be better than its reputation — I built it
out rather than dismissing it. See **DooD vs DinD, measured** below.

**A** is what the community converged on
([supabase#30078](https://github.com/orgs/supabase/discussions/30078),
[supabase#15365](https://github.com/orgs/supabase/discussions/15365)).

## What this repo does differently from the community recipe

The usual advice from those threads is:

```bash
supabase start --ignore-health-check
docker network connect supabase_network_myproject $(hostname)
# then use http://supabase_kong_myproject:8000 as your API URL
```

That joins the devcontainer to Supabase's bridge network so it can reach services
by container name. It works for *your application code*, but it does **not** fix
the CLI: `supabase start` still dials `127.0.0.1:54322` before that network even
exists, and `--ignore-health-check` doesn't help because the DB connection is a
real dependency, not a health probe. It also masks genuine startup failures.

The CLI has a much better lever — **undocumented**, found by inspecting the CLI
binary (v2.117.0), not in the docs. It is the hinge of this whole config, so
re-check it after a CLI upgrade:

```jsonc
"runArgs": ["--add-host=host.docker.internal:host-gateway"],
"containerEnv": { "SUPABASE_SERVICES_HOSTNAME": "host.docker.internal" }
```

`SUPABASE_SERVICES_HOSTNAME` replaces the hard-coded `127.0.0.1` everywhere the
CLI reaches a service. The Supabase CLI publishes its ports on `0.0.0.0`, so the
host-gateway address reaches them. Consequences:

- `supabase start` works with **no** `--ignore-health-check`; all 12 containers
  report healthy, so a failure is a real failure.
- `db reset`, `migration`, `functions`, `status` all work unmodified.
- `supabase status` *prints* `host.docker.internal:54321` — it honours the
  variable, so there is no mental translation step.
- No network-connect hack, and no `supabase_kong_<project>` hostnames baked into
  application config.

### The workspace path (the part that is easy to get wrong)

```jsonc
"workspaceMount": "source=${localWorkspaceFolder},target=${localWorkspaceFolder},type=bind,consistency=cached",
"workspaceFolder": "${localWorkspaceFolder}"
```

Mounting the workspace at the **same absolute path** it has on the host makes the
path problem disappear: every path the CLI hands the host daemon is already a
valid host path. This is load-bearing, not cosmetic. Verified in this repo:

```console
$ docker inspect supabase_edge_runtime_supabase-experiment --format '{{json .Mounts}}'
... "Source": "/host_mnt/home/ambrus/supabase-experiment/supabase/functions",
    "Destination": "/home/ambrus/supabase-experiment/supabase/functions" ...
```

Source and destination agree, and the edge function actually executes. Without the
same-path mount, the host daemon gets a source path that doesn't exist on the
host. It then either refuses loudly (Docker Desktop: `mounts denied: the path ...
is not shared from the host`) or, on a plain `dockerd`, quietly creates an empty
directory — which surfaces much later as a mystifying `Function not found`.

The `/host_mnt/` prefix above is Docker Desktop's internal representation of a
host path, not a problem.

## Lifecycle: what if you *don't* stop Supabase?

Short answer: rebuilding the devcontainer without stopping Supabase **just works**.
Measured on this repo — devcontainer removed while the stack ran, then
`devcontainer up`:

| | Result |
| --- | --- |
| Supabase images re-pulled | **No.** 14 images before and after, each present exactly once. |
| Supabase containers | **Reused** — identical container IDs, uptime kept counting. `supabase start` is a no-op. |
| Database contents | **Intact.** |
| Images that did change | Only the devcontainer's own two, rebuilt from cache; old tags replaced, 0 dangling. |

The stack is keyed on `project_id` from `config.toml`, not on the devcontainer, so
there is no way to end up with two competing sets. Stopping first is hygiene, not
a correctness requirement.

The actual costs of leaving it up:

- **~1.8 GB of RAM** across 12 idle containers (analytics/Logflare alone is ~600 MB).
- **They come back after a reboot — but not all of them.** 11 of the 12 are
  `restart: unless-stopped`; the devcontainer is `no`, so you can reboot into
  Supabase running with no devcontainer in sight. Worse, `supabase_edge_runtime_*`
  is `restart: no`, so it does *not* come back, and `supabase start` will report
  "already running" without repairing it — the stack looks healthy while every
  edge function 5xx's. `setup.sh` detects exited containers and cycles the stack
  for exactly this reason.
- **Stale config — the one that actually bites.** `supabase start` no-ops against a
  running stack and *silently ignores `config.toml`*. Verified: changed the Studio
  port to 54333, ran `supabase start`, got exit 0 and a full status table — and the
  container was still on 54323. No warning. After a `stop` + `start` it picked up
  54333 correctly. **If a `config.toml` change seems to do nothing, you need
  `supabase stop && supabase start`, not `supabase start`.**
- **Losing the handle.** The CLI finds the stack via `config.toml`. Delete or rename
  the project directory, or change `project_id`, while it runs and you are down to
  `docker rm -f` by hand.

## DooD vs DinD, measured

Both were built and run to a passing smoke test (schema + seed + edge function
read back through `supabase-js`). Prototype: [`supabase-dind`](https://github.com/tothambrus11/supabase-dind).

| | **A — DooD** (this repo) | **C — DinD** ([`supabase-dind`](https://github.com/tothambrus11/supabase-dind)) |
| --- | --- | --- |
| `devcontainer.json` workarounds | **Two** — `SUPABASE_SERVICES_HOSTNAME` + same-path `workspaceMount` | **None.** Stock config |
| Why | CLI drives the *host* daemon: wrong `localhost`, wrong paths | Inner daemon *is* the devcontainer: `127.0.0.1` and container paths are both already correct |
| `setup.sh` lifecycle handling | Repair needed only after a **host reboot** | A readiness wait + a one-line policy fix; repair path now rarely fires |
| Cold first `up` | — (images shared with host) | **174 s** |
| Rebuild (`--remove-existing-container`) | **43–45 s** (12 containers) | **22 s** (10 — analytics off) |
| Re-pulls images on rebuild | No | **No** — `/var/lib/docker` is a persistent named volume |
| DB data survives rebuild | Yes (host volumes) | **Yes** (inner volumes, inside that same named volume) |
| Disk | Shares the host image cache | **+7.9 GB private cache, per project** |
| RAM | ~1.7 GB (12 containers) | ~2.35 GB as built; **~1.1–1.3 GB** with analytics off (see note) |
| Host browser access | **Free** — ports published on the host | **Works headless** via `appPort` (not `forwardPorts`) |
| Privileged | No | **Yes, `--privileged`** |
| Can touch host's other containers | **Yes** (full control of host daemon) | **No** — cannot see them |
| Two projects at once | Host port conflicts (54321 etc.) | **No conflict** — separate daemons |
| Leftovers if you forget to stop | 12 host containers, survive reboot | **None** — die with the devcontainer |

> **The DinD column above is post-fix.** The three problems found in the first
> prototype — no headless host access, a mandatory stack repair on every rebuild,
> and 2.35 GB RAM — were all fixed; see
> [the DinD repo](https://github.com/tothambrus11/supabase-dind#what-was-broken-and-what-fixed-it).
> The RAM figure comes from turning Logflare off in `config.toml`, which is not a
> DinD fix at all — it saves the same ~0.6 GB under DooD, where it is still on.

**The "DinD re-pulls 2 GB every rebuild" claim is false**, and I had repeated it
here before testing it. The `docker-in-docker` feature mounts a named volume
(`dind-var-lib-docker-<id>`) at `/var/lib/docker`, keyed to the workspace, so
images *and* database volumes survive `--remove-existing-container`. Verified:
0 pulls on rebuild, and a row written before the rebuild was still there after.
Only deleting that volume forces the 174 s cold path.

**On security, neither is a boundary.** DooD hands the container the host's Docker
socket — it can start a privileged container or bind-mount `/` and own the host.
DinD needs `--privileged`, which is also escapable. If anything DooD is the more
exposed of the two, since DinD at least cannot see or touch the host's other
containers. Don't pick either because it "feels" safer.

### The bug that applies to *both* setups

`supabase_edge_runtime_*` is the **only** container in the stack that the CLI
creates with `restart: no`; the other 11 are `unless-stopped`:

```
supabase_edge_runtime_*    no               exited
supabase_db_*              unless-stopped   running     (and the other 10)
```

So after any daemon restart the stack comes back *without* the edge runtime — and
`supabase start` reports "already running" and does **not** repair it. The DB
works, `docker ps` looks healthy, and only edge functions fail with a non-2xx.
Nothing announces it; it was caught here only because the smoke test invokes a
function.

Under DinD this fires on **every rebuild** (the inner daemon dies with the
devcontainer). Under DooD it needs a host reboot or a Docker restart — rarer, but
the same silent failure.

Both `setup.sh` files now handle it two ways: they re-assert
`docker update --restart unless-stopped` on the edge runtime after every
`supabase start` (idempotent, so the container simply comes back on its own next
time), and they fall back to cycling the stack if any `supabase_*` container is
found exited. Verified on both: stop the edge runtime, run `setup.sh`, smoke
passes again.

### DinD's remaining quirk

Because `/var/lib/docker` persists, the inner daemon restarts the previous stack
itself on boot, and `supabase start` can race it:

```
supabase_db_supabase-dind container is not ready: starting
```

`setup.sh` waits for the inner dockerd, then for `supabase_db_*` to report
healthy. That wait is the whole cost — rebuilds are 22 s.

### What cannot be fixed about DinD

`--privileged` is required by the feature. The ~8 GB per-project image cache is the
price of daemon isolation — sharing one `dind-var-lib-docker` volume between
projects would corrupt it if two ever ran at once, so don't.

### Which to use

**Keep DooD (this repo) for a shared team setup.** The two workarounds are written
down once in a commented config and then invisible; in exchange, host-browser
access to Studio and the API works with no editor involvement, `psql`/GUI clients
on the host connect to 54322 directly, and the image cache is shared. It should also
port to Docker Desktop for Mac/Windows and to Codespaces, where
`host.docker.internal` is built in — though I only verified it on this Linux host.

**Prefer DinD if** you run several Supabase projects at once (separate daemons, no
port fights), want zero host residue, or object to handing the container your host
Docker socket — and can accept `--privileged` and ~8 GB of disk per project.

## Portability: Claude VMs, CI, other machines

**Run `./scripts/preflight.sh` in the target environment — its output is the
answer.** It probes the real daemon instead of guessing from hostnames, and takes
a few seconds.

### The decision rule

DooD needs two things beyond a working daemon:

1. **A reachable Docker daemon**, and
2. **the workspace path must be valid on that daemon's host.** The CLI runs inside
   the devcontainer but asks the daemon to bind-mount workspace paths, and the
   daemon resolves them against *its own* host.

Condition 2 holds when the devcontainer CLI runs **directly on the Docker host**
(your laptop, a VM-based CI runner). It breaks when the CLI runs **inside a
container** that talks to an outer daemon — which is what a cloud sandbox or a
`container:` CI job usually is.

Verified here by running `preflight.sh` inside a socket-sharing container, twice:

| Nested, workspace mounted at… | Check 3 | Verdict |
| --- | --- | --- |
| the **same** path as the host (`/home/ambrus/supabase-experiment`) | PASS | DooD works |
| a **different** path (`/workspace`) | **FAIL** — `mounts denied` | DooD breaks |

On Docker Desktop that failure is loud (`mounts denied`). On a plain `dockerd` it
is **silent** — the daemon creates an empty directory, the stack starts happily,
and only edge functions and Studio snippets are quietly empty. That is the trap
condition 2 exists to catch.

### Which survives where

| | DooD | DinD |
| --- | --- | --- |
| Your laptop (verified) | ✅ | ✅ |
| GitHub Actions `ubuntu-latest` (VM runner) | ✅ **verified in CI** | ✅ **verified in CI** |
| GitHub Actions with a `container:` job | ❌ *expected* — path mismatch | ✅ if privileged |
| Cloud sandbox / Claude VM | **Depends — run the preflight** | ❌ usually no `--privileged` |
| No Docker daemon at all | ❌ | ❌ |

DooD is fragile about **paths**; DinD is fragile about **privileges**. They fail in
opposite environments, which is a decent reason to keep both configs around.

### Claude VMs and other cloud sandboxes

I cannot verify this from here — this session runs on a normal Linux host, not in
that environment — so treat the row above as a decision procedure, not a result.

**To get a real answer: open a Claude Code cloud session on this repo and run**

```bash
./scripts/preflight.sh          # or: copy just this one file over and run it
```

The script is self-contained — with no argument it probes `$PWD` and needs nothing
but a `docker` client — so you can paste it into any sandbox and read the verdict.
Three things decide it, all covered by the preflight:

- **Is there a Docker daemon at all?** Many sandboxes have none. Then neither
  option works and the answer is a hosted Supabase project, not local dev.
- **Is the workspace path valid on the daemon's host?** If the sandbox is itself a
  container sharing an outer socket, DooD needs the project mounted at the *same*
  absolute path — check 3 tells you in seconds.
- **Is `--privileged` allowed?** Usually not in a sandbox, which rules out DinD.

Also watch egress: the first start pulls ~2 GB from `public.ecr.aws`, and a
restricted sandbox may block it (preflight check 2).

### GitHub Actions

**Use `.github/workflows/ci.yml` — no devcontainer.** On a VM runner the runner
*is* the Docker host, so `127.0.0.1` and workspace paths are already correct and
every workaround in this repo is unnecessary. Verified locally by running the
smoke test from the host with no `SUPABASE_SERVICES_HOSTNAME`: it connects to
`http://127.0.0.1:54321` and passes, which is exactly what the runner does.

`.github/workflows/ci-devcontainer.yml` additionally builds the devcontainer, so a
broken `devcontainer.json` fails a PR. **Verified green on `ubuntu-latest`** — it
runs on every push. The runner confirmed every prediction:

```
--mount source=/home/runner/work/supabase-experiment/supabase-experiment,\
        target=/home/runner/work/supabase-experiment/supabase-experiment,type=bind
-e SUPABASE_SERVICES_HOSTNAME=host.docker.internal --add-host=host.docker.internal:host-gateway

PASS  the daemon mounts this exact path and sees the real contents
PASS  resolves to 172.17.0.1
Connecting to http://host.docker.internal:54321
OK: read 2 rows from public.notes
OK: edge function -> {"message":"hello from a devcontainer-managed edge function"}
```

`host-gateway` is `172.17.0.1` on a runner rather than Docker Desktop's address —
fine either way, since the CLI publishes on `0.0.0.0`. The edge function passing is
the part that matters: it proves the same-path `workspaceMount` resolved against
the runner's own daemon.

The one thing that will *not* work is adding `container:` to a job. GitHub mounts
the workspace at `/__w/<repo>/<repo>` inside such a container while the runner
holds it at `/home/runner/work/<repo>/<repo>`; the daemon is the runner's, so
`${localWorkspaceFolder}` names a path the daemon cannot resolve. That is exactly
the nested half-(b) case above. Expected rather than verified — I modelled it with
a socket-sharing container, not on Actions itself.

## Gotchas hit while building this

- **`docker-outside-of-docker` fails on the default Node image.** The base image is
  Debian *trixie*, which has no `moby-cli` package. The feature needs
  `"moby": false` to install the upstream Docker CE client instead. The error
  (`Feature ... failed to install`) does not make the cause obvious.
- **`forwardPorts` is pointless here.** The Supabase ports are published by the
  *host* daemon, so they're already on your host's `localhost`. The devcontainer
  never binds them, so there's nothing to forward. Omitted deliberately.
- **Edge functions need a restart if `supabase/functions/` didn't exist at
  `supabase start` time.** The bind mount is established at container creation.
  `supabase stop && supabase start` after creating your first function.
- **Everything binds to `0.0.0.0`,** so your local Supabase is reachable from your
  LAN, with well-known default keys. The CLI warns about this. Don't run it on an
  untrusted network.
- **`remoteUser` matters.** The image's `node` user is uid 1000; if that matches
  your host uid, bind-mounted files keep sane ownership.

## Layout

```
.devcontainer/devcontainer.json   the config, heavily commented
.devcontainer/setup.sh            postStartCommand; idempotent, safe on restart
supabase/config.toml              project_id drives all container names
supabase/migrations/              schema
supabase/seed.sql                 seed data
supabase/functions/hello/         example edge function
scripts/smoke.mjs                 proves DB + edge function reachable from inside
scripts/preflight.sh              "will this work here?" - run it in any new environment
.github/workflows/ci.yml          CI without a devcontainer (the recommended path)
.github/workflows/ci-devcontainer.yml  builds the devcontainer in CI (verified green)
.env.example                      the inside-vs-browser URL split
```

## Falling back to option B

A sketch, not a tested config. If `host.docker.internal` ever isn't an option
(Linux hosts only):

```jsonc
"runArgs": ["--network=host"],
"containerEnv": { "LOCAL_WORKSPACE_FOLDER": "${localWorkspaceFolder}" }
```

Drop `SUPABASE_SERVICES_HOSTNAME` — `127.0.0.1` is then correct. Keep the
`workspaceMount`; the path problem is independent of networking.

## Verified with

Every gotcha below was version-specific, so: Docker Desktop for Linux 29.7.2
(`docker info` reports `Docker Desktop`), Compose v5.1.3, Supabase CLI 2.117.0,
`@devcontainers/cli` 0.89.0, base image `mcr.microsoft.com/devcontainers/typescript-node:24`
(Debian trixie), host uid 1000.

Note `package.json` pins `supabase` as `^2.117.0` — a caret range. If a CLI
upgrade breaks startup, suspect `SUPABASE_SERVICES_HOSTNAME` first.

## Sources

- [Does supabase work in a devcontainer with docker-outside-of-docker? — supabase#30078](https://github.com/orgs/supabase/discussions/30078)
- [Issues running `supabase start` within a devcontainer without `network_mode: host` — supabase/cli#1939](https://github.com/supabase/cli/issues/1939)
- [Codespaces / .devcontainer setup — supabase#15365](https://github.com/orgs/supabase/discussions/15365)
- [devcontainers/features — docker-outside-of-docker](https://github.com/devcontainers/features/tree/main/src/docker-outside-of-docker)
- [Supabase Local Development & CLI](https://supabase.com/docs/guides/local-development)
