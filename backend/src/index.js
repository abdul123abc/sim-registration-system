/**
 * backend/src/index.js
 * Entry point — Express server wiring all route modules.
 */

const express = require('express');
const cors = require('cors');
const { execFile } = require('child_process');
const registrationRoutes = require('./routes/registration');
const auditRoutes = require('./routes/audit');
const accessRoutes = require('./routes/access');

const app = express();
const PORT = process.env.PORT || 3001;
const couchEndpoint = process.env.COUCHDB_URL || 'http://localhost:5984';
const peerStateEndpoints = [
  'http://couchdb.ncc.example.com:5984/',
  'http://couchdb.mno1.example.com:5984/',
  'http://couchdb.mno2.example.com:5984/',
  'http://couchdb.mno3.example.com:5984/',
  'http://couchdb.mno4.example.com:5984/',
];

async function getTotalSubscribers() {
  try {
    const data = await new Promise((resolve, reject) => {
      execFile('wget', [
        '-qO-',
        '-T', '3',
        '--header', `Authorization: Basic ${Buffer.from('admin:adminpw').toString('base64')}`,
        `${couchEndpoint}/sim-registration-channel_subscriber-registration/_all_docs`,
      ], (error, stdout) => {
        if (error) {
          reject(error);
          return;
        }
        try {
          resolve(JSON.parse(stdout));
        } catch (parseError) {
          reject(parseError);
        }
      });
    });
    return {
      total: typeof data.total_rows === 'number' ? data.total_rows : 0,
      available: true,
    };
  } catch (_err) {
    return { total: 0, available: false, error: `${_err.message} (${couchEndpoint})` };
  }
}

app.use(cors());
app.use(express.json());

// Mount routes
app.use('/api/registration', registrationRoutes);
app.use('/api/audit', auditRoutes);
app.use('/api/access', accessRoutes);

// Health is based on network reachability, so it works without Docker CLI access.
app.get('/health', async (_req, res) => {
  const subscriberState = await getTotalSubscribers();
  const activePeers = subscriberState.available ? peerStateEndpoints.length : 0;
  const fabricReachable = subscriberState.available;

  res.json({
    status: fabricReachable ? 'ok' : 'degraded',
    activePeers,
    totalPeers: peerStateEndpoints.length,
    totalSubscribers: subscriberState.total,
    ordererRunning: null,
    fabricNetwork: fabricReachable ? 'reachable' : 'unreachable',
    consensusStatus: fabricReachable
      ? `Fabric ledger state reachable; ${activePeers}/${peerStateEndpoints.length} peers configured`
      : 'Fabric peer state unavailable',
    healthBasis: 'NCC CouchDB ledger-state reachability and configured Fabric peer topology; orderer metrics are not exposed to the app container',
  });
});

app.listen(PORT, () => {
  console.log(`SIM Blockchain backend running on port ${PORT}`);
});

module.exports = app;
