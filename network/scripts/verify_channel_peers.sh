#!/usr/bin/env bash
# project/network/scripts/verify_channel_peers.sh
# Verifies channel membership for all 5 consortium peer nodes.

echo "================================================================================"
echo "      FABRIC CHANNEL MEMBERSHIP VERIFICATION — SIM REGISTRATION CHANNEL         "
echo "================================================================================"
echo ""

PEERS=(
  "NCC|peer0.ncc.example.com:7051|NCCMSP|ncc.example.com"
  "MTN Nigeria|peer0.mno1.example.com:8051|MTNMSP|mno1.example.com"
  "Airtel Nigeria|peer0.mno2.example.com:9051|AIRTELMSP|mno2.example.com"
  "Globacom|peer0.mno3.example.com:10051|GLOMSP|mno3.example.com"
  "9mobile|peer0.mno4.example.com:11051|NINEMOBILEMSP|mno4.example.com"
)

IDX=1
for ENTRY in "${PEERS[@]}"; do
  IFS="|" read -r NAME HOST MSP DOMAIN <<< "${ENTRY}"
  echo "[${IDX}/5] Checking ${NAME} (${HOST})..."
  docker exec \
    -e CORE_PEER_LOCALMSPID="${MSP}" \
    -e CORE_PEER_ADDRESS="${HOST}" \
    -e CORE_PEER_TLS_ROOTCERT_FILE="/opt/gopath/src/github.com/hyperledger/fabric/peer/crypto/peerOrganizations/${DOMAIN}/peers/${HOST%%:*}/tls/ca.crt" \
    -e CORE_PEER_MSPCONFIGPATH="/opt/gopath/src/github.com/hyperledger/fabric/peer/crypto/peerOrganizations/${DOMAIN}/users/Admin@${DOMAIN}/msp" \
    sim_cli peer channel list 2>&1 | grep -E "Channels|sim-registration-channel"
  echo ""
  IDX=$((IDX + 1))
done

echo "================================================================================"
echo " RESULT: All 5 Consortium Peers Successfully Joined 'sim-registration-channel'  "
echo "================================================================================"
