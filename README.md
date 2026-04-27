# ForgeTemplate

A full-stack deployment template for **Strapi CMS** (VPS + Docker) and an **Astro** frontend (Cloudflare Workers or same VPS). One script provisions everything from scratch — Ansible, Docker Compose, nginx, SSL, and optionally GitHub Actions CI/CD.

---

## What's included

| Layer | Technology |
|---|---|
| CMS / API | Strapi v5, PostgreSQL, Docker Compose |
| Frontend | Astro (SSR) — deploy to Cloudflare Workers or a Node.js container on the VPS |
| Reverse proxy | nginx + Let's Encrypt (certbot) |
| Provisioning | Ansible |
| CI/CD | GitHub Actions |

---

## Prerequisites

- Ansible (`pip install ansible` or `brew install ansible`)
- Node.js ≥ 22
- OpenSSL
- A VPS with Docker + Docker Compose installed, reachable via SSH
- A domain with DNS pointing to your VPS

Optional (enables automatic GitHub secret setup):
- GitHub CLI: `brew install gh` then `gh auth login`

---

## Quick start

```bash
git clone https://github.com/CodyJG10/ForgeTemplate.git
cd ForgeTemplate
bash infrastructure/deploy.sh
```

The script walks you through everything interactively — no flags required on first run.

---

## Deploy script commands

All commands are run from the **repo root**:

```bash
bash infrastructure/deploy.sh [command]
```

### (no flag) — Full deployment

Runs all steps in sequence:

1. **Backend config** — collects Strapi/DB/domain settings, writes `infrastructure/ansible/vars.yml`
2. **Frontend config** — asks which hosting method you want (see below), collects the relevant settings
3. **VPS deploy** — Ansible provisions the VPS: clones the repo, writes `.env` files, starts Docker containers, configures nginx, and obtains SSL certificates
4. **Cloudflare deploy** — if you chose Cloudflare Workers, builds and deploys the Astro app
5. **GitHub Actions CI/CD** — uses `gh` to set the required secrets in your repo automatically (falls back to printing instructions if `gh` is not available)

On re-runs, steps 1 and 2 are skipped automatically if config files already exist. Pass `--reconfigure` to redo them.

---

### `--reconfigure` — Re-run configuration

```bash
bash infrastructure/deploy.sh --reconfigure
```

Deletes the existing `vars.yml` (and `vars.sh` for Cloudflare) and re-prompts for all settings before deploying. Use this when:
- You're deploying to a new domain or VPS
- You want to change the frontend hosting method
- Any credentials have changed

---

### `--setup-cicd` — Configure GitHub Actions secrets only

```bash
bash infrastructure/deploy.sh --setup-cicd
```

Skips deployment entirely and jumps straight to setting GitHub Actions secrets. Use this after your first deploy if you skipped the CI/CD step or need to update the credentials.

