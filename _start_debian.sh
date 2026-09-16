#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_INSTALL="${AUTO_INSTALL:-true}"
INSTALL_TOOLCHAIN="${INSTALL_TOOLCHAIN:-true}"   # set false to skip rust/circom/snarkjs/zk build

log() { printf '[startup] %s\n' "$*"; }
fail() { printf '[startup] ERROR: %s\n' "$*" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────
as_root() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

have() { command -v "$1" >/dev/null 2>&1; }

ensure_cargo_on_path() {
  if [ -f "${HOME}/.cargo/env" ]; then
    # shellcheck disable=SC1091
    . "${HOME}/.cargo/env"
  fi
  export PATH="${HOME}/.cargo/bin:${PATH}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Buildx version floor
# ─────────────────────────────────────────────────────────────────────────────
buildx_meets_min_version() {
  local min_version="0.17.0"
  local raw
  raw="$(docker buildx version 2>/dev/null)" || return 1
  local ver
  ver="$(printf '%s' "${raw}" | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n1 | tr -d v)"
  [ -n "${ver}" ] || return 1
  [ "$(printf '%s\n%s\n' "${min_version}" "${ver}" | sort -V | head -n1)" = "${min_version}" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Docker Compose + Buildx manual installs (fallback only)
# ─────────────────────────────────────────────────────────────────────────────
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

  have curl || fail 'curl is required to install the Docker Compose plugin manually.'

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

  have curl || fail 'curl is required to install the Docker Buildx plugin manually.'

  local arch buildx_arch
  arch="$(uname -m)"
  case "${arch}" in
    x86_64) buildx_arch=amd64 ;;
    aarch64|arm64) buildx_arch=arm64 ;;
    *) fail "Unsupported architecture '${arch}' for manual Docker Buildx install." ;;
  esac

  log 'Looking up latest Docker Buildx release.'
  local api_response tag
  api_response="$(curl -fsSL https://api.github.com/repos/docker/buildx/releases/latest)" \
    || fail 'Could not reach GitHub to determine the latest Docker Buildx release. Check internet, DNS, proxy, or firewall settings.'
  tag="$(printf '%s' "${api_response}" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
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

# ─────────────────────────────────────────────────────────────────────────────
# Debian/Ubuntu: install Docker from Docker's official repository
# ─────────────────────────────────────────────────────────────────────────────
install_docker_debian() {
  log 'Installing Docker Engine from Docker official repository.'

  as_root apt-get update
  as_root apt-get install -y ca-certificates curl gnupg git build-essential nodejs npm

  # Remove any conflicting pre-installed packages
  as_root apt-get remove -y docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc 2>/dev/null || true

  # Add Docker's official GPG key
  as_root install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    as_root gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  as_root chmod a+r /etc/apt/keyrings/docker.gpg

  # Add Docker's official APT repository
  # shellcheck disable=SC1091
  local codename
  codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-stable}}")"
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    ${codename} stable" | as_root tee /etc/apt/sources.list.d/docker.list > /dev/null

  as_root apt-get update
  as_root apt-get install -y \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

  log '  Docker Engine + Compose v2 + Buildx installed from official repo.'
}

# ─────────────────────────────────────────────────────────────────────────────
# OS package installation
# ─────────────────────────────────────────────────────────────────────────────
install_os_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    install_docker_debian
  elif command -v dnf >/dev/null 2>&1; then
    log 'Red Hat/Fedora-family detected. Installing Docker, curl, Git, build tools, Node.js/npm.'
    have curl || as_root dnf install -y curl
    as_root dnf install -y docker git ca-certificates gcc gcc-c++ make nodejs npm
    if dnf list docker-compose-plugin >/dev/null 2>&1; then
      as_root dnf install -y docker-compose-plugin
    else
      log 'docker-compose-plugin not in repos; installing Compose v2 manually.'
      install_compose_plugin_manually
    fi
  elif command -v yum >/dev/null 2>&1; then
    log 'YUM-based Linux detected. Installing Docker, curl, Git, build tools, Node.js/npm.'
    have curl || as_root yum install -y curl
    as_root yum install -y docker git ca-certificates gcc gcc-c++ make nodejs npm
    if yum list docker-compose-plugin >/dev/null 2>&1; then
      as_root yum install -y docker-compose-plugin
    else
      log 'docker-compose-plugin not in repos; installing Compose v2 manually.'
      install_compose_plugin_manually
    fi
  else
    fail 'Unsupported Linux package manager. Install Docker Engine, Compose v2, curl, Git, build tools, and Node.js manually.'
  fi
}

