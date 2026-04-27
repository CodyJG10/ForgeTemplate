#Requires -Version 5.1
# Full-stack deploy: Strapi backend (VPS) + Astro frontend (Cloudflare Workers or VPS)
# Usage: pwsh -File infrastructure\deploy.ps1 [--reconfigure] [--setup-cicd] [--update-strapi-token]
#
# Prerequisites:
#   - Node.js >= 22, npm
#   - WSL with Ansible installed: wsl pip install ansible   (required for VPS step)
#   - OpenSSH for Windows (built into Windows 10 1809+)
#   - GitHub CLI (gh) -- optional, for automatic CI/CD secret setup
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$AnsibleDir = Join-Path $ScriptDir "ansible"
$CfDir      = Join-Path $ScriptDir "cloudflare"
$PSExe      = (Get-Process -Id $PID).MainModule.FileName   # current pwsh/powershell exe

$Reconfigure       = $false
$SetupCicdOnly     = $false
$UpdateStrapiToken = $false
$FrontendMode      = ""

foreach ($arg in $args) {
    if ($arg -eq '--reconfigure')         { $Reconfigure       = $true }
    if ($arg -eq '--setup-cicd')          { $SetupCicdOnly     = $true }
    if ($arg -eq '--update-strapi-token') { $UpdateStrapiToken = $true }
}

# ── helpers ────────────────────────────────────────────────────────────────────

function Step($msg) {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════╗"
    Write-Host ("║  {0,-52}  ║" -f $msg)
    Write-Host "╚══════════════════════════════════════════════════════╝"
    Write-Host ""
}

function Require-Cmd($name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        Write-Error "Error: '$name' is required but not installed."
        exit 1
    }
}

function Extract-Var($key) {
    $content = Get-Content "$AnsibleDir\vars.yml" -ErrorAction SilentlyContinue
    $line = $content | Where-Object { $_ -match "^${key}:" } | Select-Object -First 1
    if ($line) { return ($line -replace "^[^:]*:\s*", "") -replace '"', '' }
    return ""
}

function Import-CfVars {
    $vars = @{}
    Get-Content "$CfDir\vars.sh" | ForEach-Object {
        if ($_ -match '^([A-Z_]+)="(.*)"$') { $vars[$Matches[1]] = $Matches[2] }
    }
    return $vars
}

