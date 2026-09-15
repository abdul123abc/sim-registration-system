# Run Guide for the Privacy-Preserving SIM Registration System

This project includes:
- a Hyperledger Fabric network
- backend API services
- a React frontend
- ZK proof and IPFS integrations

This guide explains how to run the project from a fresh checkout on another machine.

---

## 1. Prerequisites

The startup launcher can install missing host prerequisites when run with its default settings. You still need permission to install software and internet access for the first package and image downloads.

Supported Linux families are Debian/Ubuntu (`apt-get`), Red Hat/Fedora/Rocky/Alma (`dnf`), and older Red Hat-family systems (`yum`). The launcher installs or checks Docker Engine, Docker Compose v2, Git, curl, and CA certificates. Fabric command-line binaries are bundled under `network/scripts/bin`.

On Windows, use PowerShell. The Windows launcher uses `winget` to install Docker Desktop when needed, checks WSL, starts Docker Desktop, and runs the tested Bash workflow inside WSL. A restart may be required after the first WSL installation.

If automatic setup is unavailable, install the following manually:

- Docker Engine
- Docker Compose v2
- Node.js 20+
- npm
- Git

Check versions:

```bash
docker --version
docker compose version
node -v
npm -v
```

---

## 2. Clone the project

```bash
git clone <your-repo-url>
cd HyperLedger/project
```

If your folder is already present, just go to the project root:

```bash
cd /path/to/HyperLedger/project
```

---

## 3. Start everything

The startup script creates the shared `sim_net` network, starts Fabric, starts the app, and restores or deploys the committed CCaaS chaincode services.

```bash
chmod +x start.sh
./start.sh
```

On Windows PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\start.ps1
```

The launcher detects the operating system before starting. Do not run `start.sh` directly in ordinary Windows Command Prompt.

To disable automatic Linux package installation:

```bash
AUTO_INSTALL=false ./start.sh
```

---

## 4. Manual startup

From the project root, create the shared network, start Fabric, restore chaincode services, and start the app:

```bash
docker network create sim_net 2>/dev/null || true
cd network/docker
docker compose up -d
cd ../..
bash network/scripts/network.sh deploy
docker compose up --build -d
```

The deployment command is restart-safe: already-committed definitions restore only their CCaaS services.

To see the running containers:

```bash
docker ps
```

---

## 5. Open the app

Open your browser to:

```text
http://localhost:3000
```

The backend API is available at:

```text
http://localhost:3001
```

Health endpoint:

```text
http://localhost:3001/health
```

The dashboard subscriber count and NCC audit log are loaded from CouchDB-backed backend APIs:

```bash
curl http://localhost:3001/api/registration/subscribers/all
curl http://localhost:3001/api/audit/all
```

The backend container uses BusyBox `wget` for these queries and does not require `curl` inside the container.

---

## 6. If you need to manage the Fabric blockchain network

The Fabric network is under:

```bash
cd /path/to/HyperLedger/project/network/docker
```

Then start it:

```bash
docker compose up -d
```

This is separate from the frontend/backend app containers.

To deploy or restore chaincode services:

```bash
cd /path/to/HyperLedger/project
bash network/scripts/network.sh deploy
```

---

## 7. Stop everything

Stop app containers:

```bash
docker compose down
```

Stop Fabric network if running:

```bash
cd /path/to/HyperLedger/project/network/docker
docker compose down -v
```

---

## 8. Useful commands

View logs:

```bash
docker compose logs -f backend
docker compose logs -f frontend
```

Rebuild after code changes:

```bash
docker compose up --build -d
```

Check network:

```bash
docker network ls
```

---

## 9. Notes

- The project was updated to avoid machine-specific absolute paths like `/home/molade/...`.
- The Docker setup is portable across machines as long as Docker and Node are installed.
- If the Fabric network is not running, the app may still start, but ledger operations will fail until the blockchain services are active.

---

## 10. Troubleshooting

### Automatic setup cannot install prerequisites

The launcher needs administrator/root permission, a supported package manager, and network access. Install Docker Engine, Docker Compose v2, Git, curl, and CA certificates manually, then rerun with:

```bash
AUTO_INSTALL=false ./start.sh
```

On Windows, install Docker Desktop, WSL, and Windows App Installer/`winget` manually, then rerun:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\start.ps1
```

### Docker says the network is missing

Run:

```bash
docker network create sim_net 2>/dev/null || true
```

Then rerun `bash start.sh`.

### Fabric cannot resolve a chaincode service

Check the four CCaaS containers:

```bash
docker ps --filter name=subscriber-registration \
	--filter name=identity-validation \
	--filter name=update-tracking \
	--filter name=access-control
```

Restore them with:

```bash
bash network/scripts/network.sh deploy
```

### Frontend or backend not starting

Check logs:

```bash
docker compose logs
```

### Docker cannot resolve `node:20-alpine`

This means Docker cannot reach Docker Hub while building the frontend and backend images. It is usually a temporary internet, DNS, firewall, proxy, or Docker Hub connection problem. Test the download directly:

```bash
docker pull node:20-alpine
```

After the pull succeeds, run:

```bash
bash start.sh
```

The startup script also checks for this image and retries the download three times before showing a useful error.

### Disk space issue during image build

Free space with:

```bash
docker system prune -af --volumes
docker builder prune -af
```

Then build again.

---

You are now ready to run the project on another machine.

## Current verification

```text
Passed: 35
Warnings: 0
Failed: 0
MASTER QA RESULT: PASSED
```
