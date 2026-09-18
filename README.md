# supabase-experiment

A Supabase project that develops inside a devcontainer. The Supabase stack runs as
sibling containers on the host Docker daemon (docker-outside-of-docker).

## Start

Open the folder in VS Code → "Reopen in Container". Headless:

```bash
npx @devcontainers/cli up --workspace-folder .
npx @devcontainers/cli exec --workspace-folder . npm run smoke
```

First start pulls ~2GB of images. After that it is a few seconds.

## Daily use

| | |
| --- | --- |
| `npm run smoke` | check the stack is reachable |
| `npm run db:reset` | re-apply migrations + seed from scratch |
| `npx supabase migration new <name>` | new migration in `supabase/migrations/` |
| `npx supabase stop` | stop the stack (**keeps** your data) |
| `npx supabase status` | URLs and keys |

## URLs

Same instance, two addresses — the devcontainer and the Supabase containers are
siblings, so they do not share a "localhost".

| | From your host browser | From inside the devcontainer |
| --- | --- | --- |
| API | http://localhost:54321 | http://host.docker.internal:54321 |
| Studio | http://localhost:54323 | — |
| Postgres | `localhost:54322` | `host.docker.internal:54322` |
| Mail | http://localhost:54324 | — |

`supabase status` prints whichever is right for where you run it. See `.env.example`.

## Three things that will bite you

- **A `config.toml` change seems to do nothing** — `supabase start` silently ignores
  config when the stack is already running. Use `npx supabase stop && npx supabase start`.
- **`supabase stop` keeps your data; `supabase stop --no-backup` deletes the volumes.**
- **Edge functions 5xx after a reboot** — the CLI creates the edge runtime with
  `restart: no` while the other services are `unless-stopped`, and `supabase start`
  won't repair a partially-down stack. Re-run `.devcontainer/setup.sh`, which handles
  both. Also: a function created *after* `supabase start` needs a stop/start to be
  mounted.

## A new machine, CI, or a sandbox

```bash
./scripts/preflight.sh
```

It probes the real daemon and says whether this setup can work there. The decisive
check is whether the workspace path is valid on the daemon's host — that is why
`devcontainer.json` mounts the workspace at its host path, and why this breaks
inside a GitHub Actions `container:` job.

CI runs Supabase directly on the runner (`.github/workflows/ci.yml`); no
devcontainer is needed there. `ci-devcontainer.yml` additionally builds the
devcontainer so a broken config fails a PR.

---

Design rationale, the docker-in-docker comparison and the portability research:
[supabase-dind](https://github.com/tothambrus11/supabase-dind) and this repo's
git history (tag `research-writeup`).
