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
