#!/usr/bin/env bash
# network/scripts/utils.sh
# Shared environment variables and helper functions used by all network scripts.
# Chapter Three, Section 3.4.

set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NETWORK_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CRYPTO_DIR="${NETWORK_DIR}/crypto-config"
CHANNEL_ARTIFACTS="${NETWORK_DIR}/channel-artifacts"
CHAINCODE_DIR="${NETWORK_DIR}/../chaincode"

# ── Fabric binaries — must be on PATH (installed via fabric-samples) ──────────
export PATH="${SCRIPT_DIR}/bin:${NETWORK_DIR}/bin:${PATH}"
export FABRIC_CFG_PATH="${NETWORK_DIR}"

# ── Docker Compose — supports both plugin (docker compose) and standalone ─────
# Modern Docker Desktop / Engine ships compose as a plugin; fall back to the
# legacy standalone binary if the plugin is absent.
if docker compose version &>/dev/null 2>&1; then
  DOCKER_COMPOSE="docker compose"
elif command -v docker-compose &>/dev/null; then
  DOCKER_COMPOSE="docker-compose"
else
  DOCKER_COMPOSE="docker compose"   # will fail at runtime with a clear message
fi
export DOCKER_COMPOSE

# ── Network constants ─────────────────────────────────────────────────────────
CHANNEL_NAME="sim-registration-channel"
ORDERER_CA="${CRYPTO_DIR}/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem"
ORDERER_ADDRESS="orderer.example.com:7050"

# ── Organisation peer addresses & TLS certs ───────────────────────────────────
declare -A PEER_ADDRESS=(
  [NCC]="peer0.ncc.example.com:7051"
  [MTN]="peer0.mno1.example.com:8051"
  [Airtel]="peer0.mno2.example.com:9051"
  [Glo]="peer0.mno3.example.com:10051"
  [NineMobile]="peer0.mno4.example.com:11051"
)

declare -A PEER_DOMAIN=(
  [NCC]="ncc.example.com"
  [MTN]="mno1.example.com"
  [Airtel]="mno2.example.com"
  [Glo]="mno3.example.com"
  [NineMobile]="mno4.example.com"
)

declare -A PEER_MSPID=(
  [NCC]="NCCMSP"
  [MTN]="MTNMSP"
  [Airtel]="AIRTELMSP"
  [Glo]="GLOMSP"
  [NineMobile]="NINEMOBILEMSP"
)

ALL_ORGS=("NCC" "MTN" "Airtel" "Glo" "NineMobile")

# ── set_peer_env ORG ─────────────────────────────────────────────────────────
# Set CORE_PEER_* environment variables for the given org.
set_peer_env() {
  local ORG=$1
  local DOMAIN="${PEER_DOMAIN[$ORG]}"
  local PEER="${PEER_ADDRESS[$ORG]%%:*}"   # hostname only

  export CORE_PEER_LOCALMSPID="${PEER_MSPID[$ORG]}"
  export CORE_PEER_ADDRESS="${PEER_ADDRESS[$ORG]}"
  export CORE_PEER_TLS_ENABLED=true
  export CORE_PEER_TLS_ROOTCERT_FILE="${CRYPTO_DIR}/peerOrganizations/${DOMAIN}/peers/${PEER}/tls/ca.crt"
  export CORE_PEER_MSPCONFIGPATH="${CRYPTO_DIR}/peerOrganizations/${DOMAIN}/users/Admin@${DOMAIN}/msp"
}

# ── log / error helpers ───────────────────────────────────────────────────────
log()   { echo "[$(date '+%H:%M:%S')] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }
