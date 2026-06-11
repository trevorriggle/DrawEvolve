// GET /v1/me/quota — quota status readout (tier sprint part 1, 2026-06-11).
//
// Read-only: aggregates the KV counters the rate-limit gates maintain so
// the iOS app can render "N of M critiques used" and drive paywall/upsell
// UX. Same auth gates as every other /v1/me surface (JWT + App Attest when
// enforced) via requireAuth. Never writes; safe to poll.
//
// Response shape (all counts integers, resets in seconds):
//   {
//     tier: "free" | "pro",
//     critiques: { used_today, limit_today, used_month, limit_month,
//                  day_resets_in, month_resets_in },
//     eve_messages: { used_today, limit_today },
//     tokens: { used_today, cap_today | null }
//   }

import { validateWorkerConfig, getUserTier } from '../middleware/auth.js';
import { requireAuth } from './profiles.js';
import { readQuotaStatus } from '../middleware/rate-limit.js';
import { jsonResponse } from '../lib/http.js';

export async function handleQuotaStatus(request, env, ctx) {
  const configErr = validateWorkerConfig(env);
  if (configErr) return jsonResponse({ error: configErr }, 500);

  const auth = await requireAuth(request, env, ctx);
  if (!auth.ok) return auth.response;

  const { tier } = getUserTier(auth.payload);
  try {
    const body = await readQuotaStatus({
      env,
      userId: auth.userId,
      tier,
      now: Date.now(),
    });
    return jsonResponse(body);
  } catch (err) {
    console.error('[quota] readQuotaStatus failed', err?.message);
    return jsonResponse({ error: 'quota_unavailable' }, 502);
  }
}