install_linux_prerequisites() {
  [ "${AUTO_INSTALL}" = true ] || return 0

  # Fast path: everything already present
  if have docker && docker compose version >/dev/null 2>&1 && buildx_meets_min_version \
     && have curl && have git && have npm && have node && have gcc && have make; then
    log 'Docker, Compose, Buildx, curl, Git, Node.js, npm, and build tools are already installed; skipping package installation.'
    return 0
  fi

  install_os_packages

  have node || fail 'Node.js installation failed or node is not on PATH.'
  have npm  || fail 'npm installation failed or npm is not on PATH.'
  log "  Node.js version: $(node --version)"
  log "  npm version:     $(npm --version)"
}

# ─────────────────────────────────────────────────────────────────────────────
# Rust toolchain (needed to build circom)
# ─────────────────────────────────────────────────────────────────────────────
install_rust_toolchain() {
  [ "${INSTALL_TOOLCHAIN}" = true ] || { log 'INSTALL_TOOLCHAIN=false — skipping Rust install.'; return 0; }
  ensure_cargo_on_path
  if have cargo && have rustc; then
    log "Rust toolchain already installed (cargo $(cargo --version | awk '{print $2}'))."
    return 0
  fi
  log 'Installing Rust toolchain via rustup...'
  have curl || fail 'curl is required to install Rust.'
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile default
  ensure_cargo_on_path
  have cargo || fail 'Rust installation failed — cargo not found after install.'
  log "  cargo: $(cargo --version)"
}

# ─────────────────────────────────────────────────────────────────────────────
# Circom (built from source, installed to ~/.cargo/bin)
# ─────────────────────────────────────────────────────────────────────────────
install_circom() {
  [ "${INSTALL_TOOLCHAIN}" = true ] || { log 'INSTALL_TOOLCHAIN=false — skipping circom build.'; return 0; }
  ensure_cargo_on_path
  if have circom; then
    log "circom already installed ($(circom --version 2>/dev/null | head -n1))."
    return 0
  fi
  log 'Building circom from source (this takes ~2–3 minutes)...'
  local build_dir
  build_dir="$(mktemp -d)"
  git clone --depth 1 https://github.com/iden3/circom.git "${build_dir}/circom"
  ( cd "${build_dir}/circom" && cargo build --release && cargo install --path circom )
  rm -rf "${build_dir}"
  have circom || fail 'circom build failed — binary not found.'
  log "  circom: $(circom --version 2>/dev/null | head -n1)"
}

# ─────────────────────────────────────────────────────────────────────────────
# SnarkJS (global npm package)
# ─────────────────────────────────────────────────────────────────────────────
install_snarkjs() {
  [ "${INSTALL_TOOLCHAIN}" = true ] || { log 'INSTALL_TOOLCHAIN=false — skipping snarkjs install.'; return 0; }
  if have snarkjs; then
    log "snarkjs already installed ($(snarkjs --version 2>/dev/null | head -n1 || echo 'unknown'))."
    return 0
  fi
  log 'Installing snarkjs globally via npm...'
  have npm || fail 'npm is required to install snarkjs.'
  as_root npm install -g snarkjs
  have snarkjs || fail 'snarkjs installation failed — binary not found.'
  log '  snarkjs installed.'
}

