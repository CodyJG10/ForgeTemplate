#Requires -Version 5.1
# One-command deploy to Cloudflare Workers.
# Usage: pwsh -File infrastructure\cloudflare\deploy.ps1  (or via deploy.ps1)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$VarsFile    = Join-Path $ScriptDir "vars.sh"
$FrontendDir = Join-Path (Split-Path -Parent (Split-Path -Parent $ScriptDir)) "Frontend"

# ── load vars ──────────────────────────────────────────────────────────────────

if (-not (Test-Path $VarsFile)) {
    Write-Error "Error: cloudflare/vars.sh not found. Run cloudflare/setup-cloudflare.ps1 first."
    exit 1
}

$cfVars = @{}
Get-Content $VarsFile | ForEach-Object {
    if ($_ -match '^([A-Z_]+)="(.*)"$') {
        $cfVars[$Matches[1]] = $Matches[2]
    }
}

$env:CLOUDFLARE_API_TOKEN  = $cfVars['CF_API_TOKEN']
$env:CLOUDFLARE_ACCOUNT_ID = $cfVars['CF_ACCOUNT_ID']

# ── build + deploy ─────────────────────────────────────────────────────────────

Write-Host "Building Astro project..."
Push-Location $FrontendDir
try {
    npm ci
    $env:ASTRO_ADAPTER = "cloudflare"
    npm run build
    Remove-Item Env:\ASTRO_ADAPTER -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Host "Deploying to Cloudflare Workers ($($cfVars['CF_PROJECT_NAME']))..."
    npx wrangler deploy

    Write-Host ""
    Write-Host "Syncing Worker secrets..."
    Write-Output $cfVars['STRAPI_API_TOKEN'] | npx wrangler secret put STRAPI_API_TOKEN
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "Deployed successfully!"
Write-Host "Worker: https://$($cfVars['CF_PROJECT_NAME']).workers.dev"
