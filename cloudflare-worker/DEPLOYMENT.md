# Deploy DrawEvolve Backend to Cloudflare Workers

## Required secrets (Phase 5a/5b)

Every feedback request now requires a valid Supabase JWT and a `drawing_id`
that belongs to the JWT's user. To deploy, four secrets must be set on the
Worker via `wrangler secret put <NAME>`:

| Secret | Where to find it | Purpose |
|---|---|---|
| `OPENAI_API_KEY` | OpenAI dashboard → API Keys | GPT-4o Vision call |
| `SUPABASE_URL` | Supabase dashboard → Project Settings → API → Project URL (e.g. `https://jkjfcjptzvieaonrmkzd.supabase.co`) | JWKS endpoint + PostgREST queries |
| `SUPABASE_JWT_ISSUER` | Same URL with `/auth/v1` appended (e.g. `https://jkjfcjptzvieaonrmkzd.supabase.co/auth/v1`) | Verified against every JWT's `iss` claim |
| `SUPABASE_SERVICE_ROLE_KEY` | Supabase dashboard → Project Settings → API → `service_role` key | Ownership check + critique-history fetch (bypasses RLS) |

**Never commit `SUPABASE_SERVICE_ROLE_KEY`** — it's god-mode for the Postgres
database. Worker secrets live only in Cloudflare's encrypted store.

JWT validation uses **ES256 with the project's public JWKS** (Phase 5a). No
shared HMAC secret is needed; the Worker fetches
`<SUPABASE_URL>/auth/v1/.well-known/jwks.json` and caches it for 10 minutes.

```bash
wrangler secret put OPENAI_API_KEY
wrangler secret put SUPABASE_URL
wrangler secret put SUPABASE_JWT_ISSUER
wrangler secret put SUPABASE_SERVICE_ROLE_KEY
```

After all four are set: `wrangler deploy`.

## Phase 5c manual steps (rate limiting + cost ceilings)

### KV namespace (REQUIRED before deploy)

The Worker reads/writes daily quotas, per-minute timestamps, per-IP backstop
counters, and an hourly anomaly counter from a single KV namespace bound as
`QUOTA_KV`.

```bash
wrangler kv:namespace create drawevolve-quota
```

Wrangler prints a namespace `id`. Paste it into `wrangler.toml`, replacing
`REPLACE_WITH_NAMESPACE_ID`. Without this, `wrangler deploy` will fail.

### OpenAI monthly cap (REQUIRED before public TestFlight)

The KV-backed Worker checks are the first line of defense. The provider-level
cap is the last line — enforced by OpenAI itself, cannot be bypassed by any
bug in our stack.

1. Go to [platform.openai.com → Settings → Limits](https://platform.openai.com/account/limits).
2. Set **Monthly budget** to **$75** for the TestFlight phase. (Covers ~50
   active free-tier users at full daily quota with headroom; revisit before
   public launch.)
3. Configure email alerts at **50%** ($37.50) and **80%** ($60).

This is mandatory before distributing the build to anyone outside the team.

### Anomaly alert webhook (OPTIONAL — defer until ready)

If `ANOMALY_ALERT_WEBHOOK` is configured, the Worker POSTs JSON when a single
user crosses 5× their daily quota in a 1-hour window (likely JWT theft or a
runaway client). Until configured, threshold crossings fall back to
`console.error` and surface in `wrangler tail`.

```bash
wrangler secret put ANOMALY_ALERT_WEBHOOK
# Paste a Slack incoming webhook URL (or compatible) when prompted.
```

## Files Created
- `index.js` - The Cloudflare Worker code
- `wrangler.toml` - Configuration file

## Deployment Steps

### 1. Clean up your DrawEvolve-BACKEND repo
Delete these files from the repo (they're from the failed Vercel attempt):
- `package.json`
- `next.config.js`
- `vercel.json`
- `pages/` folder (entire directory)
- `api/` folder (if it exists outside pages)

### 2. Copy these files to your DrawEvolve-BACKEND repo
Copy both files to the root of your DrawEvolve-BACKEND repo:
- `index.js`
- `wrangler.toml`

Your repo should look like:
```
DrawEvolve-BACKEND/
├── index.js
└── wrangler.toml
```

### 3. Deploy from your Mac Mini

Open Terminal on your Mac Mini and run:

```bash
cd path/to/DrawEvolve-BACKEND

# Login to Cloudflare (opens browser, login once)
wrangler login

# Set your OpenAI API key as a secret
wrangler secret put OPENAI_API_KEY
# Paste your OpenAI API key when prompted

# Deploy!
wrangler deploy
```

### 4. Get your Worker URL
After deployment succeeds, Wrangler will show you the URL:
```
https://drawevolve-backend.YOUR-SUBDOMAIN.workers.dev
```

Copy that URL.

### 5. Update iOS app
In `DrawEvolve/Services/OpenAIManager.swift` line 35, update:
```swift
private let backendURL = "https://drawevolve-backend.YOUR-SUBDOMAIN.workers.dev"
```

### 6. Test
- Build and run the iOS app
- Draw something
- Tap "Get Feedback"
- Should see AI feedback appear!

## Troubleshooting

**"wrangler: command not found"**
```bash
npm install -g wrangler
```

**"Not authenticated"**
```bash
wrangler login
```

**"OPENAI_API_KEY not set"**
```bash
wrangler secret put OPENAI_API_KEY
```

**Worker deployed but returns errors**
Check Cloudflare dashboard → Workers → Logs to see errors
