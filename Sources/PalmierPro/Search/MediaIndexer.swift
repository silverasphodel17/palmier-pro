import AVFoundation
import Foundation

/// Builds and owns the project's semantic search indexes. One asset at a time,
/// in the background; results land in `indexes` and on disk under `analysis/`.
@MainActor
@Observable
final class MediaIndexer {
    weak var editor: EditorViewModel?

    private(set) var indexes: [String: AssetSearchIndex] = [:]
    private(set) var revision = 0
    private(set) var pendingCount = 0
    /// Assets enqueued since the current batch started; resets when the queue drains.
    private(set) var batchTotal = 0
    private(set) var batchCompleted = 0
    /// 0...1 within the asset currently being indexed (visual pass only).
    private(set) var currentAssetFraction: Double = 0

    var indexingActive: Bool { batchCompleted < batchTotal }
    var indexingProgress: Double {
        guard batchTotal > 0 else { return 0 }
        return min(1, (Double(batchCompleted) + min(max(currentAssetFraction, 0), 1)) / Double(batchTotal))
    }

    private var queue: [String] = []
    private var queuedIds: Set<String> = []
    private var worker: Task<Void, Never>?
    /// Assets whose indexing failed this session — don't retry in a loop.
    private var failedIds: Set<String> = []

    struct AssetSnapshot: Sendable {
        let id: String
        let url: URL
        let type: ClipType
        let duration: Double
        let hasAudio: Bool
        let projectURL: URL?
    }

    // MARK: - Triggers

