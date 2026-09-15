#!/bin/bash
# project/network/scripts/compile_all.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHAINCODE_DIR="$(cd "${SCRIPT_DIR}/../../chaincode" && pwd)"

for CC in subscriber-registration identity-validation update-tracking access-control; do
  echo "Compiling ${CC}..."
  cd "${CHAINCODE_DIR}/${CC}"
  GO111MODULE=on CGO_ENABLED=0 go build -o "${SCRIPT_DIR}/${CC}-bin" .
  echo "✓ ${CC} compiled successfully"
done
