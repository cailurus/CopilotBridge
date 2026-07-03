# Copilot Bridge

A small macOS menu-bar app that lets local coding tools use the GitHub Copilot
subscription you already have.

Copilot Bridge starts a local proxy, signs in with GitHub, and can write simple
profiles for tools like Codex, Codex CLI, and Claude Code.

> This project uses unofficial GitHub Copilot endpoints. Use it only with your
> own Copilot subscription. The integration may need updates if GitHub changes
> those endpoints.

## Requirements

- macOS 14+
- Xcode / Swift 6 toolchain
- An active GitHub Copilot subscription

## Build

```bash
./scripts/build-app.sh release
open dist/CopilotBridge.app
```

For development:

```bash
swift build
swift run
```

## Use

1. Launch `CopilotBridge.app`.
2. Click the menu-bar icon.
3. Sign in to GitHub and enter the device code in the browser.
4. Open Settings, add a profile for your tool, then apply it.
5. Start your coding tool in a new terminal.

The default local server is:

- OpenAI-style endpoint: `http://127.0.0.1:10086/openai`
- Anthropic-style endpoint: `http://127.0.0.1:10086/anthropic`

## Profiles

Profiles write the local configuration needed by each tool:

- Codex / Codex CLI: `~/.codex/config.toml`
- Claude Code: `~/.claude/settings.json`

Before changing a config file, Copilot Bridge creates a backup under:

```text
~/Library/Application Support/CopilotBridge/backups/
```

You can revert an applied profile from the app.

## Settings

The app lets you configure:

- Proxy port
- Local-only or LAN access
- Optional access key for LAN clients
- Auto-start on launch
- Launch at login
- Profiles per client

## Notes

GitHub login tokens are stored in the macOS Keychain. During development, rebuilt
apps may ask for Keychain permission again because ad-hoc signing changes the
app identity.
