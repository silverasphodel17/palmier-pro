import Foundation

/// Owns the model lifecycle and the per-project indexing queue
@MainActor
@Observable
final class SearchIndexCoordinator {
    enum ModelState: Equatable {
        case unknown
        case notInstalled
        case downloading(Double)
        case preparing
        case ready
        case failed(String)
    }

    private(set) var modelState: ModelState = .unknown
    private(set) var batchTotal = 0
    private(set) var batchCompleted = 0
    private(set) var currentAssetFraction: Double = 0
    /// Observable mirror of SearchIndexConfig.enabled so UI reacts to the Settings toggle.
    private(set) var enabled = SearchIndexConfig.enabled

    var indexingActive: Bool { batchCompleted < batchTotal }
    var indexingProgress: Double {
        guard batchTotal > 0 else { return 0 }
        return min(1, (Double(batchCompleted) + min(max(currentAssetFraction, 0), 1)) / Double(batchTotal))
    }

    var assetsProvider: () -> [MediaAsset] = { [] }

    @ObservationIgnored private(set) var model: VisualEmbedder?
    private let downloader = ModelDownloader()
    private var queue: [String] = []
    private var failedIds: Set<String> = []
    private var worker: Task<Void, Never>?
    /// Bumped whenever `worker` is replaced or cancelled, so a stale worker's
    /// exit path can't clobber the reference to a newer one.
    private var workerGeneration = 0
    private var loadedIndexes: [String: (key: String, index: EmbeddingStore.AssetIndex)] = [:]

    private static let registry = NSHashTable<SearchIndexCoordinator>.weakObjects()
    private static var live: [SearchIndexCoordinator] { registry.allObjects }

    init() {
        Self.registry.add(self)
    }

    // MARK: - Export pause (refcounted across windows)

    /// Counts in-flight exports across all windows; indexing pauses while any run.
    struct ExportPauseCounter {
        private(set) var count = 0
        var isActive: Bool { count > 0 }
        mutating func begin() { count += 1 }
        mutating func end() { count = max(0, count - 1) }
    }

    private static var exportPause = ExportPauseCounter()
    static var exportActive: Bool { exportPause.isActive }
    static func exportDidBegin() { exportPause.begin() }
    static func exportDidEnd() { exportPause.end() }

    static func waitWhileExportActive() async throws {
        while exportActive {
            try await Task.sleep(for: .seconds(2))
        }
    }

    // MARK: - Model lifecycle

    /// Loads an installed model if present. Never starts a download.
    func prepare() async {
        guard modelState == .unknown else { return }
        guard let installed = ModelDownloader.installed(for: SearchIndexConfig.manifest) else {
            modelState = .notInstalled
            return
        }
        modelState = .preparing
        await loadModel(installed)
    }

