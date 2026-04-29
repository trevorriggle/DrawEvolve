// Phase 6 — account deletion edge function.
//
// Cascade order (hard-stop on any failure, audit before auth):
//   1. storage  — list + bulk-delete all objects under <user_id>/ in `drawings`
//   2. drawings — delete rows from public.drawings (cascades feedback_requests
//                 via existing FK; critique_history is jsonb, dies with the row)
//   3. profile  — defensive delete from public.profiles if the table exists;
//                 "relation does not exist" is treated as a no-op
//   4. audit    — insert into public.account_deletions BEFORE the auth deletion,
//                 so a failure of the final step still leaves a record
//   5. auth     — supabase.auth.admin.deleteUser(user_id) hard-deletes from auth.users
//
// On any step failure: { success: false, error, step }. The caller (iOS) reads
// `step` to surface step-specific copy — audit-step failures are the safest
// failure mode (user data fully intact) and get distinct user-facing copy.
//
// SECURITY: the user_id from the request body, if any, is IGNORED. The JWT's
// `sub` claim is the only thing that determines who's deleted — this prevents
// a privilege-escalation attack where Mallory could send Alice's user_id.

// deno-lint-ignore-file no-explicit-any
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import { verifyJwt } from "./jwt.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization",
};

const STORAGE_BUCKET = "drawings";

interface DeleteResult {
  success: boolean;
  error?: string;
  step?: string;
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

async function deleteStorageObjects(client: any, userId: string): Promise<void> {
  // List can return at most 1000 entries per call. Loop until we drain the
  // user's prefix. Each entry's `name` is path-relative to the bucket.
  const prefix = userId; // matches the pattern used by saveDrawing / RLS
  // Keep listing+deleting until a list returns empty.
  // (Bounded by a safety cap to prevent runaway loops.)
  for (let i = 0; i < 100; i++) {
    const { data: entries, error: listError } = await client.storage
      .from(STORAGE_BUCKET)
      .list(prefix, { limit: 1000 });
    if (listError) throw new Error(`storage list failed: ${listError.message}`);
    if (!entries || entries.length === 0) return;
    const paths = entries.map((e: { name: string }) => `${prefix}/${e.name}`);
    const { error: removeError } = await client.storage
      .from(STORAGE_BUCKET)
      .remove(paths);
    if (removeError) throw new Error(`storage remove failed: ${removeError.message}`);
  }
  throw new Error("storage list pagination exceeded safety cap");
}

async function deleteDrawingRows(client: any, userId: string): Promise<void> {
  const { error } = await client.from("drawings").delete().eq("user_id", userId);
  if (error) throw new Error(`drawings delete failed: ${error.message}`);
}

async function deleteProfileRow(client: any, userId: string): Promise<void> {
  // profiles table may not exist yet — treat "relation does not exist"
  // (Postgres SQLSTATE 42P01) as a no-op. Any other error propagates.
  const { error } = await client.from("profiles").delete().eq("id", userId);
  if (!error) return;
  const code = (error as { code?: string }).code;
  const msg = error.message ?? "";
  if (code === "42P01" || /does not exist|relation .* does not exist/i.test(msg)) return;
  throw new Error(`profile delete failed: ${msg}`);
}

async function insertAuditRow(client: any, userId: string, email: string | null): Promise<void> {
  const { error } = await client.from("account_deletions").insert({
    user_id: userId,
    email,
    reason: "user_initiated",
  });
  if (error) throw new Error(`audit insert failed: ${error.message}`);
}

async function deleteAuthUser(client: any, userId: string): Promise<void> {
  const { error } = await client.auth.admin.deleteUser(userId);
  if (error) throw new Error(`auth.admin.deleteUser failed: ${error.message}`);
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== "POST") return jsonResponse({ success: false, error: "Method not allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  // Issuer defaults to <SUPABASE_URL>/auth/v1 — same convention the Worker uses.
  const issuer = Deno.env.get("SUPABASE_JWT_ISSUER") ?? (supabaseUrl ? `${supabaseUrl}/auth/v1` : "");
  if (!supabaseUrl || !serviceRoleKey) {
    return jsonResponse({ success: false, error: "Edge function misconfigured", step: "config" }, 500);
  }

  // Verify JWT — the user_id from any body is IGNORED. JWT sub is the only source.
  const authHeader = req.headers.get("Authorization") ?? "";
  const token = authHeader.replace(/^Bearer\s+/i, "");
  let verified;
  try {
    verified = await verifyJwt(token, supabaseUrl, issuer);
  } catch {
    // No body — don't leak why the JWT was rejected.
    return new Response(null, { status: 401, headers: CORS_HEADERS });
  }
  const userId = verified.sub.toLowerCase();

  const client = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // Cascade — fail fast, label the step on any error.
  const steps: Array<{ name: string; run: () => Promise<void> }> = [
    { name: "storage",  run: () => deleteStorageObjects(client, userId) },
    { name: "drawings", run: () => deleteDrawingRows(client, userId) },
    { name: "profile",  run: () => deleteProfileRow(client, userId) },
    { name: "audit",    run: () => insertAuditRow(client, userId, verified.email) },
    { name: "auth",     run: () => deleteAuthUser(client, userId) },
  ];

  for (const step of steps) {
    try {
      await step.run();
    } catch (err) {
      const result: DeleteResult = {
        success: false,
        error: err instanceof Error ? err.message : String(err),
        step: step.name,
      };
      // Status code only — never log error.message which may contain
      // user-identifying info from the underlying Postgres/Storage error.
      console.error(`[delete-account] step '${step.name}' failed`);
      return jsonResponse(result, 500);
    }
  }

  return jsonResponse({ success: true } satisfies DeleteResult);
});
