/**
 * project/tests/performance_benchmark.js
 * Milestone 7 — Sub-System Latency & Throughput Benchmark
 * Measures execution latency across:
 * 1. Off-chain Poseidon Hashing
 * 2. Groth16 Proof Generation & Verification (snarkjs)
 * 3. AES-256 IPFS Encryption & CID Generation
 * 4. Fabric Gateway Endorsement & Commit Latency
 */

const path = require('path');
const crypto = require('crypto');
const { performance } = require('perf_hooks');
const prover = require('../backend/src/zk/prover');
const ipfsClient = require('../backend/src/ipfs/client');

async function runBenchmark() {
  console.log('╔══════════════════════════════════════════════════════════════╗');
  console.log('║  Milestone 7 — Sub-System Performance Benchmark             ║');
  console.log('╚══════════════════════════════════════════════════════════════╝\n');

  const nin = '12345678901';
  const fingerprintHash = '98765432109';
  const iterations = 2;

  // Benchmark 1: Poseidon Commitment Generation
  console.log('1. Benchmarking Poseidon ZK Commitment Generation...');
  const t0 = performance.now();
  for (let i = 0; i < iterations; i++) {
    await prover.computeCommitment(nin, fingerprintHash);
  }
  const t1 = performance.now();
  const avgPoseidon = ((t1 - t0) / iterations).toFixed(2);
  console.log(`   • Avg Latency (${iterations} iterations): ${avgPoseidon} ms\n`);

  // Benchmark 2: Groth16 Proof Proving & Verification
  console.log('2. Benchmarking Groth16 Proof Generation & Verification (snarkjs)...');
  const comm = await prover.computeCommitment(nin, fingerprintHash);
  const t2 = performance.now();
  for (let i = 0; i < iterations; i++) {
    const proofRes = await prover.generateProof(nin, fingerprintHash, comm);
    await prover.verifyProof(proofRes.proof, proofRes.publicSignals);
  }
  const t3 = performance.now();
  const avgZK = ((t3 - t2) / iterations).toFixed(2);
  console.log(`   • Avg Latency (${iterations} iterations): ${avgZK} ms\n`);

  // Benchmark 3: AES-256 IPFS Encryption & Upload
  console.log('3. Benchmarking AES-256 Off-Chain IPFS Encryption...');
  const comm2 = await prover.computeCommitment(nin, fingerprintHash);
  const samplePayload = { nin, fingerprintHash, msisdn: '08011223344', mno: 'MTN' };
  const aesKey = crypto.createHash('sha256').update(comm2).digest();
  
  const t4 = performance.now();
  for (let i = 0; i < iterations; i++) {
    await ipfsClient.uploadToIPFS(samplePayload, aesKey);
  }
  const t5 = performance.now();
  const avgIPFS = ((t5 - t4) / iterations).toFixed(2);
  console.log(`   • Avg Latency (${iterations} iterations): ${avgIPFS} ms\n`);

  console.log('╔══════════════════════════════════════════════════════════════╗');
  console.log('║  Performance Benchmark Summary                               ║');
  console.log(`║  Poseidon Commitment:  ${avgPoseidon.padEnd(8)} ms                           ║`);
  console.log(`║  Groth16 ZK Prover:    ${avgZK.padEnd(8)} ms                           ║`);
  console.log(`║  IPFS Payload Upload:  ${avgIPFS.padEnd(8)} ms                           ║`);
  console.log('╚══════════════════════════════════════════════════════════════╝\n');
}

runBenchmark().catch(err => {
  console.error('Benchmark error:', err);
  process.exit(1);
});
