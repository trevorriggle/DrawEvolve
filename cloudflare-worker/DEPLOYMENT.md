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

## Phase 5f manual steps (App Attest device verification)

App Attest layers on top of Supabase JWT auth. JWT proves who the user is;
App Attest proves the request comes from a real DrawEvolve install on a real
Apple device. **Both must pass for any protected request.**

### iOS-side prerequisites

1. **Xcode capability** — In Signing & Capabilities for the DrawEvolve target,
   add **App Attest**. This puts
   `com.apple.developer.devicecheck.appattest-environment` in the entitlements
   plist (already added in this branch with value `development`).
2. **Provisioning profile** — Apple Developer Portal → Identifiers → your
   App ID → enable **App Attest**. Regenerate the provisioning profile if
   Xcode has already cached an older one.
3. **Environment string** — `DrawEvolve/DrawEvolve/DrawEvolve.entitlements`:
   - `development` for local builds + TestFlight
   - `production` for App Store builds
   The string selects which Apple endpoints `DCAppAttestService` talks to and
   which AAGUID the resulting attestation carries — the Worker checks both.
4. **No simulator** — App Attest requires real Apple hardware. The simulator
   reports `DCAppAttestService.shared.isSupported == false`. Test on a device.

### Worker-side prerequisites

The Worker reuses the existing `QUOTA_KV` namespace for App Attest storage —
no new binding required. Three new vars must be set in `wrangler.toml`'s
`[vars]` block before deploy:

| Var | Value |
|---|---|
| `APP_ATTEST_TEAM_ID` | Your 10-character Apple Team ID (e.g. `ABCDE12345`) |
| `APP_ATTEST_BUNDLE_ID` | iOS bundle identifier (default `com.drawevolve.app`) |
| `APP_ATTEST_ENV` | `development` or `production` — must match the iOS entitlement value |

`APP_ATTEST_TEAM_ID + "." + APP_ATTEST_BUNDLE_ID` is hashed into the rpId
that the Worker checks on every request — a mismatch with the iOS app ID
will reject every assertion with `assert_rpid_mismatch`.

### One-time: pin the Apple App Attest Root CA public key

`/attest/register` fail-closes with `attest_root_not_pinned` (HTTP 500) until
the operator pastes the Apple App Attest Root CA's uncompressed P-384 public
key into `middleware/app-attest.js`'s `APPLE_ATTEST_ROOT_PUBKEY_HEX` constant.
This lives as a source constant on purpose — bundling it with the worker code
ensures a deploy can never accidentally pair the wrong root with the wrong
worker version.

To extract it:

1. Download `Apple_App_Attestation_Root_CA.pem` from
   <https://www.apple.com/certificateauthority/>.
2. Confirm SHA-256 fingerprint matches what Apple publishes on that page
   (cross-check before pasting).
3. Extract the EC public key as an uncompressed point (`04` || X(48) || Y(48),
   97 bytes / 194 hex chars):
   ```bash
   openssl x509 -in Apple_App_Attestation_Root_CA.pem -noout -pubkey \
     | openssl ec -pubin -outform DER 2>/dev/null \
     | tail -c 97 \
     | xxd -p -c 0
   ```
4. Paste the resulting hex string (no `0x`, no whitespace) into
   `APPLE_ATTEST_ROOT_PUBKEY_HEX` and redeploy.

Until this step is done, the Worker is intentionally unable to register any
new device.

### Endpoints

- `POST /attest/challenge` — returns `{ challenge: <base64-32-bytes> }`. No
  auth required; rate-limited only by Cloudflare's per-IP defaults at this
  level. Stored under `attest_chal:<base64url>` in QUOTA_KV with 5-min TTL.
- `POST /attest/register` — body `{ keyId, attestation, challenge }`. Verifies
  the attestation per Apple's spec (cert chain → root, nonce extension,
  rpIdHash, AAGUID, credId), then stores `{ pub, counter: 0, env }` under
  `attest_key:<keyId>` with 30-day TTL.
- All other paths (the existing critique endpoint) — require both a valid
  Supabase JWT *and* `X-Apple-AppAttest-KeyId` + `X-Apple-AppAttest-Assertion`
  headers. Rejection codes the iOS client uses to decide what to do:
  - `attest_headers_missing` → wipe local cache, re-register
  - `attest_key_unknown` → server has no record of this key (KV TTL expired
    or never registered) → wipe local cache, re-register
  - `attest_env_mismatch` → dev key seen by prod Worker (or vice versa) — fix
    the entitlement env, re-register
  - `attest_assertion_invalid` → bad signature, replay, or rpId mismatch

### Troubleshooting

**`attest_root_not_pinned` (500)** — see "pin the Apple App Attest Root CA"
above. The Worker won't accept any registration until this is done.

**`attest_assertion_invalid` on every request** — most often
`APP_ATTEST_TEAM_ID` or `APP_ATTEST_BUNDLE_ID` doesn't match the iOS app's
team/bundle. Check both sides.

**`attest_headers_missing` after a fresh install** — usually means
`AppAttestManager` failed to register silently and the iOS app shipped the
critique request anyway. Check Crashlytics for `App Attest` errors.

**Simulator builds get `notSupported`** — expected. Use a physical device.
