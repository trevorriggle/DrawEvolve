# Deploy DrawEvolve Backend to Cloudflare Workers

## Required secrets (Phase 5a/5b)

Every feedback request now requires a valid Supabase JWT and a `drawing_id`
that belongs to the JWT's user. To deploy, four secrets must be set on the
Worker via `wrangler secret put <NAME>`:

| Secret | Where to find it | Purpose |
|---|---|---|
| `OPENAI_API_KEY` | OpenAI dashboard → API Keys | gpt-5.1 critique + gpt-5-mini classifier/annotator calls |
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

## Files (current layout — post PR #3 modular refactor)

The worker is no longer a single `index.js`. Current structure:

```
cloudflare-worker/
├── index.js                    # top-level router only (~244 lines)
├── routes/
│   ├── feedback.js             # POST / — AI critique flow
│   ├── profiles.js             # /v1/me, /v1/profiles/* (Phase A social)
│   ├── prompts.js              # /v1/prompts/* — custom prompt CRUD
│   ├── evolution.js            # GET /v1/me/evolution — Phase 2 Evolution
│   └── attest/
│       ├── challenge.js        # POST /attest/challenge
│       └── register.js         # POST /attest/register
├── middleware/
│   ├── auth.js                 # JWT validation (ES256/JWKS), getUserTier
│   ├── app-attest.js           # Apple App Attest assertion verification
│   ├── rate-limit.js           # TIER_LIMITS, per-IP backstop, cost ceilings
│   └── idempotency.js          # client_request_id replay cache
├── lib/
│   ├── prompt.js               # voice presets, SHARED_SYSTEM_RULES, assembly
│   ├── supabase.js             # service-role REST helpers
│   ├── http.js                 # CORS_HEADERS, jsonResponse
│   ├── classifier.js           # critique tagging (My Evolution Phase 1)
│   ├── evolution-aggregation.js # pure aggregation for /v1/me/evolution
│   └── taxonomy.js             # critique tag enum (single source of truth)
├── test.mjs                    # node:test suite
├── package.json
└── wrangler.toml
```

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

## Phase 5f manual steps (App Attest device verification — ✅ SHIPPED via PR #5)

App Attest layers on top of Supabase JWT auth. JWT proves who the user is;
App Attest proves the request comes from a real DrawEvolve install on a real
Apple device. **Both must pass for any protected request.**

PR #5 (`b306787` — "Forward-port App Attest + JWT testability into modular Worker") landed the Worker-side enforcement in `cloudflare-worker/middleware/app-attest.js` and the iOS-side in `Services/AppAttestManager.swift`. The manual steps below remain operator-required (capability, profile, root-CA pinning) — the *code* is in place, but a fresh Worker deploy still needs the Apple App Attest Root CA pinned per the runbook below before `/attest/register` will accept any device.

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
`[vars]` block before deploy. These are non-secret operational values, so
they go in `[vars]` (committed) — not `wrangler secret put`.

| Var | Value | Where to find it |
|---|---|---|
| `APP_ATTEST_TEAM_ID` | Your 10-character Apple Team ID (e.g. `ABCDE12345`) | Apple Developer Portal → Membership → Team ID |
| `APP_ATTEST_BUNDLE_ID` | iOS bundle identifier — MUST match the iOS target's `PRODUCT_BUNDLE_IDENTIFIER` (currently `com.rigtech.drawevolve`). Mismatch surfaces as `attestation_invalid` HTTP 400 on every `/attest/register` because the rpId hash won't match the device's authenticatorData. | Xcode → DrawEvolve target → General → Bundle Identifier |
| `APP_ATTEST_ENV` | `development` or `production` — must match the iOS entitlement value | `DrawEvolve.entitlements` → `com.apple.developer.devicecheck.appattest-environment` |

`APP_ATTEST_TEAM_ID` **must** be set in `wrangler.toml` before any
TestFlight build. The shipped value is the DrawEvolve Apple Team ID;
forks need to replace it with their own. The error paths differ
depending on how it's wrong:

