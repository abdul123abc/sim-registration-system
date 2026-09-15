#!/usr/bin/env bash
# Master QA gate for the running Docker deployment.
# This script is intentionally non-destructive: it creates one unique test
# registration and does not stop, reset, or remove any project containers.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
API_BASE="${API_BASE:-http://localhost:3001}"
FRONTEND_BASE="${FRONTEND_BASE:-http://localhost:3000}"
IPFS_BASE="${IPFS_BASE:-http://localhost:5001}"
NETWORK_NAME="${NETWORK_NAME:-sim_net}"
TEST_DIR="$(mktemp -d)"
PASSED=0
FAILED=0
WARNED=0

cleanup() {
  rm -rf "${TEST_DIR}"
}
trap cleanup EXIT

pass() {
  PASSED=$((PASSED + 1))
  printf '  PASS  %s\n' "$1"
}

fail() {
  FAILED=$((FAILED + 1))
  printf '  FAIL  %s\n' "$1"
}

warn() {
  WARNED=$((WARNED + 1))
  printf '  WARN  %s\n' "$1"
}

section() {
  printf '\n== %s ==\n' "$1"
}

http_status() {
  curl -sS --max-time 20 -o "$1.body" -w '%{http_code}' "$2" 2>"$1.error"
}

require_command() {
  if command -v "$1" >/dev/null 2>&1; then
    pass "Command available: $1"
  else
    fail "Required command missing: $1"
  fi
}

is_running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" = "true" ]
}

printf '%s\n' '============================================================'
printf '%s\n' ' Master QA Suite — Privacy-Preserving SIM Registration'
printf '%s\n' '============================================================'
printf 'Project: %s\nAPI: %s\n' "${PROJECT_DIR}" "${API_BASE}"

section '1. Tooling and Docker prerequisites'
for command_name in docker curl; do
  require_command "${command_name}"
done

if docker info >/dev/null 2>&1; then
  pass 'Docker daemon is reachable'
else
  fail 'Docker daemon is not reachable'
fi

if docker compose version >/dev/null 2>&1; then
  pass 'Docker Compose v2 is available'
else
  fail 'Docker Compose v2 is unavailable'
fi

section '2. Compose and shared-network configuration'
if docker compose -f "${PROJECT_DIR}/docker-compose.yml" config >/dev/null 2>&1; then
  pass 'Application Compose configuration is valid'
else
  fail 'Application Compose configuration is invalid'
fi

if docker compose -f "${PROJECT_DIR}/network/docker/docker-compose.yaml" config >/dev/null 2>&1; then
  pass 'Fabric Compose configuration is valid'
else
  fail 'Fabric Compose configuration is invalid'
fi

if docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
  pass "Shared Docker network exists: ${NETWORK_NAME}"
else
  fail "Shared Docker network is missing: ${NETWORK_NAME}"
fi

section '3. Required running containers'
required_containers=(
  ipfs
  sim-backend
  sim-frontend
  orderer.example.com
  peer0.ncc.example.com
  peer0.mno1.example.com
  peer0.mno2.example.com
  peer0.mno3.example.com
  peer0.mno4.example.com
  subscriber-registration
  identity-validation
  update-tracking
  access-control
)

for container in "${required_containers[@]}"; do
  if is_running "${container}"; then
    pass "Container running: ${container}"
  else
    fail "Container not running: ${container}"
  fi
done

section '4. ZK artifacts and IPFS readiness'
zk_files=(
  "${PROJECT_DIR}/zk/build/nin_commitment_js/nin_commitment.wasm"
  "${PROJECT_DIR}/zk/build/nin_commitment_final.zkey"
  "${PROJECT_DIR}/zk/build/verification_key.json"
)
for artifact in "${zk_files[@]}"; do
  if [ -s "${artifact}" ]; then
    pass "ZK artifact present: ${artifact#"${PROJECT_DIR}/"}"
  else
    fail "ZK artifact missing or empty: ${artifact#"${PROJECT_DIR}/"}"
  fi
done

ipfs_status=$(curl -sS --max-time 20 -o "${TEST_DIR}/ipfs.body" -w '%{http_code}' \
  -X POST "${IPFS_BASE}/api/v0/id" 2>"${TEST_DIR}/ipfs.error")
if [ "${ipfs_status}" = '200' ]; then
  pass 'IPFS Kubo API is reachable'
else
  fail "IPFS Kubo API returned HTTP ${ipfs_status}"
fi

section '5. Application endpoints'
frontend_status=$(http_status "${TEST_DIR}/frontend" "${FRONTEND_BASE}/")
if [ "${frontend_status}" = '200' ]; then
  pass 'Frontend responds with HTTP 200'
else
  fail "Frontend returned HTTP ${frontend_status}"
fi

