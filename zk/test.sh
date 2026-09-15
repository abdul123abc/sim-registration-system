#!/usr/bin/env bash
# zk/test.sh — Shell runner for Milestone 4 Zero-Knowledge Proof tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

if [ ! -d "node_modules" ]; then
  echo "Installing ZK dependencies..."
  npm install
fi

node test.js
