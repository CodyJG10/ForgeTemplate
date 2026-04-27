#!/usr/bin/env bash
# Full-stack deploy: Strapi backend (VPS) + Astro frontend (Cloudflare Workers or VPS)
# Usage: bash infrastructure/deploy.sh [--reconfigure] [--setup-cicd]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$SCRIPT_DIR/ansible"
CF_DIR="$SCRIPT_DIR/cloudflare"
RECONFIGURE=false
SETUP_CICD_ONLY=false
UPDATE_STRAPI_TOKEN=false
FRONTEND_MODE=""

for arg in "$@"; do
  [[ "$arg" == "--reconfigure"          ]] && RECONFIGURE=true
  [[ "$arg" == "--setup-cicd"           ]] && SETUP_CICD_ONLY=true
  [[ "$arg" == "--update-strapi-token"  ]] && UPDATE_STRAPI_TOKEN=true
done

# ── helpers ───────────────────────────────────────────────────────────────────
step() {
  echo ""
  echo "╔══════════════════════════════════════════════════════╗"
  printf  "║  %-52s  ║\n" "$1"
  echo "╚══════════════════════════════════════════════════════╝"
  echo ""
}

check_cmd() {
  command -v "$1" &>/dev/null || { echo "Error: '$1' is required but not installed." >&2; exit 1; }
}

extract_var() {
  grep "^$1:" "$ANSIBLE_DIR/vars.yml" | head -1 | sed 's/^[^:]*: *//; s/"//g'
}

# Expects VPS_HOST, VPS_USER, SITE_NAME, GH_REPO, AUTH_CHOICE, SSH_KEY, VPS_PASS
_setup_gh_secrets() {
  local key_file="$1"
  echo "  Setting secrets on $GH_REPO ..."
  gh secret set VPS_HOST      --body "$VPS_HOST"  --repo "$GH_REPO"
  gh secret set VPS_USER      --body "$VPS_USER"  --repo "$GH_REPO"
  gh secret set VPS_SITE_NAME --body "$SITE_NAME" --repo "$GH_REPO"
  gh secret set VPS_SSH_KEY   < "$key_file"       --repo "$GH_REPO"
  echo ""
  echo "  Secrets set:"
  echo "    VPS_HOST       $VPS_HOST"
  echo "    VPS_USER       $VPS_USER"
  echo "    VPS_SITE_NAME  $SITE_NAME"
  echo "    VPS_SSH_KEY    (private key contents)"
}

_print_manual_instructions() {
  local repo_url
  repo_url=$(extract_var repo_url | sed 's/\.git$//')
  echo ""
  echo "  Add these secrets manually at:"
  echo "  $repo_url/settings/secrets/actions"
  echo ""
  echo "    VPS_HOST       $VPS_HOST"
  echo "    VPS_USER       $VPS_USER"
  echo "    VPS_SITE_NAME  $SITE_NAME"
  echo "    VPS_SSH_KEY    (contents of your SSH private key)"
}

run_cicd_setup() {
  if ! command -v gh &>/dev/null; then
    echo "  GitHub CLI (gh) not installed — cannot set secrets automatically."
    echo "  Install from https://cli.github.com/ and run with --setup-cicd to retry."
    _print_manual_instructions

  elif ! gh auth status &>/dev/null 2>&1; then
    echo "  GitHub CLI is not authenticated. Run: gh auth login"
    _print_manual_instructions

  elif [[ "$AUTH_CHOICE" == "1" ]]; then
    local key_file="${SSH_KEY/#\~/$HOME}"
    if [[ -f "$key_file" ]]; then
      _setup_gh_secrets "$key_file"
    else
      echo "  SSH key not found at $SSH_KEY."
      _print_manual_instructions
    fi

  else
    echo "  You connected with a password. CI/CD needs an SSH key."
    read -rp "  Generate a deploy key, install it on the VPS, and add to GitHub? [Y/n]: " _gk
    _gk="${_gk:-y}"
    if [[ "$_gk" =~ ^[Yy] ]]; then
      local deploy_key
      deploy_key="$(mktemp /tmp/forge_deploy_XXXXXX)"
      ssh-keygen -t ed25519 -C "forge-deploy@$SITE_NAME" -f "$deploy_key" -N "" -q

      echo "  Installing public key on VPS ..."
      if command -v sshpass &>/dev/null; then
        sshpass -p "$VPS_PASS" ssh-copy-id \
          -i "${deploy_key}.pub" \
          -o StrictHostKeyChecking=no \
          "$VPS_USER@$VPS_HOST"
      else
        ssh -o StrictHostKeyChecking=no "$VPS_USER@$VPS_HOST" \
          "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys" \
          < "${deploy_key}.pub"
      fi

      _setup_gh_secrets "$deploy_key"
      rm -f "$deploy_key" "${deploy_key}.pub"
      echo "  Temporary key files removed."
    else
      _print_manual_instructions
    fi
  fi
}

