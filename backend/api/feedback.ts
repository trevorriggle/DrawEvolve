// Vercel Edge Function - Deploy this to Vercel
// Place at: api/feedback.ts

import { NextRequest, NextResponse } from 'next/server';

export const config = {
  runtime: 'edge',
};

export default async function handler(req: NextRequest) {
  if (req.method !== 'POST') {
    return NextResponse.json({ error: 'Method not allowed' }, { status: 405 });
  }

  try {
    const { image, context } = await req.json();

    // Your API key is stored in Vercel environment variables
    const response = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${process.env.OPENAI_API_KEY}`,
      },
      body: JSON.stringify({
        model: 'gpt-4o',
        messages: [
          {
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

Provide detailed, constructive feedback (max 800 tokens). Be specific, encouraging, and include one small friendly joke.`,
              },
              {
                type: 'image_url',
                image_url: {
                  url: `data:image/jpeg;base64,${image}`,
                },
              },
            ],
          },
        ],
        max_tokens: 800,
      }),
    });

    const data = await response.json();

    if (!response.ok) {
      throw new Error(data.error?.message || 'OpenAI API error');
    }

    return NextResponse.json({
      feedback: data.choices[0]?.message?.content || 'No feedback generated',
    });
  } catch (error: any) {
    console.error('Error:', error);
    return NextResponse.json(
      { error: error.message || 'Internal server error' },
      { status: 500 }
    );
  }
}
