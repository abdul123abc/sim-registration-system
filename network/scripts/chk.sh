#!/bin/bash
docker run --rm \
  -v /home/molade/HyperLedger/project:/opt/project \
  -w /opt/project/chaincode/subscriber-registration \
  golang:1.21-alpine \
  go build -o /opt/project/network/scripts/subscriber-registration-bin .
