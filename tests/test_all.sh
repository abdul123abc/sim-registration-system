#!/usr/bin/env bash
# project/tests/test_all.sh — Milestone 7 Master Master Verification Test Suite

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "================================================================"
echo "  Milestone 7 Master Verification Suite"
echo "================================================================"
echo ""

echo "[Step 1/3] Running Zero-Knowledge Proof Test Suite..."
cd "${PROJECT_DIR}/zk"
bash test.sh

echo ""
echo "[Step 2/3] Running Sub-System Performance Benchmarks..."
cd "${PROJECT_DIR}/tests"
node performance_benchmark.js

echo ""
echo "[Step 3/3] Running End-to-End API Integration Suite..."
cd "${PROJECT_DIR}/tests"
node e2e_integration_test.js

echo ""
echo "================================================================"
echo "  ✓ ALL MILESTONE 7 VERIFICATION SUITES PASSED SUCCESSFULLY!"
echo "================================================================"
