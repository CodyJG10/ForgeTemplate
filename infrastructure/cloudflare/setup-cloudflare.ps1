#Requires -Version 5.1
# Cloudflare Worker setup wizard for Windows.
# Usage: pwsh -File infrastructure\cloudflare\setup-cloudflare.ps1  (or via deploy.ps1)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot     = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$VarsFile     = Join-Path $ScriptDir "vars.sh"
$FrontendDir  = Join-Path $RepoRoot "Frontend"
$WranglerToml = Join-Path $FrontendDir "wrangler.toml"

# ── helpers ────────────────────────────────────────────────────────────────────

function Prompt-Required {
    param([string]$Label)
    while ($true) {
        $val = Read-Host $Label
        if ($val -ne '') { return $val }
        Write-Host "  (required)" -ForegroundColor Yellow
    }
}

function Prompt-Optional {
    param([string]$Label, [string]$Default = "")
    if ($Default -ne '') {
        $val = Read-Host "$Label [$Default]"
        if ($val -ne '') { return $val }
        return $Default
    } else {
        return Read-Host "$Label [leave blank to skip]"
    }
}

function Prompt-Secret {
    param([string]$Label)
    while ($true) {
        $secure = Read-Host -Prompt $Label -AsSecureString
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try   { $val = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        if ($val -ne '') { return $val }
        Write-Host "  (required)" -ForegroundColor Yellow
    }
}

function Write-UnixFile {
    param([string]$Path, [string]$Content)
    $lf = $Content -replace "`r`n", "`n"
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $lf, $enc)
}

function Protect-File {
    param([string]$Path)
    try {
        $acl = Get-Acl $Path
        $acl.SetAccessRuleProtection($true, $false)
        $me   = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($me, "FullControl", "Allow")
        $acl.SetAccessRule($rule)
        Set-Acl $Path $acl
    } catch {
        Write-Host "  Note: could not restrict file permissions: $_" -ForegroundColor Yellow
    }
}

# ── prerequisites ──────────────────────────────────────────────────────────────

Write-Host "-- Checking prerequisites --"

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Error "Error: node is not installed. Install Node.js >= 22 first."
    exit 1
}
if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    Write-Error "Error: npm is not installed."
    exit 1
}

$nodeMajor = [int](node -e "process.stdout.write(process.version.replace('v','').split('.')[0])")
if ($nodeMajor -lt 20) {
    Write-Error "Error: Node.js >= 20 required (found $(node -v))."
    exit 1
}
Write-Host "  Node $(node -v)  npm $(npm -v)  OK"

if (-not (Get-Command wrangler -ErrorAction SilentlyContinue)) {
    npx --no wrangler --version 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $installW = Read-Host "wrangler not found globally. Install it globally now? [Y/n]"
        if ($installW -eq '' -or $installW -match '^[Yy]') {
            npm install -g wrangler
        } else {
            Write-Host "  wrangler will be run via npx during deploy."
        }
    }
}

# ── guard against overwrite ────────────────────────────────────────────────────

if (Test-Path $VarsFile) {
    $confirmOw = Read-Host "vars.sh already exists. Overwrite? [y/N]"
    if ($confirmOw -notmatch '^[Yy]') { Write-Host "Aborted."; exit 0 }
}

Write-Host ""
Write-Host "=== Cloudflare Worker setup wizard ==="
Write-Host "This will configure the Astro project in Frontend/ for Cloudflare Workers."
Write-Host ""

# ── project config ─────────────────────────────────────────────────────────────

Write-Host "-- Project config --"
while ($true) {
    $rawName       = Prompt-Required "Worker name (lowercase, hyphens OK, e.g. my-client-site)"
    $cfProjectName = ($rawName.ToLower() -replace '[\s_]', '-' -replace '[^a-z0-9\-]', '')
    if ($cfProjectName -match '^[a-z0-9]([a-z0-9\-]*[a-z0-9])?$') {
        if ($cfProjectName -ne $rawName) { Write-Host "  Normalized to: $cfProjectName" -ForegroundColor Cyan }
        break
    }
    Write-Host "  Invalid name after normalization ('$cfProjectName'). Use letters, numbers, and hyphens." -ForegroundColor Yellow
}
$repoUrl = Prompt-Required "GitHub repo URL (e.g. https://github.com/org/repo)"
$branch  = Prompt-Optional "Deploy branch" "main"
Write-Host ""

# ── Cloudflare credentials ─────────────────────────────────────────────────────

Write-Host "-- Cloudflare credentials --"
Write-Host "  Account ID: Cloudflare dashboard -> right sidebar on any zone page"
$cfAccountId = Prompt-Required "Cloudflare Account ID"
Write-Host ""
Write-Host "  API Token: My Profile -> API Tokens -> Create Token"
Write-Host "  Required permissions: Workers Scripts:Edit, Workers Routes:Edit, Account Settings:Read"
$cfApiToken = Prompt-Secret "Cloudflare API Token"
Write-Host ""

# ── application environment ────────────────────────────────────────────────────

