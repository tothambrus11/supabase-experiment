Deno.serve((req) => {
  return new Response(
    JSON.stringify({ message: "hello from a devcontainer-managed edge function" }),
    { headers: { "Content-Type": "application/json" } },
  );
});
