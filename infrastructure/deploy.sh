#!/usr/bin/env bash
# Full-stack deploy: Strapi backend (VPS) + Astro frontend (Cloudflare Workers or VPS)
# Usage: bash infrastructure/deploy.sh [--reconfigure]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$SCRIPT_DIR/ansible"
CF_DIR="$SCRIPT_DIR/cloudflare"
RECONFIGURE=false
FRONTEND_MODE=""

for arg in "$@"; do
  [[ "$arg" == "--reconfigure" ]] && RECONFIGURE=true
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

# ── prerequisites ─────────────────────────────────────────────────────────────
check_cmd ansible-playbook
check_cmd node
check_cmd npm
check_cmd openssl

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

if [[ "$AUTH_CHOICE" == "1" ]]; then
  read -rp "Path to SSH key [~/.ssh/id_rsa]: " SSH_KEY
  SSH_KEY="${SSH_KEY:-~/.ssh/id_rsa}"
  ANSIBLE_CONN="-e ansible_host=$VPS_HOST -e ansible_user=$VPS_USER -e ansible_ssh_private_key_file=$SSH_KEY"
else
  read -rsp "VPS password: " VPS_PASS; echo
  ANSIBLE_CONN="-e ansible_host=$VPS_HOST -e ansible_user=$VPS_USER -e ansible_password=$VPS_PASS"
fi

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

# ── Done ──────────────────────────────────────────────────────────────────────
step "Deployment complete"

SITE_NAME=$(grep 'site_name:' "$ANSIBLE_DIR/vars.yml" | head -1 | sed 's/.*: *"\?\([^"]*\)"\?.*/\1/')
DOMAIN=$(grep 'domain_name:' "$ANSIBLE_DIR/vars.yml" | head -1 | sed 's/.*: *"\?\([^"]*\)"\?.*/\1/')

echo "  Backend:   https://$DOMAIN"

case "$FRONTEND_MODE" in
  cloudflare)
    CF_PROJECT=$(grep 'CF_PROJECT_NAME=' "$CF_DIR/vars.sh" | head -1 | sed 's/.*="\?\([^"]*\)"\?.*/\1/')
    echo "  Frontend:  https://$CF_PROJECT.workers.dev"
    ;;
  vps)
    FRONTEND_DOMAIN=$(grep 'frontend_domain:' "$ANSIBLE_DIR/vars.yml" | head -1 | sed 's/.*: *"\?\([^"]*\)"\?.*/\1/')
    echo "  Frontend:  https://$FRONTEND_DOMAIN"
    ;;
esac

echo "  Adminer:   http://$VPS_HOST (port shown in VPS .env)"
echo ""

if [[ "$FRONTEND_MODE" == "vps" ]]; then
  echo "GitHub Actions secrets for VPS CI/CD — add to your repo:"
  echo "  VPS_HOST       $VPS_HOST"
  echo "  VPS_USER       $VPS_USER"
  echo "  VPS_SITE_NAME  $SITE_NAME"
  echo "  VPS_SSH_KEY    (contents of your private SSH key)"
  echo ""
fi
