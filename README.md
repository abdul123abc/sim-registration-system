# Privacy-Preserving SIM Registration System

An academic prototype for privacy-preserving SIM registration using Hyperledger Fabric, zero-knowledge proofs, encrypted IPFS storage, and a React dashboard.

This README is written for non-technical readers as well as developers. Think of the system as a secure registration office:

- The **frontend** is the reception desk.
- The **backend** is the trained clerk coordinating the work.
- The **zero-knowledge proof** checks an identity claim without exposing the identity details.
- **IPFS** stores an encrypted copy of sensitive information.
- **Hyperledger Fabric** is the shared, tamper-evident record book.

This is a research and demonstration prototype, not a production national identity platform.

## What the system does

When a subscriber is registered, the system:

1. Receives a NIN, fingerprint hash, phone number, and mobile network.
2. Computes an identity commitment, similar to a sealed mathematical fingerprint.
3. Creates a zero-knowledge proof that the private identity inputs match that commitment.
4. Encrypts the sensitive payload with AES-256-GCM.
5. Uploads the encrypted payload to IPFS and receives a CID, which is a content address.
6. Stores the subscriber ID, phone number, operator, commitment, IPFS CID, and status on Fabric.
7. Records an audit event in the update-tracking chaincode.

Raw NIN and fingerprint data are not written directly to the Fabric ledger.

## How everything connects

```text
Browser
	|
	v
React frontend :3000
	|
	v
Express backend :3001
	|----> Poseidon commitment + Groth16 proof
	|----> AES-256-GCM encryption --> IPFS
	|----> Fabric Gateway --> NCC peer
															|---- subscriber-registration
															|---- identity-validation
															|---- update-tracking
															|---- access-control
															v
												Fabric ledger
```

### A simple analogy

Imagine a restaurant. The browser is the customer, the backend is the waiter, chaincode is the rulebook, IPFS is the secure storage room, and Fabric is the permanent transaction journal. The waiter coordinates the request, but the rulebook decides whether the order is allowed. This is why the backend cannot simply “edit” a Fabric record.

---

## Technical Stack Overview

| Component | Plain-language meaning | Role here |
| --- | --- | --- |
| React | User-interface library | Dashboard, registration form, lookups, audit, and access control |
| Express.js | Node.js web server framework | Backend API |
| Docker | Isolated application containers | Portable setup across computers |
| Hyperledger Fabric | Permissioned blockchain | Shared registration ledger |
| Chaincode | Fabric smart-contract program | Registration and access rules |
| Go | Programming language | Chaincode implementation |
| Groth16 and Circom | Zero-knowledge proof tools | Prove identity consistency without revealing inputs |
| Poseidon | ZK-friendly hash | Identity commitment calculation |
| IPFS | Content-addressed storage | Encrypted off-chain payload storage |
| AES-256-GCM | Authenticated encryption | Protects sensitive registration data |
| CouchDB | Queryable database used by Fabric | Subscriber and audit queries |

* **Consensus & Smart Contracts**: Hyperledger Fabric v2.5.7 (Raft Consensus, CCaaS Chaincode in Go).
* **Organizations**: NCC (Regulator), MTN, Airtel, Glo, 9mobile.
* **Privacy Engine**: Circom 2.1 + `snarkjs` (Groth16 over BN254) + Poseidon field element hash commitments.
* **Storage Layer**: IPFS (Kubo) with AES-256-GCM symmetric payload envelope encryption.
* **Middleware**: Express.js Node.js Gateway with `@hyperledger/fabric-gateway` gRPC client.
* **Frontend**: React 18 with Vercel/Linear design aesthetics, Plus Jakarta Sans, and JetBrains Mono typography.

## Privacy model and important limitation

The current circuit uses Poseidon consistently in both the backend and the Circom circuit. Some older comments mention SHA-256, but SHA-256 is not the hash used inside the current proof circuit.