# ─────────────────────────────────────────────────────────────────────────────
# ZK circuit artifacts (install deps + compile if missing)
# ─────────────────────────────────────────────────────────────────────────────
ensure_zk_artifacts() {
  [ "${INSTALL_TOOLCHAIN}" = true ] || { log 'INSTALL_TOOLCHAIN=false — skipping ZK compile.'; return 0; }

  local zk_dir="${ROOT_DIR}/zk"
  [ -d "${zk_dir}" ] || { log 'No zk/ directory found — skipping ZK artifact compilation.'; return 0; }

  local wasm="${zk_dir}/build/nin_commitment_js/nin_commitment.wasm"
  local zkey="${zk_dir}/build/nin_commitment_final.zkey"
  local vkey="${zk_dir}/build/verification_key.json"

  if [ -s "${wasm}" ] && [ -s "${zkey}" ] && [ -s "${vkey}" ]; then
    log 'ZK circuit artifacts already present; skipping compilation.'
    return 0
  fi

  have circom  || fail 'circom is required to compile the ZK circuit.'
  have snarkjs || fail 'snarkjs is required to compile the ZK circuit.'
  have npm     || fail 'npm is required to install ZK circuit dependencies.'

  # Install npm dependencies required by the .circom sources.
  # Circuit files `include` templates from circomlib (e.g. poseidon.circom),
  # resolved via node_modules/circomlib relative to the circuit file.
  if [ -f "${zk_dir}/package.json" ]; then
    log 'Installing ZK circuit npm dependencies (circomlib, etc.)...'
    ( cd "${zk_dir}" && npm install --no-audit --no-fund )
    if [ ! -d "${zk_dir}/node_modules/circomlib" ]; then
      log '  circomlib not found after npm install — adding it explicitly.'
      ( cd "${zk_dir}" && npm install --no-audit --no-fund circomlib )
    fi
    [ -d "${zk_dir}/node_modules/circomlib" ] \
      || fail 'Failed to install circomlib into zk/node_modules.'
  else
    log 'No zk/package.json found — installing circomlib directly.'
    ( cd "${zk_dir}" && npm install --no-audit --no-fund circomlib )
  fi

  log 'ZK circuit artifacts missing — compiling now.'
  ( cd "${zk_dir}" && bash compile.sh )

  [ -s "${wasm}" ] && [ -s "${zkey}" ] && [ -s "${vkey}" ] \
    || fail 'ZK compilation completed but artifacts are still missing. Inspect zk/compile.sh output.'
  log '  ZK artifacts generated.'
}

# ─────────────────────────────────────────────────────────────────────────────
# Main flow
# ─────────────────────────────────────────────────────────────────────────────
if [ "$(uname -s)" != Linux ]; then
  fail 'This is the Linux launcher. On Windows, run .\\start.ps1 from PowerShell; macOS is not supported by this launcher.'
fi

install_linux_prerequisites
install_rust_toolchain
install_circom
install_snarkjs
ensure_zk_artifacts

have docker || fail 'Docker is not installed.'
docker compose version >/dev/null 2>&1 || fail 'Docker Compose v2 is not available.'
if ! buildx_meets_min_version; then
  log 'No sufficiently new Docker Buildx found; installing a current version manually.'
  install_buildx_plugin_manually
  buildx_meets_min_version || fail 'Docker Buildx still does not meet the 0.17.0+ version Compose requires after manual install.'
fi

if ! docker info >/dev/null 2>&1; then
  if have systemctl && [ "${AUTO_INSTALL}" = true ]; then
    log 'Starting Docker service.'
    as_root systemctl enable --now docker
  fi
fi
docker info >/dev/null 2>&1 || fail 'Docker is installed but not running or your user lacks Docker permission.'

# Add current user to docker group so future logins don't need sudo
if ! id -nG "$USER" 2>/dev/null | grep -qw docker; then
  log "Adding ${USER} to the docker group (log out and back in for it to apply to new shells)."
  as_root usermod -aG docker "$USER" 2>/dev/null || true
fi

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
if [ ! -d "${ROOT_DIR}/network/crypto-config" ] || [ ! -d "${ROOT_DIR}/network/channel-artifacts" ]; then
  log '  No crypto material / channel artifacts found — running full network bootstrap (generate + channel create/join).'
  bash "${ROOT_DIR}/network/scripts/network.sh" up
else
  (cd "${ROOT_DIR}/network/docker" && docker compose up -d)
fi

log 'Building and starting application containers.'
docker compose rm -sfv backend frontend >/dev/null 2>&1 || true
docker compose up --build -d

log 'Restoring committed chaincode services.'
bash "${ROOT_DIR}/network/scripts/network.sh" deploy

printf '\nEverything started.\nFrontend: http://localhost:3000\nBackend:  http://localhost:3001\nHealth:   http://localhost:3001/health\n'
