/**
 * backend/src/fabric/gateway.js
 * Hyperledger Fabric Gateway connection helper.
 * Uses the @hyperledger/fabric-gateway SDK (Fabric v2.4+).
 * Chapter Three, Section 3.4 — network topology.
 */

const { connect, signers, hash } = require('@hyperledger/fabric-gateway');
const grpc = require('@grpc/grpc-js');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const dns = require('dns');
const { resolveNetworkDir } = require('../config/network');

// Override DNS lookup inside Node to map *.example.com container hostnames to 127.0.0.1
const originalLookup = dns.lookup;
dns.lookup = (hostname, options, callback) => {
  if (typeof options === 'function') {
    callback = options;
    options = {};
  }
  if (hostname && (hostname.endsWith('.example.com') || hostname === 'orderer.example.com')) {
    return callback(null, '127.0.0.1', 4);
  }
  return originalLookup(hostname, options, callback);
};

// Paths to network crypto material
const NETWORK_DIR = resolveNetworkDir();

/**
 * Build a gRPC client for a given peer endpoint.
 * @param {string} peerEndpoint  e.g. "peer0.mno1.example.com:7051"
 * @param {string} tlsCertPath  Absolute path to the peer's TLS CA cert (PEM)
 * @returns {grpc.Client}
 */
function buildGrpcClient(peerEndpoint, tlsCertPath, sslTargetNameOverride = 'peer0.ncc.example.com') {
  const tlsCert = fs.readFileSync(tlsCertPath);
  const credentials = grpc.credentials.createSsl(tlsCert);
  const options = {
    'grpc.ssl_target_name_override': sslTargetNameOverride,
    'grpc.default_authority': sslTargetNameOverride
  };
  return new grpc.Client(peerEndpoint, credentials, options);
}

function getPrivateKeyPath(keyPath) {
  if (fs.existsSync(keyPath) && fs.lstatSync(keyPath).isDirectory()) {
    const files = fs.readdirSync(keyPath);
    const keyFile = files.find(f => f.endsWith('_sk') || f.endsWith('.pem') || f.endsWith('.key')) || files[0];
    return path.join(keyPath, keyFile);
  }
  return keyPath;
}

/**
 * Open a Fabric Gateway connection for a given organisation identity.
 * Returns the Gateway instance; caller must call gateway.close() when done.
 */
async function openGateway({ peerEndpoint, tlsCertPath, certPath, keyPath, mspId, sslTargetNameOverride }) {
  const client = buildGrpcClient(peerEndpoint, tlsCertPath, sslTargetNameOverride || 'peer0.ncc.example.com');
  const resolvedKeyPath = getPrivateKeyPath(keyPath);

  const identity = {
    mspId,
    credentials: fs.readFileSync(certPath),
  };

  const key = crypto.createPrivateKey(fs.readFileSync(resolvedKeyPath));
  const signer = signers.newPrivateKeySigner(key);

  const gateway = connect({
    client,
    identity,
    signer,
    hash: hash.sha256,
  });

  return gateway;
}

/**
 * getContract — convenience wrapper to retrieve a named chaincode contract.
 * @param {import('@hyperledger/fabric-gateway').Gateway} gateway
 * @param {string} channelName
 * @param {string} chaincodeName
 * @param {string} contractName
 */
function getContract(gateway, channelName, chaincodeName, contractName) {
  const network = gateway.getNetwork(channelName);
  return network.getContract(chaincodeName, contractName);
}

module.exports = { openGateway, getContract };
