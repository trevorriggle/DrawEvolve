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

// Tier shape locked 2026-06-12 (pricing decision, see Desktop cost
// sheet): free = one real coaching session/day; pro = feels-unlimited
// for a serious hobbyist, profit-floored by the monthly spend cap below.
export const TIER_LIMITS = {
  free: { perMinute: 5,  perDay: 3  },
  pro:  { perMinute: 15, perDay: 20 },
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

// =============================================================================
// Monthly quota windows — tier sprint part 1 (2026-06-11)
//
// Daily windows alone can't express "N critiques per month" pricing (a
// daily-capped free user could do perDay × ~30 a month). Monthly counters
// run ALONGSIDE the daily ones: same KV shape, calendar-month UTC key,
// incremented in the same recordSuccessfulCritique batch.
//
//   quota_month:<user_id>:<YYYY-MM>   monthly counter, 40-day TTL
//
// Window semantics: CALENDAR month, UTC — the plumbing default. If pricing
// lands on rolling-30-days-from-purchase instead, the window derivation is
// the one function to swap (utcMonthKey → an anchor-date key fed from the
// entitlements table); counters and gates stay as-is.
//
// Limits are env vars so pricing changes are a wrangler.toml edit, not a
// code change. The compiled defaults below are PLUMBING placeholders sized
// to stay out of TestFlight users' way (looser per-month than the daily
// caps imply) — real numbers come with the pricing decision.

export const MONTHLY_LIMIT_DEFAULTS = { free: 20, pro: 200 };

export function utcMonthKey(now) {
  const d = new Date(now);
  const y = d.getUTCFullYear();
  const m = String(d.getUTCMonth() + 1).padStart(2, '0');
  return `${y}-${m}`;
}

export function secondsUntilNextUtcMonth(now) {
  const d = new Date(now);
  const next = Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 1);
  return Math.max(1, Math.ceil((next - now) / 1000));
}

/** Monthly critique limit for `tier`, env-overridable. */
export function readMonthlyCritiqueLimit(env, tier) {
  const raw = tier === 'pro' ? env?.MONTHLY_CRITIQUES_PRO : env?.MONTHLY_CRITIQUES_FREE;
  const parsed = parseInt(raw ?? '', 10);
  if (Number.isFinite(parsed) && parsed > 0) return parsed;
  return MONTHLY_LIMIT_DEFAULTS[tier] ?? MONTHLY_LIMIT_DEFAULTS.free;
}

