import Accelerate
import AppKit
import CoreML
import NaturalLanguage

/// On-device embedding models for semantic media search.
///
/// Visual: MobileCLIP-S2 (Apple, CoreML) — image and text encoders sharing one
/// embedding space. Downloaded to Application Support on first use (~198 MB).
/// Spoken: `NLContextualEmbedding` (built into macOS) for transcript windows.
@MainActor
@Observable
final class EmbeddingService {
    static let shared = EmbeddingService()

    enum VisualState: Equatable {
        case unknown
        case notInstalled
        case downloading(Double)
        case preparing
        case ready
        case failed(String)
    }

    private(set) var visualState: VisualState = .unknown
    private(set) var spokenReady = false

    var visualReady: Bool { visualState == .ready }

    @ObservationIgnored nonisolated(unsafe) private(set) var clip: CLIPRuntime?
    @ObservationIgnored nonisolated(unsafe) private(set) var spoken: SpokenEmbedder?

    private var prepareTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?

    private init() {}

    // MARK: - Preparation

    /// Loads whatever is already installed. Does not start the visual model download.
    func prepare() async {
        if let prepareTask {
            await prepareTask.value
            return
        }
        let task = Task { await doPrepare() }
        prepareTask = task
        await task.value
    }

    private func doPrepare() async {
        if spoken == nil {
            do {
                let embedder = try await SpokenEmbedder.make()
                spoken = embedder
                spokenReady = true
            } catch {
                Log.search.error("spoken embedder unavailable: \(error.localizedDescription)")
            }
        }
        if clip == nil, visualState == .unknown {
            if Self.installedModelsPresent() {
                visualState = .preparing
                await loadInstalledCLIP()
            } else if Self.obsoleteModelsPresent() {
                // User already opted into visual search on an older model;
                // upgrade in place instead of asking again.
                Self.removeObsoleteModels()
                visualState = .notInstalled
                downloadVisualModels()
            } else {
                visualState = .notInstalled
            }
        }
    }

