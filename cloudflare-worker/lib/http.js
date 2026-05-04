// Shared HTTP scaffolding for the Worker.
//
// CORS is locked to the production web origin. The iOS app is the primary
// client and doesn't trigger CORS, so this only matters for browser callers.
// Previously '*', which let any origin call the endpoint with a stolen JWT.
// If localhost or another origin needs access later, add it here — the cost
// of plurality is one extra header value, not architectural.

export const CORS_HEADERS = {
  'Access-Control-Allow-Origin': 'https://drawevolve.com',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-Apple-AppAttest-KeyId, X-Apple-AppAttest-Assertion',
};

export function jsonResponse(body, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS_HEADERS, ...extraHeaders },
  });
}

export function unauthorized() {
  // No body — don't leak which routes exist or why the JWT was rejected.
  return new Response(null, { status: 401, headers: CORS_HEADERS });
}
