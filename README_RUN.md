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

### Windows setup options

There are two supported Windows workflows:

1. **Native PowerShell:** Run the repository's PowerShell launcher from Windows. It uses Docker Desktop, Git for Windows, Node.js, npm, Rust, and Git Bash.
2. **WSL2 Ubuntu:** Run the Linux launcher inside Ubuntu on WSL2. Docker Desktop must be connected to the WSL distribution.

#### Option A: Native Windows PowerShell

Open PowerShell as a normal user, not an administrator. If the required tools are missing, install them with `winget`:

```powershell
winget install --id Docker.DockerDesktop -e --accept-package-agreements --accept-source-agreements
winget install --id Git.Git -e --accept-package-agreements --accept-source-agreements
winget install --id OpenJS.NodeJS.LTS -e --accept-package-agreements --accept-source-agreements
```

Restart PowerShell after installation. Start Docker Desktop, wait until **Engine running**, and verify that the Docker CLI can reach it:

```powershell
docker info
docker compose version
git --version
node --version
npm --version
```

If `docker info` fails, reopen Docker Desktop and confirm that its engine is running. Do not run the launcher until the Docker Desktop engine is ready.

The repository's Windows launcher can install additional required packages automatically. From the project directory, run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\start.ps1
```

The launcher uses Git Bash for the shell scripts. If Bash is not found, install Git for Windows and reopen the terminal so the updated PATH is available.

#### Option B: WSL2 Ubuntu

First, enable WSL2 from Windows PowerShell:

```powershell
wsl --install -d Ubuntu
```

Restart Windows if the installation asks you to do so. Check the distribution and confirm WSL2:

```powershell
wsl -l -v
wsl --set-version Ubuntu 2
```

Open Ubuntu from the Start menu, then install the basic host tools:

```bash
sudo apt update
sudo apt install -y git curl ca-certificates nodejs npm
```

Start Docker Desktop from the Windows Start menu and wait for **Engine running**. In Ubuntu, verify that Docker Desktop is the active Docker context:

```bash
docker info
docker context inspect
docker compose version
```

If the Docker CLI reports a WSL or context error, run:

```bash
docker context use desktop-linux
```

Restart the Ubuntu terminal after changing the Docker context. Then enter the project directory. If the project is not already present, clone it into WSL:

```bash
git clone <your-repo-url>
cd HyperLedger/project
```

If you already have the project on Windows, mount the containing directory into WSL and change into the project path. For example:

```bash
cd /mnt/d/path/to/HyperLedger/project
```

Use the repository's Linux launcher from the project root. The launcher can install missing Linux dependencies, but Docker Desktop must already be running and connected to the WSL distribution:

```bash
chmod +x start.sh
AUTO_INSTALL=false ./start.sh
```

The `AUTO_INSTALL=false` option skips package-manager installation. Install the required Linux packages manually before using it. To let the launcher perform its full setup, run:

```bash
./start.sh
```

The launcher creates `sim_net`, starts the Fabric network, builds the application images, starts the frontend and backend, and restores the four CCaaS containers.

> If Docker Desktop is running on Windows but `docker info` fails inside Ubuntu, open Docker Desktop's **Settings > Resources > WSL Integration**, enable the Ubuntu distribution, and restart the WSL terminal.

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

The project provides separate launchers for the supported operating systems. On Linux or Debian/Ubuntu, run the Linux launcher from the project root:

```bash
chmod +x start.sh
./start.sh
```

On Windows PowerShell, use the native Windows launcher:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\start.ps1
```

The native launcher requires Docker Desktop, Git for Windows, Node.js, and npm. It installs missing tools with `winget`, starts Docker Desktop when needed, and uses Git Bash for the repository's shell scripts. It does not require a WSL distribution. If you prefer WSL2, follow the WSL2 Ubuntu instructions above and run `./start.sh` from Ubuntu instead.

To disable automatic Linux package installation:

```bash
AUTO_INSTALL=false ./start.sh
```

Other Linux launcher variants are available for compatibility checks:

```bash
./start_debian.sh
./start_v1.sh
./start_v2.sh
./start_v3.sh
```

Use the launcher intended for the current environment and review its behavior before running it in a production host.

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

The latest repository state contains clean Git status, valid Docker Compose configuration, and valid Bash syntax for the startup, network, QA, and ZK scripts. A fresh live check on 2026-10-07 found no running Docker containers and no service on port 3001, so the runtime QA result is not currently available.

Run these commands only after starting the stack:

```bash
bash start.sh
bash tests/master_qa.sh
```

A successful run is expected to print the following marker after the live QA command completes:

```text
MASTER QA RESULT: PASSED
```

Do not copy the earlier 35/35 result into the current status unless the QA command has been run again against a live deployment.
