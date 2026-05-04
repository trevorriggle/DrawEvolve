// Phase 5c — rate limiting + cost ceilings.
//
// Three KV-backed gates run in front of the OpenAI call, plus one anomaly
// counter that runs behind it:
//
//   quota:<user_id>:<utc-day>       daily counter, 48h TTL  → tier.perDay
//   rate:<user_id>                  rolling window of timestamps, 120s TTL → tier.perMinute
//   ip:<sha256(ip)>:<utc-hour>      per-IP counter, 1h TTL  → IP_HOURLY_CAP
//   hourly:<user_id>:<utc-hour>     anomaly counter, 2h TTL → 5× tier.perDay fires alert
//
// Daily quota counts *delivered* critiques (incremented after OpenAI success).
// Per-minute + per-IP record the *attempt* before OpenAI so concurrent bursts
// can't slip past the gate while OpenAI is still responding.
//
// Daily-spend cap (DAILY_SPEND_CAP_USD + getDailySpend / incrementDailySpend
// helpers below) is a global hard ceiling enforced by the request handler
// before any OpenAI call. Lives in this file because it's cost / abuse
// machinery in the same neighborhood as quota counters.

export const TIER_LIMITS = {
  free: { perMinute: 5,  perDay: 20  },
  pro:  { perMinute: 15, perDay: 200 },
};
export const IP_HOURLY_CAP = 100;
export const ANOMALY_MULTIPLIER = 5;

export function utcDayKey(now) {
  const d = new Date(now);
  const y = d.getUTCFullYear();
  const m = String(d.getUTCMonth() + 1).padStart(2, '0');
  const day = String(d.getUTCDate()).padStart(2, '0');
  return `${y}-${m}-${day}`;
}

export function utcHourKey(now) {
  const d = new Date(now);
  const h = String(d.getUTCHours()).padStart(2, '0');
  return `${utcDayKey(now)}T${h}`;
}

export function secondsUntilNextUtcMidnight(now) {
  const d = new Date(now);
  const next = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() + 1);
  return Math.max(1, Math.ceil((next - now) / 1000));
}

function formatDuration(seconds) {
  if (seconds < 60) return `${seconds}s`;
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  if (h > 0 && m > 0) return `${h}h ${m}m`;
  if (h > 0) return `${h}h`;
  return `${m}m`;
}