function monthlyMessage(tier, limit, retryAfterSeconds) {
  const reset = formatDuration(retryAfterSeconds);
  if (tier === 'pro') {
    return `You've used all ${limit} Pro critiques for this month. Your quota resets on the 1st (in ${reset}).`;
  }
  return `You've used all ${limit} free critiques for this month. Your quota resets on the 1st (in ${reset}). Upgrade to Pro for more.`;
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

  const monthKey = utcMonthKey(now);

  const dailyKey   = `quota:${userId}:${dayKey}`;
  const monthlyKey = `quota_month:${userId}:${monthKey}`;
  const minuteKey  = `rate:${userId}`;
  const ipKey      = `ip:${ipHash}:${hourKey}`;

  const [dailyRaw, monthlyRaw, minuteRaw, ipRaw] = await Promise.all([
    env.QUOTA_KV.get(dailyKey),
    env.QUOTA_KV.get(monthlyKey),
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

  // Monthly gate (tier sprint part 1). Checked after daily so the daily
  // message keeps fronting the common case; both produce `quota_exceeded`
  // with a distinguishing `scope` the client can map to paywall UX.
  const monthlyCount = parseInt(monthlyRaw ?? '0', 10) || 0;
  const monthlyLimit = readMonthlyCritiqueLimit(env, tier);
  if (monthlyCount >= monthlyLimit) {
    const retryAfter = secondsUntilNextUtcMonth(now);
    return {
      ok: false,
      status: 429,
      body: {
        error: 'quota_exceeded',
        scope: 'monthly',
        tier,
        limit: monthlyLimit,
        used: monthlyCount,
        retryAfter,
        message: monthlyMessage(tier, monthlyLimit, retryAfter),
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

  return {
    ok: true,
    ctx: { dailyKey, dailyCount, monthlyKey, monthlyCount, tier, userId, hourKey, limits },
  };
}

/**
 * Increments the daily quota counter and the hourly anomaly counter. Called
 * AFTER a successful OpenAI response — failed requests don't burn quota. If
 * the hourly counter crosses 5× the daily quota on this request (and only on
 * the transition, not on subsequent requests in the same window) fires the
 * webhook or falls back to console.error.
 */
export async function recordSuccessfulCritique({ env, ctx, now }) {
  const { dailyKey, dailyCount, monthlyKey, monthlyCount, tier, userId, hourKey, limits } = ctx;
  const newDaily = dailyCount + 1;
  // Monthly counter rides the same success-only increment. ctx fields are
  // optional for back-compat with any caller built before the monthly gate
  // (none in-tree, but the guard is free).
  const newMonthly = (monthlyCount ?? 0) + 1;

  const anomalyKey = `hourly:${userId}:${hourKey}`;
  const prevHourlyRaw = await env.QUOTA_KV.get(anomalyKey);
  const prevHourly = parseInt(prevHourlyRaw ?? '0', 10) || 0;
  const newHourly = prevHourly + 1;

  const puts = [
    env.QUOTA_KV.put(dailyKey, String(newDaily), { expirationTtl: 48 * 3600 }),
    env.QUOTA_KV.put(anomalyKey, String(newHourly), { expirationTtl: 2 * 3600 }),
  ];
  if (monthlyKey) {
    // 40-day TTL: covers the calendar month plus grace for clock skew /
    // late reads; the key name carries the month so a stale value can
    // never bleed into the next window.
    puts.push(env.QUOTA_KV.put(monthlyKey, String(newMonthly), { expirationTtl: 40 * 24 * 3600 }));
  }
  await Promise.all(puts);

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
// Cost ceilings (launch-blocker hard caps)
// =============================================================================
//
// Two independent fail-closed ceilings sit in front of the OpenAI call,
// AFTER tier rate limits. They run on every critique request:
//
//   1. Provider daily spend cap — caps cumulative estimated USD spend per
//      UTC day across ALL users. Reads OPENAI_DAILY_SPEND_CAP_USD env var,
//      falls back to DAILY_SPEND_CAP_USD constant. Tracked under
//      `daily_spend:<YYYY-MM-DD>`. On breach: 429 daily_spend_cap_exceeded.
//
//   2. Per-user daily token cap — caps cumulative input+output tokens per
//      (user, UTC day). Reads PER_USER_DAILY_TOKEN_CAP env var; if unset,
//      no cap is enforced. Tracked under `user_tokens:<user_id>:<YYYY-MM-DD>`.
//      Pre-flight reject when at-or-above; post-flight increment by actual
//      tokens from the OpenAI usage block. On breach: 429
//      per_user_token_cap_exceeded.
//
// Both reset implicitly at UTC midnight (new day = new key). Both are
// independent of TIER_LIMITS — the tier-based per-minute / per-day quotas
// stay in place as soft rate limits; these are absolute spend/abuse caps.

export const DAILY_SPEND_CAP_USD = 5.00;

// Pre-flight cost estimate added to the running daily spend total before the
// cap comparison. Conservative — sized to cover the worst-typical gpt-5.1
// critique cost from RATELIMITSPLAN.md §1.5 (~$0.0043) plus headroom. The
// catastrophic high-detail-vision case ($0.0108) under-counts here, but that
// path isn't shipped today and the ceiling is a hard circuit breaker, not a
// precise meter — actual cost is recorded post-flight via incrementDailySpend.
export const ESTIMATED_REQUEST_COST_USD = 0.005;

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

/**
 * Resolve the active daily spend cap. Env override wins; missing/invalid
 * values fall back to the compiled-in DAILY_SPEND_CAP_USD constant so a
 * misconfigured deploy still has a ceiling.
 */
export function readDailySpendCapUsd(env) {
  const raw = env?.OPENAI_DAILY_SPEND_CAP_USD;
  if (raw === undefined || raw === null || raw === '') return DAILY_SPEND_CAP_USD;
  const parsed = typeof raw === 'number' ? raw : parseFloat(raw);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : DAILY_SPEND_CAP_USD;
}

/**
 * Resolve the active per-user daily token cap. Returns Infinity (no cap)
 * when unset or unparseable — operators must explicitly opt in by setting
 * PER_USER_DAILY_TOKEN_CAP. Documented as a launch-blocker in wrangler.toml.
 */
export function readPerUserDailyTokenCap(env) {
  const raw = env?.PER_USER_DAILY_TOKEN_CAP;
  if (raw === undefined || raw === null || raw === '') return Infinity;
  const parsed = typeof raw === 'number' ? raw : parseInt(raw, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : Infinity;
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

export async function getUserTokensToday(env, userId, dayKey) {
  if (!env?.QUOTA_KV) return 0;
  const raw = await env.QUOTA_KV.get(`user_tokens:${userId}:${dayKey}`);
  const parsed = parseInt(raw ?? '0', 10);
  return Number.isFinite(parsed) ? parsed : 0;
}

export async function incrementUserTokensToday(env, userId, dayKey, tokens) {
  if (!env?.QUOTA_KV) return tokens;
  const safe = Math.max(0, Math.floor(Number(tokens) || 0));
  const current = await getUserTokensToday(env, userId, dayKey);
  const next = current + safe;
  await env.QUOTA_KV.put(`user_tokens:${userId}:${dayKey}`, String(next), { expirationTtl: 48 * 3600 });
  return next;
}

/**
 * Pre-flight cost ceilings. Runs after JWT + App Attest + tier rate limits,
 * before the OpenAI call. Returns a rejection decision (status + body) on
 * breach, or { ok: true, ctx: { dayKey } } on pass.
 *
 * Daily spend cap: rejects when (current spend + estimated request cost) >
 * cap. The estimate is the buffer that prevents N concurrent isolates from
 * all reading the same sub-cap value and racing past the ceiling.
 *
 * Per-user token cap: rejects when current token count is at-or-above the
 * cap. No estimated-token charge — a user who's just barely under the cap
 * still gets to make one request, which then records its actual usage and
 * pushes them over. Acceptable: the next request is rejected.
 */
export async function enforceCostCeilings({ env, userId, now, tier = 'free' }) {
  const dayKey = utcDayKey(now);
  const dailyCap = readDailySpendCapUsd(env);
  const userTokenCap = readPerUserDailyTokenCap(env);
  const retryAfter = secondsUntilNextUtcMidnight(now);

  // Per-user MONTHLY spend cap — the no-loss guarantee. Checked first:
  // it's the only ceiling whose breach means "this user costs more than
  // they pay," and its scope tells the client this isn't a daily wall.
  // Should essentially never fire (UX caps bound usage far below it) —
  // if telemetry shows it firing, that's a pricing-design signal.
  const monthKey = utcMonthKey(now);
  const monthlySpendCap = readMonthlySpendCapUsd(env, tier);
  const monthlySpend = await getUserSpendMonth(env, userId, monthKey);
  if (monthlySpend >= monthlySpendCap) {
    return {
      ok: false,
      status: 429,
      body: {
        error: 'monthly_spend_cap_exceeded',
        scope: 'spend',
        tier,
        retryAfter: secondsUntilNextUtcMonth(now),
        message: 'You have genuinely maxed out the engine this month — quota resets on the 1st.',
      },
    };
  }

  const dailySpend = await getDailySpend(env, dayKey);
  if (dailySpend + ESTIMATED_REQUEST_COST_USD > dailyCap) {
    return {
      ok: false,
      status: 429,
      body: {
        error: 'daily_spend_cap_exceeded',
        retryAfter,
        message: 'Daily limit reached, try again tomorrow.',
      },
    };
  }

  if (Number.isFinite(userTokenCap)) {
    const currentTokens = await getUserTokensToday(env, userId, dayKey);
    if (currentTokens >= userTokenCap) {
      return {
        ok: false,
        status: 429,
        body: {
          error: 'per_user_token_cap_exceeded',
          retryAfter,
          message: 'Daily limit reached, try again tomorrow.',
        },
      };
    }
  }

  return { ok: true, ctx: { dayKey } };
}

/**
 * Post-flight: increment the per-user daily token counter by the actual
 * usage from the OpenAI response. Fire-and-forget by callers — a failure
 * here doesn't block the user's response.
 */
export async function recordRequestUsage({ env, userId, dayKey, usage }) {
  if (!usage) return;
  const tokens = (usage.prompt_tokens ?? 0) + (usage.completion_tokens ?? 0);
  const puts = [];
  if (tokens > 0) {
    puts.push(incrementUserTokensToday(env, userId, dayKey, tokens));
  }
  // Per-user MONTHLY spend meter (no-loss guarantee, 2026-06-12). Every
  // OpenAI path (critique, Eve, recommendations) already routes its
  // usage block through here, so this single choke point accumulates
  // each user's actual measured dollar cost. monthKey derives from
  // dayKey (YYYY-MM-DD → YYYY-MM). computeRequestCost prices everything
  // at gpt-5.1 rates, OVERCOUNTING the mini calls — conservative in the
  // profitable direction.
  const cost = computeRequestCost(usage);
  if (cost > 0) {
    puts.push(incrementUserSpendMonth(env, userId, dayKey.slice(0, 7), cost));
  }
  await Promise.all(puts);
}

// =============================================================================
// Per-user monthly spend cap — the Pro no-loss guarantee (2026-06-12)
//
// UX caps (daily/monthly counts) shape the experience; THIS is the profit
// floor. A user's measured spend (actual OpenAI usage × list price, via
// computeRequestCost) accumulates in user_spend_month:<user>:<YYYY-MM>;
// enforceCostCeilings hard-stops at the tier's cap. Caps sit far above
// what the UX caps even permit (pro $3.00 ≈ 450 critiques of cost vs the
// 200/month UX cap), so they're invisible to every legitimate user —
// they exist to make "loss-making Pro subscriber" mathematically
// impossible at $4.99 (nets $4.24 under the App Store Small Business
// Program; guaranteed margin ≥ $1.24).

export const SPEND_CAP_MONTHLY_DEFAULTS_USD = { free: 0.75, pro: 3.00 };

export function readMonthlySpendCapUsd(env, tier) {
  const raw = tier === 'pro' ? env?.SPEND_CAP_MONTHLY_PRO_USD : env?.SPEND_CAP_MONTHLY_FREE_USD;
  const parsed = parseFloat(raw ?? '');
  if (Number.isFinite(parsed) && parsed > 0) return parsed;
  return SPEND_CAP_MONTHLY_DEFAULTS_USD[tier] ?? SPEND_CAP_MONTHLY_DEFAULTS_USD.free;
}

export async function getUserSpendMonth(env, userId, monthKey) {
  const raw = await env.QUOTA_KV.get(`user_spend_month:${userId}:${monthKey}`);
  const parsed = parseFloat(raw ?? '0');
  return Number.isFinite(parsed) ? parsed : 0;
}

export async function incrementUserSpendMonth(env, userId, monthKey, amountUsd) {
  if (!Number.isFinite(amountUsd) || amountUsd <= 0) return;
  const current = await getUserSpendMonth(env, userId, monthKey);
  await env.QUOTA_KV.put(
    `user_spend_month:${userId}:${monthKey}`,
    String(current + amountUsd),
    { expirationTtl: 40 * 24 * 3600 },
  );
}

// =============================================================================
// Eve conversational coach — Feature 2, Phase 2A
// =============================================================================
//
// Eve message sends share the global daily-spend cap and the per-user
// daily-token cap with critiques (one wallet, two paths — a user blowing
// through tokens on Eve shouldn't get a free critique on top), but get
// their OWN per-minute and per-day MESSAGE counts so a user can have a
// rapid back-and-forth with Eve without burning their critique allowance.
//
//   eve_quota:<user_id>:<utc-day>   daily message counter, 48h TTL
//   eve_rate:<user_id>              rolling 60s window of timestamps
//
// EVE_MAX_TURNS_PER_CONVERSATION lives in env, but is enforced at the
// per-conversation level inside routes/eve.js (a SELECT count on the
// message table) — it's a structural ceiling, not a rate gate, so it
// doesn't belong in the per-user KV layer.

export const EVE_TIER_LIMITS = {
  free: { perMinute: 10, perDay: 10  },
  pro:  { perMinute: 30, perDay: 100 },
};

// Eve monthly windows (tier shape 2026-06-12). Eve is the cost center —
// daily caps alone left a "$9/month grinder" hole (60/day × 30). Same
// calendar-month KV pattern as the critique monthly windows.
export const EVE_MONTHLY_DEFAULTS = { free: 75, pro: 1000 };

export function readEveMonthlyLimit(env, tier) {
  const raw = tier === 'pro' ? env?.EVE_MONTHLY_PRO : env?.EVE_MONTHLY_FREE;
  const parsed = parseInt(raw ?? '', 10);
  if (Number.isFinite(parsed) && parsed > 0) return parsed;
  return EVE_MONTHLY_DEFAULTS[tier] ?? EVE_MONTHLY_DEFAULTS.free;
}

function readEveLimit(env, key, fallback) {
  const raw = env?.[key];
  if (raw === undefined || raw === null || raw === '') return fallback;
  const parsed = typeof raw === 'number' ? raw : parseInt(raw, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

/**
 * Resolve Eve's per-tier limits from env (which the wrangler vars set
 * as strings). Pulls each axis independently so a partial override still
 * gets defaults for the others.
 */
export function readEveTierLimits(env) {
  return {
    free: {
      perMinute: readEveLimit(env, 'EVE_PER_MINUTE_FREE', EVE_TIER_LIMITS.free.perMinute),
      perDay:    readEveLimit(env, 'EVE_PER_DAY_FREE',    EVE_TIER_LIMITS.free.perDay),
    },
    pro: {
      perMinute: readEveLimit(env, 'EVE_PER_MINUTE_PRO',  EVE_TIER_LIMITS.pro.perMinute),
      perDay:    readEveLimit(env, 'EVE_PER_DAY_PRO',     EVE_TIER_LIMITS.pro.perDay),
    },
  };
}

export function readEveMaxTurnsPerConversation(env) {
  return readEveLimit(env, 'EVE_MAX_TURNS_PER_CONVERSATION', 100);
}

/**
 * Per-conversation raw-tail message count hydrated on each send. Default
 * 20 messages = 10 turns. Backs the rolling-summary proposal §2 — the
 * tail is the recent verbatim window, everything older is represented
 * by conversations.rolling_summary. Env override:
 * EVE_RAW_TAIL_MESSAGES=<int>.
 */
export function readEveRawTailMessages(env) {
  return readEveLimit(env, 'EVE_RAW_TAIL_MESSAGES', 20);
}

/**
 * Stride at which rolling_summary regenerates, in messages. Default 10
 * messages = 5 turns. MUST satisfy `stride <= tailLimit` — see
 * proposal R1: the constraint is what keeps the staleness window
 * inside the tail's reach (so the dropped middle never opens up
 * between summary boundary and raw tail). Env override:
 * EVE_SUMMARY_REGEN_STRIDE=<int>.
 */
export function readEveSummaryRegenStride(env) {
  return readEveLimit(env, 'EVE_SUMMARY_REGEN_STRIDE', 10);
}

function eveDailyMessage(tier, limit, retryAfterSeconds) {
  const reset = formatDuration(retryAfterSeconds);
  if (tier === 'pro') {
    return `You've reached the Pro tier limit of ${limit} Eve messages today. Your quota resets at midnight UTC (in ${reset}).`;
  }
  return `You've reached the free tier limit of ${limit} Eve messages today. Your quota resets at midnight UTC (in ${reset}).`;
}

function eveMinuteMessage(retryAfterSeconds) {
  return `Slow down a moment — you're sending messages to Eve too quickly. Try again in ${formatDuration(retryAfterSeconds)}.`;
}

/**
 * Same shape as enforceRateLimits but uses Eve's own counters + Eve's
 * own messaging. Returns a rejection decision or a ctx for the post-
 * flight increment.
 *
 * Eve does NOT enforce a per-IP backstop in 2A — the critique flow's
 * per-IP cap already gates the same JWT/user/IP triple at a coarser
 * level. Adding a second per-IP bucket here would double-count without
 * adding real protection.
 */
export async function enforceEveRateLimits({ env, userId, tier, now }) {
  const limits = readEveTierLimits(env)[tier] ?? readEveTierLimits(env).free;
  const dayKey = utcDayKey(now);

  const monthKey = utcMonthKey(now);
  const dailyKey   = `eve_quota:${userId}:${dayKey}`;
  const monthlyKey = `eve_quota_month:${userId}:${monthKey}`;
  const minuteKey  = `eve_rate:${userId}`;

  const [dailyRaw, monthlyRaw, minuteRaw] = await Promise.all([
    env.QUOTA_KV.get(dailyKey),
    env.QUOTA_KV.get(monthlyKey),
    env.QUOTA_KV.get(minuteKey),
  ]);

  const dailyCount = parseInt(dailyRaw ?? '0', 10) || 0;
  if (dailyCount >= limits.perDay) {
    const retryAfter = secondsUntilNextUtcMidnight(now);
    return {
      ok: false,
      status: 429,
      body: {
        error: 'eve_quota_exceeded',
        scope: 'daily',
        tier,
        limit: limits.perDay,
        used: dailyCount,
        retryAfter,
        message: eveDailyMessage(tier, limits.perDay, retryAfter),
      },
    };
  }

  // Eve monthly gate (tier shape 2026-06-12) — closes the daily-grinder
  // cost hole. Same calendar-month semantics as the critique windows.
  const monthlyCount = parseInt(monthlyRaw ?? '0', 10) || 0;
  const monthlyLimit = readEveMonthlyLimit(env, tier);
  if (monthlyCount >= monthlyLimit) {
    const retryAfter = secondsUntilNextUtcMonth(now);
    return {
      ok: false,
      status: 429,
      body: {
        error: 'eve_quota_exceeded',
        scope: 'monthly',
        tier,
        limit: monthlyLimit,
        used: monthlyCount,
        retryAfter,
        message: tier === 'pro'
          ? `You've used all ${monthlyLimit} Eve messages for this month. Resets on the 1st.`
          : `You've used all ${monthlyLimit} free Eve messages for this month. Resets on the 1st — or upgrade to Pro for more.`,
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
        error: 'eve_rate_limited',
        scope: 'minute',
        tier,
        limit: limits.perMinute,
        used: recent.length,
        retryAfter,
        message: eveMinuteMessage(retryAfter),
      },
    };
  }

  // Per-minute bucket records pre-OpenAI so concurrent bursts can't slip
  // past the gate. Daily increments only on a delivered assistant turn.
  await env.QUOTA_KV.put(minuteKey, JSON.stringify([...recent, now]), { expirationTtl: 120 });

  return {
    ok: true,
    ctx: { dailyKey, dailyCount, monthlyKey, monthlyCount, tier, userId, limits },
  };
}

/**
 * Increment the Eve daily + monthly message counters after a successful
 * assistant turn. Pairs with enforceEveRateLimits. Fire-and-forget —
 * failure never blocks the user response.
 */
export async function recordSuccessfulEveTurn({ env, ctx }) {
  const { dailyKey, dailyCount, monthlyKey, monthlyCount } = ctx;
  const puts = [
    env.QUOTA_KV.put(dailyKey, String(dailyCount + 1), { expirationTtl: 48 * 3600 }),
  ];
  if (monthlyKey) {
    puts.push(env.QUOTA_KV.put(monthlyKey, String((monthlyCount ?? 0) + 1), { expirationTtl: 40 * 24 * 3600 }));
  }
  await Promise.all(puts);
}

// =============================================================================
// Quota status readout — GET /v1/me/quota (tier sprint part 1, 2026-06-11)
//
// Read-only aggregation of the counters above so the iOS app can render
// "N of M used" and drive upsell UX. Reads the same KV keys the gates
// read; never writes. limit_month / used_month are the new monthly
// window; daily fields mirror the existing gates. `tokens.cap_today` is
// null when PER_USER_DAILY_TOKEN_CAP is unset (cap disabled).

export async function readQuotaStatus({ env, userId, tier, now }) {
  const dayKey = utcDayKey(now);
  const monthKey = utcMonthKey(now);
  const limits = TIER_LIMITS[tier] ?? TIER_LIMITS.free;
  const monthlyLimit = readMonthlyCritiqueLimit(env, tier);
  const eveLimits = readEveTierLimits(env)[tier] ?? readEveTierLimits(env).free;
  const tokenCap = readPerUserDailyTokenCap(env);

  const [dailyRaw, monthlyRaw, eveDailyRaw, eveMonthlyRaw, tokensToday] = await Promise.all([
    env.QUOTA_KV.get(`quota:${userId}:${dayKey}`),
    env.QUOTA_KV.get(`quota_month:${userId}:${monthKey}`),
    env.QUOTA_KV.get(`eve_quota:${userId}:${dayKey}`),
    env.QUOTA_KV.get(`eve_quota_month:${userId}:${monthKey}`),
    getUserTokensToday(env, userId, dayKey),
  ]);

  return {
    tier,
    critiques: {
      used_today: parseInt(dailyRaw ?? '0', 10) || 0,
      limit_today: limits.perDay,
      used_month: parseInt(monthlyRaw ?? '0', 10) || 0,
      limit_month: monthlyLimit,
      day_resets_in: secondsUntilNextUtcMidnight(now),
      month_resets_in: secondsUntilNextUtcMonth(now),
    },
    eve_messages: {
      used_today: parseInt(eveDailyRaw ?? '0', 10) || 0,
      limit_today: eveLimits.perDay,
      used_month: parseInt(eveMonthlyRaw ?? '0', 10) || 0,
      limit_month: readEveMonthlyLimit(env, tier),
    },
    tokens: {
      used_today: tokensToday,
      cap_today: Number.isFinite(tokenCap) ? tokenCap : null,
    },
  };
}
