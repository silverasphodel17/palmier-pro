import Foundation

extension ToolExecutor {
    private static let searchMediaAllowedKeys: Set<String> = ["query", "maxResults"]
    private static let searchMediaDefaultResults = 15

    func searchMedia(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.searchMediaAllowedKeys, path: "search_media")
        let query = try args.requireString("query")
        let requested = args.int("maxResults") ?? Self.searchMediaDefaultResults
        let maxResults = max(1, min(requested, SemanticSearchEngine.maxResults))

        let indexer = editor.mediaIndexer
        await EmbeddingService.shared.prepare()
        indexer.indexAllPending()
        let searchResults = await indexer.search(query: query)

        let names = Dictionary(uniqueKeysWithValues: editor.mediaAssets.map { ($0.id, $0.name) })
        let results: [[String: Any]] = searchResults.flattened(limit: maxResults).map { hit in
            var row: [String: Any] = [
                "mediaRef": hit.assetId,
                "kind": hit.kind.rawValue,
                "startSeconds": hit.start.jsonRounded(toPlaces: 3),
                "endSeconds": hit.end.jsonRounded(toPlaces: 3),
                "score": hit.score.jsonRounded(toPlaces: 3),
            ]
            if let name = names[hit.assetId] { row["name"] = name }
            if let snippet = hit.snippet { row["text"] = snippet }
            return row
        }

        let visualSearch: String
        switch EmbeddingService.shared.visualState {
        case .ready: visualSearch = "ready"
        case .downloading, .preparing: visualSearch = "installing"
        case .failed: visualSearch = "failed"
        case .unknown, .notInstalled: visualSearch = "notInstalled"
        }

        let payload: [String: Any] = [
            "query": query,
            "results": results,
            "visualSearch": visualSearch,
            "pendingAssets": indexer.pendingCount,
        ]
        guard let json = Self.jsonString(payload) else {
            throw ToolError("Failed to encode search results")
        }
        return .ok(json)
    }
}