# Build SSH_CMD from VPS_USER, VPS_HOST, AUTH_CHOICE, SSH_KEY, VPS_PASS
build_ssh_cmd() {
  local opts="-o StrictHostKeyChecking=no"
  if [[ "$AUTH_CHOICE" == "1" ]]; then
    SSH_CMD="ssh -i ${SSH_KEY/#\~/$HOME} $opts $VPS_USER@$VPS_HOST"
  else
    SSH_CMD="sshpass -p '$VPS_PASS' ssh $opts $VPS_USER@$VPS_HOST"
  fi
}

# ── prerequisites ─────────────────────────────────────────────────────────────
check_cmd ansible-playbook
check_cmd node
check_cmd npm
check_cmd openssl

# ── --setup-cicd shortcut (skips deployment, sets secrets only) ───────────────
if [[ "$SETUP_CICD_ONLY" == true ]]; then
  if [[ ! -f "$ANSIBLE_DIR/vars.yml" ]]; then
    echo "Error: vars.yml not found. Run the full deploy first." >&2
    exit 1
  fi

  step "GitHub Actions CI/CD setup"

  SITE_NAME=$(extract_var site_name)
  GH_REPO=$(extract_var repo_url | sed 's/\.git$//; s|https://github.com/||')

  read -rp "VPS IP address: " VPS_HOST
  read -rp "VPS username [root]: " VPS_USER
  VPS_USER="${VPS_USER:-root}"
  echo ""
  echo "Authentication:"
  echo "  1) SSH key"
  echo "  2) Password (will generate a deploy key)"
  read -rp "Choice [1]: " AUTH_CHOICE
  AUTH_CHOICE="${AUTH_CHOICE:-1}"
  echo ""

  VPS_PASS=""
  SSH_KEY=""
  if [[ "$AUTH_CHOICE" == "1" ]]; then
    read -rp "Path to SSH key [~/.ssh/id_rsa]: " SSH_KEY
    SSH_KEY="${SSH_KEY:-~/.ssh/id_rsa}"
  else
    read -rsp "VPS password: " VPS_PASS; echo
  fi

  run_cicd_setup
  exit 0
fi

# ── --update-strapi-token shortcut ───────────────────────────────────────────
if [[ "$UPDATE_STRAPI_TOKEN" == true ]]; then
  if [[ ! -f "$ANSIBLE_DIR/vars.yml" ]]; then
    echo "Error: vars.yml not found. Run the full deploy first." >&2
    exit 1
  fi

  step "Update Strapi API Token"

  SITE_NAME=$(extract_var site_name)
  GH_REPO=$(extract_var repo_url | sed 's/\.git$//; s|https://github.com/||')

  read -rsp "Strapi API Token (from Strapi admin → Settings → API Tokens): " STRAPI_TOKEN; echo
  [[ -z "$STRAPI_TOKEN" ]] && { echo "Error: token cannot be empty." >&2; exit 1; }
  echo ""

  read -rp "VPS IP address: " VPS_HOST
  read -rp "VPS username [root]: " VPS_USER
  VPS_USER="${VPS_USER:-root}"
  echo ""
  echo "Authentication:"
  echo "  1) SSH key"
  echo "  2) Password"
  read -rp "Choice [1]: " AUTH_CHOICE
  AUTH_CHOICE="${AUTH_CHOICE:-1}"
  echo ""

  VPS_PASS=""
  SSH_KEY=""
  if [[ "$AUTH_CHOICE" == "1" ]]; then
    read -rp "Path to SSH key [~/.ssh/id_rsa]: " SSH_KEY
    SSH_KEY="${SSH_KEY:-~/.ssh/id_rsa}"
  else
    read -rsp "VPS password: " VPS_PASS; echo
  fi
  build_ssh_cmd

  ENV_PATH="/opt/strapi-sites/$SITE_NAME/repo/Frontend/.env"
  COMPOSE_DIR="/opt/strapi-sites/$SITE_NAME/repo/Backend"

  echo "  Updating STRAPI_API_TOKEN on VPS ..."
  $SSH_CMD "bash -s" << REMOTE
set -e
sed -i "s|^STRAPI_API_TOKEN=.*|STRAPI_API_TOKEN=$STRAPI_TOKEN|" "$ENV_PATH"
cd "$COMPOSE_DIR"
docker compose --profile full up --force-recreate -d frontend
REMOTE
  echo "  Frontend container restarted with new token."

  if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
    echo ""
    read -rp "  Also update STRAPI_API_TOKEN in GitHub Actions secrets? [Y/n]: " _ugh
    if [[ "${_ugh:-y}" =~ ^[Yy] ]]; then
      gh secret set STRAPI_API_TOKEN --body "$STRAPI_TOKEN" --repo "$GH_REPO"
      echo "  GitHub secret updated."
    fi
  fi

  echo ""
  echo "Done. Token active immediately — no redeploy needed."
  exit 0
fi

# ── Step 1: Backend config ────────────────────────────────────────────────────
step "Step 1 — Backend configuration (Strapi)"

if [[ "$RECONFIGURE" == true ]] || [[ ! -f "$ANSIBLE_DIR/vars.yml" ]]; then
  [[ "$RECONFIGURE" == true && -f "$ANSIBLE_DIR/vars.yml" ]] && rm "$ANSIBLE_DIR/vars.yml"
  bash "$ANSIBLE_DIR/generate-vars.sh"
