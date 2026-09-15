#!/usr/bin/env bash
# network/scripts/smokeTest.sh
# End-to-end smoke test for all 4 deployed chaincodes.
# Invokes each contract's primary function and verifies the response.
# Chapter Three, Section 3.4.2 — Milestone 3.
#
# Usage: bash smokeTest.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"
set +e

CLI="sim_cli"
CRYPTO_INNER="/opt/gopath/src/github.com/hyperledger/fabric/peer/crypto"
ORDERER_INNER="${CRYPTO_INNER}/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem"

PASS=0
FAIL=0

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

# ── Helper: build --peerAddresses args for endorsement ────────────────────────
# For subscriber-registration and identity-validation: NCC + any one MNO
# For update-tracking: any 3 out of 5
# For access-control: any 3 out of 4 MNOs
#
# We send to ALL peers for simplicity; Fabric only requires enough endorsements.
build_peer_conn_params() {
  local -n OUT=$1
  shift
  local ORGS=("$@")
  OUT=()
  for ORG in "${ORGS[@]}"; do
    local DOMAIN="${PEER_DOMAIN[$ORG]}"
    local PEER_HOST="${PEER_ADDRESS[$ORG]%%:*}"
    OUT+=(
      --peerAddresses "${PEER_ADDRESS[$ORG]}"
      --tlsRootCertFiles "${CRYPTO_INNER}/peerOrganizations/${DOMAIN}/peers/${PEER_HOST}/tls/ca.crt"
    )
  done
}

# ── Helper: invoke chaincode ─────────────────────────────────────────────────
invoke_cc() {
  local CC_NAME=$1
  local FUNC=$2
  local ARGS=$3         # JSON array string e.g. '["arg1","arg2"]'
  local CALLER_ORG=$4   # org that submits the transaction
  shift 4
  local ENDORSER_ORGS=("$@")

  set_cli_peer_env "${CALLER_ORG}"

  local PEER_CONN=()
  build_peer_conn_params PEER_CONN "${ENDORSER_ORGS[@]}"

  docker exec "${CLI_ENV[@]}" "${CLI}" peer chaincode invoke \
    -C "${CHANNEL_NAME}" \
    -n "${CC_NAME}" \
    -c "{\"function\":\"${FUNC}\",\"Args\":${ARGS}}" \
    --tls true \
    --cafile "${ORDERER_INNER}" \
    -o orderer.example.com:7050 \
    "${PEER_CONN[@]}" \
    --waitForEvent 2>&1
}

# ── Helper: query chaincode ──────────────────────────────────────────────────
query_cc() {
  local CC_NAME=$1
  local FUNC=$2
  local ARGS=$3
  local CALLER_ORG=$4

  set_cli_peer_env "${CALLER_ORG}"

  docker exec "${CLI_ENV[@]}" "${CLI}" peer chaincode query \
    -C "${CHANNEL_NAME}" \
    -n "${CC_NAME}" \
    -c "{\"function\":\"${FUNC}\",\"Args\":${ARGS}}" 2>&1
}

