/**
 * backend/src/zk/prover.js
 * Zero-Knowledge Proof generation and verification wrapper.
 * Technology Stack: snarkjs (Groth16) + circomlibjs (Poseidon)
 * Chapter Three, Section 3.2.
 *
 * DESIGN ASSUMPTION (see nin_commitment.circom): Poseidon hash is used inside
 * the circuit in place of SHA-256 for practical constraint-count reasons.
 * The backend uses the same Poseidon implementation (circomlibjs) to compute
 * the commitment that is stored on-chain.
 */

const snarkjs = require('snarkjs');
const { buildPoseidon } = require('circomlibjs');
const path = require('path');
const fs = require('fs');

const ZK_BUILD_DIR = process.env.ZK_BUILD_DIR || path.resolve(__dirname, '../../../zk/build');

let poseidon = null;

/**
 * Initialise the Poseidon hash function (loaded once at startup).
 */
async function getPoseidon() {
  if (!poseidon) {
    poseidon = await buildPoseidon();
  }
  return poseidon;
}

/**
 * computeCommitment — compute Poseidon(nin, fingerprintHash) as a BigInt.
 * This is the value stored on-chain and used as the public signal in the ZK proof.
 *
 * @param {string} nin              NIN as a decimal string (treated as field element)
 * @param {string} fingerprintHash  Hex string of fingerprint hash
 * @returns {Promise<string>} commitment as a decimal string (for snarkjs)
 */
async function computeCommitment(nin, fingerprintHash) {
  const poseidonFn = await getPoseidon();
  // Convert inputs to BigInts (field elements).
  const ninBI = BigInt('0x' + Buffer.from(nin).toString('hex'));
  const fpBI = BigInt('0x' + fingerprintHash.replace('0x', ''));
  const hash = poseidonFn([ninBI, fpBI]);
  return poseidonFn.F.toString(hash);
}

/**
 * generateProof — create a Groth16 proof that the caller knows (nin, fingerprintHash)
 * that produce the given commitment.
 *
 * @param {string} nin
 * @param {string} fingerprintHash
 * @param {string} commitment    decimal string (from computeCommitment)
 * @returns {Promise<{proof: object, publicSignals: string[]}>}
 */
async function generateProof(nin, fingerprintHash, commitment) {
  const ninBI = BigInt('0x' + Buffer.from(nin).toString('hex'));
  const fpBI = BigInt('0x' + fingerprintHash.replace('0x', ''));

  const input = {
    nin: ninBI.toString(),
    fingerprintHash: fpBI.toString(),
    commitment: commitment,
  };

  const wasmPath = path.join(ZK_BUILD_DIR, 'nin_commitment_js', 'nin_commitment.wasm');
  const zkeyPath = path.join(ZK_BUILD_DIR, 'nin_commitment_final.zkey');

  const { proof, publicSignals } = await snarkjs.groth16.fullProve(input, wasmPath, zkeyPath);
  return { proof, publicSignals };
}

/**
 * verifyProof — verify a Groth16 proof against the verification key.
 *
 * @param {object} proof
 * @param {string[]} publicSignals
 * @returns {Promise<boolean>}
 */
async function verifyProof(proof, publicSignals) {
  const vkeyPath = path.join(ZK_BUILD_DIR, 'verification_key.json');
  const vkey = JSON.parse(fs.readFileSync(vkeyPath, 'utf8'));
  return snarkjs.groth16.verify(vkey, publicSignals, proof);
}

module.exports = { computeCommitment, generateProof, verifyProof };