health_status=$(http_status "${TEST_DIR}/health" "${API_BASE}/health")
if [ "${health_status}" = '200' ]; then
  pass 'Backend health endpoint responds with HTTP 200'
else
  fail "Backend health endpoint returned HTTP ${health_status}"
fi

if grep -q '"status":"ok"' "${TEST_DIR}/health.body"; then
  pass 'Backend health reports OK'
elif grep -q '"status":"degraded"' "${TEST_DIR}/health.body"; then
  warn 'Backend health reports degraded; inspect its Fabric reachability fields'
else
  fail 'Backend health response has no recognized status'
fi

section '6. Fabric service discovery'
ccaas_services=(
  'subscriber-registration:9999'
  'identity-validation:9998'
  'update-tracking:9997'
  'access-control:9996'
)
for service_spec in "${ccaas_services[@]}"; do
  service="${service_spec%%:*}"
  port="${service_spec##*:}"
  if docker run --rm --network "${NETWORK_NAME}" alpine sh -c "nc -z -w 3 ${service} ${port}" >/dev/null 2>&1; then
    pass "CCaaS service reachable on ${NETWORK_NAME}: ${service}:${port}"
  else
    fail "CCaaS service is not reachable on ${NETWORK_NAME}: ${service}:${port}"
  fi
done

section '7. End-to-end registration, ledger query, audit, and IPFS pin'
timestamp="$(date +%s%N)"
test_nin="991${timestamp: -11}"
test_fingerprint="$(printf '%s' "qa-fingerprint-${timestamp}" | sha256sum | awk '{print $1}')"
test_msisdn="2348${timestamp: -9}"
registration_payload=$(printf '{"nin":"%s","fingerprintHash":"%s","msisdn":"%s","mno":"MTN"}' \
  "${test_nin}" "${test_fingerprint}" "${test_msisdn}")

registration_status=$(curl -sS --max-time 180 -o "${TEST_DIR}/registration.body" -w '%{http_code}' \
  -X POST "${API_BASE}/api/registration/register" \
  -H 'Content-Type: application/json' \
  -d "${registration_payload}" 2>"${TEST_DIR}/registration.error")

subscriber_id=$(sed -n 's/.*"subscriberID":"\([^"]*\)".*/\1/p' "${TEST_DIR}/registration.body")
ipfs_cid=$(sed -n 's/.*"ipfsHash":"\([^"]*\)".*/\1/p' "${TEST_DIR}/registration.body")
commitment=$(sed -n 's/.*"commitment":"\([^"]*\)".*/\1/p' "${TEST_DIR}/registration.body")

if [ "${registration_status}" = '201' ] && [ -n "${subscriber_id}" ] && [ -n "${commitment}" ] && [ -n "${ipfs_cid}" ]; then
  pass "Registration completed with HTTP 201: ${subscriber_id}"
else
  fail "Registration failed with HTTP ${registration_status}: $(tr '\n' ' ' < "${TEST_DIR}/registration.body" | cut -c1-240)"
fi

if [ -n "${subscriber_id}" ]; then
  query_status=$(http_status "${TEST_DIR}/query" "${API_BASE}/api/registration/${subscriber_id}")
  if [ "${query_status}" = '200' ] && grep -q "${subscriber_id}" "${TEST_DIR}/query.body"; then
    pass 'Registered subscriber can be queried from the ledger'
  else
    fail "Subscriber query failed with HTTP ${query_status}"
  fi

  audit_status=$(http_status "${TEST_DIR}/audit" "${API_BASE}/api/audit/${subscriber_id}")
  if [ "${audit_status}" = '200' ] && grep -q 'REGISTERED' "${TEST_DIR}/audit.body"; then
    pass 'Registration audit event is available'
  else
    fail "Audit query failed with HTTP ${audit_status}"
  fi
fi

if [ -n "${ipfs_cid}" ]; then
  pin_status=$(curl -sS --max-time 20 -o "${TEST_DIR}/pin.body" -w '%{http_code}' \
    -X POST "${IPFS_BASE}/api/v0/pin/ls?arg=${ipfs_cid}" 2>"${TEST_DIR}/pin.error")
  if [ "${pin_status}" = '200' ] && grep -q "${ipfs_cid}" "${TEST_DIR}/pin.body"; then
    pass "Returned IPFS CID is pinned: ${ipfs_cid}"
  else
    fail "Returned IPFS CID is not pinned: ${ipfs_cid}"
  fi
fi

section '8. Final result'
printf 'Passed: %s\nWarnings: %s\nFailed: %s\n' "${PASSED}" "${WARNED}" "${FAILED}"

if [ "${FAILED}" -gt 0 ]; then
  printf '%s\n' 'MASTER QA RESULT: FAILED'
  exit 1
fi

printf '%s\n' 'MASTER QA RESULT: PASSED'
exit 0
