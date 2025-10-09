export default {
  async fetch(request, env) {
    // Handle CORS preflight
    if (request.method === 'OPTIONS') {
      return new Response(null, {
        headers: {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Methods': 'POST, OPTIONS',
          'Access-Control-Allow-Headers': 'Content-Type',
        },
      });
    }

    if (request.method !== 'POST') {
      return new Response(JSON.stringify({ error: 'Method not allowed' }), {
        status: 405,
        headers: {
          'Content-Type': 'application/json',
          'Access-Control-Allow-Origin': '*',
        },
      });
    }

    try {
      // Parse request body
      const { image, context } = await request.json();

      // Call OpenAI API
      const response = await fetch('https://api.openai.com/v1/chat/completions', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${env.OPENAI_API_KEY}`,
        },
        body: JSON.stringify({
          model: 'gpt-4o',
          messages: [{
            role: 'user',
            content: [
              {
                type: 'text',
                text: `You are an encouraging art teacher. Analyze this drawing and provide feedback.

Context from the artist:
- Subject: ${context.subject}
- Style: ${context.style}
- Artists: ${context.artists}
- Techniques: ${context.techniques}
- Focus areas: ${context.focus}
- Additional context: ${context.additionalContext}

Provide detailed, constructive feedback (max 800 tokens). Be specific, encouraging, and include one small friendly joke.`
              },
              {
                type: 'image_url',
                image_url: { url: `data:image/jpeg;base64,${image}` }
              }
            ]
          }],
          max_tokens: 800,
        }),
      });

      const data = await response.json();

      return new Response(JSON.stringify({
        feedback: data.choices[0]?.message?.content || 'No feedback generated',
      }), {
        headers: {
          'Content-Type': 'application/json',
          'Access-Control-Allow-Origin': '*',
        },
      });
    } catch (error) {
      return new Response(JSON.stringify({
        error: 'Internal server error',
        details: error.message
      }), {
        status: 500,
        headers: {
          'Content-Type': 'application/json',
          'Access-Control-Allow-Origin': '*',
        },
      });
    }
  },
};
