#!/usr/bin/env bash
# project/network/scripts/clean_and_deploy.sh
# Automates the entire process of cleaning up dead docker artifacts,
# resetting the network, and deploying the chaincode with custom timeouts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NETWORK_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() {
  echo -e "\033[1;32m[$(date +'%T')]\033[0m $1"
}

log "=== Stopping network and cleaning up ==="
bash "${SCRIPT_DIR}/network.sh" down || true

log "=== Removing leftover/dead builder & CCaaS containers ==="
docker rm -f subscriber-registration identity-validation update-tracking access-control 2>/dev/null || true
DEAD_CONTAINERS=$(docker ps -a -q -f status=exited -f status=dead -f status=created)
if [ -n "${DEAD_CONTAINERS}" ]; then
  docker rm -f ${DEAD_CONTAINERS} || true
fi

log "=== Cleaning up existing vendor folders to force fresh vendoring ==="
# Since vendor directories were created by root inside the container, we use a temporary root-owned container to clean them up.
docker run --rm -v "${NETWORK_DIR}/../chaincode:/chaincode" alpine rm -rf \
  /chaincode/subscriber-registration/vendor \
  /chaincode/identity-validation/vendor \
  /chaincode/update-tracking/vendor \
  /chaincode/access-control/vendor || true


log "=== Pruning Docker builder cache to free disk space ==="
docker builder prune -af || true
docker system prune -f || true

log "=== Starting Hyperledger Fabric network ==="
bash "${SCRIPT_DIR}/network.sh" up

log "=== Deploying all 4 chaincodes ==="
# This will run the updated deployChaincode.sh with the 20-minute build timeout
bash "${SCRIPT_DIR}/deployChaincode.sh"

log "=== Running smoke tests ==="
bash "${SCRIPT_DIR}/smokeTest.sh"
