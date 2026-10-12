#!/usr/bin/env bash
# network/scripts/network.sh
# Master network control script.
# Usage:
#   ./network.sh up       — generate certs, start Docker, create+join channel
#   ./network.sh down     — stop Docker, clean all volumes and artefacts
#   ./network.sh restart  — down then up
#   ./network.sh status   — show running containers
#   ./network.sh deploy   — deploy all 4 chaincodes (Fabric Lifecycle v2)
#   ./network.sh test     — run smoke tests on all chaincodes
#
# Chapter Three, Section 3.4.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NETWORK_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${NETWORK_DIR}/docker/docker-compose.yaml"

source "${SCRIPT_DIR}/utils.sh"

# ── Helpers ───────────────────────────────────────────────────────────────────

check_prereqs() {
  log "Checking prerequisites..."
  for cmd in docker cryptogen configtxgen; do
    if ! command -v "${cmd}" &>/dev/null; then
      error "'${cmd}' not found. Install Hyperledger Fabric binaries and Docker."
    fi
  done
  # Check for docker compose (plugin) or docker-compose (standalone)
  if ! docker compose version &>/dev/null 2>&1 && ! command -v docker-compose &>/dev/null; then
    error "Neither 'docker compose' plugin nor 'docker-compose' found. Install Docker Compose."
  fi
  log "  All prerequisites found. Using: ${DOCKER_COMPOSE}"
}

network_up() {
  check_prereqs

  log "=== Step 1: Generating crypto material and channel artefacts ==="
  bash "${SCRIPT_DIR}/generate.sh"

  log "=== Step 2: Starting Docker containers (force-recreate to pick up fresh crypto) ==="
  ${DOCKER_COMPOSE} \
    --env-file "${NETWORK_DIR}/docker/.env" \
    -f "${COMPOSE_FILE}" \
    up -d --force-recreate

  log "  Waiting 10 s for peers and orderer to fully initialise..."
  sleep 10

  log "=== Step 3: Creating channel, joining peers, setting anchor peers ==="
  # createChannel.sh runs on the HOST — it calls 'docker exec sim_cli osnadmin/peer' internally.
  # Do NOT wrap it in 'docker exec sim_cli bash ...' (that would nest docker exec inside a container).
  bash "${SCRIPT_DIR}/createChannel.sh"

  log ""
  log "╔══════════════════════════════════════════════════════════════╗"
  log "║  SIM Blockchain network is UP                                ║"
  log "║  Channel: sim-registration-channel                           ║"
  log "║  Peers:   NCC (7051) MTN (8051) Airtel (9051)               ║"
  log "║           Glo (10051) NineMobile (11051)                     ║"
  log "╚══════════════════════════════════════════════════════════════╝"
}

