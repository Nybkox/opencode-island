# OpenCode Island

A macOS menu bar app that brings Dynamic Island-style notifications to [OpenCode](https://github.com/opencode-ai/opencode) CLI sessions.

[![Release](https://img.shields.io/github/v/release/Nybkox/opencode-island?style=flat&color=white&labelColor=000000&label=release)](https://github.com/Nybkox/opencode-island/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/Nybkox/opencode-island/total?style=flat&color=white&labelColor=000000)](https://github.com/Nybkox/opencode-island/releases)

## Features

- **Notch UI** — Animated overlay that expands from the MacBook notch
- **Live Session Monitoring** — Track multiple OpenCode sessions in real-time
- **Permission Approvals** — Approve or deny tool executions directly from the notch
- **Chat History** — View full conversation history with markdown rendering
- **Auto-Setup** — Hooks install automatically on first launch
- **Auto-Updates** — Built-in Sparkle updater

## Requirements

- macOS 15.6+
- [OpenCode CLI](https://github.com/opencode-ai/opencode)
- [Bun](https://bun.sh) (for plugin/backend)

## Install

1. Download the latest DMG from [GitHub Releases](https://github.com/Nybkox/opencode-island/releases/latest)
2. Open the DMG and drag OpenCode Island to Applications
3. **First launch:** Run this to bypass Gatekeeper (app is not notarized):
   ```bash
   xattr -d com.apple.quarantine /Applications/OpenCode\ Island.app
   ```

> Alternatively: System Settings → Privacy & Security → "Open Anyway" after the first blocked launch attempt.

### Build from source

```bash
# Build plugin first
cd plugin
bun install
bun run build
bun run build:backend

# Build app
cd ../app
./scripts/build.sh
```

## Architecture

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
       └──────────────────┘              │        ↓         │
                                         │  ┌────────────┐  │
                                         │  │ NotchView  │  │
                                         │  │ (SwiftUI)  │  │
                                         │  └────────────┘  │
                                         └──────────────────┘
```

### Components

| Component | Location | Description |
|-----------|----------|-------------|
| Plugin | `plugin/src/index.ts` | Hooks into OpenCode events, sends JSON to Swift via Unix socket |
| Backend | `plugin/src/backend/` | Bun process bridging OpenCode SDK to Swift app via stdio JSON-RPC |
| Swift App | `app/OpenCodeIsland/` | Menu bar app with HookSocketServer, SessionStore, and NotchView |

### How It Works

1. **Plugin hooks** install into `~/.opencode/hooks/` on first launch
2. Plugin sends events (`tool.execute.before`, `tool.execute.after`, `permission.ask`) to Unix socket
3. Swift app receives events, updates session state, displays notch UI
4. For permissions, notch expands with approve/deny buttons—no terminal switching needed
5. Backend process queries OpenCode SDK for session/message history

### IPC Protocol

**Plugin → Swift** (Unix socket):
```json
{"session_id": "...", "event": "PermissionRequest", "tool": "bash", "tool_use_id": "..."}
```

**Swift → Plugin** (response):
```json
{"decision": "allow"}
```

**Swift ↔ Backend** (stdio JSON-RPC):
```json
{"id": 1, "method": "sessions.list", "params": null}
{"id": 1, "result": [...]}
```

## Development

```bash
# Plugin
cd plugin
bun install
bun run build        # Build plugin
bun run build:backend # Build backend
bun run typecheck    # Type check

# App
cd app
open OpenCodeIsland.xcodeproj  # Open in Xcode
./scripts/build.sh             # Build release
./scripts/create-release.sh    # Create DMG & GitHub release
```

## Analytics

OpenCode Island uses Mixpanel to collect anonymous usage data:

- **App Launched** — App version, build number, macOS version
- **Session Started** — When a new OpenCode session is detected

No personal data or conversation content is collected.

## Credits

Forked from [Claude Island](https://github.com/farouqaldori/claude-island) by [@farouqaldori](https://github.com/farouqaldori).

## License

Apache 2.0
