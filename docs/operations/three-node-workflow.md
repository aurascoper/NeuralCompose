# Three-Node Workflow

NeuralCompose development spans three machines. This document describes
how they connect and what each one owns.

## Node roles

| Node | Tailscale IP | Role |
|---|---|---|
| Mac (hunters-macbook-air) | `100.105.8.22` | Primary development, memory, builds |
| Pi 4 8GB (1705bonzos) | `100.81.234.51` | Git continuity, backups, optional review |
| Pixel 8a | `100.94.124.23` | Device validation, local inference |

## SSH

All machines connect over Tailscale. No ports exposed to the public
internet.

**Mac SSH** uses macOS Remote Login (System Settings > Sharing). Connect
via Tailscale IP:

```bash
ssh aurascoper@100.105.8.22
```

MagicDNS (`hunters-macbook-air.tail48a73f.ts.net`) may not resolve on all
clients. Use the Tailscale IP directly.

**Pi SSH** uses the standard OpenSSH server. Connect via Tailscale IP:

```bash
ssh bonzos@100.81.234.51
```

**Pixel SSH** is not always available. Termux SSH server must be started
manually. When running, connect on the configured port (default: 8022):

```bash
ssh -p 8022 <user>@100.94.124.23
```

## tmux sessions

### Mac

```
nc-fable        primary coding agent
nc-apple        Apple build/test and Swift PR work
nc-mind         optional memory-server inspection
```

### Pi

```
nc-fallback     fallback coding agent
nc-postgres     database administration/log view
nc-monitor      health and backup monitoring
```

### Pixel

```
nc-qwen         llama-server
nc-embed        embedding server
nc-stt          whisper/STT wrapper
nc-metro        Expo/Metro
```

## Git continuity

The Pi hosts a bare Git remote at `~/git/neuralcompose-client.git` for
the Android client repository. This is the commit-level recovery point
that survives Pixel reboots.

### Setup (one-time)

On the Pi:

```bash
mkdir -p ~/git
git init --bare ~/git/neuralcompose-client.git
```

On the Pixel (or Mac, if the repo is cloned there):

```bash
git remote add pi ssh://bonzos@100.81.234.51/home/bonzos/git/neuralcompose-client.git
git push -u pi <branch-name>
```

### Workflow

**Code-only phase** (Mac agent active, Pixel as terminal):

```bash
# On the Pixel:
./scripts/termux/stop-neuralcompose-services.sh --runtime

# On the Mac:
ssh aurascoper@100.105.8.22 'tmux new -As nc-fable'
```

**Device-validation phase** (Pixel running services):

```bash
# Push from Mac:
git push pi <android-branch>

# On the Pixel:
git fetch pi
git switch <android-branch>
git pull --ff-only pi <android-branch>
./scripts/termux/start-neuralcompose-services.sh --runtime
./scripts/termux/healthcheck-neuralcompose-services.sh

# Run physical test, sanitize evidence, commit, then:
git push pi <android-branch>

# Clean up:
./scripts/termux/stop-neuralcompose-services.sh --runtime
```

**Recovery after Pixel reboot:**

```bash
# On the Pixel:
git fetch pi
git switch <android-branch>
git pull --ff-only pi <android-branch>
```

### Branch ownership

One active writer per branch. Use separate branches for independent
reviewers. Do not push to a branch another agent is actively editing.

### Files excluded from the Pi remote

The following must not be pushed to the Pi remote:

- `*.gguf` and other model weight files
- Whisper/model binaries
- Raw audio recordings
- Private transcripts and Journal databases
- Runtime logs under `.runtime/`
- PID files
- `.env` files and credentials
- Unsanitized evidence
- Metro/Expo caches

Provenance manifests and sanitized acceptance artifacts are committable.

## Pixel service management

Scripts live in `scripts/termux/` on the Android client repository.

```bash
# Start runtime services (Qwen + embeddings + STT):
./scripts/termux/start-neuralcompose-services.sh --runtime

# Start Metro only (UI development):
./scripts/termux/start-neuralcompose-services.sh --dev

# Stop runtime services:
./scripts/termux/stop-neuralcompose-services.sh --runtime

# Stop everything including Metro:
./scripts/termux/stop-neuralcompose-services.sh --all

# Check status:
./scripts/termux/status-neuralcompose-services.sh

# Health check:
./scripts/termux/healthcheck-neuralcompose-services.sh

# Memory snapshot:
./scripts/termux/snapshot-memory.sh
```

Configuration goes in `.runtime/neuralcompose/neuralcompose-services.env`.
Copy from `scripts/termux/neuralcompose-services.env.example` and edit.

## Pi agent limitation

The Pi 4 8GB can run Claude Code (ARM64 Linux, 4GB+ RAM required). It is
not a guaranteed second simultaneous agent until tested for:

- Agent authentication and operation
- Cloud provider concurrent session limits
- Memory stability during repository indexing and tests

Until then, treat the Pi as Git continuity, backups, monitoring, and
optional review host only.

## Deferred

- claude-mind-mcp over SSH bridge
- Postgres/pgvector on the Pi
- Independent Linux memory service
- Sequential Thinking MCP
- Automated failover from Mac to Pi agent
