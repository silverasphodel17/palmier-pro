# Constraints & Vision — Agentic Educational Video Platform

> Status: **draft for review** (constraints lock, not full design). Date: 2026-05-31.
> Feeds the design specs for the individual subsystems.

## 1. Vision (one line)

An **agentic animation platform that lets non-animators create math & science
education videos** (BYJU'S-style narrated explainers) from content, using
**templatised animations** — the agent generates a first cut, and a **layer-based
(Premiere-style) timeline** lets the user adjust everything manually as well as with help of agent (internal mcp tool?).

## 2. Target user

Non-animators — educators / content creators. No keyframing or animation skill
required. The platform must produce good results from *content*, and make
adjustment a matter of parameters and dragging, not animation craft.

## 3. Product constraints (the "musts")

- **C1 — Agentic generation.** The agent turns content (topic / script) into a
  video by composing templates. The user never animates from scratch.
- **C2 — Templatised animation, via "template families" (not generic stock).**
  Components are *primitives*; the reusable **creative** unit is a **template
  family** — a saved, concept-themed design + motion system (like a *font family*)
  that styles those primitives and is **reused across videos in a topic**, not
  recreated per video. The platform must **NOT** mass-produce from one generic
  master template — BYJU'S deliberately rejected that (see §6a).
  The user **always picks a template family** (or the agent auto-selects → the user
  confirms) before generation. *(MVP: the set starts as the **one default family**
  the creator built with agent help; more families accrue over time.)*
- **C3 — Math & science first.** LaTeX, plots/graphs, geometry, 3D (molecules, visualisation) and diagrams are first-class citizens, not afterthoughts. They can either be downloaded or AI created and verified before usage. *(MVP: **no 3D** — 3D + the download/AI-create+verify asset pipeline are **post-MVP**; see N3.)*
- **C4 — Voiceover-synced highlighting.** Narration (VO) drives timing; specific
  **text and formula elements highlight in sync with the spoken words** —
  word/element-level alignment, BYJU'S style.
- **C4a — VO source (MVP): user-uploaded.** The narration is **uploaded audio, or
  a video of a single teacher** explaining the topic. **TTS is deferred** to a
  later version. The product is therefore framed as *augmenting a teacher's
  recorded explanation with synced animations*, not generating a video from a
  bare script.
- **C5 — Layer-based, editable timeline.** Premiere-Pro-like: tracks/layers with
  clips on a timeline. **Every agent decision is user-adjustable** — timing,
  position, style, content.
- **C6 — Non-animator UX.** Adjustments via parameters / drag, not manual
  keyframes. Templates carry sensible **adjustable** motion defaults.
- **C7 — BYJU'S-style aesthetic.** Narrated explainer with clean reveals and
  synced text/formula highlights as the signature look.
- **C8 — Template families are previewable, customisable, and saveable — dual-mode.**
  Every element of a family (the six in §6a) can be **previewed**, **customised by
  the agent**, **and customised manually** for finer fixes, then **saved** for
  reuse. Non-animator ease *plus* a manual escape hatch for control. Always have auto
  undo points after for every change in template customisation manually or by agent
  so that creative backtracking can happen. *(MVP: a **linear undo/redo** stack with
  auto-checkpoints; branching history is post-MVP.)*

## 4. Locked technical decisions (validated during exploration)

- **T1 — Foundation: Revideo** (Motion Canvas engine). Verified across 9 demos
  (math plots, LaTeX, step-by-step explainer, theming, real 3D, reusable
  components, local 3D library). No capability gap forced a reach for Manim.
- **T2 — Agent model: compose-from-library.** The agent emits *validated data*,
  not code. (Hybrid code-snippet escape hatch is deferred to a later version.)
- **T3 — Single source of truth: a Scene IR (JSON).** Both the agent and the
  editor produce/edit it; the engine renders it. **The IR is layer/timeline-
  structured** (tracks + clips with start/end), to satisfy C5.
- **T4 — Component library: typed registry.** Each component declares a props
  schema + variants and implements the `{node, play}` contract.
- **T5 — Theme as data.** Style tokens (color, font, glow, shadow, effect) set by
  agent and user.
- **T6 — Verification: render-and-inspect (vision) loop.** `tsc` passing does not
  mean a scene renders correctly; the agent loop verifies by rendering frames.
- **T7 — Export: `renderVideo()`** (+ parallelized AWS Lambda for long videos,
  per the `parallelized_awd_lambda` reference).

## 5. Explicit non-goals (YAGNI / out of scope)

- **N1** — Not a general After Effects / Premiere clone. Only the layer/timeline
  editing these videos need.
- **N2** — Not raster image editing (Photoshop-style brushes/masks).
- **N3** — **3D is out of the MVP entirely** (Three.js available for later).
  First-class 3D (molecules, visualisation) + the **download / AI-create + verify
  asset pipeline** (C3) are **post-MVP**.
- **N4** — No third-party plugin ecosystem.
- **N5** — Real-time multi-user collaboration: out for v1 (revisit later).
- **N6** — Accounts, cloud storage, project management, billing: deferred to
  post-MVP (v1 is single-user / local).
- **N7** — TTS-generated narration: deferred (MVP uses uploaded audio/teacher video).
- **N8** — **Footage-aware shot composition** (visual paragraphing, SAM/YOLO,
  face-avoidance, dynamic per-shot placement): **post-MVP** (see §6, §6b).

## 6. Architectural implications introduced by this vision

- **Ingest + VO/timing subsystem (new, 5th subsystem).** For MVP the input is
  **uploaded audio or a teacher video**, so the pipeline must **extract** timing,
  not receive it: **ASR with word-level timestamps** (e.g. Elevenlabs). No forced
  alignment of a provided transcript. Word timestamps drive the timeline.
  This is the `yt-shorts` word-timestamp pattern promoted to the core timing model.
- **Teacher video as a media layer.** The footage is a `<Video>` layer with the
  agent-generated animation layers synced to it.
  - **MVP — footage used *as-is*.** The presenter video is shown as uploaded
    (full-frame, or **user-manually** placed in the timeline), animations overlaid;
    the user can rearrange manually. **No footage analysis, no auto safe-area, no
    agent-driven placement.** Audio-only stays an option.
  - **Post-MVP — footage-aware shots.** Analyse the footage (Segment Anything /
    YOLO) to detect the presenter, derive a **safe area**, and place text/visuals to
    avoid the face — enabling **dynamic, per-shot placement** (full / side / closer
    / hidden) chosen contextually. See §6b. The IR's presenter layer is built to
    carry **time-varying** placement so this upgrade is additive.
- **The agent's primary input is the transcript (+ timestamps).** It reads what
  the teacher says and when, then generates synced highlight/animation layers.
- **Layer/timeline IR.** The Scene IR models **tracks/layers + clips
  (start/end/component/props)**, not just sequential beats.
- **Two-way editability / round-tripping.** Agent writes IR → user edits IR via
  the timeline → re-render. User edits must survive agent regeneration (a
  lock/merge concept will be needed — flagged for design).

## 6a. The creative model — mechanical vs. creative (KEY)

BYJU'S quality came from **contextual, concept-resonant motion design** (wave
motion for sound; an atom squishing in to reveal elements), created fresh per
topic — they **deliberately rejected a single generic master template**. So the
platform must not mass-produce from stock. The work splits in two:

