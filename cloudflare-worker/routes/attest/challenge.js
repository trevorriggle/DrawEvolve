// POST /attest/challenge — issue a fresh server-side challenge for the iOS
// device to bind into its attestation. Runs WITHOUT JWT validation on
// purpose: an unattested device on first launch needs to register before any
// JWT-gated endpoint is reachable. Bounded by the underlying KV TTL (5min)
// + per-IP rate limit on the surrounding worker.

import { issueAppAttestChallenge } from '../../middleware/app-attest.js';
import { jsonResponse } from '../../lib/http.js';

export async function handleAttestChallenge(request, env, ctx) {
  try {
    const { challengeBytes } = await issueAppAttestChallenge(env);
    return jsonResponse({ challenge: btoa(String.fromCharCode(...challengeBytes)) });
  } catch (err) {
    console.error('[attest/challenge] failed', err?.message);
    return jsonResponse({ error: 'challenge_unavailable' }, 500);
  }
}
