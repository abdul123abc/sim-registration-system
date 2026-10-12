#!/usr/bin/env bash
# network/scripts/createChannel.sh
# Creates SIM_REGISTRATION_CHANNEL using the Fabric 2.5 channel participation API.
# Uses osnadmin INSIDE the CLI container (Docker DNS resolves orderer.example.com).
# Then joins all peers and sets anchor peers.
# Chapter Three, Section 3.4.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANNEL_NAME="sim-registration-channel"
CRYPTO_INNER="/opt/gopath/src/github.com/hyperledger/fabric/peer/crypto"
ARTIFACTS_INNER="/opt/gopath/src/github.com/hyperledger/fabric/peer/channel-artifacts"
CHANNEL_BLOCK_HOST="${SCRIPT_DIR}/../channel-artifacts/${CHANNEL_NAME}.block"

echo "[$(date '+%H:%M:%S')] === Joining orderer to channel ${CHANNEL_NAME} via osnadmin ==="

ORDERER_CHANNELS=$(docker exec sim_cli osnadmin channel list \
  -o "orderer.example.com:7053" \
  --ca-file "${CRYPTO_INNER}/ordererOrganizations/example.com/orderers/orderer.example.com/tls/ca.crt" \
  --client-cert "${CRYPTO_INNER}/ordererOrganizations/example.com/orderers/orderer.example.com/tls/server.crt" \
  --client-key "${CRYPTO_INNER}/ordererOrganizations/example.com/orderers/orderer.example.com/tls/server.key" \
  --no-status 2>&1) || {
    echo "${ORDERER_CHANNELS}" >&2
    echo "[ERROR] Could not query orderer channel participation." >&2
    exit 1
  }

if ! ORDERER_HAS_CHANNEL=$(printf '%s\n' "${ORDERER_CHANNELS}" | python3 -c "
import json, sys
try:
    response = json.load(sys.stdin)
except (json.JSONDecodeError, AttributeError) as error:
    print(f'Invalid osnadmin channel-list response: {error}', file=sys.stderr)
    sys.exit(2)
if not isinstance(response, dict):
    print('Invalid osnadmin channel-list response: expected a JSON object', file=sys.stderr)
    sys.exit(2)
channels = response.get('channels') or []
if not isinstance(channels, list):
    print('Invalid osnadmin channel-list response: channels must be a list or null', file=sys.stderr)
    sys.exit(2)
print('yes' if any(channel.get('name') == '${CHANNEL_NAME}' for channel in channels) else 'no')
" 2>&1); then
  echo "${ORDERER_HAS_CHANNEL}" >&2
  exit 1
fi
if [ "${ORDERER_HAS_CHANNEL}" != yes ] && [ "${ORDERER_HAS_CHANNEL}" != no ]; then
  echo "[ERROR] Unexpected orderer channel query result: ${ORDERER_HAS_CHANNEL}" >&2
  exit 1
fi

if [ "${ORDERER_HAS_CHANNEL}" = yes ]; then
  echo "[$(date '+%H:%M:%S')]   Orderer already has channel ${CHANNEL_NAME}; skipping join."
else
  if [ ! -s "${CHANNEL_BLOCK_HOST}" ]; then
    echo "[ERROR] Channel block is missing or empty on the host: ${CHANNEL_BLOCK_HOST}" >&2
    exit 1
  fi
  OSNADMIN_OUT=$(docker exec sim_cli osnadmin channel join \
    --channelID "${CHANNEL_NAME}" \
    --config-block "${ARTIFACTS_INNER}/${CHANNEL_NAME}.block" \
    -o "orderer.example.com:7053" \
    --ca-file "${CRYPTO_INNER}/ordererOrganizations/example.com/orderers/orderer.example.com/tls/ca.crt" \
    --client-cert "${CRYPTO_INNER}/ordererOrganizations/example.com/orderers/orderer.example.com/tls/server.crt" \
    --client-key "${CRYPTO_INNER}/ordererOrganizations/example.com/orderers/orderer.example.com/tls/server.key" 2>&1) || {
      echo "${OSNADMIN_OUT}" >&2
      echo "[ERROR] Could not join orderer to channel ${CHANNEL_NAME}." >&2
      exit 1
    }
  echo "${OSNADMIN_OUT}"
  if echo "${OSNADMIN_OUT}" | grep -q '"error"'; then
    echo "[ERROR] osnadmin returned an error — aborting." >&2
    exit 1
  fi
fi

echo "[$(date '+%H:%M:%S')] === Ensuring peers have joined channel... ==="
docker exec sim_cli bash /opt/gopath/src/github.com/hyperledger/fabric/peer/scripts/joinChannel.sh

echo "[$(date '+%H:%M:%S')] === Verifying channel membership across all 5 peer nodes... ==="
bash "$(dirname "${BASH_SOURCE[0]}")/verify_channel_peers.sh"

echo "[$(date '+%H:%M:%S')] === createChannel.sh complete ==="