Write-Host "-- Application environment --"
Write-Host "  These are passed to the Astro app at runtime."
Write-Host ""
$strapiApiUrl   = Prompt-Required "Strapi API URL (e.g. https://api.yourdomain.com)"
$strapiApiToken = Prompt-Secret   "Strapi API Token (secret -- stored as Worker secret, not in wrangler.toml)"
Write-Host ""

# ── custom domain ──────────────────────────────────────────────────────────────

Write-Host "-- Custom domain (optional) --"
$customDomain = Prompt-Optional "Custom domain for this Worker (leave blank to skip)" ""
Write-Host ""

# ── write vars.sh ──────────────────────────────────────────────────────────────

$varsContent = @"
# Generated by setup-cloudflare.ps1 -- DO NOT COMMIT THIS FILE

# Cloudflare credentials
CF_ACCOUNT_ID="$cfAccountId"
CF_API_TOKEN="$cfApiToken"

# Project config
CF_PROJECT_NAME="$cfProjectName"

# Application environment
STRAPI_API_URL="$strapiApiUrl"
STRAPI_API_TOKEN="$strapiApiToken"
"@

Write-UnixFile $VarsFile $varsContent
Protect-File $VarsFile
Write-Host "  Written: cloudflare/vars.sh"

# ── install @astrojs/cloudflare adapter ───────────────────────────────────────

Write-Host "-- Installing @astrojs/cloudflare adapter --"
Push-Location $FrontendDir
try {
    $pkgJson = Get-Content "package.json" -Raw
    if ($pkgJson -match '"@astrojs/cloudflare"') {
        Write-Host "  @astrojs/cloudflare already in package.json -- skipping install"
    } else {
        npm install "@astrojs/cloudflare@^13.0.0"
        npm install --save-dev "wrangler@^4.61.1"
        Write-Host "  Installed @astrojs/cloudflare and wrangler"
    }
} finally {
    Pop-Location
}

# ── generate wrangler.toml ─────────────────────────────────────────────────────

Write-Host "-- Generating Frontend/wrangler.toml --"

$compatDate  = (Get-Date).ToString("yyyy-MM-dd")
$domainBlock = ""
if ($customDomain -ne '') {
    $domainBlock = @"

[[routes]]
pattern = "$customDomain"
custom_domain = true
"@
}

$wranglerContent = @"
# Generated by cloudflare/setup-cloudflare.ps1
# Commit this file -- it contains no secrets.
# Secrets are managed via ``wrangler secret put`` (see cloudflare/deploy.ps1).

name = "$cfProjectName"
compatibility_date = "$compatDate"
compatibility_flags = ["nodejs_compat"]

[assets]
directory = "./dist"
not_found_handling = "single-page-application"

[vars]
STRAPI_API_URL = "$strapiApiUrl"
$domainBlock
"@

Write-UnixFile $WranglerToml $wranglerContent
Write-Host "  Written: Frontend/wrangler.toml"

# ── push Worker secrets ────────────────────────────────────────────────────────

Write-Host "-- Pushing Worker secrets to Cloudflare --"
Write-Host "  Secrets are encrypted at rest and never visible after being set."

$env:CLOUDFLARE_API_TOKEN  = $cfApiToken
$env:CLOUDFLARE_ACCOUNT_ID = $cfAccountId

$doBuild = Read-Host "Build and do an initial deploy now? (required to push secrets on first run) [Y/n]"
if ($doBuild -eq '' -or $doBuild -match '^[Yy]') {
    Push-Location $FrontendDir
    try {
        $env:ASTRO_ADAPTER = "cloudflare"
        npm run build
        Remove-Item Env:\ASTRO_ADAPTER -ErrorAction SilentlyContinue
        npx wrangler deploy
        Write-Output $strapiApiToken | npx wrangler secret put STRAPI_API_TOKEN
        Write-Host "  Secrets pushed."
    } finally {
        Pop-Location
    }
} else {
    Write-Host "  Skipped. Run cloudflare/deploy.ps1 to deploy and push secrets later."
}

# ── GitHub Actions secrets instructions ───────────────────────────────────────

Write-Host ""
Write-Host "========================================================"
Write-Host "  GitHub Actions secrets -- add these to your repo"
Write-Host "  $repoUrl/settings/secrets/actions"
Write-Host "========================================================"
Write-Host ""
Write-Host "  Secret name              Value"
Write-Host "  ---------------------    -----------------------------"
Write-Host "  CLOUDFLARE_API_TOKEN     $cfApiToken"
Write-Host "  CLOUDFLARE_ACCOUNT_ID    $cfAccountId"
Write-Host "  STRAPI_API_TOKEN         (your Strapi token -- set above)"
Write-Host ""
Write-Host "  The workflow file is already at:"
Write-Host "  .github/workflows/deploy-frontend.yml"
Write-Host ""
Write-Host "  Push to $branch to trigger a deployment."
Write-Host "========================================================"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Add the secrets above to GitHub"
Write-Host "  2. git add Frontend\wrangler.toml Frontend\package.json Frontend\astro.config.mjs"
Write-Host "  3. git commit -m 'chore: add Cloudflare Worker deployment'"
Write-Host "  4. git push -- GitHub Actions will build and deploy automatically"
Write-Host ""
Write-Host "To deploy manually at any time:"
Write-Host "  pwsh -File infrastructure\deploy.ps1"
