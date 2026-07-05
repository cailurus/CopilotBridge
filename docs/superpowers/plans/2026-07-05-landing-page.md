# CopilotBridge Landing Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a deploy-ready, single-file landing page under `landing/` for Cloudflare Pages with Apple-minimal style, dual CTAs (DMG + Releases), and concise usage guidance.

**Architecture:** Keep it static and self-contained: one `landing/index.html` with inline CSS and semantic sections. No JS/framework/build step. Use link placeholders that are easy to update each release.

**Tech Stack:** HTML5, inline CSS (system font stack), shell-based smoke checks.

---

## File Structure

- Create: `landing/index.html` — production landing page (single deploy artifact).
- Create: `docs/release-notes/landing-page-link-update.md` — tiny operator note on where to update DMG/Release links (optional but practical).

No existing source/app files are modified.

---

### Task 1: Create failing content checks (RED)

**Files:**
- Create: `landing/index.html`

- [ ] **Step 1: Write minimal placeholder file that intentionally fails checks**

```html
<!doctype html>
<html lang="en">
  <head><meta charset="UTF-8"><title>Placeholder</title></head>
  <body><h1>Placeholder</h1></body>
</html>
```

- [ ] **Step 2: Run failing checks to verify RED**

Run:
```bash
test -f landing/index.html && grep -q "Download DMG" landing/index.html && grep -q "View Releases" landing/index.html && grep -q "How it works" landing/index.html
```

Expected: non-zero exit (fails because required content is missing).

- [ ] **Step 3: Commit red baseline**

```bash
git add landing/index.html
git commit -m "test: add failing landing-page placeholder"
```

---

### Task 2: Implement final landing page (GREEN)

**Files:**
- Modify: `landing/index.html`

- [ ] **Step 1: Replace placeholder with full page content**

```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>CopilotBridge — Use Copilot models in Codex and Claude Code</title>
    <meta name="description" content="CopilotBridge is a local macOS menu-bar proxy that lets Codex/Codex CLI/Claude Code use your GitHub Copilot subscription." />
    <style>
      :root {
        --bg: #f5f7fb;
        --surface: rgba(255, 255, 255, 0.72);
        --text: #0f172a;
        --muted: #5b6476;
        --line: rgba(15, 23, 42, 0.12);
        --primary: #1d4ed8;
        --primary-hover: #1e40af;
      }
      * { box-sizing: border-box; }
      body {
        margin: 0;
        font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
        color: var(--text);
        background:
          radial-gradient(900px 420px at 88% -10%, rgba(37, 99, 235, 0.15), transparent 60%),
          radial-gradient(700px 360px at -10% 30%, rgba(56, 189, 248, 0.12), transparent 60%),
          var(--bg);
      }
      .wrap { max-width: 960px; margin: 0 auto; padding: 40px 20px 72px; }
      .card {
        background: var(--surface);
        border: 1px solid var(--line);
        backdrop-filter: blur(12px);
        border-radius: 18px;
        box-shadow: 0 12px 36px rgba(15, 23, 42, 0.08);
      }
      .hero { padding: 42px 32px; }
      h1 { margin: 0 0 12px; font-size: clamp(2rem, 4vw, 3rem); line-height: 1.08; }
      .sub { margin: 0; color: var(--muted); font-size: 1.08rem; max-width: 62ch; }
      .cta { margin-top: 24px; display: flex; gap: 12px; flex-wrap: wrap; }
      .btn {
        text-decoration: none;
        border-radius: 12px;
        padding: 11px 16px;
        font-weight: 600;
        border: 1px solid transparent;
        transition: transform .12s ease, box-shadow .12s ease, background-color .12s ease;
      }
      .btn:hover { transform: translateY(-1px); }
      .btn.primary { background: var(--primary); color: #fff; box-shadow: 0 8px 18px rgba(29, 78, 216, .28); }
      .btn.primary:hover { background: var(--primary-hover); }
      .btn.secondary { background: rgba(255,255,255,.65); color: var(--text); border-color: var(--line); }
      .grid { display: grid; gap: 14px; grid-template-columns: repeat(3, minmax(0, 1fr)); margin-top: 18px; }
      .section { margin-top: 18px; padding: 24px; }
      h2 { margin: 0 0 12px; font-size: 1.18rem; }
      .step { padding: 16px; border: 1px solid var(--line); border-radius: 12px; background: rgba(255,255,255,.55); }
      .step strong { display: block; margin-bottom: 6px; }
      ul { margin: 0; padding-left: 20px; color: var(--muted); }
      .foot { margin-top: 18px; color: var(--muted); font-size: .92rem; }
      code { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
      @media (max-width: 760px) {
        .hero, .section { padding: 20px; }
        .grid { grid-template-columns: 1fr; }
      }
    </style>
  </head>
  <body>
    <main class="wrap">
      <section class="card hero">
        <h1>CopilotBridge</h1>
        <p class="sub">A local macOS menu-bar proxy that lets Codex, Codex CLI, and Claude Code use your own GitHub Copilot subscription.</p>
        <div class="cta">
          <a class="btn primary" href="https://github.com/cailurus/CopilotBridge/releases/latest/download/CopilotBridge-0.1.2.dmg">Download DMG</a>
          <a class="btn secondary" href="https://github.com/cailurus/CopilotBridge/releases">View Releases</a>
        </div>
      </section>

      <section class="card section">
        <h2>How it works</h2>
        <div class="grid">
          <div class="step"><strong>1) Install</strong>Open the app and keep CopilotBridge running in the menu bar.</div>
          <div class="step"><strong>2) Sign in</strong>Authenticate with your GitHub account that has Copilot access.</div>
          <div class="step"><strong>3) Apply profile</strong>Apply a client profile for Codex, Codex CLI, or Claude Code.</div>
        </div>
      </section>

      <section class="card section">
        <h2>Supported clients</h2>
        <ul>
          <li>Codex</li>
          <li>Codex CLI</li>
          <li>Claude Code</li>
        </ul>
      </section>

      <section class="card section">
        <h2>Safety note</h2>
        <p class="sub">CopilotBridge runs locally and stores login tokens in macOS Keychain. It relies on unofficial Copilot endpoints and should be used only with your own account.</p>
      </section>

      <footer class="foot">
        GitHub: <a href="https://github.com/cailurus/CopilotBridge">cailurus/CopilotBridge</a>
      </footer>
    </main>
  </body>
</html>
```

