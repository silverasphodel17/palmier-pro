import Foundation
import Testing
@testable import PalmierPro

@Suite("Drag payload — segment fragments")
struct SegmentDragPayloadTests {

    @Test func segmentStringRoundTrips() {
        let line = MediaTab.assetDragString(forAssetId: "asset-1", segmentStart: 12.5, segmentEnd: 18.25)
        #expect(MediaTab.assetId(fromDragString: line) == "asset-1")
        let segment = MediaTab.assetSegment(fromDragString: line)
        #expect(segment?.start == 12.5)
        #expect(segment?.end == 18.25)
    }

    @Test func plainAssetStringHasNoSegment() {
        let line = MediaTab.assetDragString(forAssetId: "asset-1")
        #expect(MediaTab.assetId(fromDragString: line) == "asset-1")
        #expect(MediaTab.assetSegment(fromDragString: line) == nil)
    }

    @Test func invalidSegmentsAreRejected() {
        // end <= start
        #expect(MediaTab.assetSegment(fromDragString: "palmier-asset://x#5.000-5.000") == nil)
        // garbage fragment
        #expect(MediaTab.assetSegment(fromDragString: "palmier-asset://x#nope") == nil)
        // id still parses despite a broken fragment
        #expect(MediaTab.assetId(fromDragString: "palmier-asset://x#nope") == "x")
    }

    @Test func folderStringsDoNotDecodeAsSegments() {
        let folderLine = MediaTab.folderDragString(forFolderId: "f1")
        #expect(MediaTab.assetSegment(fromDragString: folderLine) == nil)
    }
}

@Suite("SpokenWindowBuilder")
struct SpokenWindowBuilderTests {

    private func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptionWord {
        TranscriptionWord(text: text, start: start, end: end, type: "word", speakerId: nil)
    }

    @Test func shortSegmentsMergeIntoOneWindow() {
        let result = TranscriptionResult(
            text: "Hello there. How are you.",
            language: "en-US", languageProbability: nil, words: [],
            segments: [
                TranscriptionSegment(text: "Hello there.", start: 0, end: 2),
                TranscriptionSegment(text: "How are you.", start: 2.5, end: 4.5),
            ]
        )
        let windows = SpokenWindowBuilder.windows(from: result)
        #expect(windows.count == 1)
        #expect(windows[0].text == "Hello there. How are you.")
        #expect(windows[0].start == 0)
        #expect(windows[0].end == 4.5)
    }

    @Test func largeGapStartsNewWindow() {
        let result = TranscriptionResult(
            text: "", language: nil, languageProbability: nil, words: [],
            segments: [
                TranscriptionSegment(text: "First.", start: 0, end: 2),
                TranscriptionSegment(text: "Second.", start: 10, end: 12),
            ]
        )
        let windows = SpokenWindowBuilder.windows(from: result)
        #expect(windows.count == 2)
    }

    @Test func longSegmentSplitsOnWordBoundaries() {
        let words = (0..<30).map { i in
            word("w\(i)", Double(i), Double(i) + 0.9)
        }
        let result = TranscriptionResult(
            text: "", language: nil, languageProbability: nil, words: words,
            segments: [TranscriptionSegment(text: words.map(\.text).joined(separator: " "), start: 0, end: 29.9)]
        )
        let windows = SpokenWindowBuilder.windows(from: result)
        #expect(windows.count > 1)
        for window in windows {
            #expect(window.end - window.start <= SpokenWindowBuilder.maxDuration)
        }
        // No words lost across the split.
        let joined = windows.map(\.text).joined(separator: " ")
        #expect(joined.split(separator: " ").count == 30)
    }

    @Test func emptySegmentsAreDropped() {
        let result = TranscriptionResult(
            text: "", language: nil, languageProbability: nil, words: [],
            segments: [TranscriptionSegment(text: "   ", start: 0, end: 1)]
        )
        #expect(SpokenWindowBuilder.windows(from: result).isEmpty)
    }

    @Test func punctuationOnlySegmentsAreDropped() {
        let result = TranscriptionResult(
            text: "", language: nil, languageProbability: nil, words: [],
            segments: [
                TranscriptionSegment(text: ".", start: 0, end: 1),
                TranscriptionSegment(text: "…", start: 2, end: 3),
                TranscriptionSegment(text: "Real words.", start: 4, end: 6),
            ]
        )
        let windows = SpokenWindowBuilder.windows(from: result)
        #expect(windows.count == 1)
        #expect(windows[0].text == "Real words.")
    }
}

@Suite("SearchIndexStore — vector packing")
struct VectorPackingTests {

    @Test func packUnpackRoundTripsWithinFloat16Precision() {
        let vector: [Float] = [0.125, -0.5, 0.999, 0.0, -0.0625]
        let unpacked = SearchIndexStore.unpack(SearchIndexStore.pack(vector))
        #expect(unpacked.count == vector.count)
        for (a, b) in zip(vector, unpacked) {
            #expect(abs(a - b) < 0.001)
        }
    }

