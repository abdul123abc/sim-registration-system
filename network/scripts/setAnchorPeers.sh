#!/usr/bin/env bash
# network/scripts/setAnchorPeers.sh
# Sets anchor peers for all organisations on SIM_REGISTRATION_CHANNEL.
# Designed to run INSIDE the sim_cli Docker container.
# Chapter Three, Section 3.4.

set -euo pipefail

CHANNEL_NAME="sim-registration-channel"
CRYPTO="/opt/gopath/src/github.com/hyperledger/fabric/peer/crypto"
CHANNEL_ARTIFACTS="/opt/gopath/src/github.com/hyperledger/fabric/peer/channel-artifacts"
ORDERER_CA="${CRYPTO}/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem"
ORDERER_ADDRESS="orderer.example.com:7050"

declare -A ORGS=(
  [NCC]="NCCMSP ncc.example.com peer0.ncc.example.com 7051"
  [MTN]="MTNMSP mno1.example.com peer0.mno1.example.com 8051"
  [Airtel]="AIRTELMSP mno2.example.com peer0.mno2.example.com 9051"
  [Glo]="GLOMSP mno3.example.com peer0.mno3.example.com 10051"
  [NineMobile]="NINEMOBILEMSP mno4.example.com peer0.mno4.example.com 11051"
)

echo "[$(date '+%H:%M:%S')] === Setting anchor peers ==="

for ORG in NCC MTN Airtel Glo NineMobile; do
  read -r MSPID DOMAIN PEER_HOST PORT <<< "${ORGS[$ORG]}"
  ANCHOR_TX="${CHANNEL_ARTIFACTS}/${MSPID}anchors.tx"

  if [ ! -f "${ANCHOR_TX}" ]; then
    echo "[ERROR] Anchor tx not found: ${ANCHOR_TX}" >&2; exit 1
  fi

  echo "[$(date '+%H:%M:%S')]   Setting anchor for ${ORG} (${MSPID})..."

  CORE_PEER_LOCALMSPID="${MSPID}" \
  CORE_PEER_ADDRESS="${PEER_HOST}:${PORT}" \
  CORE_PEER_TLS_ROOTCERT_FILE="${CRYPTO}/peerOrganizations/${DOMAIN}/peers/${PEER_HOST}/tls/ca.crt" \
  CORE_PEER_MSPCONFIGPATH="${CRYPTO}/peerOrganizations/${DOMAIN}/users/Admin@${DOMAIN}/msp" \
  peer channel update \
    -o "${ORDERER_ADDRESS}" \
    -c "${CHANNEL_NAME}" \
    -f "${ANCHOR_TX}" \
    --tls \
    --cafile "${ORDERER_CA}"

  echo "[$(date '+%H:%M:%S')]   ✓ Anchor set for ${ORG}"
done

echo "[$(date '+%H:%M:%S')] === setAnchorPeers.sh complete ==="
