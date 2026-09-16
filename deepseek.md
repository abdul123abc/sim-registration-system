Here's a PowerShell startup script for Windows 10/11 that mirrors the Linux `start_debian.sh` — it installs Docker Desktop prerequisites, Node.js/npm, Rust, circom, snarkjs, compiles the ZK artifacts, and boots the stack.

Save this as **`start.ps1`** in the root of the repo (next to `start.sh`).

```powershell
# start.ps1
# Windows 10/11 launcher for the Privacy-Preserving SIM Registration System.
# Mirrors network/scripts/start.sh behavior.
#
# Usage (from an elevated PowerShell prompt):
#   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#   .\start.ps1
#
# Optional flags via environment:
#   $env:AUTO_INSTALL="false"       # skip OS/package installs
#   $env:INSTALL_TOOLCHAIN="false"  # skip Rust/circom/snarkjs/ZK compile

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # speeds up Invoke-WebRequest

$RootDir           = Split-Path -Parent $MyInvocation.MyCommand.Path
$AutoInstall       = if ($env:AUTO_INSTALL)       { $env:AUTO_INSTALL }       else { 'true' }
$InstallToolchain  = if ($env:INSTALL_TOOLCHAIN)  { $env:INSTALL_TOOLCHAIN }  else { 'true' }

function Log  { param([string]$msg) Write-Host "[startup] $msg" }
function Warn { param([string]$msg) Write-Host "[startup] WARN: $msg" -ForegroundColor Yellow }
function Fail { param([string]$msg) Write-Host "[startup] ERROR: $msg" -ForegroundColor Red; exit 1 }

function Have {
  param([string]$cmd)
  return [bool](Get-Command $cmd -ErrorAction SilentlyContinue)
}

# ─────────────────────────────────────────────────────────────────────────────
# Winget install helper
# ─────────────────────────────────────────────────────────────────────────────
function Install-WingetPackage {
  param(
    [string]$Id,
    [string]$Name = $Id
  )
  if (-not (Have winget)) {
    Fail "winget is not available. Install App Installer from the Microsoft Store, then re-run."
  }
  Log "Installing $Name via winget..."
  # --accept-* flags avoid interactive prompts
  $args = @(
    'install', '--id', $Id, '-e',
    '--accept-package-agreements', '--accept-source-agreements',
    '--silent'
  )
  & winget @args
  if ($LASTEXITCODE -ne 0) {
    Warn "winget returned exit code $LASTEXITCODE while installing $Name (may already be installed)."
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Refresh PATH after installs (winget doesn't update the current session)
# ─────────────────────────────────────────────────────────────────────────────
function Refresh-Path {
  $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
  $env:Path = ($machine, $user -join ';')
}

# ─────────────────────────────────────────────────────────────────────────────
# Prerequisite checks / installs
# ─────────────────────────────────────────────────────────────────────────────
function Ensure-BasePrerequisites {
  if ($AutoInstall -ne 'true') {
    Log 'AUTO_INSTALL=false - skipping package installation.'
    return
  }

  $needDocker = -not (Have docker)
  $needGit    = -not (Have git)
  $needNode   = -not (Have node) -or -not (Have npm)

  if (-not $needDocker -and -not $needGit -and -not $needNode) {
    Log 'Docker, Git, Node.js, and npm already installed; skipping package installation.'
    return
  }

  if ($needDocker) {
    Log 'Docker Desktop is required. Installing via winget (this may take several minutes and prompt for a reboot).'
    Install-WingetPackage -Id 'Docker.DockerDesktop' -Name 'Docker Desktop'
    Warn 'Docker Desktop may need to be started manually the first time. Launch "Docker Desktop" from the Start menu and wait for "Engine running".'
  }

  if ($needGit) {
    Install-WingetPackage -Id 'Git.Git' -Name 'Git for Windows'
  }

  if ($needNode) {
    Install-WingetPackage -Id 'OpenJS.NodeJS.LTS' -Name 'Node.js LTS'
  }

  Refresh-Path

  if ($needDocker) {
    # Docker Desktop installs the CLI, but the engine must be running to do anything useful.
    $dockerReady = $false
    try {
      & docker info *> $null
      if ($LASTEXITCODE -eq 0) { $dockerReady = $true }
    } catch { }

    if (-not $dockerReady) {
      Warn 'Docker Desktop is installed but the engine is not running.'
      Warn 'Open Docker Desktop, wait for "Engine running", then re-run this script.'
      Fail 'Docker engine not reachable.'
    }
  }
}

function Ensure-DevTools {
  # On Windows, Rust provides the MSVC toolchain via rustup-init. No need for
  # gcc/g++/make — Visual Studio Build Tools are installed by rustup if missing.
  # We do need "Build Tools for Visual Studio" which rustup detects and offers
  # to install. If the user already has VS Build Tools, rustup skips it.
}

# ─────────────────────────────────────────────────────────────────────────────
# Rust toolchain
# ─────────────────────────────────────────────────────────────────────────────
function Ensure-CargoOnPath {
  $cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
  if (Test-Path $cargoBin) {
    if ($env:Path -notlike "*$cargoBin*") {
      $env:Path = "$cargoBin;$env:Path"
    }
  }
}

function Install-RustToolchain {
  if ($InstallToolchain -ne 'true') { Log 'INSTALL_TOOLCHAIN=false - skipping Rust install.'; return }
  Ensure-CargoOnPath
  if ((Have cargo) -and (Have rustc)) {
    Log "Rust toolchain already installed ($(cargo --version))."
    return
  }

  Log 'Installing Rust toolchain via rustup...'
  $tmp = Join-Path $env:TEMP 'rustup-init.exe'
  Invoke-WebRequest -Uri 'https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe' -OutFile $tmp
  # -y: accept defaults; the MSVC toolchain will be used
  & $tmp -y --profile default --default-toolchain stable
  if ($LASTEXITCODE -ne 0) { Fail "rustup-init failed with exit code $LASTEXITCODE" }
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue

  Ensure-CargoOnPath
  if (-not (Have cargo)) { Fail 'Rust installation failed - cargo not found after install.' }
  Log "  cargo: $(cargo --version)"
}

# ─────────────────────────────────────────────────────────────────────────────
# Circom
# ─────────────────────────────────────────────────────────────────────────────
function Install-Circom {
  if ($InstallToolchain -ne 'true') { Log 'INSTALL_TOOLCHAIN=false - skipping circom build.'; return }
  Ensure-CargoOnPath
  if (Have circom) {
    Log "circom already installed ($(circom --version 2>$null | Select-Object -First 1))."
    return
  }

  Log 'Building circom from source (this takes ~3-5 minutes on Windows)...'
  $buildDir = Join-Path $env:TEMP ("circom-" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $buildDir | Out-Null
  try {
    & git clone --depth 1 https://github.com/iden3/circom.git (Join-Path $buildDir 'circom')
    Push-Location (Join-Path $buildDir 'circom')
    try {
      & cargo build --release
      if ($LASTEXITCODE -ne 0) { Fail "cargo build failed with exit code $LASTEXITCODE" }
      & cargo install --path circom
      if ($LASTEXITCODE -ne 0) { Fail "cargo install failed with exit code $LASTEXITCODE" }
    } finally {
      Pop-Location
    }
  } finally {
    Remove-Item -Recurse -Force $buildDir -ErrorAction SilentlyContinue
  }
  Ensure-CargoOnPath
  if (-not (Have circom)) { Fail 'circom build failed - binary not found.' }
  Log "  circom installed."
}

# ─────────────────────────────────────────────────────────────────────────────
# SnarkJS
# ─────────────────────────────────────────────────────────────────────────────
function Install-SnarkJS {
  if ($InstallToolchain -ne 'true') { Log 'INSTALL_TOOLCHAIN=false - skipping snarkjs install.'; return }
  if (Have snarkjs) {
    Log 'snarkjs already installed.'
    return
  }
  Log 'Installing snarkjs globally via npm...'
  if (-not (Have npm)) { Fail 'npm is required to install snarkjs.' }
  & npm install -g snarkjs
  if ($LASTEXITCODE -ne 0) { Fail "npm install -g snarkjs failed with exit code $LASTEXITCODE" }
  Refresh-Path
  Log '  snarkjs installed.'
}

# ─────────────────────────────────────────────────────────────────────────────
# ZK circuit artifacts
# ─────────────────────────────────────────────────────────────────────────────
function Ensure-ZKArtifacts {
  if ($InstallToolchain -ne 'true') { Log 'INSTALL_TOOLCHAIN=false - skipping ZK compile.'; return }

  $zkDir = Join-Path $RootDir 'zk'
  if (-not (Test-Path $zkDir)) {
    Log 'No zk/ directory found - skipping ZK artifact compilation.'
    return
  }

  $wasm = Join-Path $zkDir 'build\nin_commitment_js\nin_commitment.wasm'
  $zkey = Join-Path $zkDir 'build\nin_commitment_final.zkey'
  $vkey = Join-Path $zkDir 'build\verification_key.json'

  if ((Test-Path $wasm) -and (Test-Path $zkey) -and (Test-Path $vkey)) {
    $okWasm = (Get-Item $wasm).Length -gt 0
    $okZkey = (Get-Item $zkey).Length -gt 0
    $okVkey = (Get-Item $vkey).Length -gt 0
    if ($okWasm -and $okZkey -and $okVkey) {
      Log 'ZK circuit artifacts already present; skipping compilation.'
      return
    }
  }

  if (-not (Have circom))  { Fail 'circom is required to compile the ZK circuit.' }
  if (-not (Have snarkjs)) { Fail 'snarkjs is required to compile the ZK circuit.' }
  if (-not (Have npm))     { Fail 'npm is required to install ZK circuit dependencies.' }

  Push-Location $zkDir
  try {
    if (Test-Path (Join-Path $zkDir 'package.json')) {
      Log 'Installing ZK circuit npm dependencies (circomlib, etc.)...'
      & npm install --no-audit --no-fund
      if ($LASTEXITCODE -ne 0) { Fail "npm install in zk/ failed with exit code $LASTEXITCODE" }

      $circomlib = Join-Path $zkDir 'node_modules\circomlib'
      if (-not (Test-Path $circomlib)) {
        Log '  circomlib not found after npm install - adding it explicitly.'
        & npm install --no-audit --no-fund circomlib
        if ($LASTEXITCODE -ne 0) { Fail "npm install circomlib failed with exit code $LASTEXITCODE" }
      }
    } else {
      Log 'No zk/package.json found - installing circomlib directly.'
      & npm install --no-audit --no-fund circomlib
    }

    Log 'ZK circuit artifacts missing - compiling now.'
    # compile.sh requires bash. Git for Windows provides Git Bash.
    $bash = $null
    foreach ($candidate in @(
      'C:\Program Files\Git\bin\bash.exe',
      'C:\Program Files\Git\usr\bin\bash.exe'
    )) {
      if (Test-Path $candidate) { $bash = $candidate; break }
    }
    if (-not $bash) {
      $bash = (Get-Command bash -ErrorAction SilentlyContinue).Source
    }
    if (-not $bash) {
      Fail 'bash.exe not found. Install Git for Windows (which ships Git Bash) and re-run.'
    }

    & $bash -lc 'bash compile.sh'
    if ($LASTEXITCODE -ne 0) { Fail "zk compile failed with exit code $LASTEXITCODE" }
  } finally {
    Pop-Location
  }

  if (-not ((Test-Path $wasm) -and (Test-Path $zkey) -and (Test-Path $vkey))) {
    Fail 'ZK compilation completed but artifacts are still missing.'
  }
  Log '  ZK artifacts generated.'
}

# ─────────────────────────────────────────────────────────────────────────────
# Buildx version floor
# ─────────────────────────────────────────────────────────────────────────────
function Test-BuildxMinVersion {
  try {
    $raw = & docker buildx version 2>$null
    if (-not $raw) { return $false }
    $m = [regex]::Match($raw, 'v?(\d+)\.(\d+)\.(\d+)')
    if (-not $m.Success) { return $false }
    $ver = [version]("{0}.{1}.{2}" -f $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value)
    return $ver -ge [version]'0.17.0'
  } catch {
    return $false
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Compose / Buildx sanity
# ─────────────────────────────────────────────────────────────────────────────
function Ensure-DockerComposeAndBuildx {
  if (-not (Have docker)) { Fail 'Docker is not installed.' }
  & docker compose version *> $null
  if ($LASTEXITCODE -ne 0) { Fail 'Docker Compose v2 is not available.' }
  if (-not (Test-BuildxMinVersion)) {
    Fail 'Docker Buildx < 0.17.0. Update Docker Desktop to the latest version.'
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Docker engine running?
# ─────────────────────────────────────────────────────────────────────────────
function Ensure-DockerEngineRunning {
  try {
    & docker info *> $null
    if ($LASTEXITCODE -ne 0) { throw }
  } catch {
    Warn 'Docker engine is not reachable. Attempting to start Docker Desktop...'
    $dd = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
    if (Test-Path $dd) {
      Start-Process $dd
      Log 'Waiting up to 120 seconds for Docker Desktop to start...'
      $ok = $false
      for ($i = 1; $i -le 60; $i++) {
        Start-Sleep -Seconds 2
        try {
          & docker info *> $null
          if ($LASTEXITCODE -eq 0) { $ok = $true; break }
        } catch { }
      }
      if (-not $ok) {
        Fail 'Docker Desktop did not become ready. Open it manually, wait for "Engine running", then re-run.'
      }
      Log '  Docker engine is up.'
    } else {
      Fail 'Docker Desktop not found. Install it from https://www.docker.com/products/docker-desktop/ and re-run.'
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
  Fail 'This is the Windows launcher. On Linux/macOS use ./start.sh instead.'
}
if ($PSVersionTable.PSEdition -eq 'Desktop' -and [Environment]::OSVersion.Platform -ne 'Win32NT') {
  Fail 'This is the Windows launcher.'
}

Log '=== SIM Registration System - Windows launcher ==='

Ensure-BasePrerequisites
Refresh-Path
Ensure-DockerEngineRunning
Ensure-DockerComposeAndBuildx

Install-RustToolchain
Install-Circom
Install-SnarkJS
Ensure-ZKArtifacts

Set-Location $RootDir

Log 'Creating shared Docker network.'
& docker network inspect sim_net *> $null
if ($LASTEXITCODE -ne 0) {
  & docker network create sim_net *> $null
  if ($LASTEXITCODE -ne 0) { Fail 'Could not create Docker network sim_net.' }
}

Log 'Checking Node.js base image.'
& docker image inspect node:20-alpine *> $null
if ($LASTEXITCODE -ne 0) {
  $pulled = $false
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    & docker pull node:20-alpine
    if ($LASTEXITCODE -eq 0) { $pulled = $true; break }
  }
  if (-not $pulled) { Fail 'Docker Hub could not provide node:20-alpine.' }
}

Log 'Starting Hyperledger Fabric network.'
$cryptoDir   = Join-Path $RootDir 'network\crypto-config'
$artifactDir = Join-Path $RootDir 'network\channel-artifacts'
if (-not (Test-Path $cryptoDir) -or -not (Test-Path $artifactDir)) {
  Log '  No crypto material / channel artifacts found - running full network bootstrap (generate + channel create/join).'
  # network.sh requires bash. Use Git Bash.
  $bash = 'C:\Program Files\Git\bin\bash.exe'
  if (-not (Test-Path $bash)) { $bash = (Get-Command bash -ErrorAction SilentlyContinue).Source }
  if (-not $bash) { Fail 'bash.exe not found. Install Git for Windows.' }

  & $bash -lc "cd '$($RootDir -replace '\\','/')/network/scripts' && bash network.sh up"
  if ($LASTEXITCODE -ne 0) { Fail "network.sh up failed with exit code $LASTEXITCODE" }
} else {
  Push-Location (Join-Path $RootDir 'network\docker')
  try {
    & docker compose up -d
    if ($LASTEXITCODE -ne 0) { Fail 'docker compose up (Fabric) failed.' }
  } finally {
    Pop-Location
  }
}

Log 'Building and starting application containers.'
& docker compose rm -sfv backend frontend *> $null
& docker compose up --build -d
if ($LASTEXITCODE -ne 0) { Fail 'docker compose up (app) failed.' }

Log 'Restoring committed chaincode services.'
$bash = 'C:\Program Files\Git\bin\bash.exe'
if (-not (Test-Path $bash)) { $bash = (Get-Command bash -ErrorAction SilentlyContinue).Source }
& $bash -lc "cd '$($RootDir -replace '\\','/')/network/scripts' && bash network.sh deploy"
if ($LASTEXITCODE -ne 0) { Fail "network.sh deploy failed with exit code $LASTEXITCODE" }

Write-Host ''
Write-Host 'Everything started.'
Write-Host 'Frontend: http://localhost:3000'
Write-Host 'Backend:  http://localhost:3001'
Write-Host 'Health:   http://localhost:3001/health'
```

