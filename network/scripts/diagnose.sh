#!/usr/bin/env bash
# Test script to isolate whether the issue is:
#   A) Go build compatibility (ccenv image vs chaincode code)
#   B) Docker-in-Docker socket communication
#
# Run: bash test_build.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NETWORK_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CC_DIR="${NETWORK_DIR}/../chaincode/subscriber-registration"

echo "=== Test 1: Build chaincode directly using ccenv image (no Docker-in-Docker) ==="
echo "This tests if the Go code compiles correctly with the ccenv image's Go version."
echo ""

docker run --rm \
  -v "${CC_DIR}:/chaincode/input/src" \
  -w /chaincode/input/src \
  -e GO111MODULE=on \
  hyperledger/fabric-ccenv:2.5.7 \
  go build -v -mod=vendor -o /dev/null . 2>&1

BUILD_EXIT=$?
if [ $BUILD_EXIT -eq 0 ]; then
  echo ""
  echo "✓ TEST 1 PASSED — Go build works with ccenv image"
  echo "  The issue is Docker-in-Docker socket communication, not Go compatibility."
  echo ""
  echo "=== Fix: Trying Docker socket mount adjustment ==="
  echo "The peer containers mount the Docker socket at /host/var/run/docker.sock"
  echo "but the build error shows /run/docker.sock — there may be a path mismatch."
  echo ""
  echo "Recommended fix: Update docker-compose.yaml to mount at /var/run/docker.sock"
  echo "and set CORE_VM_ENDPOINT=unix:///var/run/docker.sock"
else
  echo ""
  echo "✗ TEST 1 FAILED — Go build does NOT work with ccenv image"
  echo "  This is a Go/code compatibility issue."
fi

echo ""
echo "=== Test 2: Can the peer container reach the Docker daemon? ==="
# The peer's Go code connects to CORE_VM_ENDPOINT. Let's test from the peer.
docker exec peer0.ncc.example.com sh -c \
  'echo -e "GET /version HTTP/1.0\r\n" | socat - UNIX-CONNECT:/host/var/run/docker.sock 2>/dev/null | head -5' 2>&1 || \
  echo "(socat not available — trying alternative)"

# Alternative: check if the socket file exists and is accessible
docker exec peer0.ncc.example.com ls -la /host/var/run/docker.sock 2>&1
docker exec peer0.ncc.example.com sh -c 'cat /proc/1/environ 2>/dev/null | tr "\0" "\n" | grep CORE_VM' 2>&1 || true

echo ""
echo "=== Test 3: Docker socket permissions from host ==="
ls -la /var/run/docker.sock
stat /var/run/docker.sock

echo ""
echo "=== Test 4: Check available disk space ==="
df -h / 2>/dev/null || echo "df not available"
docker system df 2>/dev/null || echo "docker system df not available"

echo ""
echo "=== Done ==="