function Read-Secret {
    param([string]$Prompt)
    $secure = Read-Host -Prompt $Prompt -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try   { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Get-WslPath($winPath) {
    $winPath = $winPath -replace '^~', $env:USERPROFILE
    return (wsl wslpath -u ($winPath -replace '\\', '/')).Trim()
}

# Invoke an Ansible playbook via WSL. All Windows paths are converted to WSL paths.
function Invoke-Ansible {
    param([string]$Playbook, [string]$ExtraArgs)
    if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
        Write-Error "Ansible requires WSL on Windows. Install WSL then run: wsl pip install ansible"
        exit 1
    }
    $wslPlaybook  = Get-WslPath (Join-Path $AnsibleDir $Playbook)
    $wslInventory = Get-WslPath (Join-Path $AnsibleDir "inventory.example")
    $wslVars      = Get-WslPath (Join-Path $AnsibleDir "vars.yml")
    $cmd = "ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook '$wslPlaybook' -i '$wslInventory' -e '@$wslVars' $ExtraArgs"
    wsl bash -c $cmd
    if ($LASTEXITCODE -ne 0) { Write-Error "Ansible playbook failed (exit $LASTEXITCODE)."; exit 1 }
}

# Run a multi-line bash script on the remote VPS via SSH stdin.
# Uses System.Diagnostics.Process to control line endings, avoiding CRLF issues.
function Invoke-SshScript {
    param([string]$Script)
    $pinfo = New-Object System.Diagnostics.ProcessStartInfo("ssh")
    $pinfo.Arguments       = ($script:SshConnArgs -join ' ') + " $script:SshTarget `"bash -s`""
    $pinfo.RedirectStandardInput = $true
    $pinfo.UseShellExecute       = $false
    $p = [System.Diagnostics.Process]::Start($pinfo)
    $p.StandardInput.NewLine = "`n"   # force LF so remote bash parses correctly
    $p.StandardInput.Write($Script.Trim() + "`n")
    $p.StandardInput.Close()
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { Write-Error "SSH command failed (exit $($p.ExitCode))."; exit 1 }
}

# Install a public key on the remote VPS (equivalent of ssh-copy-id).
function Install-SshPublicKey {
    param([string]$PubKeyFile)
    $pubKey = (Get-Content $PubKeyFile -Raw).Trim()
    $pinfo = New-Object System.Diagnostics.ProcessStartInfo("ssh")
    $pinfo.Arguments       = ($script:SshConnArgs -join ' ') + " $script:SshTarget `"mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys`""
    $pinfo.RedirectStandardInput = $true
    $pinfo.UseShellExecute       = $false
    $p = [System.Diagnostics.Process]::Start($pinfo)
    $p.StandardInput.NewLine = "`n"   # avoid CRLF corrupting authorized_keys on the VPS
    $p.StandardInput.WriteLine($pubKey)
    $p.StandardInput.Close()
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { Write-Error "Failed to install public key on VPS."; exit 1 }
}

function Test-GhAuth {
    gh auth status 2>&1 | Out-Null
    return $LASTEXITCODE -eq 0
}

function Setup-GhSecrets($keyFile) {
    Write-Host "  Setting secrets on $script:GhRepo ..."
    gh secret set VPS_HOST      --body $script:VpsHost  --repo $script:GhRepo
    gh secret set VPS_USER      --body $script:VpsUser  --repo $script:GhRepo
    gh secret set VPS_SITE_NAME --body $script:SiteName --repo $script:GhRepo
    Get-Content $keyFile -Raw | gh secret set VPS_SSH_KEY --repo $script:GhRepo
    Write-Host ""
    Write-Host "  Secrets set:"
    Write-Host "    VPS_HOST       $script:VpsHost"
    Write-Host "    VPS_USER       $script:VpsUser"
    Write-Host "    VPS_SITE_NAME  $script:SiteName"
    Write-Host "    VPS_SSH_KEY    (private key contents)"
}

function Print-ManualInstructions {
    $repoUrl = (Extract-Var "repo_url") -replace '\.git$', ''
    Write-Host ""
    Write-Host "  Add these secrets manually at:"
    Write-Host "  $repoUrl/settings/secrets/actions"
    Write-Host ""
    Write-Host "    VPS_HOST       $script:VpsHost"
    Write-Host "    VPS_USER       $script:VpsUser"
    Write-Host "    VPS_SITE_NAME  $script:SiteName"
    Write-Host "    VPS_SSH_KEY    (contents of your SSH private key)"
}

function Run-CicdSetup {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Host "  GitHub CLI (gh) not installed -- cannot set secrets automatically."
        Write-Host "  Install from https://cli.github.com/ and run with --setup-cicd to retry."
        Print-ManualInstructions
    } elseif (-not (Test-GhAuth)) {
        Write-Host "  GitHub CLI is not authenticated. Run: gh auth login"
        Print-ManualInstructions
    } elseif ($script:AuthChoice -eq "1") {
        $keyPath = $script:SshKey -replace '^~', $env:USERPROFILE
        if (Test-Path $keyPath) {
            Setup-GhSecrets $keyPath
        } else {
            Write-Host "  SSH key not found at $script:SshKey."
            Print-ManualInstructions
        }
    } else {
        Write-Host "  You connected with a password. CI/CD needs an SSH key."
        $genKey = Read-Host "  Generate a deploy key, install it on the VPS, and add to GitHub? [Y/n]"
        if ($genKey -eq '' -or $genKey -match '^[Yy]') {
            $deployKey = Join-Path $env:TEMP "forge_deploy_$(Get-Random)"
            ssh-keygen -t ed25519 -C "forge-deploy@$($script:SiteName)" -f $deployKey -N "" -q
            Write-Host "  Installing public key on VPS ..."
            Install-SshPublicKey "${deployKey}.pub"
            Setup-GhSecrets $deployKey
            Remove-Item $deployKey, "${deployKey}.pub" -ErrorAction SilentlyContinue
            Write-Host "  Temporary key files removed."
        } else {
            Print-ManualInstructions
        }
    }
}

# Collect VPS connection details into script-scoped variables.
function Collect-VpsCreds {
    $script:VpsHost = Read-Host "VPS IP address"
    $u = Read-Host "VPS username [root]"
    $script:VpsUser = if ($u -eq '') { 'root' } else { $u }
    Write-Host ""
    Write-Host "Authentication:"
    Write-Host "  1) SSH key (recommended)"
    Write-Host "  2) Password"
    $a = Read-Host "Choice [1]"
    $script:AuthChoice = if ($a -eq '') { '1' } else { $a }
    Write-Host ""
    $script:SshKey  = ""
    $script:VpsPass = ""
    if ($script:AuthChoice -eq "1") {
        $k = Read-Host "Path to SSH key [~/.ssh/id_rsa]"
        $script:SshKey = if ($k -eq '') { '~/.ssh/id_rsa' } else { $k }
    } else {
        $script:VpsPass = Read-Secret "VPS password"
    }
}

