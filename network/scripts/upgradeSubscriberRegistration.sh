#!/usr/bin/env bash
# network/scripts/upgradeSubscriberRegistration.sh
#
# Upgrades the subscriber-registration chaincode from v1.0 (sequence 1)
# to v2.0 (sequence 2) to activate the MaxRegistrationsPerOperator limit
# fix (Section 3.2.3, Addendum A of Milestone 3 report, 2026-08-10).
#
# This script:
#   1. Rebuilds the CCaaS package tarball with label subscriber-registration_2.0
#   2. Installs the new package on all 5 org peers
#   3. Extracts the new package ID
#   4. Restarts the CCaaS container bound to the new package ID
#   5. Approves the new version from all 5 orgs
#   6. Checks commit readiness (all orgs must show true)
#   7. Commits v2.0 / sequence 2 to sim-registration-channel
#   8. Runs the full 17-case smoke test suite
#
# Usage:
#   cd project/network/scripts
#   bash upgradeSubscriberRegistration.sh
#
# Prerequisites: network must be UP and v1.0 must already be committed.
# Chapter Three, Section 3.2.3 — Milestone 3, Addendum A.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

# ── Upgrade constants ─────────────────────────────────────────────────────────
CC_NAME="subscriber-registration"
CC_VERSION="2.0"
CC_SEQUENCE="2"
CC_PORT="9999"
CC_LABEL="${CC_NAME}_${CC_VERSION}"
CC_POLICY="AND('NCCMSP.peer', OR('MTNMSP.peer','AIRTELMSP.peer','GLOMSP.peer','NINEMOBILEMSP.peer'))"

# ── Container-internal paths ──────────────────────────────────────────────────
CLI="sim_cli"
CRYPTO_INNER="/opt/gopath/src/github.com/hyperledger/fabric/peer/crypto"
ARTIFACTS_INNER="/opt/gopath/src/github.com/hyperledger/fabric/peer/channel-artifacts"
ORDERER_INNER="${CRYPTO_INNER}/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem"

PKG_HOST_PATH="${NETWORK_DIR}/channel-artifacts/${CC_NAME}_v2.tar.gz"

# ── Wait for CCaaS gRPC port to be accepting connections ───────────────────────
# Polls inside sim_net via a temporary Alpine container (nc -z).
# go run -mod=vendor . recompiles from source on every start — typically
# 30-90 s on this host. A flat sleep is not reliable.
wait_for_ccaas_port() {
  local HOST=$1
  local PORT=$2
  local MAX_ATTEMPTS=60   # 60 × 2 s = up to 2 minutes
  log "   Polling ${HOST}:${PORT} for gRPC readiness..."
  for i in $(seq 1 ${MAX_ATTEMPTS}); do
    if docker run --rm --network sim_net alpine \
         sh -c "nc -z ${HOST} ${PORT}" 2>/dev/null; then
      log "   ✓ ${HOST}:${PORT} ready after $((i * 2))s"
      return 0
    fi
    sleep 2
  done
  log "   ERROR: ${HOST}:${PORT} not ready after $((MAX_ATTEMPTS * 2))s — recent container logs:"
  docker logs "${HOST}" --tail 30 2>&1 || true
  exit 1
}

# ── Helper: set CLI env for a given org ──────────────────────────────────────
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

# ════════════════════════════════════════════════════════════════════════════
log "╔══════════════════════════════════════════════════════════════╗"
log "║  subscriber-registration Upgrade: v1.0 → v2.0 (seq 1 → 2)  ║"
log "║  Fix: MaxRegistrationsPerOperator = 4 (Section 3.2.3)        ║"
log "╚══════════════════════════════════════════════════════════════╝"

# ── Step 1: Re-vendor source inside CLI container ────────────────────────────
log ""
log "── Step 1: Re-vendor Go modules ────────────────────────────────"
log "   Removing stale vendor dir (may be root-owned from prior build)..."
docker run --rm \
  -v "${CHAINCODE_DIR}/${CC_NAME}:/chaincode" \
  alpine rm -rf /chaincode/vendor || true

log "   Running go mod vendor inside sim_cli..."
docker exec sim_cli bash -c \
  "cd /opt/gopath/src/github.com/chaincode/${CC_NAME} && go mod vendor"
log "   ✓ Vendoring complete"

# ── Step 2: Package new CCaaS tarball (label = subscriber-registration_2.0) ──
log ""
log "── Step 2: Package CCaaS tarball (label: ${CC_LABEL}) ──────────"

TMP_DIR=$(mktemp -d)

cat > "${TMP_DIR}/connection.json" <<EOF
{
  "address": "${CC_NAME}:${CC_PORT}",
  "dial_timeout": "10s",
  "tls_required": false
}
EOF

tar -czf "${TMP_DIR}/code.tar.gz" -C "${TMP_DIR}" connection.json

cat > "${TMP_DIR}/metadata.json" <<EOF
{
  "type": "ccaas",
  "label": "${CC_LABEL}"
}
EOF

tar -czf "${PKG_HOST_PATH}" -C "${TMP_DIR}" metadata.json code.tar.gz
rm -rf "${TMP_DIR}"
log "   ✓ Package written → ${PKG_HOST_PATH}"

# ── Step 3: Install on all 5 org peers ───────────────────────────────────────
log ""
log "── Step 3: Install ${CC_LABEL} on all 5 peers ──────────────────"

PKG_FILE_INNER="${ARTIFACTS_INNER}/${CC_NAME}_v2.tar.gz"
for ORG in "${ALL_ORGS[@]}"; do
  log "   Installing on ${ORG} (${PEER_ADDRESS[$ORG]})..."
  set_cli_peer_env "${ORG}"
  docker exec "${CLI_ENV[@]}" "${CLI}" peer lifecycle chaincode install "${PKG_FILE_INNER}"
  log "   ✓ Installed on ${ORG}"
