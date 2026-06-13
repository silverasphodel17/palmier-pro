import Foundation

/// Spoken search: exact keyword matches rank first, semantic segment matches fill below.
/// Semantic matching runs per model family — the query is embedded once per family
/// present in the library and ranked only against that family's indexes.
enum SpokenSearch {
    static func search(
        query: String, assets: [(id: String, url: URL)], limit: Int = 20
    ) async -> [TranscriptSearch.Hit] {
        let keyword = TranscriptSearch.search(query: query, assets: assets, limit: limit)
        guard keyword.count < limit, SpokenModel.anyAvailable else { return keyword }

        var byFamily: [SpokenModel: [(String, EmbeddingStore.AssetIndex)]] = [:]
        var transcripts: [String: TranscriptionResult] = [:]
        for (id, url) in assets {
            guard let key = EmbeddingStore.key(for: url),
                  let index = try? EmbeddingStore.load(key: SpokenIndexer.spokenKey(key)),
                  index.header.count > 0,
                  let family = SpokenModel(rawValue: index.header.model) else { continue }
            byFamily[family, default: []].append((id, index))
            transcripts[id] = TranscriptCache.cachedOnDisk(for: url)
        }
        guard !byFamily.isEmpty else { return keyword }

        var semantic: [VisualSearch.Hit] = []
        for (family, indexes) in byFamily {
            guard let queryVector = await SentenceEmbedder.shared.vector(for: query, family: family) else { continue }
            semantic += VisualSearch.search(query: queryVector, indexes: indexes, limit: limit)
        }
        semantic.sort { $0.score > $1.score }
        return merge(keyword: keyword, semantic: semantic, transcripts: transcripts, limit: limit)
    }

    /// Appends semantic hits below the keyword tier, skipping segments keyword already found.
    static func merge(
        keyword: [TranscriptSearch.Hit],
        semantic: [VisualSearch.Hit],
        transcripts: [String: TranscriptionResult],
        limit: Int
    ) -> [TranscriptSearch.Hit] {
        var seen = Set(keyword.map { "\($0.assetID)@\($0.start)" })
        var hits = keyword
        for s in semantic {
            guard hits.count < limit else { break }
            let dedupeKey = "\(s.assetID)@\(s.shotStart)"
            guard !seen.contains(dedupeKey),
                  let text = windowText(transcripts[s.assetID], start: s.shotStart, end: s.shotEnd)
            else { continue }
            seen.insert(dedupeKey)
            hits.append(TranscriptSearch.Hit(assetID: s.assetID, start: s.shotStart, end: s.shotEnd, text: text))
        }
        return hits
    }

    /// Reconstructs a window's text by joining the transcript segments it spans.
    static func windowText(_ transcript: TranscriptionResult?, start: Double, end: Double) -> String? {
        guard let transcript else { return nil }
        let parts = transcript.segments
            .filter { $0.end > start && $0.start < end }
            .sorted { $0.start < $1.start }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
