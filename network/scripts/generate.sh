#!/usr/bin/env bash
# network/scripts/generate.sh
# Generate crypto material and channel artefacts.
# Fabric 2.5: no system channel — channel genesis block is created directly.
# Chapter Three, Section 3.4.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NETWORK_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CRYPTO_DIR="${NETWORK_DIR}/crypto-config"
CHANNEL_ARTIFACTS="${NETWORK_DIR}/channel-artifacts"
CHANNEL_NAME="sim-registration-channel"
export PATH="${SCRIPT_DIR}/bin:${NETWORK_DIR}/bin:${PATH}"
export FABRIC_CFG_PATH="${NETWORK_DIR}"

log()   { echo "[$(date '+%H:%M:%S')] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

declare -A PEER_MSPID=(
  [NCC]="NCCMSP"
  [MTN]="MTNMSP"
  [Airtel]="AIRTELMSP"
  [Glo]="GLOMSP"
  [NineMobile]="NINEMOBILEMSP"
)
ALL_ORGS=(NCC MTN Airtel Glo NineMobile)

log "=== Step 1: Generating crypto material with cryptogen ==="
if [ -d "${CRYPTO_DIR}/peerOrganizations" ]; then
  log "  Existing crypto-config found — removing and regenerating"
  rm -rf "${CRYPTO_DIR}"
fi
cryptogen generate \
  --config="${NETWORK_DIR}/crypto-config.yaml" \
  --output="${CRYPTO_DIR}"
log "  Crypto material written to: ${CRYPTO_DIR}"

log "=== Step 2: Creating channel-artifacts directory ==="
mkdir -p "${CHANNEL_ARTIFACTS}"

log "=== Step 3: Generating channel genesis block (Fabric 2.5 — no system channel) ==="
# In Fabric 2.5 with channel participation API, configtxgen outputs the
# application channel genesis block directly. There is no system channel.
configtxgen \
  -profile SimRegistrationChannel \
  -outputBlock "${CHANNEL_ARTIFACTS}/${CHANNEL_NAME}.block" \
  -channelID "${CHANNEL_NAME}"
log "  Channel genesis block: ${CHANNEL_ARTIFACTS}/${CHANNEL_NAME}.block"

log "=== Step 4: Generating anchor peer updates ==="
for ORG in "${ALL_ORGS[@]}"; do
  MSPID="${PEER_MSPID[$ORG]}"
  configtxgen \
    -profile SimRegistrationChannel \
    -outputAnchorPeersUpdate "${CHANNEL_ARTIFACTS}/${MSPID}anchors.tx" \
    -channelID "${CHANNEL_NAME}" \
    -asOrg "${MSPID}"
  log "  Anchor peer tx for ${ORG}: ${CHANNEL_ARTIFACTS}/${MSPID}anchors.tx"
done

log "=== generate.sh complete ==="
