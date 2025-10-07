# Backend Setup - Secure API Key Management

## Problem
iOS apps bundle their files, so anyone can extract Config.plist and steal your OpenAI API key.

## Solution
Use a Vercel Edge Function as a secure proxy. Your API key stays in Vercel's environment variables.

## Deploy Backend (5 minutes)

### 1. Deploy to Vercel

```bash
cd /workspaces/DrawEvolve/backend
vercel
```

Follow the prompts:
- Set up and deploy? **Y**
- Scope? **Your account**
- Link to existing project? **N**
- Project name? **drawevolve-backend**
- Directory? **./backend**
- Override settings? **N**

### 2. Add API Key to Vercel

Go to: https://vercel.com/YOUR-USERNAME/drawevolve-backend/settings/environment-variables

Add:
- **Key**: `OPENAI_API_KEY`
- **Value**: `sk-proj-your-actual-key-here`
- **Environments**: Production, Preview, Development

Click **Save**.

### 3. Redeploy

```bash
vercel --prod
```

Your API is now live at: `https://drawevolve-backend.vercel.app/api/feedback`

### 4. Update iOS App

In `/workspaces/DrawEvolve/DrawEvolve/DrawEvolve/Services/OpenAIManager.swift`:

```swift
private let backendURL = "https://drawevolve-backend.vercel.app/api/feedback"
```

## Local Testing

```bash
cd backend
npm install
echo "OPENAI_API_KEY=sk-proj-your-key" > .env.local
vercel dev
```

Then in iOS app:
```swift
private let backendURL = "http://localhost:3000/api/feedback"
```

## Security Checklist

✅ API key is in Vercel environment variables (never in code)
✅ iOS app ONLY talks to YOUR backend
✅ Backend validates requests and calls OpenAI
✅ No API key ever shipped with the app
⚠️ Add rate limiting for production (see Vercel Edge Middleware)
⚠️ Add authentication when you add user accounts

## How It Works

```
iOS App → YOUR Backend (Vercel) → OpenAI API
         ^                         ^
         | No API key              | Has API key
         | Public endpoint         | Protected by Vercel
```

## Cost

- Vercel: **FREE** (Hobby plan)
- OpenAI: **Pay per request** (same as before)

## Troubleshooting

**"Cannot connect to backend"**
- Check URL in OpenAIManager.swift
- Verify deployment with: `curl https://your-backend.vercel.app/api/feedback -X POST -d '{"image":"test","context":{}}'`

**"OpenAI API error"**
- Check environment variable is set in Vercel dashboard
- Redeploy after adding the variable

**"Missing API key"**
- The old Config.plist error is gone now!
- If you still see it, you're running old code
