# Deploy DrawEvolve Backend to Cloudflare Workers

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