The ledger stores a commitment and an IPFS reference, not the raw NIN. IPFS receives an encrypted envelope containing the payload, initialization vector, and authentication tag. A commitment is not encryption: it is for verification and comparison, not for recovering the original identity.

The prototype still needs production-grade key management, authentication, authorization, secrets storage, audit controls, legal review, and independent security testing before real deployment.

## Project layout

```text
project/
├── backend/                 Express API and Fabric client
├── frontend/                React dashboard
├── chaincode/                Go smart contracts
├── network/                 Fabric peers, certificates, channel, scripts
├── zk/                      Circom circuit and compiled proof artifacts
├── tests/                   Integration and performance tests
├── docker-compose.yml       Backend and frontend containers
├── start.sh                 One-command startup
└── README_RUN.md            Short run guide
```

---

## Quick Start & Verification

### Requirements

Install Docker Engine, Docker Compose v2, Git, Node.js 20 or newer, npm, and the Hyperledger Fabric command-line tools used by the network scripts.

```bash
docker --version
docker compose version
node --version
npm --version
```

Docker must be running. On Linux, your user must be allowed to use Docker.

### Fastest startup

From this `project` directory:

```bash
bash start.sh
```

The script creates the shared `sim_net` network, starts Fabric and CouchDB, starts the frontend and backend, then restores or deploys the four CCaaS chaincode services.

Open the dashboard at `http://localhost:3000`. The backend health endpoint is `http://localhost:3001/health`.

You should eventually see `sim-frontend`, `sim-backend`, the Fabric peers and orderer, and these four chaincode containers:

```text
subscriber-registration
identity-validation
update-tracking
access-control
```

Verify the web services:

```bash
curl -i http://localhost:3000/
curl -i http://localhost:3001/health
```

Both should return HTTP `200` when ready.

The health response reports the subscriber count from the NCC CouchDB ledger-state database and reports the configured peer topology when that ledger state is reachable. The backend container does not mount the Docker socket, so it does not pretend to inspect host container processes or directly expose Raft orderer metrics.

## Master QA validation

The project includes a deployment-level QA gate at `tests/master_qa.sh`. It is intended for a QA engineer, release check, or operator who needs one command to validate the running system.

Run it from the project directory after `./start.sh` has completed:

```bash
bash tests/master_qa.sh
```

The suite is non-destructive. It does not stop containers, delete Fabric volumes, recreate the channel, or reset the ledger. It creates one unique test subscriber so it can verify a complete transaction path.

### What the master QA suite tests

1. Docker daemon and Docker Compose availability.
2. Application and Fabric Compose-file syntax.
3. Existence of the shared `sim_net` Docker network.
4. Running IPFS, backend, frontend, Fabric, and four CCaaS containers.
5. Required zero-knowledge artifacts: WASM, proving key, and verification key.
6. IPFS Kubo API availability.
7. Frontend HTTP availability.
8. Backend health endpoint availability.
9. DNS and TCP reachability of every CCaaS service on its correct port.
10. End-to-end registration through ZK commitment/proof, AES encryption, IPFS upload/pinning, and Fabric submission.
11. Retrieval of the new subscriber from the ledger.
12. Presence of the corresponding `REGISTERED` audit event.
13. Verification that the returned IPFS CID is actually pinned.

### Reading the result

The script prints `PASS`, `WARN`, and `FAIL` records and exits with:

- `0`: no failed checks; the master QA gate passed.
- `1`: one or more checks failed; inspect the failed check and service logs.

A degraded health report is recorded as a warning so the suite can still complete the more decisive end-to-end registration test. A successful registration, ledger query, audit lookup, and CID pin check demonstrate that the transaction path is working. A healthy response normally includes `activePeers: 5`, `totalPeers: 5`, a non-zero `totalSubscribers` value when registrations exist, and `fabricNetwork: "reachable"`.

### Recommended QA sequence

```bash
./start.sh
bash tests/master_qa.sh
```

If the suite fails, collect the following before changing or deleting anything:

