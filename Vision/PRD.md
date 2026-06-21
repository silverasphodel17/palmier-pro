# PRD — Educational Explainer Mode (PalmierPro fork)

> Short PRD. Foundation = **PalmierPro** (macOS, Swift, AppKit/AVFoundation), modified.
> Tech-stack questions deliberately out of scope here.

## 1. Product in one line

Turn a teacher's recorded explanation into a BYJU'S-style, voice-synced math/science
explainer — the agent builds the first cut on PalmierPro's timeline, the human edits it.

## 2. User & job

Non-animator educators / content creators. They upload an explanation, review the
agent's first cut, and adjust via clips, parameters, and drag — never keyframing from scratch.

## 3. Core loop (the MVP we ship)

`Upload audio/teacher-video → transcribe with word timestamps → agent segments into
key moments → agent generates word-synced visuals (text/formula reveals, highlights)
from the default template family → composited on the editable timeline → export MP4.`

## 4. What we REUSE from PalmierPro (no/low change)

- Layer-based timeline + clips (`Timeline` / `Track` / `Clip`), keyframes, undo.
- Media panel, import, preview/playback, `CompositionBuilder` render + MP4 export.
- Transcription / captions subsystem (`Transcription/`, `MediaPanel/CaptionsTab`).
- Agent + tool layer (`ToolExecutor`, MCP) — extended with new tools, same plumbing.
- Text clips + `TextStyle` / `TextLayout` as the basis for synced text reveals.

## 5. Feature set (the actual work)

Status reflects **today's** vision boundary — re-tag as requirements firm up.

| # | Feature | Status | Touches / notes |
|---|---------|--------|-----------------|
| A | **Word-level timestamps** from ASR drive timing. | MVP | `Transcription/` — verify/extend to emit per-word times |
| B | **Key-moment segmentation** — timed transcript → logical sections, transition at each break. | MVP | new `ToolExecutor+KeyMoments`, `Agent/` |
| C | **Word-synced highlights** — map spoken words → on-screen text/formula elements that reveal/pop/glow on cue. | MVP | new clip behavior + agent tool **(signature feature, riskiest)** |
| D | **2D math/science primitives** — LaTeX, plots, simple diagrams as first-class clip types. | MVP | `Models/ClipType`, new renderers in `Preview/` |
| E | **Default template family** — one saved concept-themed motion+theme+component set; agent-assisted authoring. | MVP | new `TemplateFamily` model + theming over clips **(quality-bounding)** |
| F | **Generation backend swap** — our AI provider behind the existing `GenerationBackend` interface. | MVP | `Generation/GenerationBackend`, `ModelCatalog` (per `TODO.md`) |
| G | **TTS narration** — generate VO from a script instead of uploaded audio. | Deferred | new ingest path; MVP uses uploaded audio/teacher video |
| H | **Footage-aware placement** — presenter detection, safe areas, face-avoidance (SAM/YOLO). | Deferred | new footage-vision subsystem; IR presenter layer carries time-varying placement |
| I | **Shots / visual paragraphing** — per-shot composition (full/side/closer/hidden). | Deferred | depends on H |
| J | **3D primitives** — molecules, visualisations. | Deferred | extends D |
| K | **Multiple + agent-*generated* template families** — concept-resonant themes the agent invents; human curates. | Deferred | extends E |
| L | **Asset pipeline** — download / AI-create + verify diagrams & visuals. | Deferred | new; pairs with D/J |
| M | **Accounts / cloud / billing / collaboration.** | Deferred | v1 is single-user / local |

Riskiest MVP items: **C** (word→element alignment, the BYJU'S signature) and **E**
(MVP output quality is bounded by the one default family).

## 6. Success criterion

A non-animator uploads one explanation and exports a polished, voice-synced explainer
that feels intentionally designed — and can tweak any element the agent produced.
> "Did the boring 80% like a production assistant, but still let me make it mine."