### 🖥️ How to Run

Open **PowerShell as Administrator** (needed for Docker Desktop install and PATH updates), then:

```powershell
cd C:\path\to\sim-registration-system
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\start.ps1
```

The `Set-ExecutionPolicy -Scope Process` line lets you run the script in this session only without changing your system policy.

### 📋 What the Script Does

| Step | Details |
|---|---|
| **Base prerequisites** | Installs Docker Desktop, Git for Windows, Node.js LTS via `winget` if missing |
| **Docker engine** | Starts Docker Desktop automatically and waits up to 120s for it to be ready |
| **Compose + Buildx** | Verifies `docker compose` and Buildx ≥ 0.17.0 |
| **Rust** | Downloads `rustup-init.exe` and installs `cargo` + `rustc` (MSVC toolchain) |
| **Circom** | Clones and `cargo build --release` + `cargo install --path circom` |
| **SnarkJS** | `npm install -g snarkjs` |
| **ZK artifacts** | Runs `npm install` in `zk/` and invokes `bash compile.sh` via Git Bash |
| **Fabric bootstrap** | Runs `network.sh up` via Git Bash if crypto material is missing |
| **App containers** | `docker compose up --build -d` |
| **Chaincode deploy** | Runs `network.sh deploy` via Git Bash |

### ⚙️ Environment Flags

