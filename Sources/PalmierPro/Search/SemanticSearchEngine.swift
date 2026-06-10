import Accelerate
import Foundation

struct SearchHit: Identifiable, Sendable {
    enum Kind: String, Sendable {
        case spoken, visual
    }

    let assetId: String
    let kind: Kind
    /// Source-media seconds.
    let start: Double
    let end: Double
    let score: Double
    let snippet: String?

    var id: String { "\(assetId)-\(kind.rawValue)-\(start)" }
    var midpoint: Double { (start + end) / 2 }
}

struct SearchResults: Sendable {
    var spoken: [SearchHit] = []
    var visual: [SearchHit] = []

    var isEmpty: Bool { spoken.isEmpty && visual.isEmpty }
    var count: Int { spoken.count + visual.count }

    func flattened(limit: Int = SemanticSearchEngine.maxResults) -> [SearchHit] {
        var out: [SearchHit] = []
        for hit in visual + spoken {
            guard out.count < limit else { break }
            out.append(hit)
        }
        return out
    }
}

/// Query-time search: visual (CLIP) and spoken (transcript, lexical + semantic).
enum SemanticSearchEngine {
    static let visualFloor: Float = 0.18
    static let visualRelativeWindow = 0.04
    static let spokenSemanticFloor: Float = 0.78
    /// Semantic-only hits must come this close to the best semantic score.
    static let spokenSemanticRelativeWindow: Float = 0.04
    /// Short interjections ("Really?", "Thank you.") embed close to everything.
    static let spokenSemanticMinWords = 3
    static let coalesceGap: Double = 1.0
    static let maxResults = 30
    static let perModalityCandidates = 40
    private static let phraseBonus = 0.3

    nonisolated static func search(
        query: String,
        indexes: [String: AssetSearchIndex],
        clip: CLIPRuntime?,
        spoken: SpokenEmbedder?
    ) async -> SearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !indexes.isEmpty else { return SearchResults() }

        let queryTokens = tokens(trimmed)
        let queryWords = contentWords(trimmed)
        let clipVector = clip?.embedText(trimmed)
        let spokenVector = spoken?.embed(trimmed)

        struct SpokenCandidate {
            let hit: SearchHit
            let semantic: Float
            let semanticOnly: Bool
        }
        var spokenCandidates: [SpokenCandidate] = []
        var visualHits: [SearchHit] = []

        for (assetId, index) in indexes {
            if let clipVector {
                let matches = index.visual
                    .map { (segment: $0, score: MediaIndexer.dot($0.vector, clipVector)) }
                    .filter { $0.score >= visualFloor }
                visualHits.append(contentsOf: coalesce(matches, assetId: assetId))
            }
            for segment in index.spoken {
                // Older indexes may still hold punctuation-only windows.
                guard let text = segment.text,
                      text.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
                let semantic = spokenVector.map { MediaIndexer.dot(segment.vector, $0) } ?? 0
                let lexical = lexicalOverlap(queryWords: queryWords, text: text)
                let phrase = containsPhrase(queryTokens: queryTokens, in: text)
                let semanticOnly = !phrase && lexical == 0
                if semanticOnly {
                    guard semantic >= spokenSemanticFloor,
                          contentWords(text).count >= spokenSemanticMinWords else { continue }
                }
                var score = Double(semantic) * 0.5 + lexical * 0.5
                if phrase { score += phraseBonus }
                spokenCandidates.append(SpokenCandidate(
                    hit: SearchHit(
                        assetId: assetId, kind: .spoken,
                        start: segment.start, end: segment.end,
                        score: score, snippet: text
                    ),
                    semantic: semantic, semanticOnly: semanticOnly
                ))
            }
        }

        // Semantic-only hits ride a relative window off the best semantic score,
        // so generic windows can't fill the list when real matches exist.
        let topSemantic = spokenCandidates.map(\.semantic).max() ?? 0
        var spokenHits = spokenCandidates
            .filter { !$0.semanticOnly || $0.semantic >= topSemantic - spokenSemanticRelativeWindow }
            .map(\.hit)

        spokenHits.sort { $0.score > $1.score }
        visualHits.sort { $0.score > $1.score }
        if let top = visualHits.first?.score {
            visualHits = visualHits.filter { $0.score >= top - visualRelativeWindow }
        }

        return SearchResults(
            spoken: Array(spokenHits.prefix(perModalityCandidates)),
            visual: Array(visualHits.prefix(perModalityCandidates))
        )
    }

    // MARK: - Lexical matching

    nonisolated static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "of", "in", "on", "at", "to", "is", "are",
        "was", "were", "be", "been", "it", "its", "this", "that", "with", "for",
        "as", "by", "from", "but", "not", "no", "so", "we", "you", "he", "she",
        "they", "them", "his", "her", "their", "our", "your", "my", "me", "us",
        "do", "does", "did", "have", "has", "had", "will", "would", "can",
        "could", "should", "there", "here", "what", "when", "where", "who",
        "how", "up", "down", "out", "about", "into", "over", "under", "just",
        "very", "really", "some", "any", "all",
    ]

    nonisolated static func contentWords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !stopwords.contains($0) }
    }

    nonisolated static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Whole-word phrase match: the query's token sequence must appear
    /// contiguously in the text's tokens ("cat" never matches "location").
    nonisolated static func containsPhrase(queryTokens: [String], in text: String) -> Bool {
        guard !queryTokens.isEmpty else { return false }
        let textTokens = tokens(text)
        guard textTokens.count >= queryTokens.count else { return false }
        for i in 0...(textTokens.count - queryTokens.count)
        where Array(textTokens[i..<(i + queryTokens.count)]) == queryTokens {
            return true
        }
        return false
    }

    nonisolated static func lexicalOverlap(queryWords: [String], text: String) -> Double {
        guard !queryWords.isEmpty else { return 0 }
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        var matched = 0
        for query in queryWords where words.contains(where: { sharesStem($0, query) }) {
            matched += 1
        }
        return Double(matched) / Double(queryWords.count)
    }

    nonisolated static func sharesStem(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard min(a.count, b.count) >= 3 else { return false }
        return a.hasPrefix(b) || b.hasPrefix(a)
    }

    /// Merge scoring segments whose time ranges touch (gap <= coalesceGap) into one hit.
    nonisolated static func coalesce(
        _ matches: [(segment: SearchSegment, score: Float)],
        assetId: String
    ) -> [SearchHit] {
        guard !matches.isEmpty else { return [] }
        let sorted = matches.sorted { $0.segment.start < $1.segment.start }
        var hits: [SearchHit] = []
        var start = sorted[0].segment.start
        var end = sorted[0].segment.end
        var best = sorted[0].score

        func flush() {
            hits.append(SearchHit(
                assetId: assetId, kind: .visual,
                start: start, end: end, score: Double(best), snippet: nil
            ))
        }

        for match in sorted.dropFirst() {
            if match.segment.start - end <= coalesceGap {
                end = max(end, match.segment.end)
                best = max(best, match.score)
            } else {
                flush()
                start = match.segment.start
                end = match.segment.end
                best = match.score
            }
        }
        flush()
        return hits
    }
}
