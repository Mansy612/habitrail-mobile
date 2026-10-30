// Supabase Edge Function: delete-account
//
// Fully deletes the signed-in user's account (required by App Store Guideline
// 5.1.1(v)). The app calls this via supabase.functions.invoke('delete-account').
// It verifies the caller's JWT, then uses the service-role key to delete the
// auth user. Every table that references auth.users(id) ON DELETE CASCADE —
// profiles, friendships, party_members, guild_members, party/guild/global
// messages, user_backups, and parties the user owns — is removed automatically;
// guilds the user owns keep existing with owner_id set to null.
//
// SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are injected
// automatically by Supabase — no extra secrets to set. Deploy with:
//   npx supabase functions deploy delete-account --project-ref <ref>
// The service-role key never leaves the server; never ship it in the app.

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
    // Identify the caller from their JWT (anon client scoped to their token).
    const authHeader = req.headers.get('Authorization') ?? '';
    const caller = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: { user } } = await caller.auth.getUser();
    if (!user) return json({ error: 'unauthorized' }, 401);

    // Delete the auth user with the service-role key; data rows cascade.
    const admin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );
    const { error } = await admin.auth.admin.deleteUser(user.id);
    if (error) return json({ error: error.message }, 500);

    return json({ ok: true });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
