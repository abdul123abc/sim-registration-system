#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_INSTALL="${AUTO_INSTALL:-true}"

log() { printf '[startup] %s\n' "$*"; }
fail() { printf '[startup] ERROR: %s\n' "$*" >&2; exit 1; }

# Compose requires buildx >= 0.17.0. `docker buildx version` succeeding only
# proves *some* buildx responded — Amazon Linux's docker package ships an old
# bundled one (observed: 0.12.1) that runs fine but is too old for Compose's
# build step. This checks the actual version, not just that the command runs.
buildx_meets_min_version() {
  local min_version="0.17.0"
  local raw
  raw="$(docker buildx version 2>/dev/null)" || return 1
  local ver
  ver="$(printf '%s' "${raw}" | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n1 | tr -d v)"
  [ -n "${ver}" ] || return 1
  [ "$(printf '%s\n%s\n' "${min_version}" "${ver}" | sort -V | head -n1)" = "${min_version}" ]
}

install_compose_plugin_manually() {
  local target_user="${SUDO_USER:-$USER}"
  local target_home
  target_home="$(getent passwd "${target_user}" | cut -d: -f6)"
  [ -n "${target_home}" ] || target_home="${HOME}"
  local plugin_dir="${target_home}/.docker/cli-plugins"
  local plugin_path="${plugin_dir}/docker-compose"

  if [ -x "${plugin_path}" ] && "${plugin_path}" version >/dev/null 2>&1; then
    log 'Docker Compose v2 CLI plugin already installed manually; skipping download.'
    return 0
  fi

  command -v curl >/dev/null 2>&1 || fail 'curl is required to install the Docker Compose plugin manually.'

  local arch compose_arch
  arch="$(uname -m)"
  case "${arch}" in
    x86_64) compose_arch=x86_64 ;;
    aarch64|arm64) compose_arch=aarch64 ;;
    *) fail "Unsupported architecture '${arch}' for manual Docker Compose install." ;;
  esac

  log "Downloading Docker Compose v2 CLI plugin to ${plugin_path}."
  mkdir -p "${plugin_dir}"
  local url="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${compose_arch}"
  local attempt
  for attempt in 1 2 3; do
    curl -fSL "${url}" -o "${plugin_path}" && break
    [ "${attempt}" -eq 3 ] && fail "Could not download Docker Compose plugin from ${url}. Check internet, DNS, proxy, or firewall settings."
  done
  chmod +x "${plugin_path}"

  if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    chown -R "${SUDO_USER}:${SUDO_USER}" "${target_home}/.docker" 2>/dev/null || true
  fi

  "${plugin_path}" version >/dev/null 2>&1 || fail 'Docker Compose plugin installed but failed to run.'
  log 'Docker Compose v2 CLI plugin installed manually.'
}

install_buildx_plugin_manually() {
  local target_user="${SUDO_USER:-$USER}"
  local target_home
  target_home="$(getent passwd "${target_user}" | cut -d: -f6)"
  [ -n "${target_home}" ] || target_home="${HOME}"
  local plugin_dir="${target_home}/.docker/cli-plugins"
  local plugin_path="${plugin_dir}/docker-buildx"

  if [ -x "${plugin_path}" ] && "${plugin_path}" version >/dev/null 2>&1 && buildx_meets_min_version; then
    log 'Docker Buildx CLI plugin already installed manually and meets the version floor; skipping download.'
    return 0
  fi

  command -v curl >/dev/null 2>&1 || fail 'curl is required to install the Docker Buildx plugin manually.'

  local arch buildx_arch
  arch="$(uname -m)"
  case "${arch}" in
    x86_64) buildx_arch=amd64 ;;
    aarch64|arm64) buildx_arch=arm64 ;;
    *) fail "Unsupported architecture '${arch}' for manual Docker Buildx install." ;;
  esac

  log 'Looking up latest Docker Buildx release.'
  local tag
  tag="$(curl -fsSL https://api.github.com/repos/docker/buildx/releases/latest \
    | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
  [ -n "${tag}" ] || fail 'Could not determine latest Docker Buildx release version. Check internet, DNS, proxy, or firewall settings.'

  log "Downloading Docker Buildx plugin ${tag} to ${plugin_path}."
  mkdir -p "${plugin_dir}"
  local url="https://github.com/docker/buildx/releases/download/${tag}/buildx-${tag}.linux-${buildx_arch}"
  local attempt
  for attempt in 1 2 3; do
    curl -fSL "${url}" -o "${plugin_path}" && break
    [ "${attempt}" -eq 3 ] && fail "Could not download Docker Buildx plugin from ${url}. Check internet, DNS, proxy, or firewall settings."
  done
  chmod +x "${plugin_path}"

  if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    chown -R "${SUDO_USER}:${SUDO_USER}" "${target_home}/.docker" 2>/dev/null || true
  fi

  "${plugin_path}" version >/dev/null 2>&1 || fail 'Docker Buildx plugin installed but failed to run.'
  log 'Docker Buildx CLI plugin installed manually.'
}

