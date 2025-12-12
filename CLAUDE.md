# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

### Plugin (in `/plugin`)
```bash
bun install                 # Install dependencies
bun run build               # Build plugin → dist/opencode-island.js
bun run build:backend       # Build backend → dist/backend.js
bun run typecheck           # Type check TypeScript
```

### App (in `/app`)
```bash
./scripts/build.sh          # Build release app (builds plugin first)
./scripts/create-release.sh # Notarize and create DMG
```

**Important**: Rebuild backend after any changes in `/plugin`:
```bash
cd plugin && bun run build:backend
```

## Architecture Overview

OpenCodeIsland is a macOS menu bar "Dynamic Island" app for monitoring OpenCode coding agents. Three main components:

```
┌─────────────────┐     Unix Socket      ┌──────────────────┐
│  OpenCode CLI   │ ←──────────────────→ │   Swift App      │
│  (Terminal)     │  /tmp/opencode-      │   (Menu Bar)     │
│                 │   island.sock        │                  │
│  ┌───────────┐  │                      │  ┌────────────┐  │
│  │  Plugin   │  │  JSON events         │  │ HookSocket │  │
│  │ index.ts  │──┼─────────────────────→│  │  Server    │  │
│  └───────────┘  │                      │  └─────┬──────┘  │
└─────────────────┘                      │        ↓         │
                                         │  ┌────────────┐  │
       ┌──────────────────┐   stdio IPC  │  │ Session    │  │
       │  Bun Backend     │←─────────────│  │ Store      │  │
       │  (SDK Bridge)    │              │  └─────┬──────┘  │
       │  backend/        │              │        ↓         │
       └──────────────────┘              │  ┌────────────┐  │
                                         │  │ NotchView  │  │
                                         │  │ (SwiftUI)  │  │
                                         │  └────────────┘  │
                                         └──────────────────┘
```

### Plugin (`/plugin/src/index.ts`)
- Hooks into OpenCode events: `tool.execute.before`, `tool.execute.after`, `permission.ask`
- Sends JSON events to Swift via Unix socket
- For permissions: waits for allow/deny response from app

### Bun Backend (`/plugin/src/backend/`)
- Spawned by Swift app, communicates via stdio JSON-RPC
- Wraps OpenCode SDK for session/message queries
- Server discovery via `lsof` to find running OpenCode ports

### Swift App (`/app/OpenCodeIsland/`)
- **HookSocketServer**: Listens on Unix socket, receives plugin events
- **SessionStore**: Actor-based central state (all mutations via `process()`)
- **BackendClient**: Spawns and communicates with Bun backend
- **NotchView**: Dynamic Island UI

## Key Files

| Component | Files |
|-----------|-------|
| Plugin entry | `plugin/src/index.ts` |
| Backend IPC | `plugin/src/backend/ipc.ts`, `types.ts` |
| SDK wrapper | `plugin/src/backend/opencode.ts` |
| Socket server | `app/.../Services/Hooks/HookSocketServer.swift` |
| State store | `app/.../Services/State/SessionStore.swift` |
| Session model | `app/.../Models/SessionState.swift`, `SessionPhase.swift` |
| Main UI | `app/.../UI/Views/NotchView.swift` |

## State Machine

Session phases: `idle` → `processing` → `waitingForInput` / `waitingForApproval` → `idle`

All phase transitions validated in `SessionPhase.canTransition(to:)`.

## IPC Protocol

Plugin → Swift (Unix socket):
```json
{"session_id": "...", "event": "PermissionRequest", "tool": "bash", "tool_use_id": "..."}
```

Swift → Plugin (response):
```json
{"decision": "allow"}
```

Swift ↔ Backend (stdio JSON-RPC):
```json
{"id": 1, "method": "sessions.list", "params": null}
{"id": 1, "result": [...]}
```