- **Empty string:** `appAttestAppId(env)` throws
  `'APP_ATTEST_TEAM_ID not configured'` at
  [`middleware/app-attest.js:330-335`](middleware/app-attest.js#L330-L335),
  which the registration handler maps to a generic
  `400 attestation_invalid` (the loud-but-misnamed failure mode —
  `wrangler tail` shows the real cause).
- **Non-empty but wrong:** registration succeeds, then every
  per-request assertion rejects with `assert_rpid_mismatch` because
  the rpId hash the Worker computes from `<TEAM>.<BUNDLE>` won't
  match what the iPad bound into its assertion.

Confirm `APP_ATTEST_ENV` matches the iOS entitlement at the same
time; a mismatch surfaces as `attest_aaguid_mismatch` on every
registration.

`APP_ATTEST_TEAM_ID + "." + APP_ATTEST_BUNDLE_ID` is hashed into the rpId
that the Worker checks on every request — a mismatch with the iOS app ID
will reject every assertion with `assert_rpid_mismatch`.

**Promoting to App Store:** flip `APP_ATTEST_ENV` to `production` in
`wrangler.toml` *and* the iOS entitlement string in the same release. The
two must move together; a one-sided flip causes `attest_env_mismatch` on
every request.

### One-time: pin the Apple App Attest Root CA public key

`/attest/register` fail-closes with `attest_root_not_pinned` (HTTP 500) until
the operator pastes the Apple App Attest Root CA's uncompressed P-384 public
key into `middleware/app-attest.js`'s `APPLE_ATTEST_ROOT_PUBKEY_HEX` constant.
This lives as a source constant on purpose — bundling it with the worker code
ensures a deploy can never accidentally pair the wrong root with the wrong
worker version. The value is a **public** key (Apple publishes it openly and
all relying parties bundle it identically), so once filled in **the constant
is meant to be committed** to this repo. It is not a secret.

> Note: the recipe references the **App Attest Root CA** specifically — this
> is a different cert than the generic "Apple Root CA" used for code signing.
> Don't substitute one for the other. Apple's PKI index page lists both.

Recipe (run on a Mac with `openssl` ≥ 1.1.1 and `curl`):

1. **Download the App Attest Root CA PEM** from Apple's PKI index. The
   parent index is at <https://www.apple.com/certificateauthority/>; the file
   is listed there as "Apple App Attestation Root CA".
   ```bash
   curl -fSL -o Apple_App_Attestation_Root_CA.pem \
     https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem
   ```
   If the URL ever 404s, fall back to the parent page and copy the link
   from there — Apple has not historically renamed this cert, but they could.

2. **Verify the SHA-256 fingerprint** by triangulating against multiple
   independent open-source App Attest verifier libraries that bundle the
   same root cert as a source constant. Apple does NOT render this
   cert's fingerprint inline on `apple.com/certificateauthority/` and
   does NOT bundle it in Xcode or in any iOS/macOS framework (the iOS
   client never verifies attestations — only the relying party does),
   so neither apple.com nor a local Xcode install can serve as a second
   source. Cross-checking against multiple unrelated maintainers who
   independently downloaded and committed the same value is the
   strongest practical supply-chain check available.

   Compute the local fingerprint:
   ```bash
   openssl x509 -in Apple_App_Attestation_Root_CA.pem -noout -fingerprint -sha256
   ```
   Expected (Apple App Attestation Root CA, valid 2020-03-18 → 2045-03-15):
   ```
   1C:B9:82:3B:A2:8B:A6:AD:2D:33:A0:06:94:1D:E2:AE:4F:51:3E:F1:D4:E8:31:B9:F7:E0:FA:7B:62:42:C9:32
   ```

   Reference set used to validate this expected value (last verified
   2026-05-05, all four matched the apple.com download bit-for-bit):

   | Repo | Commit | Lang |
   | --- | --- | --- |
   | [srinivas1729/appattest-checker-node](https://github.com/srinivas1729/appattest-checker-node) | `d958bc5256b62621089c23c70bab09382cb69aed` | TypeScript |
   | [uebelack/node-app-attest](https://github.com/uebelack/node-app-attest) | `f16c4bb71b737466872bc8b8a7dfd215364eaa83` | JavaScript |
   | [veehaitch/devicecheck-appattest](https://github.com/veehaitch/devicecheck-appattest) | `cb26211f63c1e2e7949deafe2efdf352daca27fa` | Kotlin |
   | [bas-d/appattest](https://github.com/bas-d/appattest) | `fe1ac6f8fcec9f4e711f62d4cdc0478acc3d3e69` | Go |

   Reproduce the cross-check (clones the four repos at the pinned
   commits, extracts each embedded PEM, computes SHA-256, prints
   any mismatch):
   ```bash
   set -e
   D=$(mktemp -d)
   git clone --depth 50 https://github.com/srinivas1729/appattest-checker-node.git "$D/a"
   git clone --depth 50 https://github.com/uebelack/node-app-attest.git "$D/b"
   git clone --depth 50 https://github.com/veehaitch/devicecheck-appattest.git "$D/c"
   git clone --depth 50 https://github.com/bas-d/appattest.git "$D/d"
   git -C "$D/a" checkout -q d958bc5256b62621089c23c70bab09382cb69aed
   git -C "$D/b" checkout -q f16c4bb71b737466872bc8b8a7dfd215364eaa83
   git -C "$D/c" checkout -q cb26211f63c1e2e7949deafe2efdf352daca27fa
   git -C "$D/d" checkout -q fe1ac6f8fcec9f4e711f62d4cdc0478acc3d3e69
   python3 - "$D" <<'PY'
   import re, sys, base64, hashlib, pathlib
   FILES = {
     "a/src/attestation.ts": "appattest-checker-node",
     "b/src/verifyAttestation.js": "node-app-attest",
     "c/src/main/kotlin/ch/veehait/devicecheck/appattest/attestation/AttestationValidator.kt": "devicecheck-appattest",
     "d/attestation/attestation.go": "bas-d/appattest",
   }
   EXPECT = "1cb9823ba28ba6ad2d33a006941de2ae4f513ef1d4e831b9f7e0fa7b6242c932"
   root = pathlib.Path(sys.argv[1])
   ok = True
   for rel, label in FILES.items():
     src = (root/rel).read_text()
     m = re.search(r"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", src, re.S)
     body = m.group(1).replace("\\n","").replace("\\r","")
     b64  = re.sub(r"[^A-Za-z0-9+/=]", "", body)
     der  = base64.b64decode(b64)
     fp   = hashlib.sha256(der).hexdigest()
     mark = "OK" if fp == EXPECT else "MISMATCH"
     if fp != EXPECT: ok = False
     print(f"{mark}  {label}: {fp}")
   sys.exit(0 if ok else 1)
   PY
   ```

   **If any line prints `MISMATCH`, stop and investigate** before
   continuing — a divergence means either Apple rotated the root
   (rare; would be announced), one of the libraries was tampered
   with at the pinned commit, or the apple.com download was
   tampered with. Do NOT paste an unverified value into line 61.

   When refreshing this step (e.g., adding new reference libraries
   or bumping commit hashes), update both the table above and the
   inline `git -C ... checkout` lines so they remain in sync.

3. **Extract the EC public key as an uncompressed point** (`04` || X(48) ||
   Y(48), 97 bytes / 194 hex chars). The trailing 97 bytes of a P-384 SPKI
   DER are exactly the uncompressed point inside the BIT STRING, so a blind
   `tail -c 97` slices it without needing DER-aware tooling:
   ```bash
   openssl x509 -in Apple_App_Attestation_Root_CA.pem -noout -pubkey \
     | openssl ec -pubin -outform DER 2>/dev/null \
     | tail -c 97 \
     | xxd -p \
     | tr -d '\n'
   ```
   `openssl pkey -pubin -outform DER` works as a drop-in for `openssl ec`
   on OpenSSL 3.x if `openssl ec` ever gets removed; it accepts the same
   PEM SPKI input. The output **must** be exactly 194 lowercase hex chars
   and **must** begin with `04` (the uncompressed-point marker). If it
   doesn't match both checks, the input was wrong — re-download the PEM
   and start over rather than pasting a malformed key.

4. **Paste the 194-char hex string** (no `0x` prefix, no whitespace, no
   newlines) into `middleware/app-attest.js`, replacing the empty literal:
   ```js
   const APPLE_ATTEST_ROOT_PUBKEY_HEX = '04...';   // 194 hex chars
   ```
   Commit the change to a branch and merge it. The value is a public key,
   not a secret — bundling it in source is the entire point of the design.

5. **Deploy:**
   ```bash
   wrangler deploy
   ```

6. **Verify the pin took** by hitting the worker:
   ```bash
   WORKER=https://drawevolve-backend.<your-subdomain>.workers.dev

   # /attest/challenge: should return 200 with a base64 challenge
   curl -s -o /dev/null -w "%{http_code}\n" -X POST "$WORKER/attest/challenge"
   # expect: 200

   # /attest/register with junk body: should return a 4xx structural error
   # (e.g. attest_bad_structure or attest_bad_fmt) — NOT 500
   # attest_root_not_pinned. A 500 here means the constant is still empty
   # or the worker didn't redeploy.
   curl -s -X POST -H 'content-type: application/json' \
     -d '{"keyId":"AAAA","attestation":"AAAA","challenge":"AAAA"}' \
     "$WORKER/attest/register"
   ```
   `wrangler tail` in another shell shows the exact error code each request
   produced — useful for confirming the failure mode is no longer
   `attest_root_not_pinned`.

Until step 4 lands and step 5 deploys, the Worker is intentionally unable
to register any new device. The empty placeholder in the source tree is a
fail-safe and **must not** be removed or worked around.

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