install_linux_prerequisites() {
  [ "${AUTO_INSTALL}" = true ] || return 0

  if command -v docker >/dev/null 2>&1 && \
     docker compose version >/dev/null 2>&1 && \
     buildx_meets_min_version && \
     command -v curl >/dev/null 2>&1 && \
     command -v git >/dev/null 2>&1; then
    log 'Docker, Compose, Buildx, curl, and Git are already installed; skipping package installation.'
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
    log 'Red Hat/Fedora-family detected. Installing Docker, curl, and Git if needed.'
    local as_root=()
    if [ "$(id -u)" -eq 0 ]; then
      as_root=()
    elif command -v sudo >/dev/null 2>&1; then
      as_root=(sudo)
    else
      fail 'sudo is required to install Red Hat-family prerequisites.'
    fi

    local pkgs=(docker git ca-certificates)
    # Amazon Linux 2023 ships curl-minimal, which conflicts with the full
    # curl package. curl-minimal already provides a working `curl` command,
    # so only request the full package when no curl binary exists at all.
    command -v curl >/dev/null 2>&1 || pkgs+=(curl)

    # docker-compose-plugin is not published in Amazon Linux 2023's default
    # repos (unlike RHEL/Fedora proper), so only request it there if present.
    if dnf list docker-compose-plugin >/dev/null 2>&1; then
      pkgs+=(docker-compose-plugin)
      "${as_root[@]}" dnf install -y "${pkgs[@]}"
    else
      log 'docker-compose-plugin package not found in repos (expected on Amazon Linux); installing Compose v2 manually instead.'
      "${as_root[@]}" dnf install -y "${pkgs[@]}"
      install_compose_plugin_manually
    fi
  elif command -v yum >/dev/null 2>&1; then
    log 'YUM-based Linux detected. Installing Docker, curl, and Git if needed.'
    local as_root=()
    if [ "$(id -u)" -eq 0 ]; then
      as_root=()
    elif command -v sudo >/dev/null 2>&1; then
      as_root=(sudo)
    else
      fail 'sudo is required to install YUM prerequisites.'
    fi

    local pkgs=(docker git ca-certificates)
    command -v curl >/dev/null 2>&1 || pkgs+=(curl)

    # Amazon Linux 2's yum repos don't carry docker-compose-plugin either.
    if yum list docker-compose-plugin >/dev/null 2>&1; then
      pkgs+=(docker-compose-plugin)
      "${as_root[@]}" yum install -y "${pkgs[@]}"
    else
      log 'docker-compose-plugin package not found in repos (expected on Amazon Linux); installing Compose v2 manually instead.'
      "${as_root[@]}" yum install -y "${pkgs[@]}"
      install_compose_plugin_manually
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
if ! buildx_meets_min_version; then
  log 'No sufficiently new Docker Buildx found (Amazon Linux'"'"'s docker package bundles an old one, e.g. 0.12.1, that Compose rejects); installing a current version manually.'
  install_buildx_plugin_manually
  buildx_meets_min_version || fail 'Docker Buildx still does not meet the 0.17.0+ version Compose requires after manual install.'
fi

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