Requires `vars.yml` to exist (i.e. you've already run a full deploy).

Secrets set:

| Secret | Value |
|---|---|
| `VPS_HOST` | Your VPS IP address |
| `VPS_USER` | SSH username |
| `VPS_SITE_NAME` | Site name from `vars.yml` |
| `VPS_SSH_KEY` | Private key content (if you used password auth, a fresh ed25519 deploy key is generated and installed on the VPS) |

---

### `--update-strapi-token` — Push a Strapi API token to the frontend

```bash
bash infrastructure/deploy.sh --update-strapi-token
```

After your first deploy, Strapi has no admin account and no API tokens yet. Use this command once you've created your admin and generated a token:

1. Visit `https://your-strapi-domain.com/admin` and create your admin account
2. Go to **Settings → API Tokens → Create new token**
3. Copy the token and run the command above

What it does:
- Patches `STRAPI_API_TOKEN` in `Frontend/.env` on the VPS **in place** (no rebuild)
- Restarts the frontend container to pick up the new value (`docker compose --profile full up --force-recreate -d frontend`)
- Optionally updates `STRAPI_API_TOKEN` in your GitHub Actions secrets so future CI/CD deploys carry the token automatically

---

## Frontend hosting options

The deploy script asks which method you want during step 2:

### Option 1 — Cloudflare Workers

The Astro app is built and deployed as a Cloudflare Worker. Requires:
- A Cloudflare account and API token
- A Cloudflare Account ID

GitHub Actions workflow: `.github/workflows/deploy-frontend.yml`
Triggers on: push to `main` affecting `Frontend/**`

### Option 2 — VPS (same server as Strapi)

The Astro app runs as a Node.js container alongside Strapi. Requires:
- A separate domain or subdomain pointing to the same VPS (e.g. `example.com` for the frontend, `api.example.com` for Strapi)

GitHub Actions workflows:
- `.github/workflows/deploy-backend-vps.yml` — triggers on `Backend/**` changes
- `.github/workflows/deploy-frontend-vps.yml` — triggers on `Frontend/**` changes

Both workflows SSH into the VPS, `git pull`, and rebuild only the affected container.

### Option 3 — Skip (backend only)

Deploys Strapi with no frontend. You can add the frontend later with `--reconfigure`.

---

## GitHub Actions CI/CD

The GitHub Actions workflows require these secrets in your repo
(**Settings → Secrets and variables → Actions**):

| Secret | Used by |
|---|---|
| `VPS_HOST` | Both VPS workflows |
| `VPS_USER` | Both VPS workflows |
| `VPS_SITE_NAME` | Both VPS workflows |
| `VPS_SSH_KEY` | Both VPS workflows |
| `CLOUDFLARE_API_TOKEN` | Cloudflare workflow |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare workflow |
| `STRAPI_API_TOKEN` | All frontend workflows |

The deploy script sets the VPS secrets automatically via `gh`. The Cloudflare secrets are shown at the end of the Cloudflare setup step. `STRAPI_API_TOKEN` is set when you run `--update-strapi-token`.

---

## Project structure

```
ForgeTemplate/
├── Backend/                        # Strapi CMS
│   ├── docker-compose.yml          # Strapi + PostgreSQL + Adminer + (optional) Astro
│   └── Dockerfile
├── Frontend/                       # Astro app
│   ├── Dockerfile                  # Used for VPS deployment
│   └── astro.config.mjs            # Switches adapter via ASTRO_ADAPTER env var
├── infrastructure/
│   ├── deploy.sh                   # Main deploy script (entry point)
│   ├── ansible/
│   │   ├── deploy.yml              # Ansible playbook
│   │   ├── teardown.yml            # Destroy a site
│   │   ├── generate-vars.sh        # Backend config wizard
│   │   ├── setup-frontend-vps.sh   # VPS frontend config wizard
│   │   ├── vars.example.yml        # Variable reference (copy to vars.yml)
│   │   └── templates/
│   │       ├── strapi.env.j2       # Backend .env template
│   │       ├── frontend.env.j2     # Frontend .env template
│   │       ├── nginx.conf.j2       # nginx config for Strapi
│   │       └── nginx-frontend.conf.j2
│   └── cloudflare/
│       ├── setup-cloudflare.sh     # Cloudflare config wizard
│       └── deploy.sh               # Cloudflare build + deploy
└── .github/workflows/
    ├── deploy-frontend.yml         # Cloudflare Workers CI/CD
    ├── deploy-backend-vps.yml      # VPS backend CI/CD
    └── deploy-frontend-vps.yml     # VPS frontend CI/CD
```

---

## Tearing down a site

```bash
ansible-playbook infrastructure/ansible/teardown.yml \
  -i infrastructure/ansible/inventory.example \
  -e "ansible_host=<VPS_IP> ansible_user=root ansible_ssh_private_key_file=~/.ssh/id_rsa" \
  -e "site_name=<your_site_name>"
```

**Destructive** — stops containers, deletes the Docker volume (database), and removes the site directory. Back up your data first.

---

## Secrets and sensitive files

These files are gitignored and must never be committed:

| File | Contents |
|---|---|
| `infrastructure/ansible/vars.yml` | DB passwords, Strapi secrets |
| `infrastructure/ansible/inventory` | VPS IP and credentials |
| `infrastructure/cloudflare/vars.sh` | Cloudflare API token |
| `Frontend/wrangler.toml` | Generated per deployment |
| `.env` / `.env.*` | Any local environment files |
