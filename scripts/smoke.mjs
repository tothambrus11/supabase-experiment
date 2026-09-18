// Smoke test: proves the devcontainer can reach the Supabase stack that is
// running as sibling containers on the host daemon.
//
// Run it INSIDE the devcontainer:  npm run smoke
import { createClient } from "@supabase/supabase-js";
import { execFileSync } from "node:child_process";

// `supabase status` already honours SUPABASE_SERVICES_HOSTNAME, so the URLs it
// prints are correct for wherever this script happens to run.
const status = JSON.parse(
  execFileSync("npx", ["--yes", "supabase", "status", "-o", "json"], {
    encoding: "utf8",
  }),
);

const url = process.env.SUPABASE_URL ?? status.API_URL;
const key = process.env.SUPABASE_ANON_KEY ?? status.ANON_KEY;
console.log(`Connecting to ${url}`);

const supabase = createClient(url, key);

const { data, error } = await supabase
  .from("notes")
  .select("id, body")
  .order("id");
if (error) {
  console.error("FAIL:", error.message);
  process.exit(1);
}
console.log(`OK: read ${data.length} rows from public.notes`);
for (const row of data) console.log(`  ${row.id}. ${row.body}`);

const fn = await supabase.functions.invoke("hello");
if (fn.error) {
  console.error("FAIL: edge function:", fn.error.message);
  process.exit(1);
}
console.log("OK: edge function ->", JSON.stringify(fn.data));