- **Mechanical (automate fully).** The layer-by-layer construction + VO-sync
  choreography — every moving/highlighted element on its own layer, timed to the
  narration. This was the After Effects drudgery; **the agent does it.**
- **Creative — the "template family" (the reusable unit).** A **template family**
  is a saved, named, concept-themed design + motion system (think *font family*).
  It **owns six things**:
  1. **Motion language** — entrance/exit/emphasis motifs (waves for sound, etc.).
  2. **Visual motifs** — concept-resonant decorative/structural elements.
  3. **Theme tokens** — palette, fonts, glow/shadow/stroke style.
  4. **Styled components** — how each primitive looks + moves in this family.
  5. **Transitions** — scene-to-scene transition signatures.
  6. **Sound design** — audio motifs paired with the motion.

  One family → many videos in a topic, minimal per-video variation (e.g. colour).
  Reused, not recreated — mirroring BYJU'S evolution from per-chapter → per-topic-
  theme templates. **Every element of a family must be previewable, customisable
  (by the agent AND manually for finer fixes), and saveable** (see C8).
  - **MVP:** the agent **helps the (non-coder) creator build & iterate one default
    template family** (agent-assisted authoring); that family becomes the **default
    selection** and is **reused** across videos (not rebuilt per video).
  - **Post-MVP:** the agent **generates** concept-resonant themes itself; the human
    **leads** — brainstorms with the agent, affirms/selects what reads right for the
    concept, and locks one. (Full generative creativity is the frontier, not v1.)

