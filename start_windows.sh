#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_INSTALL="${AUTO_INSTALL:-true}"
INSTALL_TOOLCHAIN="${INSTALL_TOOLCHAIN:-true}"

log() { printf '[startup] %s\n' "$*"; }
fail() { printf '[startup] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Detect MSYS/MINGW (Git Bash)
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    IS_WINDOWS=1
    ;;
  *)
    IS_WINDOWS=0
    ;;
esac

# ── Windows-specific setup ──────────────────────────────────────────────────
if [ "$IS_WINDOWS" -eq 1 ]; then
  # Ensure cargo bin is on PATH
  if [ -d "$HOME/.cargo/bin" ]; then
    export PATH="$HOME/.cargo/bin:$PATH"
  fi

  # Docker Desktop must be running
  if ! docker info >/dev/null 2>&1; then
    fail 'Docker Desktop is not running. Start it from the Start menu, wait for "Engine running", then re-run.'
  fi

  # Git for Windows provides bash; we're already in it.
  log 'Running in Git Bash on Windows.'
fi

# ── Toolchain ───────────────────────────────────────────────────────────────
if [ "$INSTALL_TOOLCHAIN" = true ]; then
  if ! have cargo; then
    fail 'Rust/cargo not found. Install Rust from https://rustup.rs/ (choose the MSVC toolchain), then re-run.'
  fi
  if ! have circom; then
    log 'Building circom from source...'
    tmp="$(mktemp -d)"
    git clone --depth 1 https://github.com/iden3/circom.git "$tmp/circom"
    ( cd "$tmp/circom" && cargo build --release && cargo install --path circom )
    rm -rf "$tmp"
  fi
  if ! have snarkjs; then
    log 'Installing snarkjs globally...'
    npm install -g snarkjs
  fi

  # ZK artifacts
  ZK_DIR="$ROOT_DIR/zk"
  WASM="$ZK_DIR/build/nin_commitment_js/nin_commitment.wasm"
  ZKEY="$ZK_DIR/build/nin_commitment_final.zkey"
  VKEY="$ZK_DIR/build/verification_key.json"
  if [ ! -s "$WASM" ] || [ ! -s "$ZKEY" ] || [ ! -s "$VKEY" ]; then
    log 'Compiling ZK circuit...'
    ( cd "$ZK_DIR" && npm install --no-audit --no-fund && bash compile.sh )
  fi
fi

# ── Docker prerequisites ────────────────────────────────────────────────────
have docker || fail 'docker CLI not found.'
docker compose version >/dev/null 2>&1 || fail 'docker compose v2 not available.'
docker info >/dev/null 2>&1 || fail 'Docker engine not reachable.'

# ── Boot the stack ──────────────────────────────────────────────────────────
cd "$ROOT_DIR"

log 'Creating shared Docker network.'
docker network inspect sim_net >/dev/null 2>&1 || docker network create sim_net >/dev/null

log 'Checking Node.js base image.'
docker image inspect node:20-alpine >/dev/null 2>&1 || docker pull node:20-alpine

log 'Starting Hyperledger Fabric network.'
if [ ! -d "$ROOT_DIR/network/crypto-config" ] || [ ! -d "$ROOT_DIR/network/channel-artifacts" ]; then
  log '  No crypto material / channel artifacts found — running full network bootstrap.'
  bash "$ROOT_DIR/network/scripts/network.sh" up
else
  (cd "$ROOT_DIR/network/docker" && docker compose up -d)
fi

log 'Building and starting application containers.'
docker compose rm -sfv backend frontend >/dev/null 2>&1 || true
docker compose up --build -d

log 'Restoring committed chaincode services.'
bash "$ROOT_DIR/network/scripts/network.sh" deploy

printf '\nEverything started.\nFrontend: http://localhost:3000\nBackend:  http://localhost:3001\nHealth:   http://localhost:3001/health\n'