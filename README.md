# Kareya-Silo

The **sovereign ERP data node** for [Kareya](https://github.com/sengtha/Kareya).
Deploy your own Silo to achieve true data ownership: **one business == one Silo**.
The Kareya Hub holds only identity and public/social data — all ERP data (HR,
attendance, projects, accounting, sales, support, inventory) lives here, in a
database you own and control.

## How it fits together

```
  Kareya (Hub)                         Kareya-Silo (this repo)
  identity + registry                  ERP data warehouse (one per business)
  ─────────────────                    ───────────────────
  user_silos    ──── url + anon_key ──► points the app at this Silo
  silo_members  ──── role ────────────► seeds the employee roster
  silo_tickets  ◄─── redeem_silo_ticket ─── authenticate-hub-user (edge fn)
                                        mints this Silo's own 15-min JWT
```

Users log into the Hub (Google OAuth). To open a business, the app creates a
single-use Hub *ticket*, the Silo's `authenticate-hub-user` function redeems it
against the Hub, verifies membership, and mints a short-lived JWT signed with
**this Silo's own secret**. From then on the app talks to this Silo directly for
all ERP reads and writes. See `Kareya/docs/Hub-Silo-Trust.md` for the full flow.

Because one Silo is one business, the schema has **no `company_id`** — the whole
database *is* the business, and Row Level Security is gated on the local
`employees` roster. `auth.uid()` inside the Silo resolves to the **Hub user id**
carried in the minted JWT (these users are not in the Silo's own `auth.users`,
so ERP rows store `user_id` as plain columns, not FKs).

## Contents

```
supabase/setup/
  schema/
    kareya_silo_schema.sql   ERP tables + RLS helper functions + indexes
    RLS.sql                  Row Level Security policies
    verticals/               one self-contained file per newer industry module
                             (tables + indexes + RLS), applied after the above
  demo/
    demo-seed.sql            master data for every module — safe to re-run
    demo-reset.sql           clears business data, keeps your access + modules
  functions/
    authenticate-hub-user/   redeems a Hub ticket → mints the Silo JWT
    ai-chat/                 assistant: provider-agnostic chat + tools + RAG
    ai-generate/             one-shot AI helpers (text, doc OCR/templates, etc.)
    ai-ingest/               chunk + embed knowledge-base sources (incl. PDF)
    ai-embed/                Gemini batch embeddings
    notify/                  resolves event recipients → relays push to the Hub
```

Push notifications are delivered by the **Hub** (browsers hold one subscription,
bound to the Hub's VAPID key). The Silo's `notify` function resolves who should be
alerted (e.g. a document's approvers) under the caller's JWT and relays to the
Hub's `hub-push-relay`. See the Hub repo's `docs/Push-Notifications.md`.

All AI keys live in **Supabase Vault**, configured per-silo by the owner in
Settings → AI Assistant — there is no shared `GEMINI_API_KEY` env secret. The
provider (Claude / OpenAI / Gemini) is the owner's choice; embeddings always use
Gemini. Every AI query runs under the caller's JWT, so RLS binds.

## Setup

### 1. Create a Supabase project
This is your business's private database. Note its **Project URL** and
**anon (publishable) key** — you will register these on the Hub in the Silo
Manager (`user_silos.url` / `user_silos.anon_key`).

### 2. Apply the schema
Run, in order, against your Silo project (SQL editor or `psql`):
1. `supabase/setup/schema/kareya_silo_schema.sql`
2. `supabase/setup/schema/RLS.sql`
3. Every file in `supabase/setup/schema/verticals/` — in any order.

Step 3 is required, not optional: those ten files carry the tables for the
newest industry modules (property developer, petrol station, rice mill,
electronics, manpower, KTV, freight, garment, legal/notary, project billing).
Each is self-contained — it creates its own tables, indexes and RLS policies —
so they can be applied in any order, and re-applied safely.

### 2b. (Optional) Load demo data
`supabase/setup/demo/demo-seed.sql` fills the workspace with staff, clients,
vendors, stock and a starter catalog for every vertical, so no screen opens
empty. Edit the one marked email line first. `demo-reset.sql` clears it again.
See `docs/Testing-Kareya.md` in the Hub repo for the test route these support.

### 3. Deploy the edge functions
```
supabase functions deploy authenticate-hub-user --no-verify-jwt
supabase functions deploy ai-chat
supabase functions deploy ai-generate
supabase functions deploy ai-ingest
supabase functions deploy ai-embed
supabase functions deploy notify
supabase functions deploy esign-public --no-verify-jwt
supabase functions deploy esign-xades
supabase functions deploy connect-inbound --no-verify-jwt
supabase functions deploy connect-send
supabase functions deploy create-payment
supabase functions deploy payment-webhook --no-verify-jwt
```
`payment-webhook` must be public (`--no-verify-jwt`): the bank / PSP calls it
with no Silo session — the shared `x-webhook-secret` (production: the PSP's HMAC
signature) is the credential. It is the ONLY path that marks a fee paid, so
payment state can never be forged from a client. `create-payment` verifies the
caller's Silo JWT (only employees request a fee).
`authenticate-hub-user` must be public (`--no-verify-jwt`): it is called with a
raw ticket, before any Silo session exists. `esign-public` must also be public:
external customers open it from a tokenized signing link with no Silo session —
the unguessable `public_token` is the credential it validates itself.
`connect-inbound` is likewise public: a **partner Silo** posts to it with no
Silo session of ours — the shared `x-connect-key` is the credential it
validates itself (identity seam; swap for CamDigiKey later). The AI functions,
`notify`, `esign-xades`, and `connect-send` verify the caller's Silo JWT, so
deploy them with JWT verification on (the default).

### 4. Configure edge-function secrets

| Variable | Required | Description |
| :--- | :--- | :--- |
| `SILO_JWT_SECRET` | ✅ | Secret used to **sign this Silo's JWTs**. Must match this project's Supabase JWT secret (Project Settings → API → JWT Secret) so PostgREST/Realtime accept the minted tokens. |
| `SUPABASE_URL` | ✅ | This Silo's API URL (usually injected automatically). |
| `SUPABASE_SERVICE_ROLE_KEY` | ✅ | Admin key, used only to provision the employee roster on first entry. Never exposed to clients. |
| `HUB_URL` | ⛳ | The Kareya Hub Supabase URL. Defaults to the official Hub if unset. |
| `HUB_ANON_KEY` | ✅ | The Kareya Hub's anon/publishable key, so this Silo can call `redeem_silo_ticket` on the Hub. |
| `SUPABASE_ANON_KEY` | ✅ | This Silo's anon key (usually injected automatically). The AI functions use it to build a JWT-scoped client so RLS applies. |

```
supabase secrets set SILO_JWT_SECRET=... HUB_ANON_KEY=...
```

> **AI provider keys are not env secrets.** They are stored encrypted in Supabase
> Vault and set by the silo owner in the app (Settings → AI Assistant), so each
> business supplies its own Claude / OpenAI / Gemini key.

### 5. Register the Silo on the Hub
In the Kareya Hub, create a `user_silos` row (name + this project's URL +
anon key) and add yourself to `silo_members` as `admin`. On your first entry the
`authenticate-hub-user` function will auto-provision your `employees` row from
your Hub role (`admin → [Admin, Founder]`).

## Data that stays on the Hub (not here)

Per the sovereign split, the Hub keeps identity, the silo registry, and the
**public** surfaces: the careers portal (`job_postings`, `candidates`) and public
announcements. This Silo holds only the business's private ERP data.
