/**
 * backend/src/routes/registration.js
 * POST /api/registration/register
 * Orchestrates the full registration workflow from Chapter Three, Section 3.1.4.
 */

const express = require('express');
const { v4: uuidv4 } = require('uuid');
const crypto = require('crypto');
const { execFile } = require('child_process');
const { computeCommitment, generateProof, verifyProof } = require('../zk/prover');
const { uploadToIPFS } = require('../ipfs/client');
const { openGateway, getContract } = require('../fabric/gateway');
const { resolveFabricPaths } = require('../config/network');

const router = express.Router();

const CHANNEL = 'sim-registration-channel';
const CC_REGISTRATION = 'subscriber-registration';
const CC_TRACKING = 'update-tracking';

function normalizeFingerprintHash(value) {
  const normalized = String(value).trim().replace(/^0x/i, '');
  if (/^[0-9a-f]{64}$/i.test(normalized)) {
    return normalized.toLowerCase();
  }

  return crypto.createHash('sha256').update(String(value).trim(), 'utf8').digest('hex');
}

/**
 * GET /api/registration/subscribers/all
 * Returns all subscriber records on the ledger for regulator (NCC) overview.
 */
router.get('/subscribers/all', async (_req, res) => {
  try {
    const couchEndpoint = process.env.COUCHDB_URL || 'http://localhost:5984';
    execFile('wget', [
      '-qO-', '-T', '5',
      '--header', `Authorization: Basic ${Buffer.from('admin:adminpw').toString('base64')}`,
      `${couchEndpoint}/sim-registration-channel_subscriber-registration/_all_docs?include_docs=true`,
    ], (err, stdout, stderr) => {
      if (err || !stdout) return res.status(502).json({ error: `CouchDB subscriber query failed: ${stderr || err.message}` });
      try {
        const parsed = JSON.parse(stdout);
        const rows = parsed.rows || [];
        const subscribers = rows
          .map(r => r.doc)
          .filter(doc => doc && doc.subscriberID && !doc._id.startsWith('_design'))
          .sort((a, b) => (b.registeredAt || '').localeCompare(a.registeredAt || ''));
        return res.json(subscribers);
      } catch {
        return res.json([]);
      }
    });
  } catch (err) {
    return res.status(500).json({ error: err.message });
  }
});

/**
 * POST /api/registration/deactivate
 * Appends a DEACTIVATED update transaction on-chain.
 */
router.post('/deactivate', async (req, res) => {
  const subscriberID = req.body.subscriberID ? String(req.body.subscriberID).trim() : '';
  if (!subscriberID) return res.status(400).json({ error: 'subscriberID is required' });

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
      const regContract = getContract(gateway, CHANNEL, CC_REGISTRATION, 'SubscriberRegistrationContract');
      await regContract.submitTransaction('DeactivateSubscriber', subscriberID);

      // Log event in Update Tracking contract
      const trackContract = getContract(gateway, CHANNEL, CC_TRACKING, 'UpdateTrackingContract');
      const eventID = uuidv4();
      await trackContract.submitTransaction('LogEvent', eventID, subscriberID, 'DEACTIVATED', 'NCC', 'Status updated to DEACTIVATED on-chain');

      return res.json({ message: 'Subscriber deactivated successfully', subscriberID });
    } finally {
      gateway.close();
    }
  } catch (err) {
    return res.status(500).json({ error: err.message });
  }
});

/**
 * POST /api/registration/register
 * Body: { nin, fingerprintHash, msisdn, mno }
 */
