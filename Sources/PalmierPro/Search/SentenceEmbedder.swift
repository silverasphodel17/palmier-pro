import Foundation
import NaturalLanguage


enum SpokenModel: String, CaseIterable, Sendable {
    case latin = "nlce-latin" // Latin-script languages (e.g., English, Spanish, French)
    case cjk = "nlce-cjk"     // Chinese, Japanese, Korean (CJK languages)

    var script: NLScript { self == .latin ? .latin : .simplifiedChinese }

    /// OS model revision (0 = no model on this platform); cached, hit per-asset when scheduling.
    private static let revisions: [SpokenModel: Int] = {
        var r: [SpokenModel: Int] = [:]
        for m in allCases { r[m] = NLContextualEmbedding(script: m.script)?.revision ?? 0 }
        return r
    }()
    var revision: Int { Self.revisions[self] ?? 0 }
    static var anyAvailable: Bool { allCases.contains { $0.revision > 0 } }

    static func family(forBCP47 tag: String?) -> SpokenModel? {
        guard let tag else { return nil }
        let code = (Locale(identifier: tag).language.languageCode?.identifier ?? String(tag.prefix(2))).lowercased()
        if ["zh", "ja", "ko", "yue", "wuu"].contains(code) { return cjk.revision > 0 ? .cjk : nil }
        if latin.revision > 0, let m = NLContextualEmbedding(script: .latin),
           m.languages.contains(NLLanguage(rawValue: code)) { return .latin }
        return nil
    }
}

actor SentenceEmbedder {
    static let shared = SentenceEmbedder()

    private var models: [SpokenModel: NLContextualEmbedding] = [:]
    private var unavailable: Set<SpokenModel> = []

    func dimension(_ family: SpokenModel) async -> Int? { await loaded(family)?.dimension }

    func vector(for text: String, family: SpokenModel) async -> [Float]? {
        guard let embedding = await loaded(family),
              let result = try? embedding.embeddingResult(for: text, language: nil) else { return nil }
        var sum = [Double](repeating: 0, count: embedding.dimension)
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            for (i, v) in vector.enumerated() { sum[i] += v }
            count += 1
            return true
        }
        // Normalizing the summed vectors yields the same unit vector as the mean would.
        guard count > 0 else { return nil }
        var norm = 0.0
        for v in sum { norm += v * v }
        guard norm > 0 else { return nil }
        let inv = 1 / norm.squareRoot()
        return sum.map { Float($0 * inv) }
    }

    private func loaded(_ family: SpokenModel) async -> NLContextualEmbedding? {
        if let m = models[family] { return m }
        if unavailable.contains(family) { return nil }
        guard family.revision > 0, let candidate = NLContextualEmbedding(script: family.script) else {
            unavailable.insert(family)
            return nil
        }
        do {
            // Assets pending: return nil without marking unavailable so a later sweep retries.
            if !candidate.hasAvailableAssets {
                guard try await candidate.requestAssets() == .available else { return nil }
            }
            try candidate.load()
            models[family] = candidate
            return candidate
        } catch {
            Log.search.warning("sentence embedding load failed (\(family.rawValue)): \(error.localizedDescription)")
            return nil
        }
    }
}