done

# ── Step 4: Extract new package ID ───────────────────────────────────────────
log ""
log "── Step 4: Extract package ID for ${CC_LABEL} ──────────────────"

set_cli_peer_env "NCC"
PKG_ID=$(docker exec "${CLI_ENV[@]}" "${CLI}" peer lifecycle chaincode queryinstalled \
  --output json 2>/dev/null | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
for cc in data.get('installed_chaincodes', []):
    if cc.get('label') == '${CC_LABEL}':
        print(cc['package_id'])
        sys.exit(0)
sys.exit(1)
" 2>/dev/null)

if [ -z "${PKG_ID}" ]; then
  log "ERROR: Could not find package ID for ${CC_LABEL}. Aborting."
  exit 1
fi
log "   ✓ Package ID: ${PKG_ID}"

# ── Step 5: Restart CCaaS container bound to new package ID ─────────────────
log ""
log "── Step 5: Restart CCaaS container → ${CC_NAME} ────────────────"

docker rm -f "${CC_NAME}" 2>/dev/null || true

docker run -d \
  --name "${CC_NAME}" \
  --network sim_net \
  -e CHAINCODE_SERVER_ADDRESS="0.0.0.0:${CC_PORT}" \
  -e CHAINCODE_ID="${PKG_ID}" \
  -e CORE_CHAINCODE_ID_NAME="${PKG_ID}" \
  -v "${CHAINCODE_DIR}/${CC_NAME}:/opt/gopath/src/github.com/chaincode/${CC_NAME}" \
  -w "/opt/gopath/src/github.com/chaincode/${CC_NAME}" \
  hyperledger/fabric-ccenv:2.5 \
  go run -mod=vendor .


  # Block until the gRPC server is actually listening.
  # go run compiles from source on every start — this can take 30-90 s.
  wait_for_ccaas_port "${CC_NAME}" "${CC_PORT}"


# ── Step 6: Approve from all 5 orgs ─────────────────────────────────────────
log ""
log "── Step 6: Approve v${CC_VERSION} / seq ${CC_SEQUENCE} from all orgs ─────────────"

for ORG in "${ALL_ORGS[@]}"; do
  log "   Approving for ${ORG} (${PEER_MSPID[$ORG]})..."
  set_cli_peer_env "${ORG}"
  docker exec "${CLI_ENV[@]}" "${CLI}" peer lifecycle chaincode approveformyorg \
    --channelID "${CHANNEL_NAME}" \
    --name "${CC_NAME}" \
    --version "${CC_VERSION}" \
    --package-id "${PKG_ID}" \
    --sequence "${CC_SEQUENCE}" \
    --signature-policy "${CC_POLICY}" \
    --tls true \
    --cafile "${ORDERER_INNER}" \
    -o orderer.example.com:7050 \
    --waitForEvent
  log "   ✓ Approved by ${ORG}"
done

# ── Step 7: Check commit readiness (all 5 orgs must show true) ───────────────
log ""
log "── Step 7: Check commit readiness ──────────────────────────────"

set_cli_peer_env "NCC"
READINESS=$(docker exec "${CLI_ENV[@]}" "${CLI}" peer lifecycle chaincode checkcommitreadiness \
  --channelID "${CHANNEL_NAME}" \
  --name "${CC_NAME}" \
  --version "${CC_VERSION}" \
  --sequence "${CC_SEQUENCE}" \
  --signature-policy "${CC_POLICY}" \
  --output json)

log "   Readiness JSON:"
echo "${READINESS}" | python3 -m json.tool || echo "${READINESS}"

# Fail fast if any org is not ready
if echo "${READINESS}" | grep -q '"false"'; then
  log "ERROR: Not all orgs have approved — cannot commit. Check readiness output above."
  exit 1
fi
log "   ✓ All orgs ready"

# ── Step 8: Commit v2.0 / sequence 2 ─────────────────────────────────────────
log ""
log "── Step 8: Commit ${CC_NAME} v${CC_VERSION} seq ${CC_SEQUENCE} to channel ─────────"

PEER_CONN_PARAMS=()
for ORG in "${ALL_ORGS[@]}"; do
  DOMAIN="${PEER_DOMAIN[$ORG]}"
  PEER_HOST="${PEER_ADDRESS[$ORG]%%:*}"
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
  --signature-policy "${CC_POLICY}" \
  --tls true \
  --cafile "${ORDERER_INNER}" \
  -o orderer.example.com:7050 \
  "${PEER_CONN_PARAMS[@]}"

log "   ✓ ${CC_NAME} v${CC_VERSION} committed to ${CHANNEL_NAME}"

# ── Step 9: Verify committed version ─────────────────────────────────────────
log ""
log "── Step 9: Verify committed definition ─────────────────────────"

set_cli_peer_env "NCC"
docker exec "${CLI_ENV[@]}" "${CLI}" peer lifecycle chaincode querycommitted \
  --channelID "${CHANNEL_NAME}" \
  --name "${CC_NAME}" \
  --output json | python3 -m json.tool || true

# ── Step 10: Run full 17-case smoke test suite ────────────────────────────────
log ""
log "── Step 10: Running smoke test suite (17 cases) ────────────────"
bash "${SCRIPT_DIR}/smokeTest.sh"

log ""
log "╔══════════════════════════════════════════════════════════════╗"
log "║  Upgrade complete: subscriber-registration v2.0 active       ║"
log "║  MaxRegistrationsPerOperator limit is now enforced on-chain. ║"
log "╚══════════════════════════════════════════════════════════════╝"
