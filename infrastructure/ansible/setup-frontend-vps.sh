#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VARS_FILE="$SCRIPT_DIR/vars.yml"

# ── helpers ──────────────────────────────────────────────────────────────────
prompt() {
  local label="$1" var
  if [[ $# -ge 2 ]]; then
    local default="$2"
    read -rp "$label [${default:-leave blank to skip}]: " var
    echo "${var:-$default}"
  else
    while true; do
      read -rp "$label: " var
      [[ -n "$var" ]] && break
      echo "  (required)" >&2
    done
    echo "$var"
  fi
}

prompt_secret() {
  local label="$1" var
  while true; do
    read -rsp "$label: " var; echo >&2
    [[ -n "$var" ]] && break
    echo "  (required)" >&2
  done
  echo "$var"
}

# ── guard ─────────────────────────────────────────────────────────────────────
if [[ ! -f "$VARS_FILE" ]]; then
  echo "Error: vars.yml not found. Run generate-vars.sh first." >&2
  exit 1
fi

echo ""
echo "=== VPS frontend configuration ==="
echo ""

# ── collect vars ──────────────────────────────────────────────────────────────
echo "-- Frontend domain --"
echo "  This is the domain the Astro app will be served on (e.g. example.com)"
FRONTEND_DOMAIN=$(prompt "frontend_domain")
echo ""

echo "-- Strapi connection --"
# Default to the backend domain already entered
BACKEND_DOMAIN=$(grep 'domain_name:' "$VARS_FILE" | head -1 | sed 's/.*: *"\?\([^"]*\)"\?.*/\1/')
PUBLIC_STRAPI_URL=$(prompt "Public Strapi URL" "https://$BACKEND_DOMAIN")
echo ""
echo "  Strapi API Token — used by the frontend to authenticate API requests."
echo "  Leave blank now and update Frontend/.env on the VPS after creating"
echo "  a token in the Strapi admin panel."
STRAPI_API_TOKEN=$(prompt "Strapi API Token" "")
echo ""

# ── append to vars.yml ────────────────────────────────────────────────────────
cat >> "$VARS_FILE" <<EOF

# Frontend (VPS)
deploy_frontend_vps: true
frontend_domain: "$FRONTEND_DOMAIN"
public_strapi_url: "$PUBLIC_STRAPI_URL"
strapi_api_token: "$STRAPI_API_TOKEN"
EOF

echo "Frontend VPS config appended to vars.yml"
echo ""
echo "Make sure $FRONTEND_DOMAIN has an A record pointing to your VPS."
echo ""
