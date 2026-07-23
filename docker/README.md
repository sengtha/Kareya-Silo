# 🐳 Kareya Silo — Self-Hosted Docker Distribution

Run a complete, sovereign Kareya Silo on **any VM** using the open-source
Supabase stack — no hosted Supabase account required. One `git clone`, one
script, one `docker compose up`.

This bundle packages:

- The full open-source **Supabase stack** (Postgres 17 + pgvector + Vault,
  Auth, REST, Realtime, Storage, Kong gateway, Edge Functions runtime, and the
  **Studio** admin dashboard).
- The **Silo database schema + RLS** (auto-applied on first boot).
- All **Silo edge functions** (`ai-chat`, `ai-embed`, `ai-generate`,
  `ai-ingest`, `authenticate-hub-user`, `connect-send`, `connect-inbound`,
  `create-payment`, `payment-webhook`, `notify`, `esign-public`,
  `esign-xades`).
- **Caddy** for automatic HTTPS (Let's Encrypt).
- A `bootstrap.sh` that generates every secret for you.

## Requirements

- A Linux VM with **Docker** + **Docker Compose v2** and **≥ 4 GB RAM**.
- **Ports 80 and 443** open to the internet.
- A **domain name** whose A record points at the VM (needed for a real TLS
  certificate). You can trial locally with `localhost` first.

## Install (5 steps)

```bash
git clone https://github.com/sengtha/Kareya-Silo.git
cd Kareya-Silo/docker

# 1. Generate all secrets + wire your domain into .env
./bootstrap.sh --domain silo.example.com --email you@example.com
#    (local trial:  ./bootstrap.sh --domain localhost)

# 2. (optional) open .env and add feature keys — see "Optional features" below
nano .env

# 3. Bring the stack up
docker compose up -d

# 4. Watch it come healthy (Ctrl-C to stop watching)
docker compose ps
docker compose logs -f db          # first boot applies the Silo schema + RLS

# 5. Point https://silo.example.com at this VM — Caddy fetches a cert on first hit.
```

Your Silo API is now at `https://silo.example.com`. The **Studio** admin UI is
reachable through the same domain (login: `supabase` / the dashboard password
printed by `bootstrap.sh`).

## Register your Silo with the Hub

When a Hub admin registers this workspace (Hub Admin Console → New workspace),
they need:

- **Silo Supabase URL:** `https://silo.example.com`
- **Anon Key:** the `ANON_KEY` value in your `.env`

The Silo verifies Hub-user logins itself via the `authenticate-hub-user`
function, which signs tokens with `SILO_JWT_SECRET` (bound to this stack's
`JWT_SECRET`).

## Optional features

All are off by default until you configure them, then `docker compose up -d`
(or `restart functions`) to apply:

| Feature | How to configure |
| :--- | :--- |
| **AI** (assistant, generation, RAG search) | Store the provider API key in Studio → the Kareya app's **AI settings** (kept in Vault; the `ai-*` functions read it via `ai_get_secret()`). No `.env` key needed. |
| **Hub push relay** (`notify`) | Set `HUB_URL` + `HUB_SILO_API_KEY` (+ `HUB_ANON_KEY`/`HUB_PUBLISHABLE_KEY`) in `.env`. |
| **Payments** (`create-payment` / `payment-webhook`) | Configure the payment provider in the Kareya app (**Settings → Payments**); credentials are held in the Silo, not `.env`. |

## How it fits together

```
Internet ──443──▶ Caddy (auto-TLS) ──▶ Kong gateway ─┬─▶ Studio (dashboard)
                                                      ├─▶ Auth (GoTrue)
                                                      ├─▶ REST (PostgREST)
                                                      ├─▶ Realtime (WebSockets)
                                                      ├─▶ Storage  ──▶ Postgres
                                                      └─▶ Edge Functions ──▶ Postgres
```

- The **Silo schema** (`kareya_silo_schema.sql`) and **RLS** (`RLS.sql`) are
  mounted into Postgres' init directory and applied once, on first boot, after
  Supabase's own baseline migrations create the `auth` schema.
- The **edge functions** are mounted straight from
  `../supabase/setup/functions` (single source of truth) behind a request
  router (`volumes/functions/main`).
- The **storage buckets** (`kb-sources`, `silo-media`) + their `storage.objects`
  RLS policies are applied by a one-shot `storage-init` container once the
  Storage service is ready (the `storage` schema is created at runtime, after
  Postgres init). The schema/RLS versions of those statements are guarded to
  no-op while `storage` is absent, so the same files stay valid on hosted
  Supabase.

## Common operations

```bash
docker compose logs -f <service>     # tail a service (auth, realtime, functions, …)
docker compose restart functions     # reload after editing a function or .env
docker compose down                  # stop (keeps data in named volumes)
docker compose down -v               # stop AND wipe all data (irreversible)
./bootstrap.sh --domain … --force    # rotate ALL secrets (regenerates .env)
```

## Upgrading

```bash
git pull
docker compose pull       # get newer pinned images
docker compose up -d
```

The Silo schema is applied only on a *fresh* database. To add new schema
features to an existing Silo, run the changed statements from
`../supabase/setup/schema/` in Studio's SQL editor (the schema is written to be
idempotent).

## Notes & limits

- **HTTPS is mandatory** for the PWA and the Hub relay. With
  `--domain localhost` you get a self-signed cert (browsers warn), fine for
  smoke-testing but not for real devices.
- Kong's raw ports are bound to `127.0.0.1` by default — only Caddy is public.
- This bundle vendors Supabase's official self-hosting compose (Apache-2.0)
  and pins its image versions; update them with `git pull`.