network_ensure_channel() {
  check_prereqs

  if [ ! -d "${NETWORK_DIR}/crypto-config/peerOrganizations" ] || \
     [ ! -d "${NETWORK_DIR}/crypto-config/ordererOrganizations" ]; then
    error "Existing Fabric crypto material is incomplete. Refusing to regenerate identities automatically because that could invalidate existing ledger data."
  fi

  local ARTIFACTS_DIR="${NETWORK_DIR}/channel-artifacts"
  if [ ! -s "${ARTIFACTS_DIR}/${CHANNEL_NAME}.block" ]; then
    error "Channel block is missing on the host: ${ARTIFACTS_DIR}/${CHANNEL_NAME}.block. Refusing to generate a new genesis block that might not match the existing ledger."
  fi

  local ORG
  local MSP_ID
  local -A ANCHOR_MSP=(
    [NCC]="NCCMSP"
    [MTN]="MTNMSP"
    [Airtel]="AIRTELMSP"
    [Glo]="GLOMSP"
    [NineMobile]="NINEMOBILEMSP"
  )
  for ORG in NCC MTN Airtel Glo NineMobile; do
    MSP_ID="${ANCHOR_MSP[$ORG]}"
    if [ ! -s "${ARTIFACTS_DIR}/${MSP_ID}anchors.tx" ]; then
      log "Anchor update for ${MSP_ID} is missing; generating it."
      configtxgen \
        -profile SimRegistrationChannel \
        -outputAnchorPeersUpdate "${ARTIFACTS_DIR}/${MSP_ID}anchors.tx" \
        -channelID "${CHANNEL_NAME}" \
        -asOrg "${MSP_ID}"
    fi
  done

  if [ ! -s "${ARTIFACTS_DIR}/${CHANNEL_NAME}.block" ]; then
    error "Failed to generate channel block ${ARTIFACTS_DIR}/${CHANNEL_NAME}.block"
  fi

  if ! docker network inspect sim_net >/dev/null 2>&1; then
    docker network create sim_net >/dev/null
  fi

  log "=== Starting Fabric services and repairing channel membership if needed ==="
  ${DOCKER_COMPOSE} \
    --env-file "${NETWORK_DIR}/docker/.env" \
    -f "${COMPOSE_FILE}" \
    up -d
  ${DOCKER_COMPOSE} \
    --env-file "${NETWORK_DIR}/docker/.env" \
    -f "${COMPOSE_FILE}" \
    up -d --force-recreate cli

  local DEADLINE=$((SECONDS + 120))
  local ORDERER_STATE
  local ORDERER_READY=false
  while (( SECONDS < DEADLINE )); do
    ORDERER_STATE=$(docker inspect --format '{{.State.Status}}' orderer.example.com 2>/dev/null || printf 'unknown')
    if [ "${ORDERER_STATE}" = exited ] || [ "${ORDERER_STATE}" = dead ]; then
      log "ERROR: Orderer stopped before channel recovery (state: ${ORDERER_STATE}); recent logs:"
      docker logs orderer.example.com --tail 80 2>&1 || true
      return 1
    fi
    if [ "${ORDERER_STATE}" = running ] && docker exec sim_cli timeout 3 bash -c \
      'echo > "/dev/tcp/orderer.example.com/7053"' >/dev/null 2>&1; then
      ORDERER_READY=true
      break
    fi
    sleep 2
  done

  if [ "${ORDERER_READY}" != true ]; then
    log "ERROR: Orderer admin endpoint orderer.example.com:7053 did not become ready."
    docker logs orderer.example.com --tail 80 2>&1 || true
    return 1
  fi

  bash "${SCRIPT_DIR}/createChannel.sh"
}

network_down() {
  log "=== Stopping Docker containers ==="
  ${DOCKER_COMPOSE} \
    --env-file "${NETWORK_DIR}/docker/.env" \
    -f "${COMPOSE_FILE}" \
    down --volumes --remove-orphans 2>/dev/null || true

  log "=== Cleaning artefacts ==="
  rm -rf "${NETWORK_DIR}/crypto-config" "${NETWORK_DIR}/channel-artifacts"

  log "=== Removing chaincode Docker images ==="
  docker rmi $(docker images 'dev-peer*' -q) 2>/dev/null || true

  log "Network is DOWN."
}

network_status() {
  ${DOCKER_COMPOSE} \
    --env-file "${NETWORK_DIR}/docker/.env" \
    -f "${COMPOSE_FILE}" \
    ps
}

network_deploy() {
  network_ensure_channel
  log "=== Deploying chaincodes (Fabric Lifecycle v2) ==="
  bash "${SCRIPT_DIR}/deployChaincode.sh" "$@"
}

network_test() {
  log "=== Running chaincode smoke tests ==="
  bash "${SCRIPT_DIR}/smokeTest.sh"
}

# ── Entry point ───────────────────────────────────────────────────────────────

MODE="${1:-help}"
shift || true
case "${MODE}" in
  up)      network_up ;;
  ensure-channel) network_ensure_channel ;;
  down)    network_down ;;
  restart) network_down; network_up ;;
  status)  network_status ;;
  deploy)  network_deploy "$@" ;;
  test)    network_test ;;
  *)
    echo "Usage: $0 {up|ensure-channel|down|restart|status|deploy|test}"
    exit 1
    ;;
esac
