#!/usr/bin/env bash
# network/scripts/deployChaincode.sh
# Deploys all 4 chaincodes via the Fabric Lifecycle v2.x using CCaaS:
#   1. Vendor Go dependencies
#   2. Package chaincode as CCaaS (connection.json)
#   3. Install package on all 5 peers (bypasses Docker-in-Docker socket build)
#   4. Query package ID & spin up CCaaS chaincode container
#   5. Approve from all 5 orgs (with endorsement policy)
#   6. Check commit readiness
#   7. Commit to channel
#
# Chapter Three, Section 3.4.2 — Milestone 3.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

# ── Container-internal paths ─────────────────────────────────────────────────
CLI="sim_cli"
CRYPTO_INNER="/opt/gopath/src/github.com/hyperledger/fabric/peer/crypto"
ARTIFACTS_INNER="/opt/gopath/src/github.com/hyperledger/fabric/peer/channel-artifacts"
ORDERER_INNER="${CRYPTO_INNER}/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem"

# ── Chaincode definitions ────────────────────────────────────────────────────
CC_SEQUENCE="1"
CC_VERSION="1.0"

# Ordered list of chaincodes to deploy
CHAINCODES=("subscriber-registration" "identity-validation" "update-tracking" "access-control")

# Port mappings for CCaaS servers
declare -A CC_PORT=(
  [subscriber-registration]="9999"
  [identity-validation]="9998"
  [update-tracking]="9997"
  [access-control]="9996"
)

# Endorsement policies per chaincode (Chapter 3, Section 3.4.2)
declare -A CC_POLICY=(
  [subscriber-registration]="AND('NCCMSP.peer', OR('MTNMSP.peer','AIRTELMSP.peer','GLOMSP.peer','NINEMOBILEMSP.peer'))"
  [identity-validation]="AND('NCCMSP.peer', OR('MTNMSP.peer','AIRTELMSP.peer','GLOMSP.peer','NINEMOBILEMSP.peer'))"
  [update-tracking]="OutOf(3, 'NCCMSP.peer','MTNMSP.peer','AIRTELMSP.peer','GLOMSP.peer','NINEMOBILEMSP.peer')"
  [access-control]="OutOf(3, 'MTNMSP.peer','AIRTELMSP.peer','GLOMSP.peer','NINEMOBILEMSP.peer')"
)

# ── Per-org peer environment (container-internal paths) ───────────────────────
set_cli_peer_env() {
  local ORG=$1
  local DOMAIN="${PEER_DOMAIN[$ORG]}"
  local PEER_HOST="${PEER_ADDRESS[$ORG]%%:*}"

  CLI_ENV=(
    -e "CORE_PEER_LOCALMSPID=${PEER_MSPID[$ORG]}"
    -e "CORE_PEER_ADDRESS=${PEER_ADDRESS[$ORG]}"
    -e "CORE_PEER_TLS_ENABLED=true"
    -e "CORE_PEER_TLS_ROOTCERT_FILE=${CRYPTO_INNER}/peerOrganizations/${DOMAIN}/peers/${PEER_HOST}/tls/ca.crt"
    -e "CORE_PEER_MSPCONFIGPATH=${CRYPTO_INNER}/peerOrganizations/${DOMAIN}/users/Admin@${DOMAIN}/msp"
  )
}

# ── Step 0: Vendor Go dependencies ───────────────────────────────────────────
vendor_chaincode() {
  local CC_NAME=$1
  local CC_HOST_PATH="${CHAINCODE_DIR}/${CC_NAME}"

  if [ -d "${CC_HOST_PATH}/vendor" ]; then
    log "  Vendor directory already exists for ${CC_NAME} — skipping"
    return 0
  fi

  log "  Vendoring ${CC_NAME} via sim_cli container..."
  docker exec sim_cli bash -c "cd /opt/gopath/src/github.com/chaincode/${CC_NAME} && go mod vendor" 2>&1
  log "  ✓ ${CC_NAME} vendored"
}

# ── Step 1: Package chaincode as CCaaS ────────────────────────────────────────
package_chaincode() {
  local CC_NAME=$1
  local PORT="${CC_PORT[$CC_NAME]}"
  local CC_LABEL="${CC_NAME}_${CC_VERSION}"
  local PKG_HOST_PATH="${NETWORK_DIR}/channel-artifacts/${CC_NAME}.tar.gz"

  log "  Packaging ${CC_NAME} as CCaaS (label: ${CC_LABEL}, port: ${PORT})..."

  local TMP_DIR
  TMP_DIR=$(mktemp -d)

  cat <<EOF > "${TMP_DIR}/connection.json"
{
  "address": "${CC_NAME}:${PORT}",
  "dial_timeout": "10s",
  "tls_required": false
}
EOF

  tar -czf "${TMP_DIR}/code.tar.gz" -C "${TMP_DIR}" connection.json

  cat <<EOF > "${TMP_DIR}/metadata.json"
{
  "type": "ccaas",
  "label": "${CC_LABEL}"
}
EOF

  tar -czf "${PKG_HOST_PATH}" -C "${TMP_DIR}" metadata.json code.tar.gz
  rm -rf "${TMP_DIR}"

  log "  ✓ ${CC_NAME} packaged as CCaaS → ${PKG_HOST_PATH}"
}

