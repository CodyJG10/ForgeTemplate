# Ansible — Backend Deployment

This directory contains the Ansible playbook and supporting scripts used by `infrastructure/deploy.sh` to provision the Strapi backend on a VPS.

**For normal deployments, use the deploy script from the repo root — you don't need to run Ansible directly.** See the [root README](../../README.md) for full usage.

The information below is for power users who want to run the playbook manually or understand how it works.

---

## Playbooks

### `deploy.yml`

Idempotent — safe to run multiple times. On each run it:

1. Creates `/opt/strapi-sites/<site_name>` on the VPS
2. Clones the repo (or pulls if already cloned)
3. Assigns unique host ports for Strapi, Adminer, and (optionally) the Astro frontend using Python socket binding — guaranteed free on the VPS at assignment time
4. Writes `Backend/.env` and `Frontend/.env` from Jinja2 templates — **only if the files do not already exist**
5. Writes `FRONTEND_PORT` into `Backend/.env` via `lineinfile` so Docker Compose can substitute it in the `ports:` section
6. Runs `docker compose [--profile full] up -d --build`
7. Installs nginx + certbot, writes vhost configs, enables sites, and obtains SSL certificates

### `teardown.yml`

**Destructive.** Stops containers, deletes the Docker volume (database), and removes the site directory entirely. Back up your data before running.

---

## Running manually

```bash
ansible-playbook deploy.yml \
  -i inventory.example \
  -e @vars.yml \
  -e "ansible_host=<VPS_IP> ansible_user=root ansible_ssh_private_key_file=~/.ssh/id_rsa"
```

For VPS frontend deployment, add:
```bash
  -e "deploy_frontend_vps=true frontend_domain=example.com public_strapi_url=https://api.example.com"
```

Teardown:
```bash
ansible-playbook teardown.yml \
  -i inventory.example \
  -e "ansible_host=<VPS_IP> ansible_user=root ansible_ssh_private_key_file=~/.ssh/id_rsa" \
  -e "site_name=<your_site_name>"
```

---

## Variables reference

See `vars.example.yml` for a full list with descriptions. Key variables:

| Variable | Default | Description |
|---|---|---|
| `site_name` | — | Directory name: `/opt/strapi-sites/<site_name>` |
| `repo_url` | — | GitHub URL to your repo |
| `branch` | `main` | Branch to deploy |
| `backend_subdir` | `Backend` | Subdirectory containing `docker-compose.yml` |
| `domain_name` | — | Strapi domain (must have A record pointing to VPS) |
| `ssl_email` | — | Email for Let's Encrypt notifications |
| `deploy_frontend_vps` | `false` | Set `true` to deploy the Astro frontend on the VPS |
| `frontend_domain` | — | Frontend domain (required when `deploy_frontend_vps: true`) |
| `public_strapi_url` | — | Full Strapi URL passed to the frontend at build time |
| `strapi_api_token` | `""` | Set later with `--update-strapi-token` |

---

## Files written to the VPS

```
/opt/strapi-sites/<site_name>/
└── repo/
    ├── Backend/
    │   └── .env          # Strapi + DB secrets, host port mappings
    └── Frontend/
        └── .env          # PUBLIC_STRAPI_URL, STRAPI_API_TOKEN, FRONTEND_PORT
```

Neither `.env` file is ever overwritten on re-runs. Use `--update-strapi-token` to update the API token without SSH access.
