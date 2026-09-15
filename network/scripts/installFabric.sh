#!/usr/bin/env bash
# network/scripts/installFabric.sh
# Downloads Hyperledger Fabric v2.5 binaries (cryptogen, configtxgen, peer, osnadmin)
# and Docker images into network/bin/ and network/config/.
# Run once before network.sh up.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NETWORK_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

FABRIC_VERSION="2.5.7"
CA_VERSION="1.5.9"

echo "Downloading Hyperledger Fabric ${FABRIC_VERSION} binaries..."

# The official install script from fabric-samples
curl -sSLO https://raw.githubusercontent.com/hyperledger/fabric/main/scripts/install-fabric.sh
chmod +x install-fabric.sh

# d = Docker images, b = binaries, s = config samples
./install-fabric.sh \
  --fabric-version "${FABRIC_VERSION}" \
  --ca-version "${CA_VERSION}" \
  d b

# Binaries are unpacked into the CWD (scripts/) by the install script.
# They land in ./bin relative to where the script runs.
# utils.sh already has SCRIPT_DIR/bin on PATH so no copy is needed.
echo "Binaries are in: $(pwd)/bin"

rm -f install-fabric.sh
echo "Done. Run: cd network && bash scripts/network.sh up"
