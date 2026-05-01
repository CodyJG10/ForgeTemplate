#Requires -Version 5.1
# Standalone CI/CD setup — sets GitHub Actions secrets for VPS deployment.
# Run this when you don't have vars.yml or want to configure CI/CD independently.
# Usage: pwsh -File infrastructure\ansible\setup-cicd.ps1  (or via deploy.ps1)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$VarsFile  = Join-Path $ScriptDir "vars.yml"

# ── helpers ────────────────────────────────────────────────────────────────────

function Write-Step {
    param([string]$Title)
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════╗"
    Write-Host ("║  {0,-52}  ║" -f $Title)
    Write-Host "╚══════════════════════════════════════════════════════╝"
    Write-Host ""
}

function Prompt-Required {
    param([string]$Label)
    while ($true) {
        $val = Read-Host "  $Label"
        if ($val -ne '') { return $val }
        Write-Host "  (required)" -ForegroundColor Yellow
    }
}

function Prompt-Optional {
    param([string]$Label, [string]$Default = "")
    if ($Default -ne '') {
        $val = Read-Host "  $Label [$Default]"
        if ($val -ne '') { return $val }
        return $Default
    } else {
        return Read-Host "  $Label [leave blank to skip]"
    }
}

function Prompt-Secret {
    param([string]$Label)
    while ($true) {
        $secure = Read-Host -Prompt "  $Label" -AsSecureString
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try   { $val = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        if ($val -ne '') { return $val }
        Write-Host "  (required)" -ForegroundColor Yellow
    }
}

function Get-VarsValue {
    param([string]$Key)
    $line = Get-Content $VarsFile | Where-Object { $_ -match "^$Key\s*:" } | Select-Object -First 1
    if ($line) { return ($line -replace "^[^:]*:\s*", '') -replace '"', '' }
    return ''
}

function Set-GhSecrets {
    param([string]$KeyFile)
    Write-Host "  Setting secrets on $GhRepo ..."
    gh secret set VPS_HOST      --body $VpsHost  --repo $GhRepo
    gh secret set VPS_USER      --body $VpsUser  --repo $GhRepo
    gh secret set VPS_SITE_NAME --body $SiteName --repo $GhRepo
    Get-Content $KeyFile | gh secret set VPS_SSH_KEY --repo $GhRepo
    Write-Host ""
    Write-Host "  Secrets set:"
    Write-Host "    VPS_HOST       $VpsHost"
    Write-Host "    VPS_USER       $VpsUser"
    Write-Host "    VPS_SITE_NAME  $SiteName"
    Write-Host "    VPS_SSH_KEY    (private key contents)"
}

function Show-ManualInstructions {
    Write-Host ""
    Write-Host "  Add these secrets manually at:"
    Write-Host "  https://github.com/$GhRepo/settings/secrets/actions"
    Write-Host ""
    Write-Host "    VPS_HOST       $VpsHost"
    Write-Host "    VPS_USER       $VpsUser"
    Write-Host "    VPS_SITE_NAME  $SiteName"
    Write-Host "    VPS_SSH_KEY    (contents of your SSH private key)"
}

# ── main ───────────────────────────────────────────────────────────────────────

Write-Step "GitHub Actions CI/CD setup"

Write-Host "This script sets the following secrets on your GitHub repository:"
Write-Host "  VPS_HOST, VPS_USER, VPS_SITE_NAME, VPS_SSH_KEY"
Write-Host ""

$SiteName = ''; $GhRepo = ''; $VpsHost = ''; $VpsUser = ''; $SshKey = ''; $VpsPass = ''; $AuthChoice = '1'

# Offer to read from vars.yml if present
if (Test-Path $VarsFile) {
    $useVars = Read-Host "  vars.yml found — read values from it? [Y/n]"
    if ($useVars -eq '' -or $useVars -match '^[Yy]') {
        $SiteName = Get-VarsValue 'site_name'
        $RepoUrl  = Get-VarsValue 'repo_url'
        $GhRepo   = ($RepoUrl -replace '\.git$', '') -replace 'https://github\.com/', ''
        $VpsHost  = Get-VarsValue 'vps_host'
        $VpsUser  = Get-VarsValue 'vps_user'
        $SshKey   = Get-VarsValue 'ssh_key'
        $AuthChoice = '1'
        Write-Host ""
        Write-Host "  Read from vars.yml:"
        Write-Host "    site_name  $SiteName"
        Write-Host "    repo       $GhRepo"
        Write-Host "    vps_host   $VpsHost"
        Write-Host "    vps_user   $VpsUser"
        Write-Host "    ssh_key    $SshKey"
        Write-Host ""
    }
}

# Prompt for any values not yet set
if ($SiteName -eq '') {
    Write-Host "-- Deployment info --"
    $SiteName = Prompt-Required "Site name (e.g. myproject)"
    $GhRepo   = Prompt-Required "GitHub repo (owner/repo, e.g. acme/myproject)"
    Write-Host ""

    Write-Host "-- VPS connection --"
    $VpsHost = Prompt-Required "VPS IP address"
    $VpsUser = Prompt-Optional "VPS username" "root"
    Write-Host ""

    Write-Host "-- Authentication --"
    Write-Host "  1) SSH key  (recommended)"
    Write-Host "  2) Password (a deploy key will be generated and installed)"
    $AuthChoice = Read-Host "  Choice [1]"
    if ($AuthChoice -eq '') { $AuthChoice = '1' }
    Write-Host ""

    if ($AuthChoice -eq '1') {
        $SshKey = Prompt-Optional "Path to SSH private key" "~/.ssh/id_rsa"
    } else {
        $VpsPass = Prompt-Secret "VPS password"
    }
}

# ── check gh CLI ───────────────────────────────────────────────────────────────

$ghAvailable = $null -ne (Get-Command gh -ErrorAction SilentlyContinue)
$ghAuthed    = $false
if ($ghAvailable) {
    $ghAuthed = (& gh auth status 2>&1 | Select-String 'Logged in') -ne $null
}

if (-not $ghAvailable) {
    Write-Host "  GitHub CLI (gh) not found — cannot set secrets automatically."
    Write-Host "  Install from https://cli.github.com/ and re-run this script."
    Show-ManualInstructions

} elseif (-not $ghAuthed) {
    Write-Host "  GitHub CLI is not authenticated. Run: gh auth login"
    Show-ManualInstructions

} elseif ($AuthChoice -eq '1') {
    $expandedKey = $SshKey -replace '^~', $env:USERPROFILE
    if (Test-Path $expandedKey) {
        Set-GhSecrets $expandedKey
    } else {
        Write-Host "  SSH key not found at $SshKey." -ForegroundColor Yellow
        Show-ManualInstructions
    }

} else {
    Write-Host "  You chose password authentication — a deploy key will be generated."
    $genKey = Read-Host "  Generate key, install on VPS, and upload to GitHub? [Y/n]"
    if ($genKey -eq '' -or $genKey -match '^[Yy]') {
        $tmpKey = Join-Path $env:TEMP "forge_deploy_$([System.IO.Path]::GetRandomFileName().Replace('.',''))"

        # Generate ed25519 key pair
        & ssh-keygen -t ed25519 -C "forge-deploy@$SiteName" -f $tmpKey -N '""' -q
        if ($LASTEXITCODE -ne 0) {
            Write-Error "ssh-keygen failed. Ensure OpenSSH is installed (Settings → Apps → Optional Features)."
        }

        # Install public key on VPS via ssh (requires OpenSSH client)
        Write-Host "  Installing public key on VPS ..."
        $pubKey = Get-Content "${tmpKey}.pub"
        $sshCmd = "mkdir -p ~/.ssh && echo '$pubKey' >> ~/.ssh/authorized_keys"
        & sshpass -p $VpsPass ssh -o StrictHostKeyChecking=no "${VpsUser}@${VpsHost}" $sshCmd
        if ($LASTEXITCODE -ne 0) {
            # sshpass may not be available on Windows; fall back to plink or manual
            Write-Host "  sshpass not available — attempting plain ssh (you may be prompted for password)." -ForegroundColor Yellow
            echo $pubKey | & ssh -o StrictHostKeyChecking=no "${VpsUser}@${VpsHost}" "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
        }

        Set-GhSecrets $tmpKey
        Remove-Item $tmpKey, "${tmpKey}.pub" -Force -ErrorAction SilentlyContinue
        Write-Host "  Temporary key files removed."
    } else {
        Show-ManualInstructions
    }
}

Write-Host ""
Write-Host "Done. Your GitHub Actions workflows can now deploy to $VpsHost."