    func projectOpened() {
        guard let editor else { return }
        let ids = editor.mediaAssets.map(\.id)
        let projectURL = editor.projectURL
        Task.detached(priority: .utility) { [weak self] in
            var loaded: [String: AssetSearchIndex] = [:]
            for id in ids {
                if let index = SearchIndexStore.load(assetId: id, projectURL: projectURL) {
                    loaded[id] = index
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (id, index) in loaded where self.indexes[id] == nil {
                    self.indexes[id] = index
                }
                if !loaded.isEmpty { self.revision += 1 }
                self.indexAllPending()
            }
        }
    }

    func indexAllPending() {
        guard let editor else { return }
        for asset in editor.mediaAssets {
            schedule(assetId: asset.id)
        }
    }

    func schedule(assetId: String) {
        guard !queuedIds.contains(assetId), !failedIds.contains(assetId) else { return }
        guard let asset = editor?.mediaAssets.first(where: { $0.id == assetId }), needsWork(asset) else { return }
        queuedIds.insert(assetId)
        queue.append(assetId)
        batchTotal += 1
        pendingCount = queue.count
        ensureWorker()
    }

    /// Mirrors `indexOne`'s guards (minus the disk stat) so already-indexed
    /// assets never enter the queue and progress counts only real work.
    private func needsWork(_ asset: MediaAsset) -> Bool {
        guard !asset.isGenerating, asset.type != .text else { return false }
        let index = indexes[asset.id]
        let visualPossible: Bool = switch EmbeddingService.shared.visualState {
        case .notInstalled, .failed: false
        default: true
        }
        let wantsVisual = (asset.type == .video || asset.type == .image) && visualPossible
        let wantsSpoken = asset.type == .audio || (asset.type == .video && asset.hasAudio)
        let emptyVisual = (index?.visual.isEmpty ?? true) && asset.type == .video
        let needsVisual = wantsVisual && (!(index?.visualIndexed ?? false) || emptyVisual)
        let needsSpoken = wantsSpoken && !(index?.spokenIndexed ?? false)
        return needsVisual || needsSpoken
    }

    /// Re-attempt assets that previously failed (e.g. after the visual models install).
    func resetFailures() {
        failedIds.removeAll()
    }

    // MARK: - Query

    func search(query: String) async -> SearchResults {
        let service = EmbeddingService.shared
        return await SemanticSearchEngine.search(
            query: query,
            indexes: indexes,
            clip: service.visualReady ? service.clip : nil,
            spoken: service.spokenReady ? service.spoken : nil
        )
    }

    // MARK: - Worker

    private func ensureWorker() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await EmbeddingService.shared.prepare()
            while let self, let id = self.dequeue() {
                self.currentAssetFraction = 0
                await self.indexOne(assetId: id)
                self.batchCompleted += 1
                self.currentAssetFraction = 0
            }
            self?.worker = nil
        }
    }

    private func dequeue() -> String? {
        guard !queue.isEmpty else {
            pendingCount = 0
            batchTotal = 0
            batchCompleted = 0
            currentAssetFraction = 0
            return nil
        }
        let id = queue.removeFirst()
        queuedIds.remove(id)
        pendingCount = queue.count
        return id
    }

    private func indexOne(assetId: String) async {
        guard let editor,
              let asset = editor.mediaAssets.first(where: { $0.id == assetId }),
              !asset.isGenerating,
              asset.type != .text,
              FileManager.default.fileExists(atPath: asset.url.path) else { return }

        let snapshot = AssetSnapshot(
            id: asset.id, url: asset.url, type: asset.type,
            duration: asset.duration, hasAudio: asset.hasAudio,
            projectURL: editor.projectURL
        )
        guard let contentKey = AnalysisStore.contentKey(for: snapshot.url) else { return }

        var index = indexes[assetId]
        if let existing = index, !existing.isCurrent(for: contentKey) {
            index = nil
        }

        let service = EmbeddingService.shared
        let clip = service.visualReady ? service.clip : nil
        let spoken = service.spokenReady ? service.spoken : nil

        let wantsVisual = snapshot.type == .video || snapshot.type == .image
        let wantsSpoken = snapshot.type == .audio || (snapshot.type == .video && snapshot.hasAudio)
        // Older builds saved failed passes as indexed-but-empty; treat those as stale.
        let emptyVisual = (index?.visual.isEmpty ?? true) && snapshot.type == .video
        let needsVisual = wantsVisual && clip != nil && (!(index?.visualIndexed ?? false) || emptyVisual)
        let needsSpoken = wantsSpoken && spoken != nil && !(index?.spokenIndexed ?? false)
        guard needsVisual || needsSpoken else { return }

        Log.search.notice("index start asset=\(assetId.prefix(8)) visual=\(needsVisual) spoken=\(needsSpoken)")
        let built = await Self.build(
            snapshot: snapshot, contentKey: contentKey, base: index,
            needsVisual: needsVisual, needsSpoken: needsSpoken,
            clip: clip, spoken: spoken,
            progress: { [weak self] fraction in
                Task { @MainActor [weak self] in self?.currentAssetFraction = fraction }
            }
        )

        guard let editor = self.editor, editor.mediaAssets.contains(where: { $0.id == assetId }) else { return }
        if built.visualIndexed == (index?.visualIndexed ?? false),
           built.spokenIndexed == (index?.spokenIndexed ?? false) {
            failedIds.insert(assetId)
        }
        indexes[assetId] = built
        revision += 1
        let projectURL = snapshot.projectURL
        Task.detached(priority: .utility) {
            SearchIndexStore.save(built, assetId: assetId, projectURL: projectURL)
        }
        Log.search.notice("index done asset=\(assetId.prefix(8)) visual=\(built.visual.count) spoken=\(built.spoken.count)")
    }

    // MARK: - Index building (off-main)

    private nonisolated static func build(
        snapshot: AssetSnapshot,
        contentKey: String,
        base: AssetSearchIndex?,
        needsVisual: Bool,
        needsSpoken: Bool,
        clip: CLIPRuntime?,
        spoken: SpokenEmbedder?,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> AssetSearchIndex {
        var index = base ?? AssetSearchIndex(contentKey: contentKey)
        index.contentKey = contentKey

        if needsSpoken, let spoken {
            do {
                let transcript = try await AnalysisStore.cachedOrTranscribe(
                    fileURL: snapshot.url, type: snapshot.type,
                    assetId: snapshot.id, projectURL: snapshot.projectURL
                )
                index.spoken = SpokenWindowBuilder.windows(from: transcript).compactMap { window in
                    guard let vector = spoken.embed(window.text) else { return nil }
                    return SearchSegment(start: window.start, end: window.end, text: window.text, vector: vector)
                }
                index.spokenIndexed = true
            } catch {
                Log.search.warning("transcription failed asset=\(snapshot.id.prefix(8)): \(error.localizedDescription)")
            }
        }

        if needsVisual, let clip {
            switch snapshot.type {
            case .image:
                if let cgImage = loadImage(url: snapshot.url),
                   let vector = clip.embedImage(cgImage) {
                    let end = max(snapshot.duration, 1)
                    index.visual = [SearchSegment(start: 0, end: end, text: nil, vector: vector)]
                    index.visualIndexed = true
                } else {
                    Log.search.warning("image unreadable, visual index skipped asset=\(snapshot.id.prefix(8))")
                }
            case .video:
                let segments = await videoSegments(snapshot: snapshot, clip: clip, progress: progress)
                // Zero frames means the file was unreadable (e.g. permission denied)
                // or metadata wasn't loaded yet — leave unindexed so it retries.
                if !segments.isEmpty {
                    index.visual = segments
                    index.visualIndexed = true
                } else {
                    Log.search.warning("no frames extracted, visual index skipped asset=\(snapshot.id.prefix(8))")
                }
            default:
                index.visualIndexed = true
            }
        }
        return index
    }

    /// Near-duplicate consecutive frames collapse into one time-ranged segment,
    /// so static shots cost a single vector and hits come back as ranges.
    private nonisolated static let frameDedupThreshold: Float = 0.96
    private nonisolated static let maxVisualSamples = 1200
    private nonisolated static let minVisualInterval: Double = 0.5
    /// High-res sources (4K+) decode much slower, so sample them half as often.
    private nonisolated static let highResMinInterval: Double = 1.0
    private nonisolated static let highResPixelThreshold: CGFloat = 3000

    private nonisolated static func videoSegments(
        snapshot: AssetSnapshot,
        clip: CLIPRuntime,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> [SearchSegment] {
        let avAsset = AVURLAsset(url: snapshot.url)
        var duration = snapshot.duration
        if duration <= 0 {
            duration = (try? await avAsset.load(.duration).seconds) ?? 0
        }
        guard duration > 0 else { return [] }

        var isHighRes = false
        if let track = try? await avAsset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize) {
            isHighRes = max(abs(size.width), abs(size.height)) >= highResPixelThreshold
        }
        let minInterval = isHighRes ? highResMinInterval : minVisualInterval
        let interval = max(minInterval, duration / Double(maxVisualSamples))

        var times: [CMTime] = []
        var t = interval / 2
        while t < duration {
            times.append(CMTime(seconds: t, preferredTimescale: 600))
            t += interval
        }
        guard !times.isEmpty else { return [] }

        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        // 2x the CLIP input edge so the short side of a 16:9 frame still
        // covers the model's square input after the aspect-fill stretch.
        let decodeEdge = CGFloat(clip.imageSize * 2)
        generator.maximumSize = CGSize(width: decodeEdge, height: decodeEdge)
        // Tolerance of at least ~1s lets the decoder grab the nearest sync frame
        // instead of decoding a whole GOP per sample — the difference between
        // minutes and hours on long-GOP 4K camera files.
        let tolerance = CMTime(seconds: max(interval / 2, 1.0), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var segments: [SearchSegment] = []
        var processed = 0
        let total = times.count
        for await result in generator.images(for: times) {
            processed += 1
            if processed % 16 == 0 || processed == total {
                progress(Double(processed) / Double(total))
            }
            guard case .success(let requestedTime, let image, _) = result else { continue }
            guard let vector = clip.embedImage(image) else { continue }
            let time = requestedTime.seconds
            let start = max(0, time - interval / 2)
            let end = min(duration, time + interval / 2)
            if var last = segments.last, dot(last.vector, vector) >= frameDedupThreshold {
                last.end = end
                segments[segments.count - 1] = last
            } else {
                segments.append(SearchSegment(start: start, end: end, text: nil, vector: vector))
            }
        }
        return segments
    }

    private nonisolated static func loadImage(url: URL) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceShouldCache: false,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    nonisolated static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var result: Float = 0
        for i in 0..<a.count { result += a[i] * b[i] }
        return result
    }
}

