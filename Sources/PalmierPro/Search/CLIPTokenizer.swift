import Foundation

/// Byte-level BPE tokenizer matching OpenAI CLIP's `simple_tokenizer` (used by MobileCLIP).
/// Built from `vocab.json` + `merges.txt` downloaded alongside the CoreML models.
final class CLIPTokenizer: @unchecked Sendable {
    static let contextLength = 77

    private let vocab: [String: Int32]
    private let mergeRanks: [Pair: Int]
    private let startToken: Int32
    private let endToken: Int32
    private let byteEncoder: [UInt8: Character]
    private let pattern: NSRegularExpression

    private struct Pair: Hashable {
        let a: String
        let b: String
    }

    init(vocabURL: URL, mergesURL: URL) throws {
        let vocabData = try Data(contentsOf: vocabURL)
        let raw = try JSONDecoder().decode([String: Int32].self, from: vocabData)
        vocab = raw

        var ranks: [Pair: Int] = [:]
        let mergesText = try String(contentsOf: mergesURL, encoding: .utf8)
        // First line is a version header.
        for (i, line) in mergesText.split(separator: "\n").dropFirst().enumerated() {
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            ranks[Pair(a: String(parts[0]), b: String(parts[1]))] = i
        }
        mergeRanks = ranks

        guard let sot = raw["<|startoftext|>"], let eot = raw["<|endoftext|>"] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        startToken = sot
        endToken = eot
        byteEncoder = Self.bytesToUnicode()
        pattern = try NSRegularExpression(
            pattern: #"'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+"#,
            options: [.caseInsensitive]
        )
    }

    /// Encode into a fixed-length token id array: [SOT] + tokens + [EOT], zero-padded.
    func encode(_ text: String) -> [Int32] {
        let cleaned = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()

        var ids: [Int32] = [startToken]
        let ns = cleaned as NSString
        let matches = pattern.matches(in: cleaned, range: NSRange(location: 0, length: ns.length))
        outer: for match in matches {
            let token = ns.substring(with: match.range)
            let encoded = String(token.utf8.map { byteEncoder[$0]! })
            for piece in bpe(encoded) {
                guard let id = vocab[piece] else { continue }
                ids.append(id)
                if ids.count >= Self.contextLength - 1 { break outer }
            }
        }
        ids.append(endToken)
        while ids.count < Self.contextLength { ids.append(0) }
        return ids
    }

    private func bpe(_ token: String) -> [String] {
        guard !token.isEmpty else { return [] }
        var word = token.map(String.init)
        word[word.count - 1] += "</w>"
        guard word.count > 1 else { return word }

        while true {
            var best: (pair: Pair, rank: Int)?
            for i in 0..<(word.count - 1) {
                let pair = Pair(a: word[i], b: word[i + 1])
                if let rank = mergeRanks[pair], rank < (best?.rank ?? Int.max) {
                    best = (pair, rank)
                }
            }
            guard let (pair, _) = best else { break }

            var merged: [String] = []
            var i = 0
            while i < word.count {
                if i < word.count - 1, word[i] == pair.a, word[i + 1] == pair.b {
                    merged.append(pair.a + pair.b)
                    i += 2
                } else {
                    merged.append(word[i])
                    i += 1
                }
            }
            word = merged
            if word.count == 1 { break }
        }
        return word
    }

    /// GPT-2 style printable byte → unicode char mapping.
    private static func bytesToUnicode() -> [UInt8: Character] {
        var bs: [Int] = Array(33...126) + Array(161...172) + Array(174...255)
        var cs = bs
        var n = 0
        for b in 0..<256 where !bs.contains(b) {
            bs.append(b)
            cs.append(256 + n)
            n += 1
        }
        var mapping: [UInt8: Character] = [:]
        for (b, c) in zip(bs, cs) {
            mapping[UInt8(b)] = Character(UnicodeScalar(c)!)
        }
        return mapping
    }
}
