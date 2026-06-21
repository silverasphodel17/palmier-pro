# VISION.md — Agentic Educational Video Platform

> Version: Draft 1  
> Purpose: Product vision, not PRD  
> Source notes: BYJU'S-style animation workflow, platform constraints, MVP boundary

## 1. One-line vision

Build an agentic animation platform that helps non-animators turn a teacher's recorded explanation into a BYJU'S-style math/science explainer video, with voice-synced animations, concept-resonant template families, and a layer-based timeline for human control.

## 2. The problem

High-quality educational animation is still trapped inside expert workflows.

The creative output looks simple on screen: formulas appear at the right moment, labels reveal cleanly, diagrams build step by step, highlights track the narration, and the teacher's explanation feels visually alive. But behind that is a slow manual process: storyboard planning, layer construction, keyframing, timing every visual beat to voiceover, and reworking visuals whenever the explanation changes.

For educators and content creators, that is too much animation craft. For production teams, it becomes expensive repetitive labour.

The opportunity is not to make a generic video generator. The opportunity is to automate the mechanical drudgery while preserving the creative quality that makes educational animation memorable.

## 3. The product thesis

The magic of strong educational animation comes from two things:

1. **Mechanical choreography** — every text, formula, diagram, label, highlight, and transition appears on its own layer, timed precisely to the narration.
2. **Concept-resonant motion design** — the motion and visual language are not random decoration; they carry meaning. Sound topics may use waves. Atom topics may use atom-like reveals. The template must feel born from the concept.

The platform should fully automate the first part and assist the human creator in shaping the second.

In other words:

> The agent does the After Effects grind.  
> The human still leads the taste, concept, and final judgement.

## 4. Target user

The platform is for educators, content creators, and small production teams who understand the lesson but do not have advanced animation skills.

They should not need to keyframe, build scenes from scratch, or think in animation-engine terms. They should be able to upload an explanation, review the agent's first cut, and adjust the result through understandable controls: timeline clips, layers, parameters, drag handles, style options, and agent-assisted edits.

## 5. What the product should feel like

The user experience should feel like a hybrid of:

- A smart animation assistant that understands the narration.
- A BYJU'S-style explainer system for math and science.
- A lightweight Premiere-style timeline where every generated decision remains editable.
- A template-family studio where reusable concept-themed motion systems can be created, previewed, saved, and reused.

The product should never feel like a black-box video generator that spits out something uneditable.

It should also never feel like a full After Effects clone where the user is forced into professional animation labour.

## 6. Core promise

A teacher uploads an explanation. The platform listens to it, understands the timed transcript, identifies the important teaching moments, and generates a first cut with synced visuals, formula highlights, text reveals, diagrams, and transitions.

The creator can then refine the video manually or ask the agent to make changes. Every meaningful element stays visible as a layer or clip on the timeline.

The final output is an MP4 educational explainer video.

## 7. Creative model: template families, not stock templates

The reusable creative unit is a **template family**.

A template family is not a single master template. It is a named, concept-themed design and motion system that can be reused across many videos in a topic while still feeling specific and intentional.

A template family owns:

1. **Motion language** — how things enter, exit, emphasise, pulse, reveal, or transform.
2. **Visual motifs** — recurring shapes, patterns, structures, and metaphors tied to the concept.
3. **Theme tokens** — colours, fonts, strokes, glows, shadows, spacing, and visual treatment.
4. **Styled components** — how primitives like text, formula, graph, diagram, label, callout, and highlight behave inside the family.
5. **Transitions** — the family-specific way scenes or key moments shift.
6. **Sound design** — small audio motifs that support the motion language.

This is the heart of the product. The platform should not mass-produce educational videos from one generic template. It should let creators build and reuse families that carry conceptual meaning.

## 8. Agent role

The agent is not a freeform animator writing arbitrary code.

The agent should compose from a validated component and template-family library. It should generate structured scene data, not brittle animation code. It should make decisions about timing, layout, emphasis, and sequencing, but those decisions must be editable.

The agent's responsibilities:

- Read the timed transcript.
- Identify key teaching moments.
- Choose what deserves text, formula, diagram, highlight, graph, callout, or transition treatment.
- Compose layers and clips on a timeline.
- Sync visual emphasis to spoken words.
- Use the selected template family consistently.
- Render and inspect output to catch visual failures.
- Help the user revise the generated video through natural-language instructions.

