# TODO

## ⭐ Wire our own custom AI generation (replace Palmier's closed backend)

**Goal:** swap Palmier's closed, subscription-gated generation backend for **our own
AI provider** (fal / Replicate / Kling·Seedance direct / our own models), so we own
the generation stack. This is the main thing we want to add on top of the GPLv3
editor. (Context: GPLv3 lets us keep these mods private as a *hosted service* — our
backend/keys stay server-side, never conveyed. See [FINDINGS.md](FINDINGS.md).)

### The swap surface (well-isolated — verified)
- **`Sources/PalmierPro/Generation/GenerationBackend.swift`** — this file *is* the
  entire Palmier/Convex coupling. Repoint 3 functions at our provider:
  - `uploadReference(...)` — Convex storage ticket + upload → our storage / provider input upload.
  - `submit(...)` — `convex.mutation("generations:submit", …)` → our "create generation" API call.
  - `subscribe(jobId:)` — `convex.subscribe("generations:byId")` → our polling or websocket status.
  - `BackendGenerationParams` — adjust the params shape to our provider.
- **`Sources/PalmierPro/Generation/Catalog/ModelCatalog.swift`** — currently
  `convex.subscribe("models:list")`. Replace with our own catalog (hardcoded list of
  our provider's models, or fetch from our endpoint). `VideoModelConfig` /
  `ImageModelConfig` / `AudioModelConfig` / `UpscaleModelConfig` read from
  `ModelCatalog.shared` and stay as-is.
- **`Sources/PalmierPro/Account/AccountService.swift`** — generation is gated via
  Convex auth/credits. Replace/stub with our own auth + credits (or gate at the web
  layer for the hosted service).

### What stays unchanged (no work)
- `Generation/GenerationService.swift` — orchestration (creates placeholder
  `MediaAsset`s, drives status, downloads results). Only its calls into
  `GenerationBackend` matter.
- `Generation/Submission/*` builders, the editor, and the whole render pipeline.
- **Result handling is provider-agnostic**: results come back as **URLs** →
  downloaded into a `MediaAsset` → through the `loadMetadata`/`loadTracksCompat`
  path. Minimal change.

Estimate: a few days, concentrated in `GenerationBackend.swift` + `ModelCatalog.swift`.

### Open decisions
- [ ] Which provider(s)? (fal / Replicate / direct model APIs / self-hosted)
- [ ] Job status: polling vs websocket.
- [ ] Reference-asset storage (for image→video etc.): our bucket/CDN vs provider upload.
- [ ] Auth + credit/metering model (or gate entirely at the web layer).
- [ ] Model catalog: static list vs our own `/models` endpoint.

---

## Related: hosting architecture (the bigger lift — separate from the AI swap)
PalmierPro is a **native macOS GUI app** (AppKit/SwiftUI/AVFoundation), not a web
service. To run it as SaaS, pick one (see [FINDINGS.md](FINDINGS.md) §SaaS notes):
- [ ] **Stream the Mac GUI** from cloud Mac instances (EC2 Mac / MacStadium / Orka).
  ⚠️ macOS-on-Apple-hardware EULA; ~1 session per instance; pricey.
- [ ] **Headless engine + our web UI**: drive the `Timeline` model + `CompositionBuilder`
  + MCP tool layer from a web frontend we write. ⚠️ `CompositionBuilder` is
  AVFoundation-bound → render workers must be macOS; web UI must contain no GPL code
  to stay SaaS-clean.

## Licensing reminders (see FINDINGS.md)
- GPLv3 = keep mods private only as **hosted SaaS** (no binary conveyed to users).
- Can't ship a "no-resale" desktop build — copyleft forbids it.
- Alternative: commercial/dual license from **Palmier, Inc.** (founders@palmier.io),
  which would also unlock their AI backend.
- Rebrand (the "Palmier Pro" name/logo is trademark, not GPL).

## Next actions
- [ ] Scope the `GenerationBackend` adapter spec (our provider's request/response vs.
      what `submit`/`subscribe`/`uploadReference` expect).
- [ ] Scope the headless-engine extraction (GUI-coupled vs. engine files; a
      server-side "render a Timeline" service).
