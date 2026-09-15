# HyperLedger Conversation Summary

## Purpose

This document records the work completed during the containerization, portability, troubleshooting, QA, and dashboard-correction work for the privacy-preserving SIM registration prototype.

The system is an academic prototype combining:

- Hyperledger Fabric v2.5.7
- Go chaincode running as Chaincode as a Service (CCaaS)
- Express.js backend
- React frontend
- Circom, Poseidon, and Groth16 zero-knowledge proofs
- AES-256-GCM encrypted IPFS storage
- CouchDB Fabric world state
- Docker Compose deployment

> This is a research and demonstration system. It is not production-ready for real national identity or biometric data without security, legal, operational, and privacy review.

## Original Objectives

The work began with these goals:

1. Containerize the complete application.
2. Remove machine-specific absolute paths.
3. Make the project portable to other computers.
4. Provide a one-command startup process.
5. Create clear documentation for non-technical users.
6. Test the complete system end to end.
7. Create a professional master QA script.
8. Clean unnecessary files from the workspace.
9. Add OS-aware prerequisite setup for Linux and Windows.
10. Explain why dashboard values were inaccurate.

## Final Architecture

```text
Browser
  |
  v
React frontend :3000
  |
  v
Express backend :3001
  |
  +--> Zero-knowledge commitment and Groth16 proof
  +--> AES-256-GCM encryption
  +--> IPFS Kubo :5001
  +--> Fabric Gateway
          |
          v
  Hyperledger Fabric channel: sim-registration-channel
          |
          +--> NCC peer
          +--> MTN peer
          +--> Airtel peer
          +--> Glo peer
          +--> 9mobile peer
          +--> Raft orderer
          +--> CouchDB services

CCaaS services on sim_net:
  subscriber-registration :9999
  identity-validation     :9998
  update-tracking         :9997
  access-control          :9996
```

All Docker services that need to communicate use the shared external network `sim_net`.

## Important Implementation Changes

### Portable path resolution

Added environment-aware path resolution in:

- `backend/src/config/network.js`
- `backend/src/fabric/gateway.js`
- route modules that access Fabric files
- `backend/src/zk/prover.js`

The backend now supports paths such as:

```text
PROJECT_ROOT=/app
NETWORK_DIR=/app/network
ZK_BUILD_DIR=/zk/build
```

Machine-specific paths such as `/home/molade/HyperLedger/...` are no longer required for runtime operation.

### Docker application containers

Added and configured:

- `backend/Dockerfile`
- `frontend/Dockerfile`
- root `docker-compose.yml`

The backend and frontend use Node.js 20 Alpine images.

A critical Docker issue was fixed: bind mounts originally replaced `/app` and hid the dependencies installed in the image. The Compose configuration now preserves dependencies with anonymous `node_modules` volumes:

```yaml
volumes:
  - ./backend:/app
  - /app/node_modules
```

and:

```yaml
volumes:
  - ./frontend:/app
  - /app/node_modules
```

The startup script recreates the application containers and anonymous dependency volumes so stale partial dependency installations do not survive rebuilds.

### IPFS service

Added a Kubo IPFS service to the application Compose file:

```yaml
image: ipfs/kubo:v0.30.0
container_name: ipfs
```

The backend uses:

```text
IPFS_API_URL=http://ipfs:5001
IPFS_TIMEOUT_MS=15000
IPFS_ALLOW_FALLBACK=false
```

The IPFS client now:

- awaits creation of the IPFS client
- encrypts the payload with AES-256-GCM
- uploads the encrypted envelope
- pins the returned CID
- fails clearly after a timeout
- does not silently generate a fake CID unless fallback is explicitly enabled

Direct measurement showed AES encryption plus IPFS upload and pinning took approximately 887 ms. The long delays originally blamed on IPFS were actually Fabric CCaaS startup failures.

### Fabric CCaaS deployment

