#!/usr/bin/env bash
# Standalone CI/CD setup — sets GitHub Actions secrets for VPS deployment.
# Run this when you don't have vars.yml or want to configure CI/CD independently.
# Usage: bash infrastructure/ansible/setup-cicd.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── helpers ───────────────────────────────────────────────────────────────────
step() {
  echo ""
  echo "╔══════════════════════════════════════════════════════╗"
  printf  "║  %-52s  ║\n" "$1"
  echo "╚══════════════════════════════════════════════════════╝"
  echo ""
}

prompt() {
  local label="$1" default="${2:-}" var
  if [[ -n "$default" ]]; then
    read -rp "  $label [$default]: " var
    echo "${var:-$default}"
  else
    while true; do
      read -rp "  $label: " var
      [[ -n "$var" ]] && break
      echo "  (required)" >&2
    done
    echo "$var"
  fi
}

# ── set secrets via gh CLI ────────────────────────────────────────────────────
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

# ── print manual fallback ─────────────────────────────────────────────────────
_print_manual_instructions() {
  echo ""
  echo "  Add these secrets manually at:"
  echo "  https://github.com/$GH_REPO/settings/secrets/actions"
  echo ""
  echo "    VPS_HOST       $VPS_HOST"
  echo "    VPS_USER       $VPS_USER"
  echo "    VPS_SITE_NAME  $SITE_NAME"
  echo "    VPS_SSH_KEY    (contents of your SSH private key)"
}

# ── generate deploy key, install on VPS, upload to GitHub ────────────────────
_generate_and_install_deploy_key() {
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
}

# ── main ──────────────────────────────────────────────────────────────────────
step "GitHub Actions CI/CD setup"

echo "This script sets the following secrets on your GitHub repository:"
echo "  VPS_HOST, VPS_USER, VPS_SITE_NAME, VPS_SSH_KEY"
echo ""

# Check for vars.yml and offer to read from it
if [[ -f "$SCRIPT_DIR/vars.yml" ]]; then
  read -rp "  vars.yml found — read values from it? [Y/n]: " _use_vars
  if [[ "${_use_vars:-y}" =~ ^[Yy] ]]; then
    extract_var() { grep "^$1:" "$SCRIPT_DIR/vars.yml" | head -1 | sed 's/^[^:]*: *//; s/"//g'; }
    SITE_NAME=$(extract_var site_name)
    REPO_URL=$(extract_var repo_url)
    GH_REPO=$(echo "$REPO_URL" | sed 's/\.git$//; s|https://github.com/||')
    VPS_HOST=$(extract_var vps_host)
    VPS_USER=$(extract_var vps_user)
    SSH_KEY=$(extract_var ssh_key)
    AUTH_CHOICE="1"
    VPS_PASS=""
    echo ""
    echo "  Read from vars.yml:"
    echo "    site_name  $SITE_NAME"
    echo "    repo       $GH_REPO"
    echo "    vps_host   $VPS_HOST"
    echo "    vps_user   $VPS_USER"
    echo "    ssh_key    $SSH_KEY"
    echo ""
  else
    unset -f extract_var 2>/dev/null || true
  fi
fi

# Prompt for any values not already loaded
if [[ -z "${SITE_NAME:-}" ]]; then
  echo "-- Deployment info --"
  SITE_NAME=$(prompt "Site name (e.g. myproject)")
  GH_REPO=$(prompt "GitHub repo (owner/repo, e.g. acme/myproject)")
  echo ""

  echo "-- VPS connection --"
  VPS_HOST=$(prompt "VPS IP address")
  VPS_USER=$(prompt "VPS username" "root")
  echo ""

  echo "-- Authentication --"
  echo "  1) SSH key  (recommended)"
  echo "  2) Password (a deploy key will be generated and installed)"
  read -rp "  Choice [1]: " AUTH_CHOICE
  AUTH_CHOICE="${AUTH_CHOICE:-1}"
  echo ""

  VPS_PASS=""
  SSH_KEY=""
  if [[ "$AUTH_CHOICE" == "1" ]]; then
    SSH_KEY=$(prompt "Path to SSH private key" "~/.ssh/id_rsa")
  else
    read -rsp "  VPS password: " VPS_PASS; echo
  fi
fi

# ── run setup ─────────────────────────────────────────────────────────────────
if ! command -v gh &>/dev/null; then
  echo "  GitHub CLI (gh) not found — cannot set secrets automatically."
  echo "  Install from https://cli.github.com/ and re-run this script."
  _print_manual_instructions

elif ! gh auth status &>/dev/null 2>&1; then
  echo "  GitHub CLI is not authenticated. Run: gh auth login"
  _print_manual_instructions

elif [[ "${AUTH_CHOICE:-1}" == "1" ]]; then
  local_key="${SSH_KEY/#\~/$HOME}"
  if [[ -f "$local_key" ]]; then
    _setup_gh_secrets "$local_key"
  else
    echo "  SSH key not found at $SSH_KEY."
    _print_manual_instructions
  fi

else
  echo "  You chose password authentication — a deploy key will be generated."
  read -rp "  Generate key, install on VPS, and upload to GitHub? [Y/n]: " _gk
  if [[ "${_gk:-y}" =~ ^[Yy] ]]; then
    _generate_and_install_deploy_key
  else
    _print_manual_instructions
  fi
fi

echo ""
echo "Done. Your GitHub Actions workflows can now deploy to $VPS_HOST."