```bash
docker ps -a
docker compose logs --tail=200 backend frontend ipfs
docker logs subscriber-registration --tail=200
docker logs update-tracking --tail=200
```

Do not use `docker compose down -v` as a first troubleshooting step. The `-v` option removes local Fabric and CouchDB volumes and can erase the state needed to reproduce the failure.

### 1. Run Complete Master Verification Suite
```bash
bash ./tests/test_all.sh
```

### 2. Start Middleware Backend Gateway
```bash
cd ./backend
npm install
npm run dev
```

### 3. Start React Frontend Dashboard
```bash
cd ./frontend
npm install
npm start
```
*Access UI at `http://localhost:3000`.*

## Registration flow in plain language

1. The frontend sends the form to the backend.
2. The backend validates required fields and computes `Poseidon(NIN, fingerprintHash)`.
3. The zero-knowledge prover demonstrates that the private inputs produce the public commitment.
4. The backend encrypts the complete payload with AES-256-GCM.
5. IPFS stores the encrypted payload and returns a CID.
6. Fabric Gateway submits `RegisterSubscriber` to the subscriber-registration chaincode.
7. The chaincode rejects duplicate active phone numbers, duplicate subscriber IDs, and more than four active registrations for one identity under one operator.
8. The backend records a `REGISTERED` event in update-tracking.

Use the dashboard or test the API directly:

```bash
curl -X POST http://localhost:3001/api/registration/register \
	-H 'Content-Type: application/json' \
	-d '{"nin":"12345678901234","fingerprintHash":"0xabc","msisdn":"2348000000002","mno":"MTN"}'
```

A successful request returns HTTP `201` with a generated subscriber ID, commitment, and IPFS hash.

The NCC dashboard reads its subscriber and audit views from these CouchDB-backed APIs:

```text
GET /api/registration/subscribers/all
GET /api/audit/all
```

These endpoints are included in the master QA validation and should return ledger records rather than placeholder zero values.

## Chaincodes and CCaaS

| Chaincode | Purpose |
| --- | --- |
| `subscriber-registration` | Creates, reads, queries, and deactivates subscriber records |
| `identity-validation` | Supports identity validation rules |
| `update-tracking` | Records registration and update events |
| `access-control` | Handles permission grants and revocations |

These chaincodes run as CCaaS, meaning “Chaincode as a Service.” Fabric stores the definition, while a separate Docker container exposes the chaincode gRPC service. All of those containers must be attached to `sim_net`.

That is why an error such as `lookup update-tracking ... no such host` means a chaincode container or Docker-network problem, not necessarily invalid form data.

## Latest verified QA result

```text
Passed: 35
Warnings: 0
Failed: 0
MASTER QA RESULT: PASSED
```

## Repository hygiene

The repository keeps source code, configuration, required runtime artifacts, and reproducible test scripts. Disposable workspace snapshots, Docker event logs, empty directories, and compiled chaincode executables are intentionally excluded. The `.gitignore` also excludes Node dependency folders, temporary QA output, generated Fabric state, and generated chaincode binaries.

Do not manually delete these runtime-required assets while troubleshooting:

- `network/crypto-config/` and `network/channel-artifacts/`
- `zk/build/` and `zk/pot12_final_prepared.ptau`
- Go `vendor/` directories used by the offline CCaaS build flow
- Node `node_modules/` directories when using the existing application containers

---

## Verification Reports (Milestones 1–7)

- [Milestone 1 Report — Scaffolding](../milestone1_report.md)
- [Milestone 2 Report — Fabric Network Infrastructure](../milestone2_report.md)
- [Milestone 3 Report — Chaincode Deployment](../milestone3_report.md)
- [Milestone 4 Report — Zero-Knowledge Circuits](../milestone4_report.md)
- [Milestone 5 Report — Express API Gateway](../milestone5_report.md)
- [Milestone 6 Report — Enterprise React UI](../milestone6_report.md)
- [Milestone 7 Report — Master E2E & Benchmarks](../milestone7_report.md)