The Fabric network uses four standalone chaincode service containers:

- `subscriber-registration`
- `identity-validation`
- `update-tracking`
- `access-control`

The deployment script was made restart-safe in:

- `network/scripts/deployChaincode.sh`
- `network/scripts/network.sh`

When a chaincode definition is already committed, deployment now restores only its CCaaS service instead of attempting to commit sequence 1 again.

A duplicate package-label bug was fixed. Multiple installed packages could have the same label, and the script sometimes selected a stale package ID. The package lookup now prefers the package ID referenced by the committed channel definition.

This fixed the Fabric error:

```text
could not launch chaincode ... timeout expired while starting chaincode
```

The correct committed package ID for `subscriber-registration` was selected instead of the stale package.

### Fingerprint input normalization

The frontend originally used a misleading demo value:

```text
98765432109
```

That looked like an 11-digit hash but was not a real cryptographic hash.

The system now:

- generates 64-character hexadecimal demo fingerprint values
- accepts existing 64-character hexadecimal SHA-256 values
- converts weak or digit-only input into a SHA-256 hexadecimal digest before it reaches the ZK commitment, proof, and encrypted payload stages

A hash is not encryption. The hash creates a one-way fingerprint; AES-256-GCM protects the stored payload.

### Health endpoint correction

The old health endpoint attempted to run `docker ps` inside the backend container. The backend intentionally does not mount the Docker socket, so it returned this misleading message:

```text
Fabric services are running outside the app container; docker CLI unavailable here.
```

The health model was corrected to use reachable Fabric ledger state and the configured peer topology. The health response now looks like:

```json
{
  "status": "ok",
  "activePeers": 5,
  "totalPeers": 5,
  "totalSubscribers": 22,
  "ordererRunning": null,
  "fabricNetwork": "reachable",
  "consensusStatus": "Fabric ledger state reachable; 5/5 peers configured",
  "healthBasis": "NCC CouchDB ledger-state reachability and configured Fabric peer topology; orderer metrics are not exposed to the app container"
}
```

The dashboard metric was renamed from `Consensus Status` to `Fabric Network Status` because the backend does not directly inspect the orderer’s Raft metrics.

### NCC dashboard data retrieval

The top dashboard metric and the NCC dashboard initially used different data paths.

The top metric used `/health`, while the NCC views used:

- `/api/registration/subscribers/all`
- `/api/audit/all`

Those routes used `curl` inside the Node Alpine backend container. Alpine did not include `curl`, so the routes silently returned empty arrays.

The routes now use BusyBox-compatible `wget` and return visible `502` errors if CouchDB cannot be queried.

This fixed the dashboard showing:

```text
Registered Subscribers: 0
Audit Logs: empty
```

The APIs subsequently returned real data, including subscriber records and audit events.

## Startup Scripts

### Linux

Use:

```bash
cd /path/to/HyperLedger/project
chmod +x start.sh
./start.sh
```

The Linux launcher:

1. Detects Linux.
2. Checks whether Docker, Compose, curl, and Git are already installed.
3. Supports Debian/Ubuntu through `apt-get`.
4. Supports Fedora/Red Hat/Rocky/Alma through `dnf`.
5. Supports older Red Hat-family distributions through `yum`.
6. Starts Docker with `systemctl` when possible.
7. Creates `sim_net`.
8. Checks or pulls `node:20-alpine`.
9. Starts Fabric and CouchDB.
10. Recreates application containers and dependency volumes.
11. Starts backend, frontend, and IPFS.
12. Restores committed CCaaS services.

Automatic package installation can be disabled with:

```bash
AUTO_INSTALL=false ./start.sh
```

The installer was corrected to skip package installation when Docker, Compose, curl, and Git are already available. This avoids conflicts between Docker CE and Fedora/Moby packages.

### Windows