Honest note: auto-generating genuinely novel concept-resonant motion design is the
hard creative core. MVP keeps family *creation* lighter (agent-assisted, the creator
leads) and defers deep generative theming.

## 6b. Structure — key moments, shots, transitions

Two **independent** granularities (film-production structure):

- **Key moments (macro) — IN MVP.** The big logical breakpoints of the explanation
  — a shift to a new sub-idea. Few per video. The agent segments the timed
  transcript into key moments. **Every key-moment break gets a transition** (others
  may exist, but key-moment breaks always do). Drives chapters/sections.
- **Shots (finer, content-driven) — POST-MVP.** A shot is a **"visual paragraph"**:
  it marks a change in the *content* paragraph, not merely to break monotony.
  Cinematographic grammar — a topic **opens on a master/full shot**, then **cuts
  closer for emphasis** (relative to the topic). Shots are *not* tied 1:1 to key
  moments. Realising them needs footage understanding (§6 post-MVP), so shots +
  per-shot teacher placement are **deferred**.
- **Transitions.** Owned by the template family (§6a). **Mandatory at key-moment
  breaks**; optional elsewhere. **In MVP.**

## 7. Subsystems (updated to five)

1. Animation engine + **component library** (Revideo + typed registry) + LaTeX tweening from motion canvas.
2. **Scene IR** (layer/timeline JSON; single source of truth).
3. **Agent** (content → IR, compose-from-library, vision-verified).
4. **VO / timing** (audio + word timestamps → timeline alignment).
5. **Web editor** (layer-based timeline UI + parameter inspector + live preview +
   export).

(Post-MVP adds a 6th: **footage-vision** — SAM/YOLO presenter analysis → safe areas
→ shots, per §6b.)

## 8. Open decisions (to lock next)

- **O1 — VO source:** ✅ RESOLVED — MVP = user-uploaded audio or teacher video;
  TTS deferred.
- **O2 — Word/element timing source:** ✅ RESOLVED — **ASR with word-timestamps
  (ElevenLabs Scribe)**. No supplied-transcript path, no forced alignment.
- **O8 — Creative role of the agent?** ✅ RESOLVED — MVP: agent **helps the creator
  build & save the default template family**. Post-MVP: agent **generates**
  concept-resonant themes, human leads the brainstorm/curate/select loop. (See §6a.)
- **O7 — Teacher placement?** ✅ RESOLVED — **MVP: presenter footage used *as-is***
  (full-frame / user-manual / audio-only); no agent-driven placement, no face-aware
  safe area. **Post-MVP:** footage-aware **dynamic per-shot** placement via SAM/YOLO
  + safe-area detection (§6, §6b). IR presenter layer carries **time-varying**
  placement so the upgrade is additive.
- **O3 — Target:** ✅ RESOLVED — v1 is a **thin single-user MVP** (no accounts,
  no cloud). Product-for-others (teachers) is the longer-term goal, not v1.
- **O4 — v1 scope:** ✅ RESOLVED — the §9 vertical slice, single-user, local.
- **O5 — Platform:** web app, **run locally / single-user for MVP** (Next.js +
  dedicated render server, per the examples). Confirm specifics at design time.
- **O6 — Accounts / collaboration:** ✅ RESOLVED — deferred (out for v1).

## 9. Proposed first milestone (to confirm)

A **vertical slice** (single-user, runs locally): the user **uploads a teacher's
explanation (audio or video)**; the system **transcribes + word-aligns** it; the
agent segments it into **key moments** (slicing the content into logical sections,
a **transition at each break**); the agent generates **word-synced animated
highlights/visuals** (math/text) using the **default template family**, composited
over the **presenter footage as-is** on a **layer-based timeline the user can tweak
(manually or with the agent)**; then **export to mp4**. Exercises all five
subsystems at minimum depth.

*(Out of MVP: shots / visual-paragraphing, footage-aware placement, 3D, TTS,
accounts/cloud.)*