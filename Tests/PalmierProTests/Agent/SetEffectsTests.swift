import Foundation
import Testing
@testable import PalmierPro

@Suite("set_effects tool")
@MainActor
struct SetEffectsTests {

    private func harness() -> ToolHarness {
        let clip = Fixtures.clip(id: "c1", mediaRef: "m1", start: 0, duration: 30)
        let audio = Fixtures.clip(id: "a1", mediaRef: "m2", mediaType: .audio, start: 0, duration: 30)
        var text = Fixtures.clip(id: "t1", mediaRef: "t", mediaType: .text, start: 0, duration: 30)
        text.textContent = "hi"
        return ToolHarness(timeline: Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [clip, text]),
            Fixtures.audioTrack(clips: [audio]),
        ]))
    }

    @Test func setsStackWithDefaultsAndClampsParams() async throws {
        let h = harness()
        let result = await h.runRaw("set_effects", args: [
            "clipIds": ["c1"],
            "effects": [
                ["type": "color.exposure", "params": ["ev": 99.0]],
                ["type": "stylize.vignette", "enabled": false],
            ],
        ])
        #expect(result.isError == false, "\(ToolHarness.textOf(result))")

        let effects = try #require(h.editor.clipFor(id: "c1")?.effects)
        #expect(effects.count == 2)
        #expect(effects[0].type == "color.exposure")
        #expect(effects[0].params["ev"]?.value == 3.0)  // clamped to range max
        #expect(effects[1].type == "stylize.vignette")
        #expect(effects[1].enabled == false)
        #expect(effects[1].params["intensity"]?.value == 1.0)  // default
    }

    @Test func emptyArrayClearsStack() async throws {
        let h = harness()
        h.editor.commitClipProperty(clipId: "c1") { $0.effects = [Effect.make("color.contrast")] }
        let result = await h.runRaw("set_effects", args: ["clipIds": ["c1"], "effects": []])
        #expect(result.isError == false)
        #expect(h.editor.clipFor(id: "c1")?.effects == nil)
    }

    @Test func rejectsUnknownTypeUnknownParamAndWrongClipKinds() async throws {
        let h = harness()
        let unknownType = await h.runRaw("set_effects", args: [
            "clipIds": ["c1"], "effects": [["type": "color.hologram"]],
        ])
        #expect(unknownType.isError == true)
        #expect(ToolHarness.textOf(unknownType).contains("color.exposure"))  // lists available

        let unknownParam = await h.runRaw("set_effects", args: [
            "clipIds": ["c1"], "effects": [["type": "color.exposure", "params": ["gain": 1]]],
        ])
        #expect(unknownParam.isError == true)

        for badClip in ["t1", "a1"] {
            let result = await h.runRaw("set_effects", args: [
                "clipIds": [badClip], "effects": [["type": "color.exposure"]],
            ])
            #expect(result.isError == true, "expected rejection for \(badClip)")
        }
        #expect(h.editor.clipFor(id: "c1")?.effects == nil)  // nothing applied
    }

    @Test func undoRestoresPreviousStack() async throws {
        let h = harness()
        let undoManager = UndoManager()
        h.editor.undoManager = undoManager
        _ = await h.runRaw("set_effects", args: [
            "clipIds": ["c1"], "effects": [["type": "color.saturation", "params": ["amount": 0.0]]],
        ])
        #expect(h.editor.clipFor(id: "c1")?.effects?.count == 1)
        undoManager.undo()
        #expect(h.editor.clipFor(id: "c1")?.effects == nil)
        undoManager.redo()
        #expect(h.editor.clipFor(id: "c1")?.effects?.count == 1)
    }

    @Test func timelineReportsEffectsAfterSet() async throws {
        let h = harness()
        _ = await h.runRaw("set_effects", args: [
            "clipIds": ["c1"], "effects": [["type": "blur.gaussian", "params": ["radius": 12]]],
        ])
        let timeline = try await h.runOK("get_timeline") as? [String: Any]
        let json = try #require(ToolExecutor.jsonString(timeline ?? [:]))
        #expect(json.contains("blur.gaussian"))
    }
}