    @Test func dotProductOfNormalizedVectors() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [0.6, 0.8, 0]
        #expect(abs(MediaIndexer.dot(a, b) - 0.6) < 0.0001)
        #expect(MediaIndexer.dot(a, []) == 0)
    }
}

@Suite("SemanticSearchEngine — coalescing")
struct SearchCoalescingTests {

    private func segment(_ start: Double, _ end: Double) -> SearchSegment {
        SearchSegment(start: start, end: end, text: nil, vector: [1, 0, 0])
    }

    @Test func adjacentVisualSegmentsMergeIntoOneHit() {
        let hits = SemanticSearchEngine.coalesce(
            [
                (segment(0, 2), Float(0.3)),
                (segment(3, 5), Float(0.5)),
                (segment(20, 22), Float(0.4)),
            ],
            assetId: "a"
        )
        #expect(hits.count == 2)
        #expect(hits[0].start == 0)
        #expect(hits[0].end == 5)
        #expect(abs(hits[0].score - 0.5) < 0.0001)
        #expect(hits[1].start == 20)
    }

    @Test func unsortedInputStillCoalesces() {
        let hits = SemanticSearchEngine.coalesce(
            [
                (segment(10, 12), Float(0.2)),
                (segment(0, 2), Float(0.3)),
                (segment(11, 14), Float(0.6)),
            ],
            assetId: "a"
        )
        #expect(hits.count == 2)
        #expect(hits[1].start == 10)
        #expect(hits[1].end == 14)
    }

    @Test func searchWithoutEmbeddersReturnsEmpty() async {
        var index = AssetSearchIndex(contentKey: "k")
        index.visual = [segment(0, 2)]
        index.visualIndexed = true
        let results = await SemanticSearchEngine.search(
            query: "anything", indexes: ["a": index],
            clip: nil, spoken: nil
        )
        #expect(results.isEmpty)
    }

    @Test func lexicalTranscriptMatchIsSpoken() async {
        var index = AssetSearchIndex(contentKey: "k")
        index.spoken = [
            SearchSegment(start: 4, end: 9, text: "The winds are picking up rapidly", vector: [1, 0, 0]),
            SearchSegment(start: 12, end: 18, text: "Planes were grounded at the airport", vector: [0, 1, 0]),
        ]
        index.spokenIndexed = true
        let results = await SemanticSearchEngine.search(
            query: "a plane flying", indexes: ["a": index],
            clip: nil, spoken: nil
        )
        #expect(results.spoken.count == 1)
        #expect(results.spoken[0].start == 12)
        #expect(results.spoken[0].kind == .spoken)
        #expect(results.spoken[0].snippet?.contains("Planes") == true)
        #expect(results.visual.isEmpty)
    }
}

@Suite("SemanticSearchEngine — lexical matching")
struct LexicalMatchingTests {

    @Test func contentWordsDropStopwordsAndShortTokens() {
        let words = SemanticSearchEngine.contentWords("a plane flying in the clouds")
        #expect(words == ["plane", "flying", "clouds"])
    }

    @Test func overlapIsPrefixTolerant() {
        let words = SemanticSearchEngine.contentWords("a plane flying")
        #expect(SemanticSearchEngine.lexicalOverlap(queryWords: words, text: "planes fly south") == 1.0)
        #expect(SemanticSearchEngine.lexicalOverlap(queryWords: words, text: "the winds are picking up") == 0)
        let half = SemanticSearchEngine.lexicalOverlap(queryWords: words, text: "the plane landed")
        #expect(abs(half - 0.5) < 0.0001)
    }

    @Test func stemSharingRequiresThreeChars() {
        #expect(SemanticSearchEngine.sharesStem("fly", "flying"))
        #expect(SemanticSearchEngine.sharesStem("plane", "planes"))
        #expect(!SemanticSearchEngine.sharesStem("up", "upset"))
        #expect(SemanticSearchEngine.sharesStem("rain", "rain"))
    }

    @Test func phraseMatchRespectsWordBoundaries() {
        let cat = SemanticSearchEngine.tokens("cat")
        #expect(!SemanticSearchEngine.containsPhrase(queryTokens: cat, in: "It's a great location."))
        #expect(SemanticSearchEngine.containsPhrase(queryTokens: cat, in: "The cat sat on the desk."))
        #expect(SemanticSearchEngine.containsPhrase(queryTokens: cat, in: "Cat! Over there."))
    }

    @Test func multiWordPhraseMustBeContiguous() {
        let q = SemanticSearchEngine.tokens("company update")
        #expect(SemanticSearchEngine.containsPhrase(queryTokens: q, in: "Quick company update for everyone."))
        #expect(!SemanticSearchEngine.containsPhrase(queryTokens: q, in: "The company posted an update."))
        #expect(!SemanticSearchEngine.containsPhrase(queryTokens: q, in: "company"))
    }
}