    func downloadModel() {
        switch modelState {
        case .downloading, .preparing, .ready: return
        default: break
        }
        modelState = .downloading(0)
        Task {
            do {
                let installed = try await downloader.install(
                    manifest: SearchIndexConfig.manifest,
                    baseURL: SearchIndexConfig.baseURL
                ) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.modelState else { return }
                        self.modelState = .downloading(fraction)
                    }
                }
                guard enabled else {
                    modelState = .unknown
                    return
                }
                modelState = .preparing
                await loadModel(installed)
                sweep()
            } catch {
                modelState = .failed(error.localizedDescription)
                Log.search.error("model download failed: \(error.localizedDescription)")
            }
        }
    }

    private func loadModel(_ installed: ModelDownloader.InstalledModel) async {
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                let tokenizer = try await TextTokenizer(
                    tokenizerFolder: installed.tokenizerFolder,
                    contextLength: installed.spec.contextLength
                )
                let model = try VisualEmbedder(
                    imageEncoderURL: installed.imageEncoderURL,
                    textEncoderURL: installed.textEncoderURL,
                    tokenizer: tokenizer,
                    spec: installed.spec
                )
                _ = try model.encode(text: "warm up")
                return model
            }.value
            model = loaded
            modelState = .ready
            Log.search.notice("search model ready dim=\(loaded.spec.embeddingDim)")
        } catch {
            modelState = .failed(error.localizedDescription)
            Log.search.error("search model load failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Global operations (Settings has no editor; these reach every live instance)

    static func clearIndexGlobally() async {
        for coordinator in live {
            await coordinator.cancelIndexing()
            coordinator.loadedIndexes.removeAll()
            coordinator.failedIds.removeAll()
        }
        EmbeddingStore.clearAll()
        for coordinator in live { coordinator.sweep() }
    }

    static func removeModelGlobally() async {
        for coordinator in live {
            await coordinator.cancelIndexing()
            coordinator.model = nil
            coordinator.loadedIndexes.removeAll()
            coordinator.modelState = .notInstalled
        }
        try? FileManager.default.removeItem(at: ModelDownloader.modelsDir)
    }

    static func setEnabled(_ value: Bool) {
        SearchIndexConfig.enabled = value
        for coordinator in live {
            coordinator.enabled = value
            if value {
                Task {
                    await coordinator.prepare()
                    coordinator.sweep()
                }
            } else {
                Task { await coordinator.unload() }
            }
        }
    }

    /// Disable: stop indexing and release the model's weights from memory
    private func unload() async {
        await cancelIndexing()
        model = nil
        loadedIndexes.removeAll()
        if modelState == .ready || modelState == .preparing {
            modelState = .unknown
        }
    }

    /// Stops the worker and waits for the in-flight asset to actually stop.
    private func cancelIndexing() async {
        let current = worker
        workerGeneration += 1
        worker = nil
        queue.removeAll()
        resetBatch()
        current?.cancel()
        await current?.value
    }

    // MARK: - Triggers

    func projectOpened() {
        guard enabled else { return }
        Task {
            await prepare()
            sweep()
        }
    }

    /// Enqueue all current assets that need (re)indexing.
    /// Failed assets get a fresh chance; failedIds only dedupes within a batch.
    func sweep() {
        guard enabled, modelState == .ready else { return }
        failedIds.removeAll()
        for asset in assetsProvider() {
            schedule(asset)
        }
    }

    func schedule(_ asset: MediaAsset) {
        guard enabled, let model, !asset.isGenerating else { return }
        guard !queue.contains(asset.id), !failedIds.contains(asset.id) else { return }
        let needsVisual = (asset.type == .video || asset.type == .image)
            && VisualIndexer.needsIndex(url: asset.url, spec: model.spec)
        let needsSpoken = Self.wantsTranscript(asset) && SpokenIndexer.needsIndex(url: asset.url)
        guard needsVisual || needsSpoken || needsTranscript(asset) else { return }
        queue.append(asset.id)
        batchTotal += 1
        ensureWorker()
    }

    static func wantsTranscript(_ asset: MediaAsset) -> Bool {
        asset.type == .audio || (asset.type == .video && asset.hasAudio)
    }

    private func needsTranscript(_ asset: MediaAsset) -> Bool {
        Self.wantsTranscript(asset) && !TranscriptCache.hasCachedOnDisk(for: asset.url)
    }

    // MARK: - Worker

    private func ensureWorker() {
        guard worker == nil else { return }
        workerGeneration += 1
        let generation = workerGeneration
        worker = Task(priority: .utility) { [weak self] in
            while let self, !Task.isCancelled, let asset = self.dequeue() {
                while Self.exportActive, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                }
                self.currentAssetFraction = 0
                await self.indexOne(asset)
            }
            if let self, self.workerGeneration == generation {
                self.worker = nil
            }
        }
    }

    private func dequeue() -> MediaAsset? {
        while !queue.isEmpty {
            let id = queue.removeFirst()
            if let asset = assetsProvider().first(where: { $0.id == id }) { return asset }
            batchCompleted += 1
        }
        resetBatch()
        return nil
    }

    private func resetBatch() {
        batchTotal = 0
        batchCompleted = 0
        currentAssetFraction = 0
    }

    private func indexOne(_ asset: MediaAsset) async {
        defer { batchCompleted += 1 }
        guard let model else { return }
        let transcribe = needsTranscript(asset)
        let visualShare = transcribe ? 0.5 : 1.0
        let onProgress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor [weak self] in self?.currentAssetFraction = fraction * visualShare }
        }
        let url = asset.url
        let isVideo = asset.type == .video
        let start = ContinuousClock.now
        do {
            async let transcriptDone: Void = {
                if transcribe {
                    try await SearchIndexCoordinator.waitWhileExportActive()
                    _ = try await TranscriptCache.shared.transcript(for: url, isVideo: isVideo, range: nil)
                }
                try await SpokenIndexer.index(url: url)
            }()
            switch asset.type {
            case .image:
                try await VisualIndexer.indexImage(url: url, model: model)
            case .video:
                try await VisualIndexer.index(
                    url: url, duration: asset.duration, model: model, progress: onProgress
                )
            default:
                break
            }
            loadedIndexes[asset.id] = nil
            let visualSeconds = start.duration(to: .now).seconds
            currentAssetFraction = visualShare
            try await transcriptDone
            let totalSeconds = start.duration(to: .now).seconds
            Log.search.notice("""
                indexed \(asset.id.prefix(8)) visual=\(String(format: "%.1f", visualSeconds))s \
                total=\(String(format: "%.1f", totalSeconds))s transcribed=\(transcribe)
                """)
        } catch is CancellationError {
        } catch {
            failedIds.insert(asset.id)
            Log.search.warning("index failed asset=\(asset.id.prefix(8)): \(error.localizedDescription)")
        }
    }

    // MARK: - Query

    func search(query: String, limit: Int = 20, within ids: Set<String>? = nil) async -> [VisualSearch.Hit] {
        guard let model, modelState == .ready else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Snapshot on main; stat/SHA256/file reads, encode, and ranking happen off-actor.
        let candidates = assetsProvider()
            .filter { ($0.type == .video || $0.type == .image) && (ids?.contains($0.id) ?? true) }
            .map { ($0.id, $0.url) }
        let cached = loadedIndexes

        let (hits, loaded) = await Task.detached(priority: .userInitiated) {
            var indexes: [(String, EmbeddingStore.AssetIndex)] = []
            var loaded: [String: (key: String, index: EmbeddingStore.AssetIndex)] = [:]
            for (assetID, url) in candidates {
                guard let key = EmbeddingStore.key(for: url) else { continue }
                if let hit = cached[assetID], hit.key == key {
                    indexes.append((assetID, hit.index))
                } else if let index = try? EmbeddingStore.load(key: key) {
                    loaded[assetID] = (key, index)
                    indexes.append((assetID, index))
                }
            }
            guard !indexes.isEmpty, let vector = try? model.encode(text: trimmed) else {
                return ([VisualSearch.Hit](), loaded)
            }
            return (VisualSearch.search(query: vector, indexes: indexes, limit: limit), loaded)
        }.value

        loadedIndexes.merge(loaded) { _, new in new }
        return hits
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