```powershell
# Skip OS package installs (if Docker/Git/Node are already set up)
$env:AUTO_INSTALL="false"; .\start.ps1

# Skip the entire toolchain (Rust, circom, snarkjs, ZK compile)
$env:INSTALL_TOOLCHAIN="false"; .\start.ps1
```

### ⚠️ Requirements & Caveats

| Requirement | Why |
|---|---|
| **Windows 10 21H2 or Windows 11** | Docker Desktop WSL2 backend |
| **WSL2 enabled** | Docker Desktop uses it by default |
| **Administrator PowerShell** | Needed for `winget install` and PATH refresh |
| **Git for Windows** | Provides `bash.exe` used by `network.sh` and `zk/compile.sh` |
| **~8 GB free disk space** | Fabric images + Rust build cache + circom compile |

### 🔧 Known Quirks

1. **Docker Desktop's first start** — Even after install, the user must accept the license on first launch. The script waits for the engine and fails clearly if it doesn't come up.

2. **`bash` for shell scripts** — Both `network.sh` and `zk/compile.sh` are bash scripts. Windows uses Git Bash to run them. If you don't have Git for Windows installed, the script aborts with a clear message.

3. **PATH updates after winget installs** — Winget doesn't update the current session's PATH, so `Refresh-Path` re-reads the Machine + User PATH from the registry. If a tool still isn't found after install, restart PowerShell.

4. **Line endings** — Git on Windows may check out `.sh` files with CRLF line endings, which breaks them in bash. Before running, do:
   ```powershell
   git config --global core.autocrlf input
   git rm --cached -r . ; git reset --hard
   ```
   Or manually convert:
   ```bash
   dos2unix network/scripts/*.sh zk/compile.sh
   ```
   (Git Bash has `dos2unix` available.)

5. **First-run time** — Expect **20–40 minutes** on a fresh Windows machine: Docker Desktop install (~5 min), rustup + Rust toolchain (~5 min), circom build (~4 min), ZK compile (~2 min), Fabric image pulls (~5 min), plus the network bootstrap.

### 📁 File Placement

Put `start.ps1` in the **root** of the repo, next to `start.sh`. Then a user on Windows runs:

```powershell
.\start.ps1
```

and a user on Linux/macOS runs:

```bash
./start.sh
```

Same repo, same one-command launch on both platforms.
