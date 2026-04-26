# Strapi Backend — Deployment Guide

Ansible playbooks for deploying and tearing down the Strapi + PostgreSQL backend on any VPS that has Docker and Docker Compose installed. Each site instance is isolated under `/opt/strapi-sites/<site_name>`, so multiple sites can share a single VPS.

---

## Prerequisites

**Local machine (where you run Ansible):**
- Ansible installed (`pip install ansible` or `brew install ansible`)
- SSH access to the VPS

**VPS:**
- Docker + Docker Compose installed
- SSH accessible with a key or password

---

## One-time Setup

### 1. Configure your inventory

Copy `inventory.example` to `inventory` and fill in your VPS details:

```ini
[strapi_servers]
my-vps ansible_host=203.0.113.10 ansible_user=root ansible_ssh_private_key_file=~/.ssh/id_rsa
```

### 2. Create your vars file

Copy `vars.example.yml` to `vars.yml` and fill in real values:

```bash
cp vars.example.yml vars.yml
```

**Add `vars.yml` to your `.gitignore` — it contains secrets and must not be committed.**

Open `vars.yml` and set:

| Variable | Description |
|---|---|
| `site_name` | Directory name for this site: `/opt/strapi-sites/<site_name>` |
| `repo_url` | Full GitHub URL to your repo |
| `branch` | Branch to deploy (default: `main`) |
| `db_name` | Postgres database name |
| `db_username` | Postgres username |
| `db_password` | Postgres password |
| `strapi_app_keys` | Comma-separated list of ≥2 random keys |
| `strapi_admin_jwt_secret` | Random secret for admin JWT |
| `strapi_jwt_secret` | Random secret for API JWT |
| `strapi_api_token_salt` | Random salt for API tokens |
| `strapi_transfer_token_salt` | Random salt for transfer tokens |
| `strapi_encryption_key` | Random encryption key |

Generate secrets with:
```bash
openssl rand -base64 32
```

For `strapi_app_keys`, generate two and join them with a comma:
```bash
echo "$(openssl rand -base64 32),$(openssl rand -base64 32)"
```

### 3. (Private repos only) Ensure SSH key is on the VPS

If your repo is private and you're using SSH clone URLs, add your deploy key to the VPS before running the playbook:

```bash
ssh-copy-id -i ~/.ssh/id_rsa root@<VPS_IP>
```

For HTTPS private repos, embed a Personal Access Token in the URL:
```
https://<token>@github.com/user/repo.git
```

---

## Deploy

```bash
ansible-playbook deploy.yml -i inventory -e @vars.yml
```

What this does, in order:
1. Creates `/opt/strapi-sites/<site_name>` on the VPS
2. Clones your repo into `.../repo` (or pulls if already cloned)
3. Creates `.env` inside the `Backend/` directory — **only if one does not already exist**
4. Runs `docker compose up -d --build`

The playbook is safe to re-run. Running it again will pull the latest commits and restart any changed containers without touching your `.env` or wiping data.

---

## Tear Down

```bash
ansible-playbook teardown.yml -i inventory -e "site_name=myproject"
```

**This is destructive.** It will:
- Run `docker compose down -v` (stops containers and deletes the named Postgres volume)
- Delete `/opt/strapi-sites/<site_name>` entirely

There is no undo. Back up your database before running this if you need the data.

---

## Updating an Existing Deployment

Just re-run the deploy playbook. It will pull the latest code from the configured branch and rebuild the containers:

```bash
ansible-playbook deploy.yml -i inventory -e @vars.yml
```

To update the `.env` on an existing deployment, SSH to the VPS and edit it directly:

```bash
ssh root@<VPS_IP>
nano /opt/strapi-sites/<site_name>/repo/Backend/.env
docker compose -f /opt/strapi-sites/<site_name>/repo/Backend/docker-compose.yml restart strapi
```

---

## Checking on a Running Site

SSH to the VPS and use standard Docker commands:

```bash
# Check running containers
docker ps

# View Strapi logs
docker logs strapi -f

# View database logs
docker logs strapiDB -f
```

Strapi admin panel: `http://<VPS_IP>:1337/admin`
Database admin (Adminer): `http://<VPS_IP>:9090`

---

## Overriding Defaults

The following variables have defaults that can be overridden:

| Variable | Default | Description |
|---|---|---|
| `branch` | `main` | Git branch to deploy |
| `backend_subdir` | `Backend` | Subdirectory in the repo containing `docker-compose.yml` |
| `db_client` | `postgres` | Database client |
| `db_port` | `5432` | Postgres port |
| `strapi_host` | `0.0.0.0` | Strapi bind address |
| `strapi_port` | `1337` | Strapi port |
| `node_env` | `production` | Node environment |

Override any of these in `vars.yml` or inline with `-e`:

```bash
ansible-playbook deploy.yml -i inventory -e @vars.yml -e "branch=staging backend_subdir=backend"
```
