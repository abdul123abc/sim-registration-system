/**
 * backend/src/ipfs/client.js
 * IPFS (Kubo) client wrapper for encrypted subscriber payload storage.
 * Technology Stack: IPFS Kubo + AES-256 encryption.
 * Chapter Three, Section 3.2 — off-chain encrypted storage.
 *
 * Workflow:
 *   1. AES-256-GCM encrypt the subscriber payload using a symmetric key.
 *   2. Upload the ciphertext to IPFS.
 *   3. Return the CID — this is what gets committed on-chain.
 *   Raw subscriber data never touches the ledger.
 */

const crypto = require('crypto');

const IPFS_API_URL = process.env.IPFS_API_URL || 'http://ipfs:5001';
const IPFS_TIMEOUT_MS = Number(process.env.IPFS_TIMEOUT_MS || 15000);
const ALLOW_IPFS_FALLBACK = process.env.IPFS_ALLOW_FALLBACK === 'true';

let ipfsClient = null;
let createFn = null;

/**
 * Get (or lazily create) the IPFS HTTP client.
 */
async function getIPFSClient() {
  if (!ipfsClient) {
    if (!createFn) {
      const module = await import('ipfs-http-client');
      createFn = module.create;
    }
    ipfsClient = createFn({ url: IPFS_API_URL });
  }
  return ipfsClient;
}

/**
 * encryptPayload — AES-256-GCM encrypt a JSON payload.
 *
 * @param {object} payload    Plain-text subscriber data object
 * @param {Buffer} key        32-byte AES key
 * @returns {{ ciphertext: Buffer, iv: Buffer, authTag: Buffer }}
 */
function encryptPayload(payload, key) {
  const iv = crypto.randomBytes(12); // 96-bit IV for GCM
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const plaintext = Buffer.from(JSON.stringify(payload), 'utf8');
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const authTag = cipher.getAuthTag();
  return { ciphertext, iv, authTag };
}

/**
 * decryptPayload — AES-256-GCM decrypt an encrypted subscriber payload.
 *
 * @param {Buffer} ciphertext
 * @param {Buffer} key
 * @param {Buffer} iv
 * @param {Buffer} authTag
 * @returns {object} Decrypted payload
 */
function decryptPayload(ciphertext, key, iv, authTag) {
  const decipher = crypto.createDecipheriv('aes-256-gcm', key, iv);
  decipher.setAuthTag(authTag);
  const plaintext = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
  return JSON.parse(plaintext.toString('utf8'));
}

function withTimeout(promise, operation) {
  let timeout;
  const deadline = new Promise((_, reject) => {
    timeout = setTimeout(() => {
      reject(new Error(`IPFS ${operation} timed out after ${IPFS_TIMEOUT_MS}ms at ${IPFS_API_URL}`));
    }, IPFS_TIMEOUT_MS);
  });

  return Promise.race([promise, deadline]).finally(() => clearTimeout(timeout));
}

/**
 * uploadToIPFS — encrypt a subscriber payload and add it to IPFS.
 * Returns the CID string that will be committed on-chain.
 *
 * @param {object} payload   Raw subscriber data (NIN, biometrics, etc.)
 * @param {Buffer} key       32-byte AES-256 encryption key
 * @returns {Promise<{ cid: string, iv: string, authTag: string }>}
 */
async function uploadToIPFS(payload, key) {
  const { ciphertext, iv, authTag } = encryptPayload(payload, key);

  // Package iv + authTag + ciphertext into a single envelope for storage.
  const envelope = JSON.stringify({
    iv: iv.toString('hex'),
    authTag: authTag.toString('hex'),
    data: ciphertext.toString('hex'),
  });

  try {
    const client = await getIPFSClient();
    const result = await withTimeout(
      client.add(Buffer.from(envelope, 'utf8')),
      'upload'
    );
    await withTimeout(client.pin.add(result.cid), 'pin');
    return {
      cid: result.cid.toString(),
      iv: iv.toString('hex'),
      authTag: authTag.toString('hex'),
    };
  } catch (err) {
    if (!ALLOW_IPFS_FALLBACK) {
      throw new Error(`Encrypted payload could not be stored in IPFS: ${err.message}`);
    }

    const cidHash = 'Qm' + crypto.createHash('sha256').update(envelope).digest('hex').substring(0, 44);
    return {
      cid: cidHash,
      iv: iv.toString('hex'),
      authTag: authTag.toString('hex'),
    };
  }
}

/**
 * downloadFromIPFS — retrieve and decrypt a subscriber payload by CID.
 *
 * @param {string} cid     IPFS content identifier
 * @param {Buffer} key     32-byte AES-256 decryption key
 * @returns {Promise<object>}
 */
async function downloadFromIPFS(cid, key) {
  const client = getIPFSClient();
  const chunks = [];
  for await (const chunk of client.cat(cid)) {
    chunks.push(chunk);
  }
  const envelope = JSON.parse(Buffer.concat(chunks).toString('utf8'));
  return decryptPayload(
    Buffer.from(envelope.data, 'hex'),
    key,
    Buffer.from(envelope.iv, 'hex'),
    Buffer.from(envelope.authTag, 'hex'),
  );
}

module.exports = { uploadToIPFS, downloadFromIPFS };
