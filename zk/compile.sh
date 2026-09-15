#!/usr/bin/env bash
# zk/compile.sh — compile the NIN commitment circuit and run a trusted setup
# Chapter Three, Section 3.2 / Technology Stack: Circom + snarkjs (Groth16)

set -euo pipefail

CIRCUIT_DIR="circuits"
BUILD_DIR="build"
CIRCUIT_NAME="nin_commitment"
PTAU_FILE="pot12_final_prepared.ptau"   # Prepared Powers of Tau file

mkdir -p "$BUILD_DIR"

echo "=== Step 1: Compile circuit ==="
circom "$CIRCUIT_DIR/$CIRCUIT_NAME.circom" \
  --r1cs --wasm --sym \
  -l . \
  -o "$BUILD_DIR"

echo "=== Step 2: Generate local Powers of Tau (phase 1) ==="
if [ ! -f "$PTAU_FILE" ]; then
  rm -f pot12_0000.ptau pot12_final.ptau
  npx snarkjs powersoftau new bn128 12 pot12_0000.ptau -v
  echo "dev_entropy_phase1" | npx snarkjs powersoftau contribute pot12_0000.ptau pot12_final.ptau --name="First contribution" -v
  npx snarkjs powersoftau prepare phase2 pot12_final.ptau "$PTAU_FILE" -v
  rm -f pot12_0000.ptau pot12_final.ptau
fi

echo "=== Step 3: Phase 2 setup (circuit-specific) ==="
npx snarkjs groth16 setup \
  "$BUILD_DIR/$CIRCUIT_NAME.r1cs" \
  "$PTAU_FILE" \
  "$BUILD_DIR/${CIRCUIT_NAME}_0000.zkey"

echo "=== Step 4: Contribute to phase 2 ceremony (dev randomness) ==="
echo "dev_entropy_academic_prototype" | npx snarkjs zkey contribute \
  "$BUILD_DIR/${CIRCUIT_NAME}_0000.zkey" \
  "$BUILD_DIR/${CIRCUIT_NAME}_final.zkey" \
  --name="Academic Prototype Contribution" -v

echo "=== Step 5: Export verification key ==="
npx snarkjs zkey export verificationkey \
  "$BUILD_DIR/${CIRCUIT_NAME}_final.zkey" \
  "$BUILD_DIR/verification_key.json"

echo "=== Step 6: Generate Solidity/JS verifier (for reference) ==="
npx snarkjs zkey export solidityverifier \
  "$BUILD_DIR/${CIRCUIT_NAME}_final.zkey" \
  "$BUILD_DIR/verifier.sol"

echo ""
echo "Build complete. Outputs in $BUILD_DIR/:"
echo "  - ${CIRCUIT_NAME}.r1cs         (R1CS constraint system)"
echo "  - ${CIRCUIT_NAME}_js/          (WASM prover)"
echo "  - ${CIRCUIT_NAME}_final.zkey   (proving key)"
echo "  - verification_key.json        (verifier key — used by backend)"
