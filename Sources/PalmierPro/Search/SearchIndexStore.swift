import Foundation

/// A time-ranged embedding over a slice of a media asset's content.
struct SearchSegment: Sendable {
    var start: Double
    var end: Double
    /// Transcript text for spoken segments; nil for visual segments.
    var text: String?
    /// L2-normalized embedding.
    var vector: [Float]
}

/// In-memory search index for one media asset.
struct AssetSearchIndex: Sendable {
    /// v3: tighter visual/spoken segment windows (v2 was MobileCLIP-S2).
    static let version = 3

    var contentKey: String
    var visual: [SearchSegment] = []
    var spoken: [SearchSegment] = []
    var visualIndexed = false
    var spokenIndexed = false

    func isCurrent(for key: String) -> Bool { contentKey == key }
}

/// Disk codec for `AssetSearchIndex`: binary plist with Float16-packed vectors,
/// stored at `analysis/<assetId>.bin` inside the `.palmier` bundle.
enum SearchIndexStore {
    private struct StoredSegment: Codable {
        var start: Double
        var end: Double
        var text: String?
        var vector: Data
    }

    private struct StoredIndex: Codable {
        var version: Int
        var contentKey: String
        var visual: [StoredSegment]
        var spoken: [StoredSegment]
        var visualIndexed: Bool
        var spokenIndexed: Bool
    }

    static func fileURL(assetId: String, projectURL: URL?) -> URL? {
        AnalysisStore.directory(projectURL: projectURL)?.appendingPathComponent("\(assetId).bin")
    }

    static func load(assetId: String, projectURL: URL?) -> AssetSearchIndex? {
        guard let url = fileURL(assetId: assetId, projectURL: projectURL),
              let data = try? Data(contentsOf: url),
              let stored = try? PropertyListDecoder().decode(StoredIndex.self, from: data),
              stored.version == AssetSearchIndex.version else { return nil }
        var index = AssetSearchIndex(contentKey: stored.contentKey)
        index.visual = stored.visual.map { SearchSegment(start: $0.start, end: $0.end, text: $0.text, vector: unpack($0.vector)) }
        index.spoken = stored.spoken.map { SearchSegment(start: $0.start, end: $0.end, text: $0.text, vector: unpack($0.vector)) }
        index.visualIndexed = stored.visualIndexed
        index.spokenIndexed = stored.spokenIndexed
        return index
    }

    static func save(_ index: AssetSearchIndex, assetId: String, projectURL: URL?) {
        guard let url = fileURL(assetId: assetId, projectURL: projectURL) else { return }
        let stored = StoredIndex(
            version: AssetSearchIndex.version,
            contentKey: index.contentKey,
            visual: index.visual.map { StoredSegment(start: $0.start, end: $0.end, text: $0.text, vector: pack($0.vector)) },
            spoken: index.spoken.map { StoredSegment(start: $0.start, end: $0.end, text: $0.text, vector: pack($0.vector)) },
            visualIndexed: index.visualIndexed,
            spokenIndexed: index.spokenIndexed
        )
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(stored).write(to: url, options: .atomic)
        } catch {
            Log.search.warning("index write failed asset=\(assetId.prefix(8)): \(error.localizedDescription)")
        }
    }

    static func pack(_ vector: [Float]) -> Data {
        let halves = vector.map { Float16($0) }
        return halves.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func unpack(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float16>.stride
        return data.withUnsafeBytes { raw in
            let halves = raw.bindMemory(to: Float16.self)
            return (0..<count).map { Float(halves[$0]) }
        }
    }
}
