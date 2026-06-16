import AVFoundation
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PalmierPro

@Suite("Effects — model")
struct EffectModelTests {

    @Test func clipEffectsRoundTripThroughCodable() throws {
        var clip = Fixtures.clip(id: "c1", mediaRef: "m", start: 0, duration: 30)
        clip.effects = [Effect.make("color.exposure", ["ev": 1.5])]

        let data = try JSONEncoder().encode(clip)
        let decoded = try JSONDecoder().decode(Clip.self, from: data)

        #expect(decoded.effects?.count == 1)
        #expect(decoded.effects?.first?.type == "color.exposure")
        #expect(decoded.effects?.first?.params["ev"]?.value == 1.5)
        #expect(decoded.effects?.first?.enabled == true)
    }

    @Test func clipWithoutEffectsOmitsKey() throws {
        let clip = Fixtures.clip(id: "c1", mediaRef: "m", start: 0, duration: 30)
        let data = try JSONEncoder().encode(clip)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("\"effects\""))
    }

    /// Effects from a newer build survive decode + re-encode even when the
    /// descriptor is unknown to this build.
    @Test func unknownEffectTypeIsPreserved() throws {
        var clip = Fixtures.clip(id: "c1", mediaRef: "m", start: 0, duration: 30)
        clip.effects = [Effect.make("future.hologram", ["wobble": 0.7])]

        let data = try JSONEncoder().encode(clip)
        let decoded = try JSONDecoder().decode(Clip.self, from: data)
        let reencoded = try JSONEncoder().encode(decoded)
        let final = try JSONDecoder().decode(Clip.self, from: reencoded)

        #expect(final.effects?.first?.type == "future.hologram")
        #expect(final.effects?.first?.params["wobble"]?.value == 0.7)
        #expect(EffectRegistry.descriptor(id: "future.hologram") == nil)
    }

    @Test func paramResolvesKeyframeTrackWhenPresent() {
        var param = EffectParam(value: 1.0)
        #expect(param.resolved(at: 10, default: 0) == 1.0)
        param.track = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 0.0, interpolationOut: .linear),
            Keyframe(frame: 20, value: 2.0, interpolationOut: .linear),
        ])
        #expect(abs(param.resolved(at: 10, default: 0) - 1.0) < 0.001)
        #expect(abs(param.resolved(at: 20, default: 0) - 2.0) < 0.001)
    }

    @Test func registryDescriptorsHaveUniqueIdsAndValidDefaults() {
        var seen = Set<String>()
        for descriptor in EffectRegistry.all {
            #expect(seen.insert(descriptor.id).inserted, "duplicate id \(descriptor.id)")
            for spec in descriptor.params {
                #expect(spec.range.contains(spec.defaultValue),
                        "\(descriptor.id).\(spec.key) default outside range")
            }
        }
    }
}

@Suite("Effects — rendering")
@MainActor
struct EffectRenderingTests {

    /// Exposure through the real compositor must measurably brighten/darken frames.
    @Test func exposureChangesRenderedBrightness() async throws {
        let renderSize = CompositorParityTests.renderSize
        let videoURL = try await CompositorParityTests.patternVideoURL()
        nonisolated(unsafe) let urls = ["pattern": videoURL]

        func meanLuma(ev: Double?) async throws -> Double {
            var clip = CompositorParityTests.patternClip()
            if let ev { clip.effects = [Effect.make("color.exposure", ["ev": ev])] }
            let tl = CompositorParityTests.timeline([Fixtures.videoTrack(clips: [clip])])
            let result = try await CompositionBuilder.build(
                timeline: tl, resolveURL: { urls[$0] }, renderSize: renderSize
            )
            let generator = AVAssetImageGenerator(asset: result.composition)
            generator.videoComposition = result.videoComposition
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let cg = try await generator.image(at: CMTime(value: 15, timescale: 30)).image
            let bytes = ColorProbeHelpers.srgbBytes(cg, size: renderSize)
            var total = 0.0
            for i in stride(from: 0, to: bytes.count, by: 4) {
                total += Double(bytes[i]) + Double(bytes[i + 1]) + Double(bytes[i + 2])
            }
            return total / Double(bytes.count / 4 * 3)
        }

        let base = try await meanLuma(ev: nil)
        let darker = try await meanLuma(ev: -2)
        let brighter = try await meanLuma(ev: 1)
        #expect(darker < base - 20, "ev -2 should darken: base \(base), got \(darker)")
        // Saturated pattern has little headroom above 255; +1 EV yields a small gain.
        #expect(brighter > base + 2, "ev +1 should brighten: base \(base), got \(brighter)")
    }

