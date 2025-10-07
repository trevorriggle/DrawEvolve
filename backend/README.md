# DrawEvolve Backend

Simple Vercel Edge Function to proxy OpenAI API calls and protect your API key.

## Deploy to Vercel

1. **Install Vercel CLI:**
   ```bash
   npm i -g vercel
   ```

2. **Deploy:**
   ```bash
   cd backend
   vercel
   ```

3. **Add Environment Variable:**
   - Go to your Vercel project settings
   - Add `OPENAI_API_KEY` = `sk-proj-your-key`

4. **Your endpoint will be:**
   ```
   https://your-project.vercel.app/api/feedback
   ```

## Local Testing

```bash
# Install dependencies
npm install

# Create .env.local
echo "OPENAI_API_KEY=sk-proj-your-key" > .env.local

# Test with Vercel CLI
vercel dev
```

## Usage from iOS

```swift
let url = URL(string: "https://your-project.vercel.app/api/feedback")!
var request = URLRequest(url: url)
request.httpMethod = "POST"
request.setValue("application/json", forHTTPHeaderField: "Content-Type")

let payload = [
    "image": base64Image,
    "context": [
        "subject": "landscape",
        "style": "impressionist",
        // ... other fields
    ]
]

let data = try JSONSerialization.data(withJSONObject: payload)
request.httpBody = data

let (responseData, _) = try await URLSession.shared.data(for: request)
let result = try JSONDecoder().decode(FeedbackResponse.self, from: responseData)
```

## Security

✅ API key stored in Vercel environment variables
✅ Never shipped with the app
✅ Only your backend can access OpenAI
⚠️ Add rate limiting in production
⚠️ Add authentication for paid features