    private func loadInstalledCLIP() async {
        do {
            let runtime = try await Task.detached(priority: .userInitiated) {
                try CLIPRuntime(directory: Self.modelDirectory)
            }.value
            clip = runtime
            visualState = .ready
            Log.search.notice("mobileclip ready dim=\(runtime.dimension)")
        } catch {
            visualState = .failed(error.localizedDescription)
            Log.search.error("mobileclip load failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Visual model download

    func downloadVisualModels() {
        guard downloadTask == nil else { return }
        switch visualState {
        case .ready, .downloading, .preparing: return
        default: break
        }
        visualState = .downloading(0)
        downloadTask = Task {
            do {
                try await Self.downloadAndCompile { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, case .downloading = self.visualState else { return }
                        self.visualState = .downloading(progress)
                    }
                }
                visualState = .preparing
                await loadInstalledCLIP()
            } catch {
                visualState = .failed(error.localizedDescription)
                Log.search.error("mobileclip download failed: \(error.localizedDescription)")
            }
            downloadTask = nil
        }
    }

    // MARK: - Storage layout

    nonisolated static let modelDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PalmierPro/models/mobileclip-s2", isDirectory: true)

    /// Superseded model directories, cleaned up on first prepare.
    private nonisolated static let obsoleteModelDirectories: [URL] = [
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PalmierPro/models/mobileclip-s0", isDirectory: true),
    ]

    nonisolated static func obsoleteModelsPresent() -> Bool {
        obsoleteModelDirectories.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    nonisolated static func removeObsoleteModels() {
        for dir in obsoleteModelDirectories {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private nonisolated static func installedModelsPresent() -> Bool {
        let fm = FileManager.default
        for name in ["image.mlmodelc", "text.mlmodelc", "vocab.json", "merges.txt"] {
            if !fm.fileExists(atPath: modelDirectory.appendingPathComponent(name).path) {
                return false
            }
        }
        return true
    }

    // MARK: - Download + compile

    private struct RemoteFile {
        let url: String
        let relativePath: String
        let bytes: Int
    }

    private nonisolated static let clipRepo = "https://huggingface.co/apple/coreml-mobileclip/resolve/main"
    private nonisolated static let tokenizerRepo = "https://huggingface.co/openai/clip-vit-base-patch32/resolve/main"

    private nonisolated static var remoteFiles: [RemoteFile] {
        func pkg(_ name: String, modelBytes: Int, weightBytes: Int) -> [RemoteFile] {
            [
                RemoteFile(url: "\(clipRepo)/\(name).mlpackage/Manifest.json", relativePath: "\(name).mlpackage/Manifest.json", bytes: 700),
                RemoteFile(url: "\(clipRepo)/\(name).mlpackage/Data/com.apple.CoreML/model.mlmodel", relativePath: "\(name).mlpackage/Data/com.apple.CoreML/model.mlmodel", bytes: modelBytes),
                RemoteFile(url: "\(clipRepo)/\(name).mlpackage/Data/com.apple.CoreML/weights/weight.bin", relativePath: "\(name).mlpackage/Data/com.apple.CoreML/weights/weight.bin", bytes: weightBytes),
            ]
        }
        return pkg("mobileclip_s2_image", modelBytes: 299_056, weightBytes: 71_397_632)
            + pkg("mobileclip_s2_text", modelBytes: 128_127, weightBytes: 126_866_880)
            + [
                RemoteFile(url: "\(tokenizerRepo)/vocab.json", relativePath: "vocab.json", bytes: 862_328),
                RemoteFile(url: "\(tokenizerRepo)/merges.txt", relativePath: "merges.txt", bytes: 524_657),
            ]
    }

    private nonisolated static func downloadAndCompile(progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        let staging = modelDirectory.appendingPathComponent("staging", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let files = remoteFiles
        let totalBytes = files.reduce(0) { $0 + $1.bytes }
        var doneBytes = 0
        for file in files {
            guard let url = URL(string: file.url) else { throw URLError(.badURL) }
            let (temp, response) = try await URLSession.shared.download(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let dest = staging.appendingPathComponent(file.relativePath)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: temp, to: dest)
            doneBytes += file.bytes
            progress(Double(doneBytes) / Double(totalBytes) * 0.9)
        }

        for (pkg, compiled) in [("mobileclip_s2_image", "image.mlmodelc"), ("mobileclip_s2_text", "text.mlmodelc")] {
            let compiledTemp = try await MLModel.compileModel(at: staging.appendingPathComponent("\(pkg).mlpackage"))
            let dest = modelDirectory.appendingPathComponent(compiled)
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: compiledTemp, to: dest)
        }
        for tok in ["vocab.json", "merges.txt"] {
            let dest = modelDirectory.appendingPathComponent(tok)
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: staging.appendingPathComponent(tok), to: dest)
        }
        try? fm.removeItem(at: staging)
        progress(1.0)
    }
}

// MARK: - CLIP runtime

/// Loaded MobileCLIP encoders. `MLModel.prediction` is thread-safe.
final class CLIPRuntime: @unchecked Sendable {
    private let imageModel: MLModel
    private let textModel: MLModel
    private let tokenizer: CLIPTokenizer
    private let imageInputName: String
    private let textInputName: String
    let imageSize: Int
    let dimension: Int

    init(directory: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        imageModel = try MLModel(contentsOf: directory.appendingPathComponent("image.mlmodelc"), configuration: config)
        textModel = try MLModel(contentsOf: directory.appendingPathComponent("text.mlmodelc"), configuration: config)
        tokenizer = try CLIPTokenizer(
            vocabURL: directory.appendingPathComponent("vocab.json"),
            mergesURL: directory.appendingPathComponent("merges.txt")
        )

        guard let imageInput = imageModel.modelDescription.inputDescriptionsByName.first(where: { $0.value.type == .image }),
              let constraint = imageInput.value.imageConstraint else {
            throw CocoaError(.coderInvalidValue)
        }
        imageInputName = imageInput.key
        imageSize = constraint.pixelsWide

        guard let textInput = textModel.modelDescription.inputDescriptionsByName.first(where: { $0.value.type == .multiArray }) else {
            throw CocoaError(.coderInvalidValue)
        }
        textInputName = textInput.key

        let zeroTokens = [Int32](repeating: 0, count: CLIPTokenizer.contextLength)
        let probe = try textModel.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            textInputName: MLFeatureValue(multiArray: Self.tokenArray(zeroTokens)),
        ]))
        guard let out = Self.firstMultiArray(probe) else { throw CocoaError(.coderInvalidValue) }
        dimension = out.count
    }

    func embedImage(_ cgImage: CGImage) -> [Float]? {
        guard let buffer = Self.pixelBuffer(from: cgImage, size: imageSize) else { return nil }
        guard let output = try? imageModel.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            imageInputName: MLFeatureValue(pixelBuffer: buffer),
        ])), let array = Self.firstMultiArray(output) else { return nil }
        return Self.normalized(Self.floats(array))
    }

    func embedText(_ text: String) -> [Float]? {
        let tokens = tokenizer.encode(text)
        guard let output = try? textModel.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            textInputName: MLFeatureValue(multiArray: Self.tokenArray(tokens)),
        ])), let array = Self.firstMultiArray(output) else { return nil }
        return Self.normalized(Self.floats(array))
    }

    private static func tokenArray(_ tokens: [Int32]) -> MLMultiArray {
        let array = try! MLMultiArray(shape: [1, NSNumber(value: tokens.count)], dataType: .int32)
        for (i, t) in tokens.enumerated() {
            array[i] = NSNumber(value: t)
        }
        return array
    }

    private static func firstMultiArray(_ provider: MLFeatureProvider) -> MLMultiArray? {
        for name in provider.featureNames {
            if let value = provider.featureValue(for: name)?.multiArrayValue { return value }
        }
        return nil
    }

    private static func floats(_ array: MLMultiArray) -> [Float] {
        (0..<array.count).map { array[$0].floatValue }
    }

    static func normalized(_ vector: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(vector, 1, &norm, vDSP_Length(vector.count))
        norm = sqrt(norm)
        guard norm > 0 else { return vector }
        var out = [Float](repeating: 0, count: vector.count)
        var divisor = norm
        vDSP_vsdiv(vector, 1, &divisor, &out, 1, vDSP_Length(vector.count))
        return out
    }

    private static func pixelBuffer(from cgImage: CGImage, size: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, size, size, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        return buffer
    }
}

// MARK: - Spoken (transcript) embedder

/// Mean-pooled `NLContextualEmbedding` sentence vectors.
final class SpokenEmbedder: @unchecked Sendable {
    private let embedding: NLContextualEmbedding
    private let lock = NSLock()
    let dimension: Int

    private init(embedding: NLContextualEmbedding) {
        self.embedding = embedding
        self.dimension = embedding.dimension
    }

    static func make() async throws -> SpokenEmbedder {
        guard let embedding = NLContextualEmbedding(language: .english) else {
            throw CocoaError(.featureUnsupported)
        }
        if !embedding.hasAvailableAssets {
            _ = try await embedding.requestAssets()
        }
        try embedding.load()
        return SpokenEmbedder(embedding: embedding)
    }

    func embed(_ text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let result = try? embedding.embeddingResult(for: trimmed, language: nil) else { return nil }
        var sum = [Double](repeating: 0, count: dimension)
        var count = 0
        result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { vector, _ in
            for i in 0..<min(vector.count, sum.count) {
                sum[i] += vector[i]
            }
            count += 1
            return true
        }
        guard count > 0 else { return nil }
        let mean = sum.map { Float($0 / Double(count)) }
        return CLIPRuntime.normalized(mean)
    }
}
