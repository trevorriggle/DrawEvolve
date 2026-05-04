// Thin Supabase REST wrapper. Adds service-role auth headers and the rest/v1
// base path so future route handlers don't repeat the same boilerplate. The
// existing feedback handler (routes/feedback.js) still uses inline fetch for
// its PostgREST calls — keeping that diff out of this refactor preserves
// behavior bit-for-bit. New routes added later should use this helper.
//
// Returns the Response unchanged — caller decides how to interpret status
// and parse the body. Throws only if env config is missing.

export async function supabaseFetch(env, path, init = {}) {
  if (!env?.SUPABASE_URL || !env?.SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error('SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY not configured');
  }
  const url = `${env.SUPABASE_URL}/rest/v1${path}`;
  const headers = {
    apikey: env.SUPABASE_SERVICE_ROLE_KEY,
    Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,
    Accept: 'application/json',
    ...(init.headers ?? {}),
  };
  return fetch(url, { ...init, headers });
}
