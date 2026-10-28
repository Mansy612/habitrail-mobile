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

The only thing you must provide is **one always-on server running Ollama**
(a box Claude Code can't provision for you). Steps below are copy-paste.

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
