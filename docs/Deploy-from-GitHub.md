# 🚀 Deploy a Silo from GitHub

Your Silo is a **sovereign environment** — you run it on infrastructure you
control, and Kareya never touches it. These paths all install the same
self-contained Docker stack (see [`docker/`](../docker/README.md)) straight
from this repository, on **your** server, with **your** credentials.

## What you need first

- A Linux VM you control (Ubuntu/Debian recommended), **≥ 4 GB RAM**.
- **Ports 80 and 443** open to the internet.
- A **domain name** whose DNS `A` record points at the VM (Caddy uses it to get
  an automatic HTTPS certificate — required for Web Push, the PWA, and the Hub
  relay).

---

## Option 1 — One command on your server (simplest)

SSH into your VM and run:

```bash
curl -fsSL https://raw.githubusercontent.com/sengtha/Kareya-Silo/main/install.sh \
  | sudo bash -s -- --domain silo.example.com --email you@example.com
```

That installs Docker, clones this repo to `/opt/kareya-silo`, generates all
secrets, and brings the stack up behind automatic HTTPS. Re-run the same
command any time to **update** in place.

Optional feature keys can be passed as environment variables and are written
into `.env` automatically:

```bash
curl -fsSL https://raw.githubusercontent.com/sengtha/Kareya-Silo/main/install.sh \
  | sudo OPENAI_API_KEY=... HUB_URL=https://hub.kareya.io HUB_SILO_API_KEY=... \
    bash -s -- --domain silo.example.com --email you@example.com
```

`HUB_URL` and `HUB_ANON_KEY` already default to the official Hub — set them only
for a self-hosted Hub. `HUB_SILO_API_KEY` is per-Silo and comes from the Hub's
Silo registry after you register (step 2 below); leave it blank at install time
and add it later.

---

## Option 2 — Deploy from your own GitHub fork (Actions)

Fully sovereign: it runs from **your fork**, with **your secrets**, to **your**
server. Kareya is not involved.

1. **Fork** this repository (keep the fork public so the installer is fetchable).
2. In your fork: **Settings → Secrets and variables → Actions** → add:
   - `SSH_HOST` — your server's IP/hostname
   - `SSH_USER` — an SSH user with `sudo` (or `root`)
   - `SSH_PRIVATE_KEY` — a private key authorized on that server
   - *(optional)* `OPENAI_API_KEY`, `HUB_URL`, `HUB_ANON_KEY`,
     `HUB_PUBLISHABLE_KEY`, `HUB_SILO_API_KEY`
3. **Actions → Deploy Silo → Run workflow**, enter your **domain** and **email**.

The workflow SSHes into your server and runs `install.sh` from your fork. Run
it again whenever you want to redeploy/update.

---

## Option 3 — Compose-native hosts (one-click-ish)

Platforms that deploy a `docker-compose` project directly from a Git repo. You
connect **your own** account and point it at this repo (or your fork):

- **Coolify** (self-hostable or their cloud) — add a *Docker Compose* resource
  from this repo; it builds, runs, and renews TLS. Great sovereign fit.
- **Elestio**, **Zeabur**, **Sealos** — import the repo as a compose project.

> Not supported: app-only PaaS such as Vercel / Netlify / DigitalOcean App
> Platform — the Silo is a full stateful stack (Postgres, realtime, storage),
> so it needs a VM or a compose-capable host.

---

## After it's up

1. Watch it start: `cd /opt/kareya-silo/docker && docker compose logs -f`
2. **Register the Silo on the Kareya Hub** — create a `user_silos` row (name +
   this Silo's URL + its anon key):
   - **Project URL:** `https://silo.example.com`
   - **Anon Key:** the `ANON_KEY` value in `/opt/kareya-silo/docker/.env`

   On your first login the Silo's `authenticate-hub-user` function redeems a
   single-use Hub ticket and auto-provisions your `employees` row from your Hub
   role (`admin → [Admin, Founder]`).
3. For push notifications, reveal the Silo's `HUB_SILO_API_KEY` in the Hub's
   Silo registry, add it (plus `HUB_URL`) to `docker/.env`, and re-run
   `docker compose up -d`. Left blank, `notify` reports
   `relay_not_configured` instead of failing.

## Updating later

```bash
# Option 1/2 host: just re-run the installer
curl -fsSL https://raw.githubusercontent.com/sengtha/Kareya-Silo/main/install.sh \
  | sudo bash -s -- --domain silo.example.com --email you@example.com

# or manually
cd /opt/kareya-silo && git pull && cd docker && docker compose pull && docker compose up -d
```

The Silo schema is applied automatically on first boot; later schema changes
ship as idempotent SQL in `supabase/setup/schema/` — run any new ones in the
Studio SQL editor.
