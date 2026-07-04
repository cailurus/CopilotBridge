# CopilotBridge Landing Page Design

## Context

CopilotBridge now has a stable release flow (local notarization + GitHub Release), but no dedicated landing page for distribution. The user wants a deploy-ready page for Cloudflare Pages that is simple, visually polished, and focused on:

- what CopilotBridge is
- how to use it
- where to download it

The page should avoid heavy content and be easy to maintain per release.

## Goals

1. Add a deployable landing page directory inside the repository.
2. Keep implementation minimal (single-file static page).
3. Prioritize conversion with clear download CTAs.
4. Match an Apple-like minimalist visual style.

## Non-Goals

- Multi-page marketing site
- Blog/news system
- Localization beyond English
- Build pipeline / frontend framework integration

## Confirmed Requirements

- Directory approach: **A (recommended): `landing/`**
- Primary CTAs: **both buttons**
  - `Download DMG`
  - `View Releases`
- Language: **English only**
- Style: **Apple-like minimalist**

## Information Architecture

Single-page structure in `landing/index.html`:

1. **Hero**
   - Product name
   - one-line value proposition
2. **Primary CTA block**
   - Download DMG button
   - View Releases button
3. **How it works (3 steps)**
   - Install
   - Sign in to GitHub
   - Apply profile
4. **Supported clients**
   - Codex
   - Codex CLI
   - Claude Code
5. **Safety / disclaimer note**
   - local proxy behavior
   - unofficial endpoint caveat
6. **Footer**
   - GitHub project link
   - lightweight version/release text

## Visual & Interaction Design

- Base: light theme, generous whitespace, subtle gradient accents
- Components: soft glass-like cards, thin borders, low-contrast shadows
- Typography: system font stack (`-apple-system`, SF Pro fallback)
- Buttons:
  - primary: filled/high-contrast for DMG
  - secondary: outlined for Releases
- Motion: minimal hover/focus transitions only
- Responsive behavior:
  - mobile: stacked sections and buttons
  - desktop: constrained centered layout with card grouping
- No JS required for core experience

## Technical Design

- Deliverable: `landing/index.html` (self-contained HTML + inline CSS)
- No dependencies (no npm/node/framework)
- Links represented by clearly editable constants/anchors in HTML
- Compatible with static hosting directly from repository

## Deployment Design (Cloudflare Pages)

- Framework preset: **None**
- Build command: **empty**
- Output directory: **`landing`**

## Maintenance Plan

Per new release, update only:

1. DMG download URL
2. Release URL
3. optional displayed version label

Future optional enhancement: script-assisted link/version replacement.

## Risks & Mitigations

- **Risk:** stale download links after new release
  - **Mitigation:** keep links grouped in one obvious section near top of file
- **Risk:** design drift into heavy marketing content
  - **Mitigation:** keep strict single-page scope and fixed section order

## Verification

1. Open `landing/index.html` locally in browser and validate:
   - responsive layout
   - CTA visibility above fold
   - link correctness
2. Deploy via Cloudflare Pages with output dir `landing`.
3. Verify production page on desktop + mobile widths.

## Files To Add/Change (implementation phase)

- `landing/index.html` (new)
