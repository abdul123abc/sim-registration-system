#!/usr/bin/env bash
# network/scripts/createChannel.sh
# Creates SIM_REGISTRATION_CHANNEL using the Fabric 2.5 channel participation API.
# Uses osnadmin INSIDE the CLI container (Docker DNS resolves orderer.example.com).
# Then joins all peers and sets anchor peers.
# Chapter Three, Section 3.4.

set -euo pipefail

CHANNEL_NAME="sim-registration-channel"
CRYPTO_INNER="/opt/gopath/src/github.com/hyperledger/fabric/peer/crypto"
ARTIFACTS_INNER="/opt/gopath/src/github.com/hyperledger/fabric/peer/channel-artifacts"

echo "[$(date '+%H:%M:%S')] === Joining orderer to channel ${CHANNEL_NAME} via osnadmin ==="

# osnadmin exits 0 even on HTTP 4xx/5xx — capture output and check for error field.
OSNADMIN_OUT=$(docker exec sim_cli osnadmin channel join \
  --channelID "${CHANNEL_NAME}" \
  --config-block "${ARTIFACTS_INNER}/${CHANNEL_NAME}.block" \
  -o "orderer.example.com:7053" \
  --ca-file "${CRYPTO_INNER}/ordererOrganizations/example.com/orderers/orderer.example.com/tls/ca.crt" \
  --client-cert "${CRYPTO_INNER}/ordererOrganizations/example.com/orderers/orderer.example.com/tls/server.crt" \
  --client-key "${CRYPTO_INNER}/ordererOrganizations/example.com/orderers/orderer.example.com/tls/server.key" 2>&1)

echo "${OSNADMIN_OUT}"
if echo "${OSNADMIN_OUT}" | grep -q '"error"'; then
  echo "[ERROR] osnadmin returned an error — aborting." >&2
  exit 1
fi

echo "[$(date '+%H:%M:%S')] === Orderer joined channel. Joining peers... ==="
docker exec sim_cli bash /opt/gopath/src/github.com/hyperledger/fabric/peer/scripts/joinChannel.sh

echo "[$(date '+%H:%M:%S')] === Verifying channel membership across all 5 peer nodes... ==="
bash "$(dirname "${BASH_SOURCE[0]}")/verify_channel_peers.sh"

echo "[$(date '+%H:%M:%S')] === createChannel.sh complete ==="