# Build $script:SshConnArgs and $script:SshTarget from collected creds.
function Build-SshArgs {
    $script:SshTarget = "$($script:VpsUser)@$($script:VpsHost)"
    if ($script:AuthChoice -eq "1") {
        $keyPath = $script:SshKey -replace '^~', $env:USERPROFILE
        $script:SshConnArgs = @("-i", $keyPath, "-o", "StrictHostKeyChecking=no")
    } else {
        Write-Host "  Note: sshpass is not available on Windows. SSH will prompt for your password if needed." -ForegroundColor Yellow
        $script:SshConnArgs = @("-o", "StrictHostKeyChecking=no")
    }
}

# ── prerequisites ──────────────────────────────────────────────────────────────
Require-Cmd node
Require-Cmd npm

# ── --setup-cicd shortcut ──────────────────────────────────────────────────────
if ($SetupCicdOnly) {
    if (-not (Test-Path "$AnsibleDir\vars.yml")) {
        Write-Error "Error: vars.yml not found. Run the full deploy first."
        exit 1
    }
    Step "GitHub Actions CI/CD setup"
    $script:SiteName = Extract-Var "site_name"
    $script:GhRepo   = (Extract-Var "repo_url") -replace '\.git$', '' -replace 'https://github\.com/', ''
    Collect-VpsCreds
    Build-SshArgs
    Run-CicdSetup
    exit 0
}

# ── --update-strapi-token shortcut ─────────────────────────────────────────────
if ($UpdateStrapiToken) {
    if (-not (Test-Path "$AnsibleDir\vars.yml")) {
        Write-Error "Error: vars.yml not found. Run the full deploy first."
        exit 1
    }
    Step "Update Strapi API Token"
    $script:SiteName = Extract-Var "site_name"
    $script:GhRepo   = (Extract-Var "repo_url") -replace '\.git$', '' -replace 'https://github\.com/', ''
    $strapiToken     = Read-Secret "Strapi API Token (from Strapi admin -> Settings -> API Tokens)"
    if ($strapiToken -eq '') { Write-Error "Error: token cannot be empty."; exit 1 }
    Write-Host ""
    Collect-VpsCreds
    Build-SshArgs

    $envPath    = "/opt/strapi-sites/$($script:SiteName)/repo/Frontend/.env"
    $composeDir = "/opt/strapi-sites/$($script:SiteName)/repo/Backend"

    Write-Host "  Updating STRAPI_API_TOKEN on VPS ..."
    Invoke-SshScript @"
set -e
sed -i "s|^STRAPI_API_TOKEN=.*|STRAPI_API_TOKEN=$strapiToken|" "$envPath"
cd "$composeDir"
docker compose --profile full up --force-recreate -d frontend
"@
    Write-Host "  Frontend container restarted with new token."

    if ((Get-Command gh -ErrorAction SilentlyContinue) -and (Test-GhAuth)) {
        Write-Host ""
        $updateGh = Read-Host "  Also update STRAPI_API_TOKEN in GitHub Actions secrets? [Y/n]"
        if ($updateGh -eq '' -or $updateGh -match '^[Yy]') {
            gh secret set STRAPI_API_TOKEN --body $strapiToken --repo $script:GhRepo
            Write-Host "  GitHub secret updated."
        }
    }
    Write-Host ""
    Write-Host "Done. Token active immediately -- no redeploy needed."
    exit 0
}

# ── Step 1: Backend config ─────────────────────────────────────────────────────
Step "Step 1 -- Backend configuration (Strapi)"

if ($Reconfigure -or -not (Test-Path "$AnsibleDir\vars.yml")) {
    if ($Reconfigure -and (Test-Path "$AnsibleDir\vars.yml")) { Remove-Item "$AnsibleDir\vars.yml" }
    & $PSExe -File "$AnsibleDir\generate-vars.ps1"
    if ($LASTEXITCODE -ne 0) { exit 1 }
} else {
    Write-Host "vars.yml already exists -- skipping. Run with --reconfigure to redo."
}

