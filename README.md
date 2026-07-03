# Copilot Bridge

Copilot Bridge is a small macOS menu-bar app that lets local coding agents use
GitHub Copilot models through local OpenAI-compatible and Anthropic-compatible
proxy endpoints.

It signs in with GitHub, starts a local proxy, and can write configuration
profiles for tools like Codex, Codex CLI, and Claude Code.

> This project uses unofficial GitHub Copilot endpoints. Use it only with your
> own Copilot subscription. The integration may need updates if GitHub changes
> those endpoints.

## Download

Download the latest DMG from the
[GitHub Releases](https://github.com/cailurus/CopilotBridge/releases) page.

## Requirements

- macOS 14+
- An active GitHub Copilot subscription

## Supported clients

Copilot Bridge can write local profiles for:

- Codex / Codex CLI
- Claude Code

Before changing a client config file, Copilot Bridge creates a backup under:

```text
~/Library/Application Support/CopilotBridge/backups/
```

You can revert an applied profile from the app.

## Notes

GitHub login tokens are stored in the macOS Keychain. Copilot Bridge only uses
your own GitHub Copilot subscription and runs the proxy locally by default.
