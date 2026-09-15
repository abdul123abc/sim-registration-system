/**
 * backend/src/routes/audit.js
 * GET /api/audit/:subscriberID — fetch audit trail from Update Tracking contract
 * Chapter Three, Section 3.3 — Contract 3.
 */

const express = require('express');
const { execFile } = require('child_process');
const { openGateway, getContract } = require('../fabric/gateway');
const { resolveFabricPaths } = require('../config/network');

const router = express.Router();
const CHANNEL = 'sim-registration-channel';
const CC_TRACKING = 'update-tracking';

/**
 * GET /api/audit/all
 * Returns all audit events across the national network directly from CouchDB state.
 */
router.get('/all', async (_req, res) => {
  try {
    const couchEndpoint = process.env.COUCHDB_URL || 'http://localhost:5984';
    execFile('wget', [
      '-qO-', '-T', '5',
      '--header', `Authorization: Basic ${Buffer.from('admin:adminpw').toString('base64')}`,
      `${couchEndpoint}/sim-registration-channel_update-tracking/_all_docs?include_docs=true`,
    ], (err, stdout, stderr) => {
      if (err || !stdout) return res.status(502).json({ error: `CouchDB audit query failed: ${stderr || err.message}` });
      try {
        const parsed = JSON.parse(stdout);
        const rows = parsed.rows || [];
        const events = rows
          .map(r => r.doc)
          .filter(doc => doc && doc.eventID && !doc._id.startsWith('_design'))
          .sort((a, b) => (b.timestamp || '').localeCompare(a.timestamp || ''));
        return res.json(events);
      } catch {
        return res.json([]);
      }
    });
  } catch (err) {
    return res.status(500).json({ error: err.message });
  }
});

/**
 * GET /api/audit/:subscriberID
 * Returns the audit trail for a specific subscriber from the Update Tracking contract.
 */
router.get('/:subscriberID', async (req, res) => {
  const subscriberID = req.params.subscriberID ? req.params.subscriberID.trim() : '';
  if (!subscriberID || subscriberID === 'all') {
    return res.redirect('/api/audit/all');
  }

  try {
    const { peerEndpoint, tlsCertPath, clientCertPath, clientKeyPath, mspId } = resolveFabricPaths();
    const gateway = await openGateway({
      peerEndpoint: process.env.PEER_ENDPOINT || peerEndpoint,
      tlsCertPath: process.env.TLS_CERT_PATH || tlsCertPath,
      certPath: process.env.CLIENT_CERT_PATH || clientCertPath,
      keyPath: process.env.CLIENT_KEY_PATH || clientKeyPath,
      mspId: process.env.MSP_ID || mspId,
    });
    try {
      const contract = getContract(gateway, CHANNEL, CC_TRACKING, 'UpdateTrackingContract');
      const result = await contract.evaluateTransaction('GetAuditTrail', subscriberID);
      const str = Buffer.from(result).toString().trim();
      return res.json(str ? JSON.parse(str) : []);
    } finally {
      gateway.close();
    }
  } catch (err) {
    return res.status(500).json({ error: err.message });
  }
});

module.exports = router;