router.post('/register', async (req, res) => {
  let { nin, fingerprintHash, msisdn, mno } = req.body;

  nin = nin ? String(nin).trim() : '';
  fingerprintHash = fingerprintHash ? normalizeFingerprintHash(fingerprintHash) : '';
  msisdn = msisdn ? String(msisdn).trim() : '';
  mno = mno ? String(mno).trim() : '';

  if (!nin || !fingerprintHash || !msisdn || !mno) {
    return res.status(400).json({ error: 'nin, fingerprintHash, msisdn, and mno are required' });
  }

  try {
    // Step 2: Compute identity commitment (Poseidon hash).
    const commitment = await computeCommitment(nin, fingerprintHash);

    // Step 3: Generate Groth16 ZK proof.
    const { proof, publicSignals } = await generateProof(nin, fingerprintHash, commitment);

    // Step 4: Verify proof — reject immediately on failure.
    const valid = await verifyProof(proof, publicSignals);
    if (!valid) {
      return res.status(422).json({ error: 'ZK proof verification failed — registration rejected' });
    }

    const subscriberID = uuidv4();

    // AES-256 key
    const aesKey = crypto.createHash('sha256').update(commitment).digest();

    // Step 6: Encrypt payload and upload to IPFS.
    const payload = { nin, fingerprintHash, msisdn, mno, subscriberID };
    const { cid } = await uploadToIPFS(payload, aesKey);

    // Step 7: Invoke Subscriber Registration chaincode.
    const { peerEndpoint, tlsCertPath, clientCertPath, clientKeyPath, mspId } = resolveFabricPaths();
    const gateway = await openGateway({
      peerEndpoint: process.env.PEER_ENDPOINT || peerEndpoint,
      tlsCertPath: process.env.TLS_CERT_PATH || tlsCertPath,
      certPath: process.env.CLIENT_CERT_PATH || clientCertPath,
      keyPath: process.env.CLIENT_KEY_PATH || clientKeyPath,
      mspId: process.env.MSP_ID || mspId,
    });

    try {
      const regContract = getContract(gateway, CHANNEL, CC_REGISTRATION, 'SubscriberRegistrationContract');
      await regContract.submitTransaction('RegisterSubscriber', subscriberID, msisdn, mno, commitment, cid);

      // Step 8: Log event in Update Tracking contract.
      const trackContract = getContract(gateway, CHANNEL, CC_TRACKING, 'UpdateTrackingContract');
      const eventID = uuidv4();
      await trackContract.submitTransaction('LogEvent', eventID, subscriberID, 'REGISTERED', mno, `IPFS CID: ${cid}`);

      return res.status(201).json({ subscriberID, commitment, ipfsHash: cid });
    } finally {
      gateway.close();
    }
  } catch (err) {
    console.error('Registration error details:', err);
    let errorMsg = err.message || 'Registration failed';
    const errString = JSON.stringify(err) + ' ' + (err.stack || '') + ' ' + (err.details ? JSON.stringify(err.details) : '');

    if (errString.includes('REGISTRATION_LIMIT_EXCEEDED') || errorMsg.includes('REGISTRATION_LIMIT_EXCEEDED')) {
      errorMsg = `REGISTRATION_LIMIT_EXCEEDED: Maximum registration limit (4 SIMs per identity) reached for operator ${mno}.`;
    } else if (errString.includes('DUPLICATE_MSISDN') || errorMsg.includes('DUPLICATE_MSISDN')) {
      errorMsg = `DUPLICATE_MSISDN: Mobile phone number ${msisdn} is already active on the network.`;
    } else if (err.details && Array.isArray(err.details) && err.details.length > 0) {
      const peerMsg = err.details.map(d => d.message || d.toString()).join(' ');
      if (peerMsg) errorMsg = peerMsg;
    }

    errorMsg = errorMsg.replace(/^chaincode response \d+,\s*/i, '');

    return res.status(400).json({ error: errorMsg });
  }
});

/**
 * GET /api/registration/:subscriberID
 */
router.get('/:subscriberID', async (req, res) => {
  const subscriberID = req.params.subscriberID ? req.params.subscriberID.trim() : '';
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
      const contract = getContract(gateway, CHANNEL, CC_REGISTRATION, 'SubscriberRegistrationContract');
      const result = await contract.evaluateTransaction('GetSubscriber', subscriberID);
      const str = Buffer.from(result).toString().trim();
      return res.json(str ? JSON.parse(str) : {});
    } finally {
      gateway.close();
    }
  } catch (err) {
    return res.status(500).json({ error: err.message });
  }
});

module.exports = router;