The agent should feel like an animation producer plus assistant editor, not an uncontrollable creator.

## 9. Human role

The human remains the creative director.

The user should be able to:

- Select or confirm the template family.
- Review the generated first cut.
- Edit timing, layout, text, formula, colours, and emphasis.
- Lock parts of the timeline they like.
- Ask the agent to revise only selected parts.
- Save improved template-family choices for reuse.
- Undo changes safely through auto-checkpoints.

The product succeeds only if creators feel that the system accelerates their judgement instead of replacing it badly.

## 10. Structural model: key moments and shots

The platform should treat educational video as structured storytelling, not only as word-by-word caption animation.

### Key moments

Key moments are the big logical breakpoints in the explanation. They mark when the lesson moves to a new sub-idea. In the MVP, the agent should segment the transcript into key moments and place transitions at those breaks.

Key moments are in scope for MVP.

### Shots

Shots are finer visual paragraphs: changes in the on-screen composition such as teacher full-frame, teacher side-by-side, close emphasis, hidden teacher, or animation-only staging.

Shots are important to the long-term vision, but they require footage understanding and safe-area detection. They are post-MVP.

## 11. MVP vision

The MVP is a thin, local, single-user vertical slice.

The user uploads a teacher's audio or video explanation. The platform transcribes it with word-level timestamps. The agent segments the timed transcript into key moments, generates word-synced educational visuals using the default template family, places the result on a layer-based timeline, and exports an MP4.

For MVP:

- Input is uploaded audio or a single-teacher video.
- TTS is out.
- Supplied transcript / forced alignment is out.
- Presenter footage is used as-is.
- No automatic face detection, safe-area planning, or shot composition.
- No 3D.
- No accounts, cloud storage, billing, collaboration, or plugin ecosystem.
- One agent-assisted default template family is enough.
- The timeline must still be editable.
- Undo/redo can be linear with auto-checkpoints.

The MVP should prove the full loop: upload → transcribe → understand → generate timeline → edit → render/export.

## 12. Long-term product vision

Over time, the product should evolve from a local vertical slice into a creator-facing educational animation system.

The long-term direction includes:

- Multiple reusable template families across topics and subjects.
- Agent-assisted creation of new concept-resonant families.
- Footage-aware layout using presenter detection and safe areas.
- Shot planning as visual paragraphing.
- Stronger math/science primitives: graphs, geometry, diagrams, simulations, and eventually 3D.
- Asset generation and verification for diagrams and visuals.
- Smarter regeneration that respects locked human edits.
- Cloud rendering and project storage.
- Team workflows, if and when the product demands them.

The long-term ambition is not to become a general-purpose editing suite. The ambition is to become the best system for creating narrated educational explainers where pedagogy, timing, and motion design work together.

## 13. Product principles

### 1. Automate drudgery, not taste

The platform should remove repetitive layer work, syncing work, and first-cut assembly. It should not pretend that creative judgement is solved.

### 2. Templates must carry meaning

A good educational template family is not just beautiful. It should make the concept easier to feel, remember, and understand.

### 3. Everything generated must be editable

Agent output is a first cut, not a final prison. Every important decision must be visible and adjustable.

### 4. Math and science are first-class

Formulae, plots, diagrams, geometry, labels, and visual explanations are core product objects, not decorative overlays.

### 5. Voiceover is the spine

The narration drives timing. Visuals must sync to explanation, emphasis, and spoken structure.

### 6. The timeline is the trust layer

Users trust the agent because they can see and change what it did.

### 7. Build for non-animators, not non-creators

The user may not know keyframes, but they do have taste, intent, and teaching judgement. The interface should respect that.

## 14. What this is not

This is not:

- A PRD.
- A general video editor.
- A full After Effects replacement.
- A generic AI video generator.
- A stock-template slideshow maker.
- A TTS-first course generator.
- A 3D-first animation tool.
- A collaboration/product-management platform in v1.

## 15. North-star outcome

A non-animator should be able to produce a polished, voice-synced math/science explainer that feels intentionally designed, not auto-generated.

The best version of the product will make creators say:

> “This did the boring 80% like a production assistant, but still let me make it mine.”
