#Requires -Version 5.1
# VPS frontend configuration — appends to vars.yml.
# Usage: pwsh -File infrastructure\ansible\setup-frontend-vps.ps1  (or via deploy.ps1)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$VarsFile  = Join-Path $ScriptDir "vars.yml"

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

function Append-UnixFile {
    param([string]$Path, [string]$Content)
    $existing = [System.IO.File]::ReadAllText($Path) -replace "`r`n", "`n"
    $toAppend = $Content -replace "`r`n", "`n"
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $existing + $toAppend, $enc)
}

# ── guard ──────────────────────────────────────────────────────────────────────

if (-not (Test-Path $VarsFile)) {
    Write-Error "Error: vars.yml not found. Run generate-vars.ps1 first."
    exit 1
}

Write-Host ""
Write-Host "=== VPS frontend configuration ==="
Write-Host ""

# ── collect vars ───────────────────────────────────────────────────────────────

Write-Host "-- Frontend domain --"
Write-Host "  This is the domain the Astro app will be served on (e.g. example.com)"
$frontendDomain = Prompt-Required "frontend_domain"
Write-Host ""

Write-Host "-- Strapi connection --"
$backendDomainLine = (Get-Content $VarsFile | Where-Object { $_ -match '^domain_name:' } | Select-Object -First 1)
$backendDomain = if ($backendDomainLine) { ($backendDomainLine -replace '^[^:]*:\s*', '') -replace '"', '' } else { "" }
$defaultStrapiUrl = if ($backendDomain) { "https://$backendDomain" } else { "" }
$publicStrapiUrl  = Prompt-Optional "Public Strapi URL" $defaultStrapiUrl
Write-Host ""
Write-Host "  Strapi API Token -- used by the frontend to authenticate API requests."
Write-Host "  Leave blank now and update Frontend/.env on the VPS after creating"
Write-Host "  a token in the Strapi admin panel."
$strapiApiToken = Prompt-Optional "Strapi API Token" ""
Write-Host ""

# ── append to vars.yml ─────────────────────────────────────────────────────────

$append = @"


# Frontend (VPS)
deploy_frontend_vps: true
frontend_domain: "$frontendDomain"
public_strapi_url: "$publicStrapiUrl"
strapi_api_token: "$strapiApiToken"
"@

Append-UnixFile $VarsFile $append

Write-Host "Frontend VPS config appended to vars.yml"
Write-Host ""
Write-Host "Make sure $frontendDomain has an A record pointing to your VPS."
Write-Host ""