export async function sha256Hex(input) {
  const buf = new TextEncoder().encode(input);
  const hash = await crypto.subtle.digest('SHA-256', buf);
  return [...new Uint8Array(hash)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function dailyMessage(tier, limit, retryAfterSeconds) {
  const reset = formatDuration(retryAfterSeconds);
  if (tier === 'pro') {
    return `You've reached the Pro tier limit of ${limit} critiques today. Your quota resets at midnight UTC (in ${reset}).`;
  }
  const proLimit = TIER_LIMITS.pro.perDay;
  return `You've reached the free tier limit of ${limit} critiques today. Your quota resets at midnight UTC (in ${reset}). Upgrade to Pro for ${proLimit} critiques per day.`;
}

function perMinuteMessage(retryAfterSeconds) {
  return `Slow down a moment — you're sending requests too quickly. Try again in ${formatDuration(retryAfterSeconds)}.`;
}

function ipMessage() {
  return 'Too many requests from your network. Please try again in about an hour.';
}

/**
 * Reads the three rate-limit counters and either rejects with a 429 decision
 * or records the attempt (per-minute + per-IP) and returns a ctx for the
 * post-OpenAI daily increment. KV is eventually consistent — under high
 * concurrency a small overshoot is possible; that's acceptable for a soft
 * rate limit and the per-IP backstop bounds the worst case.
 */
export async function enforceRateLimits({ env, userId, ip, tier, now }) {
  const limits = TIER_LIMITS[tier] ?? TIER_LIMITS.free;
  const dayKey = utcDayKey(now);
  const hourKey = utcHourKey(now);
  const ipHash = await sha256Hex(ip || 'unknown');

  const dailyKey   = `quota:${userId}:${dayKey}`;
  const minuteKey  = `rate:${userId}`;
  const ipKey      = `ip:${ipHash}:${hourKey}`;

  const [dailyRaw, minuteRaw, ipRaw] = await Promise.all([
    env.QUOTA_KV.get(dailyKey),
    env.QUOTA_KV.get(minuteKey),
    env.QUOTA_KV.get(ipKey),
  ]);

  const dailyCount = parseInt(dailyRaw ?? '0', 10) || 0;
  if (dailyCount >= limits.perDay) {
    const retryAfter = secondsUntilNextUtcMidnight(now);
    return {
      ok: false,
      status: 429,
      body: {
        error: 'quota_exceeded',
        scope: 'daily',
        tier,
        limit: limits.perDay,
        used: dailyCount,
        retryAfter,
        message: dailyMessage(tier, limits.perDay, retryAfter),
      },
    };
  }

  let recent = [];
  if (minuteRaw) {
    try {
      const parsed = JSON.parse(minuteRaw);
      if (Array.isArray(parsed)) {
        recent = parsed.filter((t) => typeof t === 'number' && now - t < 60_000);
      }
    } catch {
      recent = [];
    }
  }
  if (recent.length >= limits.perMinute) {
    const oldest = Math.min(...recent);
    const retryAfter = Math.max(1, Math.ceil((60_000 - (now - oldest)) / 1000));
    return {
      ok: false,
      status: 429,
      body: {
        error: 'rate_limited',
        scope: 'minute',
        tier,
        limit: limits.perMinute,
        used: recent.length,
        retryAfter,
        message: perMinuteMessage(retryAfter),
      },
    };
  }

  const ipCount = parseInt(ipRaw ?? '0', 10) || 0;
  if (ipCount >= IP_HOURLY_CAP) {
    return {
      ok: false,
      status: 429,
      body: {
        error: 'ip_rate_limited',
        scope: 'ip',
        limit: IP_HOURLY_CAP,
        used: ipCount,
        retryAfter: 3600,
        message: ipMessage(),
      },
    };
  }

  // All gates passed — record the attempt against per-minute + per-IP now so
  // concurrent requests in flight see the bump. Daily is incremented later,
  // only on OpenAI success.
  await Promise.all([
    env.QUOTA_KV.put(minuteKey, JSON.stringify([...recent, now]), { expirationTtl: 120 }),
    env.QUOTA_KV.put(ipKey, String(ipCount + 1), { expirationTtl: 3600 }),
  ]);

  return { ok: true, ctx: { dailyKey, dailyCount, tier, userId, hourKey, limits } };
}

/**
 * Increments the daily quota counter and the hourly anomaly counter. Called
 * AFTER a successful OpenAI response — failed requests don't burn quota. If
 * the hourly counter crosses 5× the daily quota on this request (and only on
 * the transition, not on subsequent requests in the same window) fires the
 * webhook or falls back to console.error.
 */
export async function recordSuccessfulCritique({ env, ctx, now }) {
  const { dailyKey, dailyCount, tier, userId, hourKey, limits } = ctx;
  const newDaily = dailyCount + 1;

  const anomalyKey = `hourly:${userId}:${hourKey}`;
  const prevHourlyRaw = await env.QUOTA_KV.get(anomalyKey);
  const prevHourly = parseInt(prevHourlyRaw ?? '0', 10) || 0;
  const newHourly = prevHourly + 1;

  await Promise.all([
    env.QUOTA_KV.put(dailyKey, String(newDaily), { expirationTtl: 48 * 3600 }),
    env.QUOTA_KV.put(anomalyKey, String(newHourly), { expirationTtl: 2 * 3600 }),
  ]);

  const threshold = limits.perDay * ANOMALY_MULTIPLIER;
  if (prevHourly < threshold && newHourly >= threshold) {
    const payload = {
      user_id: userId,
      tier,
      count: newHourly,
      limit: limits.perDay,
      window: hourKey,
      timestamp: new Date(now).toISOString(),
    };
    if (env.ANOMALY_ALERT_WEBHOOK) {
      try {
        await fetch(env.ANOMALY_ALERT_WEBHOOK, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(payload),
        });
      } catch (err) {
        console.error('[anomaly] webhook fetch failed', err?.message);
      }
    } else {
      console.error('[anomaly] threshold crossed (no webhook configured)', payload);
    }
  }
}

// =============================================================================
// Daily spend ceiling (provider-level cost circuit breaker)
// =============================================================================
//
// Hard provider-level daily spend ceiling enforced at the Worker before any
// OpenAI call. Fail-closes with 503 once exceeded, until UTC midnight rolls
// the day key over. Sized for TestFlight; revisit upward as user volume grows.
// This is a HARD ceiling, not a per-user limit — see TIER_LIMITS for those.

export const DAILY_SPEND_CAP_USD = 5.00;

// Approximate per-token rates for cost computation. Kept as a flat pair
// because we run on a single model at a time. When OPENAI_MODEL changes,
// update these to match the new model's published rates.
const COST_PER_INPUT_TOKEN_USD = 0.63 / 1_000_000;   // gpt-5.1
const COST_PER_OUTPUT_TOKEN_USD = 5.00 / 1_000_000;  // gpt-5.1

export function computeRequestCost(usage) {
  const inputTokens = usage?.prompt_tokens ?? 0;
  const outputTokens = usage?.completion_tokens ?? 0;
  return inputTokens * COST_PER_INPUT_TOKEN_USD + outputTokens * COST_PER_OUTPUT_TOKEN_USD;
}

export async function getDailySpend(env, dayKey) {
  if (!env.QUOTA_KV) return 0;
  const raw = await env.QUOTA_KV.get(`daily_spend:${dayKey}`);
  const parsed = parseFloat(raw ?? '0');
  return Number.isFinite(parsed) ? parsed : 0;
}

export async function incrementDailySpend(env, dayKey, amountUsd) {
  // Read-modify-write — small undercount possible under concurrent writes.
  // Acceptable for a daily ceiling at TestFlight scale; the per-IP and
  // per-user rate limits ahead of this gate bound the realistic concurrency.
  // 48h TTL prevents stale day-keys from accumulating in KV.
  if (!env.QUOTA_KV) return amountUsd;
  const current = await getDailySpend(env, dayKey);
  const next = current + amountUsd;
  await env.QUOTA_KV.put(`daily_spend:${dayKey}`, String(next), { expirationTtl: 48 * 3600 });
  return next;
}
