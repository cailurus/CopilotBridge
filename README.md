# Copilot Bridge

**Use the GitHub Copilot subscription you already pay for as a local backend for Codex, Codex CLI, and Claude Code — as a native macOS menu-bar app. No VS Code required.**

Copilot Bridge is a small, native Swift/SwiftUI app inspired by
[`copilot-reverse`](https://github.com/wangcansunking/copilot-reverse) and
[`agent-maestro`](https://github.com/Joouis/agent-maestro). It runs a local
OpenAI/Anthropic-compatible proxy in front of GitHub Copilot's models and writes
system-level config "profiles" so your CLI tools talk to it instead of the
official APIs.

> **Disclaimer:** The GitHub Copilot integration uses community-documented,
> unofficial endpoints, for use with **your own Copilot subscription only**. It
> may break if GitHub changes these endpoints.

## Highlights

- **Menu-bar resident.** A single status icon with sign-in, start/stop, and quick
  profile switching. Everything advanced lives in Settings.
- **No VS Code.** Signs in with GitHub device-code OAuth and calls Copilot's HTTP
  endpoints directly — exactly like `copilot-reverse` (the `agent-maestro`
  approach requires VS Code's Language Model API).
- **System profiles.** Configure Codex, Codex CLI, and Claude Code from Settings.
  Each profile maps a client to a Copilot model and applies it to the client's
  own config file.
- **Native + light.** Pure Swift, zero third-party dependencies. The HTTP server
  is built on `Network.framework`; the token is stored in the Keychain.
- **Safe writes.** Every config file is backed up (timestamped) before it's
  modified, and unrelated keys in your configs are preserved.

## Requirements

- macOS 14+ (built and tested on macOS 26, Apple Silicon)
- Xcode / Swift 6 toolchain (`swift --version`)
- An active GitHub Copilot subscription

## Build & run

```bash
# Build a signed .app bundle into ./dist
./scripts/build-app.sh release

# Launch it (also double-clickable in Finder)
open dist/CopilotBridge.app
```

For iterating on the code:

```bash
swift build          # debug build
swift run            # run the executable directly
```

## Usage

1. Launch the app — a ⚡︎ icon appears in the menu bar (no Dock icon).
2. Click it → **Sign in to GitHub**. A browser opens; paste the shown device code.
3. The proxy starts on `http://127.0.0.1:10086` (configurable).
4. Open **Settings → Profiles → Add**, pick a client + Copilot model, then **Apply**.
5. Open a new terminal and run your client (`codex`, `claude`, …). It's now
   talking to Copilot through the bridge.

### Local endpoints

- OpenAI-compatible: `http://127.0.0.1:10086/openai` (chat + `/openai/responses`)
- Anthropic-compatible: `http://127.0.0.1:10086/anthropic`

Any API key value works locally. Example for Claude Code without a profile:

```bash
export ANTHROPIC_BASE_URL=http://127.0.0.1:10086/anthropic
export ANTHROPIC_API_KEY=local
claude
```

## Profiles → what gets written

| Client | File | What Copilot Bridge writes |
|---|---|---|
| Codex / Codex CLI | `~/.codex/config.toml` | A managed `[model_providers.copilot-bridge]` block (`base_url=…/openai`, `wire_api="responses"`), plus `model` / `model_provider` / `model_context_window`. Your other keys and tables are preserved. |
| Claude Code | `~/.claude/settings.json` | An `env` block: `ANTHROPIC_BASE_URL=…/anthropic`, `ANTHROPIC_MODEL` (with `[1m]` suffix for 1M models), auto-compaction hints. Your other `env` keys are preserved. |

**Revert** restores the file by removing only the keys/blocks Copilot Bridge added.
Timestamped backups are kept under
`~/Library/Application Support/CopilotBridge/backups/`.

## Settings

- **Network:** proxy port (default `10086`) and **Accessible from** — either
  *This Mac only* (`127.0.0.1`) or *Local network* (`0.0.0.0`, reachable from
  other devices, requires an access key for remote clients).
- **Startup:** auto-start the proxy on launch; launch the app at login
  (`SMAppService`).
- **Profiles:** create / apply / revert / delete per-client profiles.

## Architecture

```
Codex / Codex CLI / Claude Code
        │  (localhost HTTP)
        ▼
Copilot Bridge  (menu-bar app)
  ├─ HTTPServer         Network.framework listener
  ├─ ProxyEngine        routes /openai + /anthropic, resolves models
  ├─ AnthropicTranslate Anthropic ⇆ OpenAI chat (+ streaming SSE)
  ├─ CopilotUpstream    calls api.githubcopilot.com with editor headers
  ├─ CopilotAuth        GitHub device-code OAuth → Copilot token (Keychain)
  └─ ConfigWriter       writes/reverts ~/.codex + ~/.claude, with backups
        │
        ▼
GitHub Copilot (chat/completions + responses)
```

- **Codex / Codex CLI** speak the OpenAI **Responses** API, which Copilot serves
  directly for gpt-5-class models — the bridge forwards these with light shaping.
- **Claude Code** speaks Anthropic Messages, which the bridge translates to
  Copilot's OpenAI chat endpoint in both directions (including streaming).

## Notes & limitations

- This is a focused proxy, not a full re-implementation of `copilot-reverse`'s
  translation layer. Text, multi-turn, system prompts, tools/tool-use, images,
  reasoning-effort, and streaming are handled; some exotic edge cases (e.g.
  inline-XML tool recovery, image round-trips on the Responses path) are not.
- Model discovery, 1M-context handling, and per-model context windows follow the
  live Copilot `/models` catalog.
