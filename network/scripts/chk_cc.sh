#!/bin/bash
docker exec peer0.ncc.example.com cat /etc/hyperledger/fabric/core.yaml | grep -C 5 -i "chaincode" | grep -v -E "^\s*#"
