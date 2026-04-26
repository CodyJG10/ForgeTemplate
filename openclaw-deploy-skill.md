# Skill: Deploy ForgeTemplate

## Overview
ForgeTemplate is a full-stack deployment template that provisions a Strapi CMS backend on a VPS (via Ansible + Docker) and an Astro frontend on Cloudflare Workers. Your job is to run the complete deployment from scratch on the user's machine.

## Step 0 — Collect all information upfront
Before running anything, ask the user for ALL of the following in a single conversational message. Tell them which ones are optional or have defaults.

**Backend (Strapi on VPS):**
- Site name — a short lowercase identifier for this project (e.g. "my-client-site"). Used as the directory name and Docker container prefix on the VPS. Letters, numbers, and underscores only.
- GitHub repo URL — the URL of the repo being deployed to the VPS (e.g. https://github.com/org/repo.git)
- Branch — which branch to deploy (default: main)
- Backend subdirectory — the folder inside the repo containing docker-compose.yml (default: Backend)
- Domain name — the domain Strapi will be served on (e.g. api.example.com). Must have an A record pointing to the VPS IP before deploy.
- SSL email — email address for Let's Encrypt certificate notifications
- Database name (default: strapi)
- Database username (default: strapi)
- Database password — any strong password, will be stored securely

**VPS connection:**
- VPS IP address
- VPS username (default: root)
- Authentication method: SSH key (ask for path, default ~/.ssh/id_rsa) or password

**Frontend (Astro on Cloudflare Workers):**
- Cloudflare Worker name — lowercase, hyphens allowed (e.g. my-client-site). This becomes the subdomain on workers.dev.
- GitHub repo URL for the frontend (can be same repo)
- Deploy branch (default: main)
- Cloudflare Account ID — found in the Cloudflare dashboard right sidebar
- Cloudflare API Token — from My Profile → API Tokens (needs Workers Scripts:Edit, Workers Routes:Edit, Account Settings:Read)
- Strapi API URL — the full URL where Strapi will be reachable (e.g. https://api.example.com)
- Strapi API Token — a Strapi API token (can be created after first login to Strapi admin)
- Custom domain for the Worker — optional, leave blank to use workers.dev subdomain

**Strapi secrets:** Tell the user these will all be auto-generated and they don't need to provide them unless they want to use specific values.

Once you have all required answers, confirm back to the user with a summary and ask them to confirm before proceeding.

## Step 1 — Install dependencies
Run these commands to install required tools. Skip any that are already installed (check with `command -v`).

```bash
# Check and install Ansible
command -v ansible-playbook || pip3 install ansible

# Check and install sshpass (needed for password-based SSH auth)
command -v sshpass || brew install sshpass   # macOS
# On Linux: sudo apt install sshpass

# Check Node.js (must be >= 20)
node --version

# Check npm
npm --version

# Check openssl
openssl version
```

## Step 2 — Clone ForgeTemplate
```bash
git clone https://github.com/CodyJG10/ForgeTemplate.git
cd ForgeTemplate
```

## Step 3 — Run the deploy script
Run:
```bash
bash infrastructure/deploy.sh
```

The script will prompt you interactively. Answer each prompt using the information collected in Step 0. Here is every prompt you will encounter and how to answer it:

### generate-vars.sh prompts (Step 1/4):
- `vars.yml already exists. Overwrite? [y/N]` → type `y` if re-deploying, otherwise this won't appear
- `site_name (used as directory name):` → enter the site name (lowercase)
- `repo_url:` → enter the GitHub repo URL
- `branch [main]:` → press Enter for default or enter branch name
- `backend_subdir (subdirectory containing docker-compose.yml) [Backend]:` → press Enter for default
- `domain_name (e.g. api.example.com):` → enter the domain name
- `ssl_email (used for Let's Encrypt notifications):` → enter the SSL email
- `db_name [strapi]:` → press Enter for default or enter custom name
- `db_username [strapi]:` → press Enter for default or enter custom username
- `db_password:` → enter the database password (input is hidden)
- All 6 Strapi secret prompts (app_keys, api_token_salt, admin_jwt_secret, transfer_token_salt, jwt_secret, encryption_key) → press Enter for each to auto-generate

### setup-cloudflare.sh prompts (Step 2/4):
- `vars.sh already exists. Overwrite? [y/N]` → type `y` if re-deploying
- `wrangler not found globally. Install it globally now? [Y/n]` → press Enter (yes)
- `Worker name (lowercase, hyphens OK, e.g. my-client-site):` → enter Worker name
- `GitHub repo URL (e.g. https://github.com/org/repo):` → enter repo URL
- `Deploy branch [main]:` → press Enter or enter branch
- `Cloudflare Account ID:` → enter Account ID
- `Cloudflare API Token:` → enter API token (input is hidden)
- `Strapi API URL (e.g. https://api.yourdomain.com):` → enter Strapi URL
- `Strapi API Token (secret — stored as Worker secret, not in wrangler.toml):` → enter Strapi API token
- `Custom domain for this Worker [leave blank to skip]:` → enter custom domain or press Enter to skip
- `Build and do an initial deploy now? [Y/n]` → press Enter (yes)

### Ansible deploy prompts (Step 3/4):
- `VPS IP address:` → enter the VPS IP
- `VPS username [root]:` → press Enter for root or enter username
- `Authentication: 1) SSH key  2) Password` → enter `1` for SSH key or `2` for password
- If SSH key: `Path to SSH key [~/.ssh/id_rsa]:` → press Enter for default or enter path
- If password: `VPS password:` → enter the VPS password (input is hidden)

### Step 4/4 — Cloudflare deploy:
This runs automatically with no prompts.

## Step 4 — Report results
When the script completes, it will print:
- Backend URL (https://your-domain.com)
- Frontend URL (https://your-worker.workers.dev)
- Adminer URL (http://site-name:port)

Report these URLs to the user and remind them:
1. Add the GitHub Actions secrets shown in the terminal output to their repo to enable automatic frontend deploys on push
2. Visit the Backend URL to create their first Strapi admin account
3. After creating the Strapi admin, generate an API token and re-run `bash infrastructure/deploy.sh --reconfigure` if the Strapi API token needs updating
