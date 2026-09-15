const path = require('path');

function resolveProjectRoot() {
  if (process.env.PROJECT_ROOT) {
    return path.resolve(process.env.PROJECT_ROOT);
  }

  if (process.env.APP_ROOT) {
    return path.resolve(process.env.APP_ROOT);
  }

  if (process.env.NODE_ENV === 'docker' || process.env.DOCKER_ENV === 'true') {
    return '/opt/project';
  }

  return path.resolve(__dirname, '../../..');
}

function resolveNetworkDir() {
  return path.resolve(process.env.NETWORK_DIR || path.join(resolveProjectRoot(), 'network'));
}

function resolveFabricPaths() {
  const networkDir = resolveNetworkDir();

  return {
    projectRoot: resolveProjectRoot(),
    networkDir,
    tlsCertPath: process.env.TLS_CERT_PATH || path.join(
      networkDir,
      'crypto-config',
      'peerOrganizations',
      'ncc.example.com',
      'peers',
      'peer0.ncc.example.com',
      'tls',
      'ca.crt'
    ),
    clientCertPath: process.env.CLIENT_CERT_PATH || path.join(
      networkDir,
      'crypto-config',
      'peerOrganizations',
      'ncc.example.com',
      'users',
      'Admin@ncc.example.com',
      'msp',
      'signcerts',
      'Admin@ncc.example.com-cert.pem'
    ),
    clientKeyPath: process.env.CLIENT_KEY_PATH || path.join(
      networkDir,
      'crypto-config',
      'peerOrganizations',
      'ncc.example.com',
      'users',
      'Admin@ncc.example.com',
      'msp',
      'keystore'
    ),
    mspId: process.env.MSP_ID || 'NCCMSP',
    peerEndpoint: process.env.PEER_ENDPOINT || 'localhost:7051',
  };
}

module.exports = {
  resolveProjectRoot,
  resolveNetworkDir,
  resolveFabricPaths,
};
