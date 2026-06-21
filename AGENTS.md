# PalmierPro

AI-native macOS video editor. Swift 6.2, SwiftUI + AppKit, AVFoundation. macOS 26 only, arm64 only. Non-sandboxed Developer ID app.

## Build & run

```bash
swift build
swift run
```

For a bundled debug `.app` that launches and streams OSLog (subsystem `io.palmier.pro`):

```bash
./scripts/dev.sh                      # bundle (fast) + launch + stream logs; Ctrl-C quits
scripts/bundle.sh debug --fast        # just build the .app bundle, no signing
scripts/bundle.sh release --dist      # sign + notarize + staple + DMG (needs .env.prod)
```

## Test

```bash
swift test                                          # full suite (Swift Testing + XCTest)
swift test --filter PalmierProTests.RippleEngineTests   # one test type/case
```

Tests live in `Tests/PalmierProTests/`, grouped by subsystem (`Timeline/`, `Agent/`, `Search/`, `Export/`, `Media/`, `Captions/`). `Fixtures.swift` and `FixtureVideo.swift` build sample timelines/media.

## Code style

- Keep comments minimal. Only write one when the *why* is non-obvious. Don't restate what the code does, don't narrate the current change, don't leave `// removed X` breadcrumbs. One short line max — no multi-line comment blocks or paragraph docstrings.

## Design System

All UI styling MUST use `AppTheme` constants from `Sources/PalmierPro/UI/AppTheme.swift`. Never use hardcoded numeric values for:

- **Spacing/padding** → `AppTheme.Spacing.*` (xxs through xxl)
- **Font sizes** → `AppTheme.FontSize.*` (xxs through display)
- **Font weights** → `AppTheme.FontWeight.*` (regular, medium, semibold, bold)
- **Corner radii** → `AppTheme.Radius.*` (xs through xl)
- **Border widths** → `AppTheme.BorderWidth.*` (hairline, thin, medium, thick)
- **Opacity** → `AppTheme.Opacity.*` (subtle, faint, muted, medium, strong, prominent)
- **Icon frame sizes** → `AppTheme.IconSize.*` (xs through xl)
- **Shadows** → `AppTheme.Shadow.*` (sm, md, lg) via `.shadow(AppTheme.Shadow.md)`
- **Colors** → `AppTheme.Text.*`, `AppTheme.Border.*`, `AppTheme.Background.*`
- **Animation durations** → `AppTheme.Anim.*`

If a needed value doesn't exist in AppTheme, add it there first — don't hardcode it.

## Drag and drop

SwiftUI `.onDrop` on a parent view shadows every drop target inside its layout area on macOS 26 — even AppKit `NSDraggingDestination` children registered directly with the window. Inner `.onDrop` modifiers silently never fire while a parent `.onDrop` is active.

Rule: **any drop target that spans an area containing other drop targets must use native AppKit** (see `MediaPanelDropArea` in `Sources/PalmierPro/MediaPanel/`). Inner / leaf drops can stay SwiftUI `.onDrop`. Do not stack SwiftUI `.onDrop` modifiers in parent/child layouts.

## Voice

Palmier Pro speaks like a quietly capable native Mac app for filmmakers: direct, technical, calm, and 
confident. Prefer Apple HIG-style terseness over warmth. Never chatty or cute. Never marketing. When the
product needs to ask for action, lead with the action verb; when it reports state, name the thing.

## Architecture

The app is an AppKit `NSDocument` app (`main.swift` → `AppDelegate`) wrapping SwiftUI views. No storyboard.

**State ownership.** `AppState.shared` (`App/`) is the app-wide singleton: it holds the `activeProject` and owns the `MCPService`. Each open document is a `VideoProject` (`Project/`, an `NSDocument` subclass) that owns exactly one `EditorViewModel` (`Editor/ViewModel/`). The `EditorViewModel` is the heart of the app — a single `@Observable @MainActor` class split across ~19 `EditorViewModel+*.swift` extension files by concern (Tracks, ClipMutations, Keyframes, Captions, AIEdit, MediaLibrary, Ripple, etc.). When adding editor behavior, add an extension file; don't grow the base class.

**Data model** (`Models/`). The document state is three `Codable` trees: `Timeline` (→ `Track` → `Clip`, all frame-based ints, fps/width/height on `Timeline`), `MediaManifest` (the `MediaAsset` library), and `GenerationLog`. A `Clip.mediaRef` is a string key resolved against the manifest via `MediaResolver`; clips never hold media directly. Clips carry trim/speed/fade/transform/crop plus optional per-property `KeyframeTrack`s for animation.

**Persistence** (`Project/VideoProject.swift`). A project is a `.palmier` file package (`Project` enum in `Utilities/Constants.swift`): `project.json` (timeline), `media.json` (manifest), `generation-log.json`, thumbnail, and chat sessions. Decoding happens off-main in `read()`, applied on main in `makeWindowControllers`; autosave-in-place is on. `Export/` writes out via `XMLExporter` (FCPXML), `PalmierProjectExporter`, and `ExportService`/`CompositionBuilder` (AVFoundation render).

**Preview/render** (`Preview/`). `VideoEngine` + `CompositionBuilder` build an `AVComposition` from the timeline; `TimelineRenderer` and `TextLayerController` drive playback. The same `CompositionBuilder` path backs export, so timeline changes render consistently in both.

**Agent & MCP** (`Agent/`). `ToolExecutor` (`@MainActor`, split across `ToolExecutor+*.swift`) is the single source of timeline-mutating tools, shared by two front ends: the external **MCP server** (`MCP/MCPService` + `MCPHTTPServer`, HTTP on `127.0.0.1:19789`, started by `AppState` when enabled) and the **in-app agent** (`AgentService` + `Panel/`, talking to `Clients/AnthropicClient`/`PalmierClient`). Every tool runs against the active `EditorViewModel`; tool edits are recorded onto an undo stack so the `undo` tool can revert them. Add new tools in `ToolDefinitions.swift` + a `ToolExecutor+*` file.

**Generative AI** (`Generation/`). Closed-source backend: `ModelCatalog` (`Catalog/`) defines video/image/audio/upscale models; `Submission/` types submit jobs; `GenerationService` tracks status back onto `MediaAsset.generationStatus`. Requires login (`Account/`, Clerk + Convex).

**Search** (`Search/`). On-device semantic video search: `VisualIndexer` samples frames (`FrameSampler`), embeds them with a CLIP model (`VisualEmbedder`/`VisualModelLoader`, downloaded via `ModelDownloader`), stores vectors in `EmbeddingStore`, queried by `VisualSearch`. `Transcription/` does on-device speech→captions.

**Logging.** Use the categorized `Log` enum (`Utilities/Log.swift`), e.g. `Log.agent.notice(...)`, subsystem `io.palmier.pro`. Some log calls also emit telemetry (`Telemetry/`). Crashes are written to `~/Library/Logs/PalmierPro/crash.log`.

