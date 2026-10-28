// Supabase Edge Function: ai-proxy
//
// Authenticated proxy from the app to a self-hosted Ollama, so the AI coach,
// weekly plan, habit-difficulty and nutrition features work for every signed-in
// user with no local Ollama. The app calls this via supabase.functions.invoke
// ('ai-proxy'); the hosted Ollama URL/token never leave the server.
//
// Set these function secrets (see docs/AI_BACKEND_SETUP.md):
//   OLLAMA_URL    required   e.g. https://ollama.yourdomain.com
//   OLLAMA_TOKEN  optional   bearer token your Ollama reverse-proxy requires
//   OLLAMA_MODEL  optional   default model when the request omits one
//
// SUPABASE_URL and SUPABASE_ANON_KEY are injected automatically.

import { createClient } from 'jsr:@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(obj: unknown, status = 200): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  try {
    // Require a signed-in user — verify the caller's JWT.
    const authHeader = req.headers.get('Authorization') ?? '';
    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: { user } } = await supabase.auth.getUser();
    if (!user) return json({ error: 'unauthorized' }, 401);

    const ollamaUrl = Deno.env.get('OLLAMA_URL');
    if (!ollamaUrl) return json({ error: 'OLLAMA_URL not configured' }, 500);

    const body = await req.json().catch(() => ({}));
    const system = String(body.system ?? '');
    const prompt = String(body.prompt ?? '');
    if (!prompt.trim()) return json({ content: '' });
    const model =
      String(body.model || Deno.env.get('OLLAMA_MODEL') || 'llama3.2');
    const wantJson = body.json === true;
    const temperature =
      typeof body.temperature === 'number' ? body.temperature : 0.6;

    const token = Deno.env.get('OLLAMA_TOKEN');
    const res = await fetch(`${ollamaUrl.replace(/\/+$/, '')}/api/chat`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: JSON.stringify({
        model,
        stream: false,
        ...(wantJson ? { format: 'json' } : {}),
        options: { temperature },
        messages: [
          { role: 'system', content: system },
          { role: 'user', content: prompt },
        ],
      }),
      signal: AbortSignal.timeout(30000),
    });
    if (!res.ok) return json({ error: `ollama ${res.status}` }, 502);
    const data = await res.json();
    const content = data?.message?.content ?? '';
    return json({ content });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
