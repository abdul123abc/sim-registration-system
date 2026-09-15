/**
 * backend/src/routes/access.js
 * Access Control routes — wraps the Access Control chaincode.
 * Chapter Three, Section 3.3 — Contract 4.
 */

const express = require('express');
const { openGateway, getContract } = require('../fabric/gateway');
const { resolveFabricPaths } = require('../config/network');

const router = express.Router();
const CHANNEL = 'sim-registration-channel';
const CC_ACCESS = 'access-control';
const CC_REGISTRATION = 'subscriber-registration';

/**
 * POST /api/access/grant
 * Body: { permissionID, grantedTo, resource, action, grantedBy }
 */
router.post('/grant', async (req, res) => {
  let { permissionID, grantedTo, resource, action, grantedBy } = req.body;
  permissionID = permissionID ? String(permissionID).trim() : '';
  grantedTo = grantedTo ? String(grantedTo).trim() : '';
  resource = resource ? String(resource).trim() : '';
  action = action ? String(action).trim() : '';
  grantedBy = grantedBy ? String(grantedBy).trim() : '';

  if (!permissionID || !grantedTo || !resource || !action || !grantedBy) {
    return res.status(400).json({ error: 'permissionID, grantedTo, resource, action, grantedBy are all required' });
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
      const contract = getContract(gateway, CHANNEL, CC_ACCESS, 'AccessControlContract');
      await contract.submitTransaction('GrantPermission', permissionID, grantedTo, resource, action, grantedBy);
      return res.status(201).json({ message: 'Permission granted', permissionID });
    } finally {
      gateway.close();
    }
  } catch (err) {
    return res.status(500).json({ error: err.message });
  }
});

/**
 * POST /api/access/revoke
 * Body: { permissionID }
 */
router.post('/revoke', async (req, res) => {
  let { permissionID } = req.body;
  permissionID = permissionID ? String(permissionID).trim() : '';
  if (!permissionID) return res.status(400).json({ error: 'permissionID is required' });

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
      const contract = getContract(gateway, CHANNEL, CC_ACCESS, 'AccessControlContract');
      await contract.submitTransaction('RevokePermission', permissionID);
      return res.json({ message: 'Permission revoked', permissionID });
    } finally {
      gateway.close();
    }
  } catch (err) {
    return res.status(500).json({ error: err.message });
  }
});

/**
 * GET /api/access/read/:callerMSPID/:subscriberID
 * Access-controlled subscriber read:
 * 1. If caller is NCCMSP or the originating MNO owner, read access is granted automatically.
 * 2. If caller is a third-party MNO, checks AccessControl contract for explicit permission grant.
 */
router.get('/read/:callerMSPID/:subscriberID', async (req, res) => {
  const callerMSPID = req.params.callerMSPID ? req.params.callerMSPID.trim() : '';
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
      // Step 1: Fetch subscriber record
      const regContract = getContract(gateway, CHANNEL, CC_REGISTRATION, 'SubscriberRegistrationContract');
      const data = await regContract.evaluateTransaction('GetSubscriber', subscriberID);
      const str = Buffer.from(data).toString().trim();

      if (!str) {
        return res.status(404).json({ error: `Subscriber ${subscriberID} not found on ledger` });
      }

      const sub = JSON.parse(str);
      const normCaller = callerMSPID.toUpperCase();
      const normMno = (sub.mno || '').toUpperCase();
      const callerBase = normCaller.replace('MSP', '');

      // Check if caller is owner or NCCMSP regulator
      const isOwner = normCaller === 'NCCMSP' || normMno.includes(callerBase) || normCaller.includes(normMno);

      if (!isOwner) {
        // Step 2: Enforce cross-organisation Access Control check via chaincode
        const acContract = getContract(gateway, CHANNEL, CC_ACCESS, 'AccessControlContract');
        const perm = await acContract.evaluateTransaction('ReadSubscriber', callerMSPID, subscriberID);
        if (Buffer.from(perm).toString() !== 'GRANTED') {
          return res.status(403).json({ error: `Access denied: ${callerMSPID} does not have READ permission for subscriber ${subscriberID}` });
        }
      }

      return res.json(sub);
    } finally {
      gateway.close();
    }
  } catch (err) {
    const msg = err.message || '';
    return res.status(msg.includes('denied') ? 403 : 500).json({ error: msg });
  }
});

module.exports = router;