// MARK: - Transcript windowing

/// Groups transcript content into ~6s windows aligned to utterance boundaries.
enum SpokenWindowBuilder {
    struct Window: Equatable, Sendable {
        var text: String
        var start: Double
        var end: Double
    }

    static let targetDuration: Double = 6
    static let maxDuration: Double = 12
    static let mergeGap: Double = 1

    static func windows(from result: TranscriptionResult) -> [Window] {
        var pieces: [Window] = []
        for segment in result.segments {
            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Punctuation-only utterances ("...", ".") embed to junk vectors
            // that score high against everything — skip them outright.
            guard trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            if segment.end - segment.start <= maxDuration {
                pieces.append(Window(text: trimmed, start: segment.start, end: segment.end))
            } else {
                pieces.append(contentsOf: split(segment: segment, words: result.words))
            }
        }

        var out: [Window] = []
        for piece in pieces {
            if var last = out.last,
               last.end - last.start < targetDuration,
               piece.start - last.end <= mergeGap,
               piece.end - last.start <= maxDuration {
                last.text += " " + piece.text
                last.end = piece.end
                out[out.count - 1] = last
            } else {
                out.append(piece)
            }
        }
        return out
    }

    private static func split(segment: TranscriptionSegment, words: [TranscriptionWord]) -> [Window] {
        let inRange = words.filter { word in
            guard let s = word.start, let e = word.end else { return false }
            return s >= segment.start - 0.01 && e <= segment.end + 0.01
        }
        guard !inRange.isEmpty else {
            return [Window(text: segment.text, start: segment.start, end: segment.end)]
        }

        var out: [Window] = []
        var texts: [String] = []
        var start = inRange.first?.start ?? segment.start
        var end = start
        for word in inRange {
            guard let ws = word.start, let we = word.end else { continue }
            if !texts.isEmpty, we - start > targetDuration {
                out.append(Window(text: texts.joined(separator: " "), start: start, end: end))
                texts = []
                start = ws
            }
            texts.append(word.text)
            end = we
        }
        if !texts.isEmpty {
            out.append(Window(text: texts.joined(separator: " "), start: start, end: end))
        }
        return out
    }
}
