// project/zk/test.js
// Standalone Test Runner for Milestone 4 (Zero-Knowledge Proofs)

const snarkjs = require("snarkjs");
const { buildPoseidon } = require("circomlibjs");
const fs = require("fs");
const path = require("path");

async function runTests() {
  console.log("╔══════════════════════════════════════════════════════════════╗");
  console.log("║  Milestone 4 — Zero-Knowledge Proof Test Suite               ║");
  console.log("╚══════════════════════════════════════════════════════════════╝");
  console.log("");

  const wasmPath = path.join(__dirname, "build", "nin_commitment_js", "nin_commitment.wasm");
  const zkeyPath = path.join(__dirname, "build", "nin_commitment_final.zkey");
  const vkeyPath = path.join(__dirname, "build", "verification_key.json");

  // Check build artifacts
  if (!fs.existsSync(wasmPath) || !fs.existsSync(zkeyPath) || !fs.existsSync(vkeyPath)) {
    console.error("  ✗ ERROR: Build artifacts missing in zk/build/. Please run 'bash compile.sh' first.");
    process.exit(1);
  }

  const poseidon = await buildPoseidon();
  const vKey = JSON.parse(fs.readFileSync(vkeyPath, "utf8"));

  let passed = 0;
  let failed = 0;

  // ── TEST 1: Valid Proof Generation & Verification ──────────────────────────
  console.log("─── Test 1: Valid NIN & Biometric Commitment ──────────────────");
  const nin1 = "12345678901";
  const fp1 = "98765432109";

  const nin1BI = BigInt('0x' + Buffer.from(nin1).toString('hex'));
  const fp1BI = BigInt('0x' + fp1);
  const hash1 = poseidon([nin1BI, fp1BI]);
  const commitment1 = poseidon.F.toString(hash1);

  console.log("  NIN (Private):          ", nin1);
  console.log("  Fingerprint (Private):  ", fp1);
  console.log("  Commitment (Public):   ", commitment1);

  const t0 = Date.now();
  const { proof: proof1, publicSignals: pub1 } = await snarkjs.groth16.fullProve(
    { nin: nin1BI.toString(), fingerprintHash: fp1BI.toString(), commitment: commitment1 },
    wasmPath,
    zkeyPath
  );
  const proveTime = Date.now() - t0;

  const t1 = Date.now();
  const isValid1 = await snarkjs.groth16.verify(vKey, pub1, proof1);
  const verifyTime = Date.now() - t1;

  if (isValid1 === true) {
    console.log(`  ✓ PASSED — Proof generated in ${proveTime}ms, verified in ${verifyTime}ms`);
    passed++;
  } else {
    console.log("  ✗ FAILED — Proof failed verification");
    failed++;
  }
  console.log("");

  // ── TEST 2: Invalid / Tampered Commitment Rejection ───────────────────────
  console.log("─── Test 2: Tampered Public Signal (Fake Commitment) ──────────");
  const fakeCommitment = "99999999999999999999999999999999999999999999999999";
  const isValid2 = await snarkjs.groth16.verify(vKey, [fakeCommitment], proof1);

  if (isValid2 === false) {
    console.log("  ✓ PASSED — Invalid commitment correctly REJECTED");
    passed++;
  } else {
    console.log("  ✗ FAILED — Invalid commitment was incorrectly accepted!");
    failed++;
  }
  console.log("");

  // ── TEST 3: Invalid Witness (Wrong NIN for same Commitment) ───────────────
  console.log("─── Test 3: Wrong NIN Witness (Forgery Attempt) ───────────────");
  const wrongNIN = "00000000000";
  const wrongNIN_BI = BigInt('0x' + Buffer.from(wrongNIN).toString('hex'));

  let forgeryFailed = false;
  const originalStderrWrite = process.stderr.write;
  process.stderr.write = () => {}; // Temporarily suppress internal C++/WASM error output
  try {
    await snarkjs.groth16.fullProve(
      { nin: wrongNIN_BI.toString(), fingerprintHash: fp1BI.toString(), commitment: commitment1 },
      wasmPath,
      zkeyPath
    );
  } catch (err) {
    forgeryFailed = true;
  } finally {
    process.stderr.write = originalStderrWrite; // Restore stderr
  }

  if (forgeryFailed) {
    console.log("  ✓ PASSED — Circuit constraint prevented proof generation for wrong NIN");
    passed++;
  } else {
    console.log("  ✗ FAILED — Forgery proof generated when it should have failed!");
    failed++;
  }
  console.log("");

  // ── Summary ────────────────────────────────────────────────────────────────
  console.log("╔══════════════════════════════════════════════════════════════╗");
  console.log(`║  Milestone 4 ZK Test Summary                                 ║`);
  console.log(`║  Passed: ${passed}                                                   ║`);
  console.log(`║  Failed: ${failed}                                                   ║`);
  console.log("╚══════════════════════════════════════════════════════════════╝");

  if (failed > 0) {
    process.exit(1);
  } else {
    process.exit(0);
  }
}

runTests().catch((err) => {
  console.error("Test execution error:", err);
  process.exit(1);
});
