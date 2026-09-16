$ErrorActionPreference = 'Stop'

function Write-Startup($Message) {
    Write-Host "[startup] $Message"
}

function Require-Command($Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' is unavailable."
    }
}

$Root = (Resolve-Path $PSScriptRoot).Path

Write-Startup 'Windows detected.'

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'Windows Package Manager (winget) is required. Install App Installer from the Microsoft Store, then rerun start.ps1.'
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Startup 'Installing Docker Desktop with winget.'
    winget install --id Docker.DockerDesktop --exact --accept-package-agreements --accept-source-agreements
}

if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
    Write-Startup 'Installing WSL. Windows may require a restart before continuing.'
    wsl --install
    throw 'WSL installation was requested. Restart Windows, then rerun start.ps1.'
}

Require-Command docker
docker info *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Startup 'Starting Docker Desktop.'
    Start-Process 'Docker Desktop' -ErrorAction SilentlyContinue
    $ready = $false
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        Start-Sleep -Seconds 2
        docker info *> $null
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
    }
    if (-not $ready) { throw 'Docker Desktop did not become ready. Open it manually and rerun start.ps1.' }
}

$wslRoot = (wsl.exe wslpath -a ($Root -replace '\\','/')).Trim()
if (-not $wslRoot) { throw 'Could not convert the project path for WSL.' }

Write-Startup 'Running the Linux bootstrap inside WSL.'
wsl.exe bash -lc "cd '$wslRoot' && chmod +x start.sh && AUTO_INSTALL=false ./start.sh"
if ($LASTEXITCODE -ne 0) { throw 'The Linux bootstrap failed inside WSL.' }