    /// Every catalog effect renders without crashing and (with non-default params)
    /// actually changes pixels. Catches broken filter names/keys as the catalog grows.
    @Test func everyCatalogEffectRendersAndChangesPixels() async throws {
        let renderSize = CompositorParityTests.renderSize
        let videoURL = try await CompositorParityTests.patternVideoURL()
        nonisolated(unsafe) let urls = ["pattern": videoURL]

        let nonDefault: [String: [String: Double]] = [
            "color.exposure": ["ev": -2],
            "color.contrast": ["amount": 0.5],
            "color.saturation": ["amount": 0],
            "color.temperature": ["temperature": 3000],
            "color.highlightsShadows": ["highlights": 0.3, "shadows": 0.8],
            "blur.gaussian": ["radius": 30],
            "blur.sharpen": ["amount": 2],
            "stylize.vignette": ["intensity": 2, "radius": 0.5],
            "stylize.pixelate": ["scale": 60],
        ]

        func frame(_ effects: [Effect]?) async throws -> [UInt8] {
            var clip = CompositorParityTests.patternClip()
            clip.effects = effects
            let tl = CompositorParityTests.timeline([Fixtures.videoTrack(clips: [clip])])
            let result = try await CompositionBuilder.build(
                timeline: tl, resolveURL: { urls[$0] }, renderSize: renderSize
            )
            let generator = AVAssetImageGenerator(asset: result.composition)
            generator.videoComposition = result.videoComposition
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let cg = try await generator.image(at: CMTime(value: 15, timescale: 30)).image
            return ColorProbeHelpers.srgbBytes(cg, size: renderSize)
        }

        let base = try await frame(nil)
        for descriptor in EffectRegistry.all where descriptor.resourceKey == nil {
            let params = nonDefault[descriptor.id]
            #expect(params != nil, "add non-default params for \(descriptor.id) to this test")
            let rendered = try await frame([Effect.make(descriptor.id, params ?? [:])])
            let changed = zip(base, rendered).contains { abs(Int($0) - Int($1)) > 8 }
            #expect(changed, "\(descriptor.id) produced an unchanged frame")
        }
    }

    /// LUT effect: a generated invert .cube file flips the pattern's colors.
    @Test func lutEffectAppliesCubeFile() async throws {
        let cubeURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("invert-\(UUID().uuidString).cube")
        defer { try? FileManager.default.removeItem(at: cubeURL) }
        var cube = "LUT_3D_SIZE 2\n"
        for b in [0.0, 1.0] {
            for g in [0.0, 1.0] {
                for r in [0.0, 1.0] {
                    cube += "\(1 - r) \(1 - g) \(1 - b)\n"
                }
            }
        }
        try cube.write(to: cubeURL, atomically: true, encoding: .utf8)

        let parsed = try #require(LUTLoader.load(path: cubeURL.path))
        #expect(parsed.dimension == 2)

        let renderSize = CompositorParityTests.renderSize
        let videoURL = try await CompositorParityTests.patternVideoURL()
        nonisolated(unsafe) let urls = ["pattern": videoURL]

        var effect = Effect.make("color.lut", ["intensity": 1])
        effect.params["path"] = EffectParam(string: cubeURL.path)
        var clip = CompositorParityTests.patternClip()
        clip.effects = [effect]
        let tl = CompositorParityTests.timeline([Fixtures.videoTrack(clips: [clip])])
        let result = try await CompositionBuilder.build(
            timeline: tl, resolveURL: { urls[$0] }, renderSize: renderSize
        )
        let generator = AVAssetImageGenerator(asset: result.composition)
        generator.videoComposition = result.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let cg = try await generator.image(at: CMTime(value: 15, timescale: 30)).image
        let bytes = ColorProbeHelpers.srgbBytes(cg, size: renderSize)

        // Pattern TL is red (≈233,0,2) → inverted ≈ cyan (low R, high G/B).
        let o = (45 * Int(renderSize.width) + 80) * 4
        #expect(bytes[o] < 80, "inverted red channel should be low, got \(bytes[o])")
        #expect(bytes[o + 1] > 180 && bytes[o + 2] > 180,
                "inverted G/B should be high, got \(bytes[o + 1]), \(bytes[o + 2])")
    }

    /// Disabled effects must not change the frame; unknown types must not crash.
    @Test func disabledAndUnknownEffectsArePassthrough() async throws {
        let renderSize = CompositorParityTests.renderSize
        let videoURL = try await CompositorParityTests.patternVideoURL()
        nonisolated(unsafe) let urls = ["pattern": videoURL]

        func frame(_ effects: [Effect]?) async throws -> [UInt8] {
            var clip = CompositorParityTests.patternClip()
            clip.effects = effects
            let tl = CompositorParityTests.timeline([Fixtures.videoTrack(clips: [clip])])
            let result = try await CompositionBuilder.build(
                timeline: tl, resolveURL: { urls[$0] }, renderSize: renderSize
            )
            let generator = AVAssetImageGenerator(asset: result.composition)
            generator.videoComposition = result.videoComposition
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let cg = try await generator.image(at: CMTime(value: 15, timescale: 30)).image
            return ColorProbeHelpers.srgbBytes(cg, size: renderSize)
        }

        var disabled = Effect.make("color.exposure", ["ev": -2])
        disabled.enabled = false
        let base = try await frame(nil)
        let withDisabled = try await frame([disabled])
        let withUnknown = try await frame([Effect.make("future.hologram")])
        #expect(base == withDisabled)
        #expect(base == withUnknown)
    }
}

enum ColorProbeHelpers {
    static func srgbBytes(_ image: CGImage, size: CGSize) -> [UInt8] {
        let w = Int(size.width), h = Int(size.height)
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(
            data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return data
    }
}