Use PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\start.ps1
```

The Windows launcher:

1. Uses `winget` to install Docker Desktop if needed.
2. Checks WSL.
3. Requests WSL installation when missing.
4. Starts Docker Desktop.
5. Converts the Windows project path to a WSL path.
6. Runs the tested Bash launcher inside WSL.

A Windows restart may be required after installing WSL.

## Cleanup Performed

Confirmed disposable files removed:

- root `path.txt`
- root `tree.txt`
- root `prompt.md`
- `project/network/scripts/docker_events.log`
- compiled chaincode binaries beside the Go sources
- empty directories

The milestone reports were intentionally preserved because they are project documentation.

Required runtime assets were preserved:

- `network/crypto-config/`
- `network/channel-artifacts/`
- `zk/build/`
- `zk/pot12_final_prepared.ptau`
- Go `vendor/` directories
- package lock files
- Dockerfiles and Compose files

The `.gitignore` now excludes generated QA output, generated chaincode binaries, Docker event logs, dependency directories, Fabric state, and ZK build output.

## Master QA Suite

Added:

```text
tests/master_qa.sh
```

Run it after startup:

```bash
./start.sh
bash tests/master_qa.sh
```

The suite is non-destructive. It does not stop containers, delete volumes, recreate the channel, or reset the ledger. It creates one unique test registration.

It checks:

1. Docker daemon availability.
2. Docker Compose availability.
3. Application and Fabric Compose syntax.
4. `sim_net` existence.
5. Required containers.
6. ZK artifacts.
7. IPFS API availability.
8. Frontend HTTP response.
9. Backend health response.
10. CCaaS DNS and TCP connectivity.
11. End-to-end registration.
12. Fabric ledger query.
13. Audit event retrieval.
14. Returned IPFS CID pinning.

Successful output:

```text
Passed: 35
Warnings: 0
Failed: 0
MASTER QA RESULT: PASSED
```

The suite also caught and helped fix:

- incorrect IPFS HTTP method
- missing chaincode services
- stale CCaaS package IDs
- missing Node modules caused by anonymous volumes
- incorrect Docker health assumptions

## Key Commands

Start everything:

```bash
./start.sh
```

Run QA:

```bash
bash tests/master_qa.sh
```

Check health:

```bash
curl http://localhost:3001/health
```

Open the frontend:

```text
http://localhost:3000
```

Check subscriber API:

```bash
curl http://localhost:3001/api/registration/subscribers/all
```

Check audit API:

```bash
curl http://localhost:3001/api/audit/all
```

Check containers:

```bash
docker ps
```

Check CCaaS logs:

```bash
docker logs subscriber-registration --tail 100
docker logs update-tracking --tail 100
```

Stop application containers:

```bash
docker compose down
```

Stop Fabric:

```bash
cd network/docker
docker compose down
```

Avoid `docker compose down -v` unless a full Fabric/CouchDB reset is intended, because it removes persisted local state.

## Known Caveats

- The dashboard’s `activePeers` value represents configured peer topology when NCC ledger state is reachable; it is not a Docker process count.
- `ordererRunning` is `null` because orderer metrics are intentionally not exposed inside the backend container.
- The health endpoint reports Fabric ledger-state reachability rather than claiming direct Raft metric visibility.
- The development React server is used in Docker; production should use a hardened static web server.
- Default development certificates, credentials, and passwords are not production-safe.
- IPFS availability depends on pinning and node availability.
- Encryption keys require proper secret management in any real deployment.
- Test runs create ledger records; this is expected for a non-destructive QA suite.

## Final Verified State

At the end of this work:

- frontend responds on port 3000
- backend responds on port 3001
- IPFS Kubo is healthy on port 5001
- five Fabric peer services are running
- the orderer is running
- all four CCaaS services are reachable on `sim_net`
- subscriber records are visible through the NCC API
- audit events are visible through the NCC API
- returned IPFS CIDs are pinned
- the master QA suite passes with zero failures
- startup works on the tested Fedora/Linux environment
