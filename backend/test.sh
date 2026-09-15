#!/usr/bin/env bash
# backend/test.sh — Shell runner for Milestone 5 Express API Gateway integration tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

if [ ! -d "node_modules" ]; then
  echo "Installing backend dependencies..."
  npm install
fi

echo "Running Milestone 5 Backend API Test Suite..."
node test_api.js