- [ ] **Step 2: Run content checks (GREEN)**

Run:
```bash
grep -q "Download DMG" landing/index.html && grep -q "View Releases" landing/index.html && grep -q "How it works" landing/index.html && grep -q "Supported clients" landing/index.html
```

Expected: zero exit (all required sections present).

- [ ] **Step 3: Manual browser sanity check**

Run:
```bash
python3 -m http.server 8080 --directory landing
```
Open `http://127.0.0.1:8080` and verify:
- Hero and both CTA buttons visible above fold on desktop
- Mobile width stacks sections correctly
- Links open expected GitHub targets

- [ ] **Step 4: Commit implementation**

```bash
git add landing/index.html
git commit -m "feat: add Cloudflare-ready landing page"
```

---

### Task 3: Add tiny operator note for release-link updates

**Files:**
- Create: `docs/release-notes/landing-page-link-update.md`

- [ ] **Step 1: Add maintenance note**

```markdown
# Landing Page Link Update

Before each release, update these links in `landing/index.html`:

- Download DMG: `.../releases/latest/download/CopilotBridge-<version>.dmg`
- Releases page: `.../releases`

If you keep `latest/download`, only the filename must stay consistent.
```

- [ ] **Step 2: Commit note**

```bash
git add docs/release-notes/landing-page-link-update.md
git commit -m "docs: add landing page link update note"
```

---

### Task 4: Deploy verification for Cloudflare Pages

**Files:**
- Modify: none

- [ ] **Step 1: Verify folder output contract**

Run:
```bash
test -f landing/index.html && echo "landing output ready"
```

Expected output:
```text
landing output ready
```

- [ ] **Step 2: Record deploy settings for operator runbook**

Use these Cloudflare Pages settings:
- Framework preset: `None`
- Build command: *(empty)*
- Output directory: `landing`

- [ ] **Step 3: Final release-friendly commit**

```bash
git add -A
git commit -m "chore: finalize landing page deployment setup"
```

---

## Self-Review Results

- **Spec coverage:** all confirmed requirements are mapped (folder `landing/`, English-only, dual CTAs, Apple-minimal style, concise usage, Cloudflare deployment settings).
- **Placeholder scan:** no TODO/TBD placeholders remain.
- **Type/name consistency:** all referenced file paths and section names are consistent across tasks.
- **Scope check:** single independent subsystem; no decomposition needed.