# ── Step 2: Install chaincode on all peers ────────────────────────────────────
install_chaincode() {
  local CC_NAME=$1
  local PKG_FILE="${ARTIFACTS_INNER}/${CC_NAME}.tar.gz"

  for ORG in "${ALL_ORGS[@]}"; do
    log "  Installing ${CC_NAME} on ${ORG} (${PEER_ADDRESS[$ORG]})..."
    set_cli_peer_env "${ORG}"
    docker exec "${CLI_ENV[@]}" "${CLI}" peer lifecycle chaincode install "${PKG_FILE}"
    log "  ✓ ${CC_NAME} installed on ${ORG}"
  done
}

# ── Step 3: Extract package ID ────────────────────────────────────────────────
get_package_id() {
  local CC_NAME=$1
  local CC_LABEL="${CC_NAME}_${CC_VERSION}"

  set_cli_peer_env "NCC"
  local PKG_ID
  PKG_ID=$(docker exec "${CLI_ENV[@]}" "${CLI}" peer lifecycle chaincode queryinstalled \
    --output json 2>/dev/null | \
    python3 -c "
import sys, json
data = json.load(sys.stdin)
for cc in data.get('installed_chaincodes', []):
  references = cc.get('references', {}).get('${CHANNEL_NAME}', {}).get('chaincodes', [])
  committed = any(item.get('name') == '${CC_NAME}' and item.get('version') == '${CC_VERSION}' for item in references)
  if cc.get('label') == '${CC_LABEL}' and committed:
        print(cc['package_id'])
        sys.exit(0)
sys.exit(1)
" 2>/dev/null)

  if [ -z "${PKG_ID}" ]; then
    error "Could not find package ID for ${CC_LABEL}"
  fi
  echo "${PKG_ID}"
}

is_committed() {
  local CC_NAME=$1

  set_cli_peer_env "NCC"
  docker exec "${CLI_ENV[@]}" "${CLI}" peer lifecycle chaincode querycommitted \
    --channelID "${CHANNEL_NAME}" 2>/dev/null | \
    grep -q "Name: ${CC_NAME},"
}

# ── Wait for CCaaS gRPC port ─────────────────────────────────────────────────
# Polls CC_NAME:PORT from inside sim_net (via a temporary Alpine container)
# until the TCP port accepts connections or the timeout expires.
# This replaces any fixed sleep and prevents smoke tests from firing before
# the chaincode gRPC server is actually listening.
wait_for_ccaas_port() {
  local CC_NAME=$1
  local PORT=$2
  local MAX_ATTEMPTS=60   # 60 × 2 s = up to 2 minutes
  log "  Waiting for ${CC_NAME}:${PORT} gRPC to be ready..."
  for i in $(seq 1 ${MAX_ATTEMPTS}); do
    if docker run --rm --network sim_net alpine \
         sh -c "nc -z ${CC_NAME} ${PORT}" 2>/dev/null; then
      log "  ✓ ${CC_NAME}:${PORT} ready (attempt ${i})"
      return 0
    fi
    sleep 2
  done
  log "  ERROR: ${CC_NAME}:${PORT} not ready after $((MAX_ATTEMPTS * 2))s — recent logs:"
  docker logs "${CC_NAME}" --tail 30 2>&1 || true
  exit 1
}

# ── Step 4: Start CCaaS Container ─────────────────────────────────────────────
start_ccaas_container() {
  local CC_NAME=$1
  local PKG_ID=$2
  local PORT="${CC_PORT[$CC_NAME]}"

  log "  Ensuring vendor directory for ${CC_NAME}..."
  vendor_chaincode "${CC_NAME}"

  log "  Starting CCaaS server container for ${CC_NAME} (port: ${PORT})..."
  docker rm -f "${CC_NAME}" 2>/dev/null || true
  docker run -d \
    --name "${CC_NAME}" \
    --network sim_net \
    -e CHAINCODE_SERVER_ADDRESS="0.0.0.0:${PORT}" \
    -e CHAINCODE_ID="${PKG_ID}" \
    -e CORE_CHAINCODE_ID_NAME="${PKG_ID}" \
    -v "${CHAINCODE_DIR}/${CC_NAME}:/opt/gopath/src/github.com/chaincode/${CC_NAME}" \
    -w "/opt/gopath/src/github.com/chaincode/${CC_NAME}" \
    hyperledger/fabric-ccenv:2.5 \
    go run -mod=vendor .

  # Block until the gRPC server is actually listening before proceeding.
  # go run compiles from source on every start — this can take 30-90 s.
  wait_for_ccaas_port "${CC_NAME}" "${PORT}"
}

# ── Step 5: Approve chaincode from all orgs ───────────────────────────────────
approve_chaincode() {
  local CC_NAME=$1
  local PKG_ID=$2
  local POLICY="${CC_POLICY[$CC_NAME]}"

  for ORG in "${ALL_ORGS[@]}"; do
    log "  Approving ${CC_NAME} for ${ORG} (${PEER_MSPID[$ORG]})..."
    set_cli_peer_env "${ORG}"
    docker exec "${CLI_ENV[@]}" "${CLI}" peer lifecycle chaincode approveformyorg \
      --channelID "${CHANNEL_NAME}" \
      --name "${CC_NAME}" \
      --version "${CC_VERSION}" \
      --package-id "${PKG_ID}" \
      --sequence "${CC_SEQUENCE}" \
      --signature-policy "${POLICY}" \
      --tls true \
      --cafile "${ORDERER_INNER}" \
      -o orderer.example.com:7050 \
      --waitForEvent
    log "  ✓ ${CC_NAME} approved by ${ORG}"
  done
}

# ── Step 6: Check commit readiness ────────────────────────────────────────────
check_commit_readiness() {
  local CC_NAME=$1
  local POLICY="${CC_POLICY[$CC_NAME]}"

  log "  Checking commit readiness for ${CC_NAME}..."
  set_cli_peer_env "NCC"
  docker exec "${CLI_ENV[@]}" "${CLI}" peer lifecycle chaincode checkcommitreadiness \
    --channelID "${CHANNEL_NAME}" \
    --name "${CC_NAME}" \
    --version "${CC_VERSION}" \
    --sequence "${CC_SEQUENCE}" \
    --signature-policy "${POLICY}" \
    --output json
}

# ── Step 7: Commit chaincode ─────────────────────────────────────────────────
commit_chaincode() {
  local CC_NAME=$1
  local POLICY="${CC_POLICY[$CC_NAME]}"

  log "  Committing ${CC_NAME} to channel ${CHANNEL_NAME}..."

  local PEER_CONN_PARAMS=()
  for ORG in "${ALL_ORGS[@]}"; do
    local DOMAIN="${PEER_DOMAIN[$ORG]}"
    local PEER_HOST="${PEER_ADDRESS[$ORG]%%:*}"
    PEER_CONN_PARAMS+=(
      --peerAddresses "${PEER_ADDRESS[$ORG]}"
      --tlsRootCertFiles "${CRYPTO_INNER}/peerOrganizations/${DOMAIN}/peers/${PEER_HOST}/tls/ca.crt"
    )
  done

  set_cli_peer_env "NCC"
  docker exec "${CLI_ENV[@]}" "${CLI}" peer lifecycle chaincode commit \
    --channelID "${CHANNEL_NAME}" \
    --name "${CC_NAME}" \
    --version "${CC_VERSION}" \
    --sequence "${CC_SEQUENCE}" \
    --signature-policy "${POLICY}" \
    --tls true \
    --cafile "${ORDERER_INNER}" \
    -o orderer.example.com:7050 \
    "${PEER_CONN_PARAMS[@]}"

  log "  ✓ ${CC_NAME} committed"
}

# ── Deploy a single chaincode (full lifecycle) ────────────────────────────────
deploy_one() {
  local CC_NAME=$1
  log ""
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "  Deploying (CCaaS): ${CC_NAME}"
  log "  Policy:            ${CC_POLICY[$CC_NAME]}"
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if is_committed "${CC_NAME}"; then
    log "  ${CC_NAME} is already committed; restoring its CCaaS service only."
    local PKG_ID
    PKG_ID=$(get_package_id "${CC_NAME}")
    start_ccaas_container "${CC_NAME}" "${PKG_ID}"
    return 0
  fi

  package_chaincode     "${CC_NAME}"
  install_chaincode     "${CC_NAME}"

  local PKG_ID
  PKG_ID=$(get_package_id "${CC_NAME}")
  log "  Package ID: ${PKG_ID}"

  start_ccaas_container  "${CC_NAME}" "${PKG_ID}"
  approve_chaincode      "${CC_NAME}" "${PKG_ID}"
  check_commit_readiness "${CC_NAME}"
  commit_chaincode       "${CC_NAME}"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  log "╔══════════════════════════════════════════════════════════════╗"
  log "║  Milestone 3 — Chaincode Deployment (CCaaS Lifecycle v2)    ║"
  log "║  Channel: ${CHANNEL_NAME}                                    ║"
  log "╚══════════════════════════════════════════════════════════════╝"

  if [ $# -gt 0 ]; then
    local TARGET="$1"
    if [ -z "${CC_POLICY[$TARGET]+x}" ]; then
      error "Unknown chaincode: ${TARGET}. Valid: ${CHAINCODES[*]}"
    fi
    deploy_one "${TARGET}"
  else
    for CC in "${CHAINCODES[@]}"; do
      deploy_one "${CC}"
    done
  fi

  log ""
  log "╔══════════════════════════════════════════════════════════════╗"
  log "║  All chaincodes deployed and committed!                      ║"
  log "║  Run: bash smokeTest.sh  to verify end-to-end.               ║"
  log "╚══════════════════════════════════════════════════════════════╝"
}

main "$@"
