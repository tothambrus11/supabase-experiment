// Proves the local Supabase stack is reachable from wherever this runs.
// Deliberately has no app schema dependency, so it keeps working as you build.
//
//   npm run smoke
import { execFileSync } from "node:child_process";

// `supabase status` honours SUPABASE_SERVICES_HOSTNAME, so its URLs are already
// correct both inside the devcontainer and on the host.
const s = JSON.parse(
  execFileSync("npx", ["--yes", "supabase", "status", "-o", "json"], {
    encoding: "utf8",
  }),
);
const url = process.env.SUPABASE_URL ?? s.API_URL;
const key = process.env.SUPABASE_ANON_KEY ?? s.ANON_KEY;
console.log(`Checking ${url}`);

let failed = false;
const check = async (name, path, init = {}) => {
  try {
    const res = await fetch(`${url}${path}`, {
      ...init,
      headers: { apikey: key, Authorization: `Bearer ${key}`, ...init.headers },
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    console.log(`OK   ${name}`);
  } catch (e) {
    console.error(`FAIL ${name}: ${e.message}`);
    failed = true;
  }
};

// Kong -> PostgREST -> Postgres.
await check("rest api", "/rest/v1/");
// Edge runtime, and therefore the supabase/functions bind mount.
await check("edge function", "/functions/v1/health");

process.exit(failed ? 1 : 0);
