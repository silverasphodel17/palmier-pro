import AVFoundation
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PalmierPro

/// Golden-frame parity: the CI compositor must reproduce the stock layer-instruction
/// renderer across the transform/crop/opacity/stacking matrix. Both paths render the
/// same composition via AVAssetImageGenerator; frames are compared per-channel.
@Suite("Compositor parity — CI vs stock")
@MainActor
struct CompositorParityTests {

    static let renderSize = CGSize(width: 320, height: 180)

    struct DiffStats {
        let mean: Double
        /// Fraction of pixels with any channel differing by more than 24/255.
        let fractionLarge: Double
    }

    // MARK: - Fixtures

    /// Asymmetric quadrants (TL red, TR green, BL blue, BR white) so flips, rotations,
    /// and crops all produce measurably distinct frames.
    static func patternPNG(size: CGSize) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parity-pattern-\(Int(size.width))x\(Int(size.height)).png")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let w = Int(size.width), h = Int(size.height)
        let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // CGContext is bottom-left origin: top quadrants sit in the upper half.
        func fill(_ r: Double, _ g: Double, _ b: Double, _ rect: CGRect) {
            ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
            ctx.fill(rect)
        }
        fill(1, 0, 0, CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2))
        fill(0, 1, 0, CGRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2))
        fill(0, 0, 1, CGRect(x: 0, y: 0, width: w / 2, height: h / 2))
        fill(1, 1, 1, CGRect(x: w / 2, y: 0, width: w / 2, height: h / 2))

        let image = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "parity", code: 1)
        }
        return url
    }

    static func patternVideoURL() async throws -> URL {
        let png = try patternPNG(size: renderSize)
        return try await ImageVideoGenerator.stillVideo(
            for: png, mediaRef: "parity-pattern", size: renderSize
        )
    }

    static func patternClip(id: String = "c1", start: Int = 0, duration: Int = 60) -> Clip {
        Fixtures.clip(id: id, mediaRef: "pattern", start: start, duration: duration)
    }

    static func timeline(_ tracks: [Track], width: CGSize = renderSize) -> Timeline {
        var t = Fixtures.timeline(tracks: tracks)
        t.width = Int(width.width)
        t.height = Int(width.height)
        return t
    }

    // MARK: - Harness

    /// Renders `frame` through both compositor paths and returns the diff.
    static func diff(
        timeline: Timeline,
        frame: Int,
        renderSize: CGSize = renderSize,
        imageURLs: [String: URL] = [:]
    ) async throws -> DiffStats {
        var urls = imageURLs
        if urls["pattern"] == nil { urls["pattern"] = try await patternVideoURL() }
        nonisolated(unsafe) let resolved = urls

        let result = try await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { resolved[$0] },
            renderSize: renderSize
        )

        var frames: [Bool: [UInt8]] = [:]
        for useCI in [true, false] {
            let (_, vc) = CompositionBuilder.buildVisuals(
                timeline: timeline,
                trackMappings: result.trackMappings,
                clipNaturalSizes: result.clipNaturalSizes,
                clipTransforms: result.clipTransforms,
                compositionDuration: result.composition.duration,
                renderSize: renderSize,
                useCICompositor: useCI
            )
            let generator = AVAssetImageGenerator(asset: result.composition)
            generator.videoComposition = vc
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let cg = try await generator.image(
                at: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(timeline.fps))
            ).image
            frames[useCI] = rgba(cg, size: renderSize)
        }

        let a = frames[true]!, b = frames[false]!
        #expect(a.count == b.count)
        var total = 0.0
        var large = 0
        let pixels = a.count / 4
        for p in 0..<pixels {
            var maxChannel = 0
            for c in 0..<4 {
                let d = abs(Int(a[p * 4 + c]) - Int(b[p * 4 + c]))
                total += Double(d)
                maxChannel = max(maxChannel, d)
            }
            if maxChannel > 24 { large += 1 }
        }
        return DiffStats(mean: total / Double(a.count), fractionLarge: Double(large) / Double(pixels))
    }

    private static func rgba(_ image: CGImage, size: CGSize) -> [UInt8] {
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

    // Defaults calibrated to pipeline noise: H.264 4:2:0 chroma edges at quadrant
    // boundaries land different YUV→RGB conversion points in the two paths (~2–3.5%
    // of pixels). Structural breakage (wrong quadrant, flip, shift, opacity) produces
    // fractions over 10% and large means.
    private func assertParity(_ stats: DiffStats, mean: Double = 3.0, large: Double = 0.05,
                              _ comment: Comment? = nil) {
        #expect(stats.mean < mean, "\(comment?.description ?? "") mean diff \(stats.mean)")
        #expect(stats.fractionLarge < large, "\(comment?.description ?? "") large-diff fraction \(stats.fractionLarge)")
    }

    // MARK: - Matrix

    @Test func identityFullFrame() async throws {
        let tl = Self.timeline([Fixtures.videoTrack(clips: [Self.patternClip()])])
        assertParity(try await Self.diff(timeline: tl, frame: 15))
    }

    @Test func pipTransformOverFullFrame() async throws {
        var pip = Self.patternClip(id: "pip")
        pip.transform = Transform(centerX: 0.3, centerY: 0.35, width: 0.5, height: 0.5)
        let tl = Self.timeline([
            Fixtures.videoTrack(clips: [pip]),
            Fixtures.videoTrack(clips: [Self.patternClip(id: "bg")]),
        ])
        assertParity(try await Self.diff(timeline: tl, frame: 15))
    }

    @Test func rotation45() async throws {
        var clip = Self.patternClip()
        clip.transform = Transform(width: 0.6, height: 0.6, rotation: 45)
        let tl = Self.timeline([Fixtures.videoTrack(clips: [clip])])
        assertParity(try await Self.diff(timeline: tl, frame: 15))
    }

    @Test func flipHorizontalStatic() async throws {
        var clip = Self.patternClip()
        clip.transform = Transform(flipHorizontal: true)
        let tl = Self.timeline([Fixtures.videoTrack(clips: [clip])])
        assertParity(try await Self.diff(timeline: tl, frame: 15))
    }

    @Test func cropInsetsStatic() async throws {
        var top = Self.patternClip(id: "top")
        top.crop = Crop(left: 0.25, top: 0.1, right: 0.1, bottom: 0.2)
        top.transform = Transform(centerX: 0.6, centerY: 0.4, width: 0.8, height: 0.8)
        let tl = Self.timeline([
            Fixtures.videoTrack(clips: [top]),
            Fixtures.videoTrack(clips: [Self.patternClip(id: "bg")]),
        ])
        assertParity(try await Self.diff(timeline: tl, frame: 15))
    }

    @Test func cropKeyframed() async throws {
        var clip = Self.patternClip()
        clip.cropTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: Crop(), interpolationOut: .linear),
            Keyframe(frame: 60, value: Crop(left: 0.3, top: 0.2, right: 0.1, bottom: 0.1), interpolationOut: .linear),
        ])
        let tl = Self.timeline([Fixtures.videoTrack(clips: [clip])])
        assertParity(try await Self.diff(timeline: tl, frame: 30))
    }

    @Test func opacityHalfOverPattern() async throws {
        var top = Self.patternClip(id: "top")
        top.opacity = 0.5
        top.transform = Transform(flipVertical: true)
        let tl = Self.timeline([
            Fixtures.videoTrack(clips: [top]),
            Fixtures.videoTrack(clips: [Self.patternClip(id: "bg")]),
        ])
        assertParity(try await Self.diff(timeline: tl, frame: 15))
    }

    @Test func fadeInSmoothMidFade() async throws {
        var top = Self.patternClip(id: "top")
        top.fadeInFrames = 20
        top.fadeInInterpolation = .smooth
        var bg = Self.patternClip(id: "bg")
        bg.transform = Transform(flipHorizontal: true)
        let tl = Self.timeline([
            Fixtures.videoTrack(clips: [top]),
            Fixtures.videoTrack(clips: [bg]),
        ])
        // Mid-subdivision frame: CI samples smoothstep exactly, stock uses 8-segment ramps.
        assertParity(try await Self.diff(timeline: tl, frame: 9))
    }

    @Test func opacityKeyframedSmoothMidSegment() async throws {
        var top = Self.patternClip(id: "top")
        top.opacityTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 1.0, interpolationOut: .smooth),
            Keyframe(frame: 60, value: 0.2, interpolationOut: .smooth),
        ])
        let tl = Self.timeline([
            Fixtures.videoTrack(clips: [top]),
            Fixtures.videoTrack(clips: [Self.patternClip(id: "bg")]),
        ])
        assertParity(try await Self.diff(timeline: tl, frame: 27))
    }

    @Test func transformKeyframed() async throws {
        var clip = Self.patternClip()
        clip.scaleTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: AnimPair(a: 1.0, b: 1.0), interpolationOut: .linear),
            Keyframe(frame: 60, value: AnimPair(a: 0.5, b: 0.5), interpolationOut: .linear),
        ])
        clip.positionTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: AnimPair(a: 0, b: 0), interpolationOut: .linear),
            Keyframe(frame: 60, value: AnimPair(a: 0.25, b: 0.1), interpolationOut: .linear),
        ])
        let tl = Self.timeline([Fixtures.videoTrack(clips: [clip])])
        assertParity(try await Self.diff(timeline: tl, frame: 23))
    }

    @Test func imageClip() async throws {
        let png = try Self.patternPNG(size: Self.renderSize)
        var clip = Fixtures.clip(id: "img", mediaRef: "pattern-image", mediaType: .image, start: 0, duration: 60)
        clip.transform = Transform(centerX: 0.5, centerY: 0.5, width: 0.7, height: 0.7)
        let tl = Self.timeline([Fixtures.videoTrack(clips: [clip])])
        assertParity(try await Self.diff(timeline: tl, frame: 15, imageURLs: ["pattern-image": png]))
    }

    @Test func gapShowsBlack() async throws {
        let tl = Self.timeline([Fixtures.videoTrack(clips: [Self.patternClip(start: 30, duration: 30)])])
        assertParity(try await Self.diff(timeline: tl, frame: 10), mean: 1.0)
    }

    @Test func hiddenTrackSkipped() async throws {
        var hidden = Fixtures.videoTrack(clips: [Self.patternClip(id: "hid")])
        hidden.hidden = true
        var bg = Self.patternClip(id: "bg")
        bg.transform = Transform(flipVertical: true)
        let tl = Self.timeline([hidden, Fixtures.videoTrack(clips: [bg])])
        assertParity(try await Self.diff(timeline: tl, frame: 15))
    }

    @Test func speedDoubleClip() async throws {
        let clip = Self.patternClip()
        var fast = clip
        fast.speed = 2.0
        let tl = Self.timeline([Fixtures.videoTrack(clips: [fast])])
        assertParity(try await Self.diff(timeline: tl, frame: 15))
    }

    @Test func nonNativeRenderSize() async throws {
        var pip = Self.patternClip(id: "pip")
        pip.transform = Transform(centerX: 0.4, centerY: 0.4, width: 0.5, height: 0.5, rotation: 20)
        let tl = Self.timeline([
            Fixtures.videoTrack(clips: [pip]),
            Fixtures.videoTrack(clips: [Self.patternClip(id: "bg")]),
        ])
        assertParity(try await Self.diff(
            timeline: tl, frame: 15, renderSize: CGSize(width: 640, height: 360)
        ))
    }

    @Test func threeLayerStack() async throws {
        var top = Self.patternClip(id: "top")
        top.transform = Transform(centerX: 0.25, centerY: 0.25, width: 0.4, height: 0.4)
        top.opacity = 0.8
        var mid = Self.patternClip(id: "mid")
        mid.transform = Transform(centerX: 0.7, centerY: 0.6, width: 0.5, height: 0.5, rotation: -15)
        mid.opacity = 0.6
        let tl = Self.timeline([
            Fixtures.videoTrack(clips: [top]),
            Fixtures.videoTrack(clips: [mid]),
            Fixtures.videoTrack(clips: [Self.patternClip(id: "bg")]),
        ])
        // Antialiased edges of two rotated/translucent layers over a patterned bg.
        assertParity(try await Self.diff(timeline: tl, frame: 15), large: 0.12)
    }

    /// Transparent ProRes 4444 still (alpha PNG → stillVideo) composited over pattern.
    @Test func alphaMediaOverPattern() async throws {
        let pngURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parity-alpha-pattern.png")
        if !FileManager.default.fileExists(atPath: pngURL.path) {
            let w = 320, h = 180
            let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2))
            ctx.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 0.5))
            ctx.fill(CGRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2))
            let dest = CGImageDestinationCreateWithURL(
                pngURL as CFURL, UTType.png.identifier as CFString, 1, nil
            )!
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
            #expect(CGImageDestinationFinalize(dest))
        }
        var overlay = Fixtures.clip(id: "ov", mediaRef: "alpha-img", mediaType: .image, start: 0, duration: 60)
        overlay.opacity = 0.9
        let tl = Self.timeline([
            Fixtures.videoTrack(clips: [overlay]),
            Fixtures.videoTrack(clips: [Self.patternClip(id: "bg")]),
        ])
        assertParity(try await Self.diff(timeline: tl, frame: 15, imageURLs: ["alpha-img": pngURL]))
    }

    /// Adjacent clips on one track: segment boundary at the cut, both sides render.
    @Test func adjacentClipsCutBoundary() async throws {
        var second = Self.patternClip(id: "c2", start: 30, duration: 30)
        second.transform = Transform(flipHorizontal: true)
        let tl = Self.timeline([
            Fixtures.videoTrack(clips: [Self.patternClip(id: "c1", duration: 30), second]),
        ])
        assertParity(try await Self.diff(timeline: tl, frame: 29))
        assertParity(try await Self.diff(timeline: tl, frame: 31))
    }
}
