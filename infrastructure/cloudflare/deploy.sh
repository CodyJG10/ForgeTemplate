#!/usr/bin/env bash
# One-command deploy to Cloudflare Workers.
# Run: bash cloudflare/deploy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VARS_FILE="$SCRIPT_DIR/vars.sh"
FRONTEND_DIR="$SCRIPT_DIR/../../Frontend"

# ── load vars ─────────────────────────────────────────────────────────────────
if [[ ! -f "$VARS_FILE" ]]; then
  echo "Error: cloudflare/vars.sh not found."
  echo "Run cloudflare/setup-cloudflare.sh first."
  exit 1
fi

# shellcheck source=/dev/null
source "$VARS_FILE"

export CLOUDFLARE_API_TOKEN="$CF_API_TOKEN"
export CLOUDFLARE_ACCOUNT_ID="$CF_ACCOUNT_ID"

# ── build ─────────────────────────────────────────────────────────────────────
echo "Building Astro project..."
cd "$FRONTEND_DIR"
npm ci
ASTRO_ADAPTER=cloudflare npm run build

# ── deploy ────────────────────────────────────────────────────────────────────
echo ""
echo "Deploying to Cloudflare Workers (${CF_PROJECT_NAME})..."
npx wrangler deploy

# ── sync secrets ──────────────────────────────────────────────────────────────
# Idempotent: safe to run on every deploy — existing value is overwritten.
echo ""
echo "Syncing Worker secrets..."
echo "$STRAPI_API_TOKEN" | npx wrangler secret put STRAPI_API_TOKEN

echo ""
echo "Deployed successfully!"
echo "Worker: https://${CF_PROJECT_NAME}.workers.dev"