else
  echo "vars.yml already exists — skipping. Run with --reconfigure to redo."
fi

# ── Frontend hosting choice ───────────────────────────────────────────────────
echo ""
echo "How would you like to host the frontend?"
echo "  1) Cloudflare Workers  (serverless, global CDN)"
echo "  2) VPS                 (same server as Strapi)"
echo "  3) Skip                (backend only)"
read -rp "Choice [1]: " _fc
_fc="${_fc:-1}"
echo ""

case "$_fc" in
  1) FRONTEND_MODE="cloudflare" ;;
  2) FRONTEND_MODE="vps" ;;
  3) FRONTEND_MODE="skip" ;;
  *) echo "Invalid choice, defaulting to Cloudflare Workers." >&2; FRONTEND_MODE="cloudflare" ;;
esac

# ── Step 2: Frontend config ───────────────────────────────────────────────────
case "$FRONTEND_MODE" in
  cloudflare)
    step "Step 2 — Frontend configuration (Cloudflare Workers)"
    if [[ "$RECONFIGURE" == true ]] || [[ ! -f "$CF_DIR/vars.sh" ]]; then
      [[ "$RECONFIGURE" == true && -f "$CF_DIR/vars.sh" ]] && rm "$CF_DIR/vars.sh"
      bash "$CF_DIR/setup-cloudflare.sh"
    else
      echo "vars.sh already exists — skipping. Run with --reconfigure to redo."
    fi
    ;;
  vps)
    step "Step 2 — Frontend configuration (VPS)"
    if [[ "$RECONFIGURE" == true ]] || ! grep -q 'deploy_frontend_vps' "$ANSIBLE_DIR/vars.yml" 2>/dev/null; then
      bash "$ANSIBLE_DIR/setup-frontend-vps.sh"
    else
      echo "Frontend VPS config already in vars.yml — skipping. Run with --reconfigure to redo."
    fi
    ;;
  skip)
    echo "  Skipping frontend — backend only."
    ;;
esac

# ── Step 3: Deploy backend (+ VPS frontend via Ansible) ───────────────────────
step "Step 3 — Deploy backend to VPS"

read -rp "VPS IP address: " VPS_HOST
read -rp "VPS username [root]: " VPS_USER
VPS_USER="${VPS_USER:-root}"

echo ""
echo "Authentication:"
echo "  1) SSH key (recommended)"
echo "  2) Password"
read -rp "Choice [1]: " AUTH_CHOICE
AUTH_CHOICE="${AUTH_CHOICE:-1}"
echo ""

VPS_PASS=""
SSH_KEY=""
if [[ "$AUTH_CHOICE" == "1" ]]; then
  read -rp "Path to SSH key [~/.ssh/id_rsa]: " SSH_KEY
  SSH_KEY="${SSH_KEY:-~/.ssh/id_rsa}"
  ANSIBLE_CONN="-e ansible_host=$VPS_HOST -e ansible_user=$VPS_USER -e ansible_ssh_private_key_file=$SSH_KEY"
else
  read -rsp "VPS password: " VPS_PASS; echo
  ANSIBLE_CONN="-e ansible_host=$VPS_HOST -e ansible_user=$VPS_USER -e ansible_password=$VPS_PASS"
fi
build_ssh_cmd

ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook \
  "$ANSIBLE_DIR/deploy.yml" \
  -i "$ANSIBLE_DIR/inventory.example" \
  -e @"$ANSIBLE_DIR/vars.yml" \
  $ANSIBLE_CONN

# ── Step 4: Deploy Cloudflare frontend (if chosen) ────────────────────────────
if [[ "$FRONTEND_MODE" == "cloudflare" ]]; then
  step "Step 4 — Deploy frontend to Cloudflare Workers"
  bash "$CF_DIR/deploy.sh"
fi

# ── Step 5: GitHub Actions CI/CD setup ───────────────────────────────────────
step "Step 5 — GitHub Actions CI/CD"

SITE_NAME=$(extract_var site_name)
GH_REPO=$(extract_var repo_url | sed 's/\.git$//; s|https://github.com/||')

run_cicd_setup

# ── Done ──────────────────────────────────────────────────────────────────────
step "Deployment complete"

DOMAIN=$(extract_var domain_name)
echo "  Backend:   https://$DOMAIN"

case "$FRONTEND_MODE" in
  cloudflare)
    CF_PROJECT=$(grep 'CF_PROJECT_NAME=' "$CF_DIR/vars.sh" | head -1 | sed 's/^[^=]*=//; s/"//g')
    echo "  Frontend:  https://$CF_PROJECT.workers.dev"
    ;;
  vps)
    FRONTEND_DOMAIN=$(extract_var frontend_domain)
    echo "  Frontend:  https://$FRONTEND_DOMAIN"
    ;;
esac

echo "  Adminer:   http://$VPS_HOST (ADMINER_PORT in Backend/.env)"
echo ""
