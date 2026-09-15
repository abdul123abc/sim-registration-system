#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_INSTALL="${AUTO_INSTALL:-true}"

log() { printf '[startup] %s\n' "$*"; }
fail() { printf '[startup] ERROR: %s\n' "$*" >&2; exit 1; }

install_linux_prerequisites() {
  [ "${AUTO_INSTALL}" = true ] || return 0

  if command -v docker >/dev/null 2>&1 && \
     docker compose version >/dev/null 2>&1 && \
     command -v curl >/dev/null 2>&1 && \
     command -v git >/dev/null 2>&1; then
    log 'Docker, Compose, curl, and Git are already installed; skipping package installation.'
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    log 'Debian/Ubuntu detected. Installing Docker, Compose, curl, and Git if needed.'
    if [ "$(id -u)" -eq 0 ]; then
      apt-get update
      apt-get install -y docker.io docker-compose-plugin curl git ca-certificates
    elif command -v sudo >/dev/null 2>&1; then
      sudo apt-get update
      sudo apt-get install -y docker.io docker-compose-plugin curl git ca-certificates
    else
      fail 'sudo is required to install Debian/Ubuntu prerequisites.'
    fi
  elif command -v dnf >/dev/null 2>&1; then
    log 'Red Hat/Fedora detected. Installing Docker, Compose, curl, and Git if needed.'
    if [ "$(id -u)" -eq 0 ]; then
      dnf install -y docker docker-compose-plugin curl git ca-certificates
    elif command -v sudo >/dev/null 2>&1; then
      sudo dnf install -y docker docker-compose-plugin curl git ca-certificates
    else
      fail 'sudo is required to install Red Hat-family prerequisites.'
    fi
  elif command -v yum >/dev/null 2>&1; then
    log 'YUM-based Linux detected. Installing Docker, Compose, curl, and Git if needed.'
    if [ "$(id -u)" -eq 0 ]; then
      yum install -y docker docker-compose-plugin curl git ca-certificates
    elif command -v sudo >/dev/null 2>&1; then
      sudo yum install -y docker docker-compose-plugin curl git ca-certificates
    else
      fail 'sudo is required to install YUM prerequisites.'
    fi
  else
    fail 'Unsupported Linux package manager. Install Docker Engine, Compose v2, curl, and Git manually.'
  fi
}

if [ "$(uname -s)" != Linux ]; then
  fail 'This is the Linux launcher. On Windows, run .\\start.ps1 from PowerShell; macOS is not supported by this launcher.'
fi

install_linux_prerequisites
command -v docker >/dev/null 2>&1 || fail 'Docker is not installed.'
docker compose version >/dev/null 2>&1 || fail 'Docker Compose v2 is not available.'

if ! docker info >/dev/null 2>&1; then
  if command -v systemctl >/dev/null 2>&1 && [ "${AUTO_INSTALL}" = true ]; then
    log 'Starting Docker service.'
    if [ "$(id -u)" -eq 0 ]; then systemctl enable --now docker; else sudo systemctl enable --now docker; fi
  fi
fi
docker info >/dev/null 2>&1 || fail 'Docker is installed but not running or your user lacks Docker permission.'

cd "${ROOT_DIR}"
log 'Creating shared Docker network.'
docker network inspect sim_net >/dev/null 2>&1 || docker network create sim_net >/dev/null

log 'Checking Node.js base image.'
if ! docker image inspect node:20-alpine >/dev/null 2>&1; then
  for attempt in 1 2 3; do
    docker pull node:20-alpine && break
    [ "${attempt}" -eq 3 ] && fail 'Docker Hub could not provide node:20-alpine. Check internet, DNS, proxy, or firewall settings.'
  done
fi

log 'Starting Hyperledger Fabric network.'
(cd "${ROOT_DIR}/network/docker" && docker compose up -d)
log 'Building and starting application containers.'
# Recreate app-only anonymous node_modules volumes so dependency changes cannot
# leave a stale partial install behind. Fabric and the persistent IPFS volume
# are not touched by this command.
docker compose rm -sfv backend frontend >/dev/null 2>&1 || true
docker compose up --build -d
log 'Restoring committed chaincode services.'
bash "${ROOT_DIR}/network/scripts/network.sh" deploy

printf '\nEverything started.\nFrontend: http://localhost:3000\nBackend:  http://localhost:3001\nHealth:   http://localhost:3001/health\n'