# ── Frontend hosting choice ────────────────────────────────────────────────────
Write-Host ""
Write-Host "How would you like to host the frontend?"
Write-Host "  1) Cloudflare Workers  (serverless, global CDN)"
Write-Host "  2) VPS                 (same server as Strapi)"
Write-Host "  3) Skip                (backend only)"
$fc = Read-Host "Choice [1]"
$fc = if ($fc -eq '') { '1' } else { $fc }
Write-Host ""

switch ($fc) {
    '1' { $FrontendMode = "cloudflare" }
    '2' { $FrontendMode = "vps" }
    '3' { $FrontendMode = "skip" }
    default { Write-Host "Invalid choice, defaulting to Cloudflare Workers." -ForegroundColor Yellow; $FrontendMode = "cloudflare" }
}

# ── Step 2: Frontend config ────────────────────────────────────────────────────
switch ($FrontendMode) {
    "cloudflare" {
        Step "Step 2 -- Frontend configuration (Cloudflare Workers)"
        if ($Reconfigure -or -not (Test-Path "$CfDir\vars.sh")) {
            if ($Reconfigure -and (Test-Path "$CfDir\vars.sh")) { Remove-Item "$CfDir\vars.sh" }
            & $PSExe -File "$CfDir\setup-cloudflare.ps1"
            if ($LASTEXITCODE -ne 0) { exit 1 }
        } else {
            Write-Host "vars.sh already exists -- skipping. Run with --reconfigure to redo."
        }
    }
    "vps" {
        Step "Step 2 -- Frontend configuration (VPS)"
        $hasVpsFrontend = (Get-Content "$AnsibleDir\vars.yml" -ErrorAction SilentlyContinue) -match 'deploy_frontend_vps'
        if ($Reconfigure -or -not $hasVpsFrontend) {
            & $PSExe -File "$AnsibleDir\setup-frontend-vps.ps1"
            if ($LASTEXITCODE -ne 0) { exit 1 }
        } else {
            Write-Host "Frontend VPS config already in vars.yml -- skipping. Run with --reconfigure to redo."
        }
    }
    "skip" { Write-Host "  Skipping frontend -- backend only." }
}

# ── Step 3: Deploy backend to VPS ─────────────────────────────────────────────
Step "Step 3 -- Deploy backend to VPS"

Collect-VpsCreds
Build-SshArgs

# Build Ansible connection args; SSH key path must be a WSL path when running via WSL.
if ($script:AuthChoice -eq "1") {
    $keyWin = $script:SshKey -replace '^~', $env:USERPROFILE
    if (Get-Command wsl -ErrorAction SilentlyContinue) {
        $keyWsl      = Get-WslPath $keyWin
        $ansibleConn = "-e ansible_host=$($script:VpsHost) -e ansible_user=$($script:VpsUser) -e 'ansible_ssh_private_key_file=$keyWsl'"
    } else {
        $ansibleConn = "-e ansible_host=$($script:VpsHost) -e ansible_user=$($script:VpsUser) -e ansible_ssh_private_key_file=$keyWin"
    }
} else {
    # ansible_password requires sshpass installed inside WSL
    $ansibleConn = "-e ansible_host=$($script:VpsHost) -e ansible_user=$($script:VpsUser) -e ansible_password=$($script:VpsPass)"
}

Invoke-Ansible "deploy.yml" $ansibleConn

# ── Step 4: Deploy Cloudflare frontend ────────────────────────────────────────
if ($FrontendMode -eq "cloudflare") {
    Step "Step 4 -- Deploy frontend to Cloudflare Workers"
    & $PSExe -File "$CfDir\deploy.ps1"
    if ($LASTEXITCODE -ne 0) { exit 1 }
}

# ── Step 5: GitHub Actions CI/CD setup ────────────────────────────────────────
Step "Step 5 -- GitHub Actions CI/CD"

$script:SiteName = Extract-Var "site_name"
$script:GhRepo   = (Extract-Var "repo_url") -replace '\.git$', '' -replace 'https://github\.com/', ''

Run-CicdSetup

# ── Done ───────────────────────────────────────────────────────────────────────
Step "Deployment complete"

$domain = Extract-Var "domain_name"
Write-Host "  Backend:   https://$domain"

switch ($FrontendMode) {
    "cloudflare" {
        $cfVars = Import-CfVars
        Write-Host "  Frontend:  https://$($cfVars['CF_PROJECT_NAME']).workers.dev"
    }
    "vps" {
        Write-Host "  Frontend:  https://$(Extract-Var 'frontend_domain')"
    }
}

Write-Host "  Adminer:   http://$($script:VpsHost) (ADMINER_PORT in Backend/.env)"
Write-Host ""