# ── Test helper ───────────────────────────────────────────────────────────────
run_test() {
  local TEST_NAME=$1
  local EXPECTED=$2
  shift 2
  local CMD_OUTPUT

  log "  TEST: ${TEST_NAME}"
  CMD_OUTPUT=$("$@" 2>&1 || true)
  if echo "${CMD_OUTPUT}" | grep -q "${EXPECTED}"; then
    log "    ✓ PASSED"
    ((PASS++))
  else
    log "    ✗ FAILED — expected '${EXPECTED}' in output"
    log "    Output: ${CMD_OUTPUT}"
    ((FAIL++))
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
#   SMOKE TESTS
# ══════════════════════════════════════════════════════════════════════════════

log "╔══════════════════════════════════════════════════════════════╗"
log "║  Smoke Test — All 4 Chaincodes                               ║"
log "╚══════════════════════════════════════════════════════════════╝"

# ── Dynamic IDs for idempotency ─────────────────────────────────────────────
TS=$(date +%s)
SUB1="SUB_${TS}_1"
SUB2="SUB_${TS}_2"
EVT1="EVT_${TS}_1"
PERM1="MTNMSP_${SUB1}_READ"
# Make identityCommit values unique per run so repeated runs on a live ledger
# never collide with the MaxRegistrationsPerOperator limit check.
COMMIT1="commit_${TS}_1"    # used for SUB1 (under MTN)
COMMIT2="commit_${TS}_2"    # used for SUB2 (under Airtel)
# IDs used specifically for the per-operator registration-limit tests (Section 3.2.3)
# Limit = 4 per identity per MNO. We register 4 times (all succeed), then
# a 5th attempt which must be rejected with REGISTRATION_LIMIT_EXCEEDED.
LIMIT_COMMIT="limit_test_commit_${TS}"
LIMIT_SUB_A="LIMIT_${TS}_A"      # MTN slot 1 — must succeed
LIMIT_SUB_B="LIMIT_${TS}_B"      # MTN slot 2 — must succeed
LIMIT_SUB_C="LIMIT_${TS}_C"      # MTN slot 3 — must succeed
LIMIT_SUB_D="LIMIT_${TS}_D"      # MTN slot 4 — must succeed (fills limit)
LIMIT_SUB_E="LIMIT_${TS}_E"      # MTN slot 5 — must be rejected
LIMIT_SUB_AIRTEL="LIMIT_${TS}_AIRTEL"  # Airtel — same identity, must succeed (cross-operator)

# ── 1. Subscriber Registration ────────────────────────────────────────────────
log ""
log "─── 1. subscriber-registration ────────────────────────────────"

# 1a. Register a subscriber (NCC submits, endorsed by NCC + MTN)
run_test "RegisterSubscriber (${SUB1})" "status:200" \
  invoke_cc "subscriber-registration" "RegisterSubscriber" \
  "[\"${SUB1}\",\"08012345678\",\"MTN\",\"${COMMIT1}\",\"QmIPFShash001\"]" \
  "NCC" "NCC" "MTN"

# Wait for commit
sleep 2

# 1b. Query the subscriber back
run_test "GetSubscriber (${SUB1})" "subscriberID" \
  query_cc "subscriber-registration" "GetSubscriber" \
  "[\"${SUB1}\"]" "NCC"

# 1c. Register a second subscriber for later tests
run_test "RegisterSubscriber (${SUB2})" "status:200" \
  invoke_cc "subscriber-registration" "RegisterSubscriber" \
  "[\"${SUB2}\",\"08098765432\",\"Airtel\",\"${COMMIT2}\",\"QmIPFShash002\"]" \
  "NCC" "NCC" "Airtel"

sleep 2

# ── 2. Identity Validation ───────────────────────────────────────────────────
log ""
log "─── 2. identity-validation ────────────────────────────────────"

# 2a. Generate identity commitment
run_test "GenerateCommitment" "status:200" \
  invoke_cc "identity-validation" "GenerateCommitment" \
  "[\"${SUB1}\",\"12345678901\",\"fingerprint_hash_abc\"]" \
  "NCC" "NCC" "MTN"

sleep 2

# 2b. Verify a ZK proof (verified=true flag)
run_test "VerifyIdentityProof" "status:200" \
  invoke_cc "identity-validation" "VerifyIdentityProof" \
  "[\"${SUB1}\",\"{\\\"pi_a\\\":[1,2],\\\"pi_b\\\":[[3,4],[5,6]],\\\"pi_c\\\":[7,8]}\",\"[\\\"signal1\\\",\\\"signal2\\\"]\",\"true\"]" \
  "NCC" "NCC" "MTN"

sleep 2

# ── 3. Update Tracking ───────────────────────────────────────────────────────
log ""
log "─── 3. update-tracking ────────────────────────────────────────"

# 3a. Log an audit event
run_test "LogEvent" "status:200" \
  invoke_cc "update-tracking" "LogEvent" \
  "[\"${EVT1}\",\"${SUB1}\",\"REGISTERED\",\"MTN\",\"New subscriber registered via smoke test\"]" \
  "NCC" "NCC" "MTN" "Airtel"

sleep 2

# 3b. Query audit trail
run_test "GetAuditTrail (${SUB1})" "eventID" \
  query_cc "update-tracking" "GetAuditTrail" \
  "[\"${SUB1}\"]" "NCC"

# ── 4. Access Control ────────────────────────────────────────────────────────
log ""
log "─── 4. access-control ─────────────────────────────────────────"

# 4a. Grant a permission
run_test "GrantPermission" "status:200" \
  invoke_cc "access-control" "GrantPermission" \
  "[\"${PERM1}\",\"MTNMSP\",\"${SUB1}\",\"READ\",\"NCCMSP\"]" \
  "MTN" "MTN" "Airtel" "Glo"

sleep 2

# 4b. Check the permission
run_test "CheckPermission (granted)" "true" \
  query_cc "access-control" "CheckPermission" \
  "[\"${PERM1}\"]" "NCC"

# 4c. ReadSubscriber via access control
run_test "ReadSubscriber (access-controlled)" "GRANTED" \
  query_cc "access-control" "ReadSubscriber" \
  "[\"MTNMSP\",\"${SUB1}\"]" "NCC"

# 4d. Revoke the permission
run_test "RevokePermission" "status:200" \
  invoke_cc "access-control" "RevokePermission" \
  "[\"${PERM1}\"]" \
  "MTN" "MTN" "Airtel" "Glo"

sleep 2

# 4e. Verify access is denied after revocation
run_test "ReadSubscriber (after revoke — access denied)" "access denied" \
  query_cc "access-control" "ReadSubscriber" \
  "[\"MTNMSP\",\"${SUB1}\"]" "NCC"

# ── 5. Subscriber Registration — Deactivation ────────────────────────────────
log ""
log "─── 5. subscriber-registration — DeactivateSubscriber ─────────"

run_test "DeactivateSubscriber (${SUB2})" "status:200" \
  invoke_cc "subscriber-registration" "DeactivateSubscriber" \
  "[\"${SUB2}\"]" \
  "NCC" "NCC" "MTN"

sleep 2

run_test "GetSubscriber (${SUB2} — should be DEACTIVATED)" "DEACTIVATED" \
  query_cc "subscriber-registration" "GetSubscriber" \
  "[\"${SUB2}\"]" "NCC"

# ── 6. Registration-Limit Enforcement (Section 3.2.3) ───────────────────────
# Verifies that RegisterSubscriber enforces MaxRegistrationsPerOperator,
# scoped per identity commitment per MNO, NOT globally across operators.
log ""
log "─── 6. subscriber-registration — per-operator limit enforcement ─"

# 15. MTN slot 1 — must succeed.
run_test "RegisterSubscriber (limit test — MTN slot 1/4, expect success)" "status:200" \
  invoke_cc "subscriber-registration" "RegisterSubscriber" \
  "[\"${LIMIT_SUB_A}\",\"08011110001\",\"MTN\",\"${LIMIT_COMMIT}\",\"QmIPFSLimitA\"]" \
  "NCC" "NCC" "MTN"

sleep 2

# 16. MTN slot 2 — must succeed.
run_test "RegisterSubscriber (limit test — MTN slot 2/4, expect success)" "status:200" \
  invoke_cc "subscriber-registration" "RegisterSubscriber" \
  "[\"${LIMIT_SUB_B}\",\"08011110002\",\"MTN\",\"${LIMIT_COMMIT}\",\"QmIPFSLimitB\"]" \
  "NCC" "NCC" "MTN"

sleep 2

# 17. MTN slot 3 — must succeed.
run_test "RegisterSubscriber (limit test — MTN slot 3/4, expect success)" "status:200" \
  invoke_cc "subscriber-registration" "RegisterSubscriber" \
  "[\"${LIMIT_SUB_C}\",\"08011110003\",\"MTN\",\"${LIMIT_COMMIT}\",\"QmIPFSLimitC\"]" \
  "NCC" "NCC" "MTN"

sleep 2

# 18. MTN slot 4 — must succeed (fills the limit).
run_test "RegisterSubscriber (limit test — MTN slot 4/4, expect success)" "status:200" \
  invoke_cc "subscriber-registration" "RegisterSubscriber" \
  "[\"${LIMIT_SUB_D}\",\"08011110004\",\"MTN\",\"${LIMIT_COMMIT}\",\"QmIPFSLimitD\"]" \
  "NCC" "NCC" "MTN"

sleep 2

# 19. MTN slot 5 — must be rejected (limit = MaxRegistrationsPerOperator = 4).
run_test "RegisterSubscriber (limit test — MTN slot 5, expect REGISTRATION_LIMIT_EXCEEDED)" "REGISTRATION_LIMIT_EXCEEDED" \
  invoke_cc "subscriber-registration" "RegisterSubscriber" \
  "[\"${LIMIT_SUB_E}\",\"08011110005\",\"MTN\",\"${LIMIT_COMMIT}\",\"QmIPFSLimitE\"]" \
  "NCC" "NCC" "MTN"

sleep 2

# 20. Cross-operator: same identityCommit under Airtel — must succeed.
#     The limit is scoped per operator, not globally across the network.
run_test "RegisterSubscriber (limit test — Airtel same identity, expect success)" "status:200" \
  invoke_cc "subscriber-registration" "RegisterSubscriber" \
  "[\"${LIMIT_SUB_AIRTEL}\",\"08011110006\",\"Airtel\",\"${LIMIT_COMMIT}\",\"QmIPFSLimitAirtel\"]" \
  "NCC" "NCC" "Airtel"

sleep 2

# ── Summary ───────────────────────────────────────────────────────────────────
log ""
log "╔══════════════════════════════════════════════════════════════╗"
log "║  Smoke Test Summary                                          ║"
log "║  Passed: ${PASS}                                             ║"
log "║  Failed: ${FAIL}                                             ║"
log "╚══════════════════════════════════════════════════════════════╝"

if [ "${FAIL}" -gt 0 ]; then
  exit 1
fi
