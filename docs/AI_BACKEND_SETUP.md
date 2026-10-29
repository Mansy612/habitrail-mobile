# AI backend — always-on Ollama for every user

**Goal:** the AI coach, weekly plan, habit-difficulty and nutrition features
work for every signed-in user with zero setup on their device.

## How it works

```
app (signed in) ──▶ Supabase Edge Function  ai-proxy ──▶ your hosted Ollama ──▶ back
```

- Users need **nothing** installed — the app calls the Edge Function
  automatically when signed in (`backend.dart` → `wireRemoteAi()`).
- Your **dev build** still falls back to local Ollama (`localhost:11434`), and
  **everything** falls back to the offline keyword heuristic / templated lines
  if the server is unreachable — so the app never breaks.
- The Ollama URL + token live as Edge Function **secrets**, never in the app.

You provide the AI host — either **Ollama Cloud** (just an API key, no server:
easiest, below) or **your own always-on Ollama box** (the self-host steps after
it). Both are copy-paste.

## Easiest: Ollama Cloud (no server to run)

Ollama hosts the models; you only need an API key. No VPS, domain, or systemd.

1. Sign up at <https://ollama.com> and create a key at **Settings → API Keys**
   (`ollama.com/settings/keys`). The free tier has usage limits (session/weekly);
   Pro is ~$20/mo for heavier use.
2. Deploy the function and point it at Ollama Cloud, picking a hosted model from
   ollama.com (e.g. `gpt-oss:20b`):

   ```bash
   supabase functions deploy ai-proxy
   supabase secrets set OLLAMA_URL=https://ollama.com OLLAMA_TOKEN=YOUR_OLLAMA_API_KEY OLLAMA_MODEL=gpt-oss:20b
   ```

That's it. The same `ai-proxy` function calls `https://ollama.com/api/chat` with
your key — kept server-side, never shipped in the app — so AI works for every
signed-in user 24/7. Keep the key in the function's secrets, **not** in the app,
so it can't be extracted and abused. The self-hosted steps below are only if
you'd rather run Ollama on your own machine.

---

## 1. Run Ollama 24/7 on a server

A Linux VPS / cloud box. A small model such as `llama3.2:3b` is fast and cheap;
more RAM (and ideally a GPU) lets you run bigger models and more concurrency.

```bash
curl -fsSL https://ollama.com/install.sh | sh
ollama pull llama3.2:3b
```

The installer registers a `systemd` service that starts on boot and restarts on
crash, so it runs 24/7:

```bash
sudo systemctl enable --now ollama
systemctl status ollama          # should be "active (running)"
```

By default Ollama listens on `127.0.0.1:11434` — **keep it local** and expose it
only through the authenticated reverse proxy below.

## 2. Put it behind HTTPS + a token (never expose port 11434 directly)

Example with [Caddy](https://caddyserver.com) (automatic HTTPS). Replace the
domain and generate a long random token (`openssl rand -hex 32`):

```
ollama.yourdomain.com {
    @authed header Authorization "Bearer YOUR_LONG_RANDOM_TOKEN"
    handle @authed {
        reverse_proxy 127.0.0.1:11434
    }
    respond "unauthorized" 401
}
```

(nginx + certbot works too — the point is TLS **and** a bearer token so only
your Edge Function can reach Ollama.)

## 3. Deploy the Edge Function + set secrets

From the project root (install the Supabase CLI, then
`supabase link --project-ref <your-ref>`):

```bash
supabase functions deploy ai-proxy
supabase secrets set \
  OLLAMA_URL=https://ollama.yourdomain.com \
  OLLAMA_TOKEN=YOUR_LONG_RANDOM_TOKEN \
  OLLAMA_MODEL=llama3.2:3b
```

`SUPABASE_URL` / `SUPABASE_ANON_KEY` are injected automatically. `OLLAMA_TOKEN`
is optional (omit it if your proxy doesn't require one); `OLLAMA_MODEL` is the
default model when a request doesn't name one.

## 4. Nothing to change in the app

Signed-in users now get AI through the function automatically. Verify from a
logged-in build: add a habit (difficulty rating), log a meal (nutrition), open
the coach card and generate a Weekly Plan. Watch the server with:

```bash
supabase functions logs ai-proxy
```

## Notes & scaling

- **Scale:** one CPU box is fine for testing and light traffic but is slow and
  won't handle many concurrent users. For scale use a GPU box, run several
  Ollama replicas behind a load balancer, or point the function's `fetch` at a
  managed LLM instead — the Edge Function is the only thing that changes.
- **Cost control:** the function already requires a signed-in user. A good next
  step is to enforce the weekly coach quota server-side (keyed by user id) so
  the allowance can't be bypassed and your compute is protected.
- **Model:** keep `OLLAMA_MODEL` matched to what you `ollama pull`ed.
