import Foundation

/// Per-asset analysis artifacts persisted inside the `.palmier` bundle's
/// `analysis/` directory: cached transcripts and search index files.
enum AnalysisStore {
    static func directory(projectURL: URL?) -> URL? {
        guard let projectURL else { return nil }
        return projectURL.appendingPathComponent(Project.analysisDirectoryName, isDirectory: true)
    }

    /// Identity of a media file's content: size + mtime. Mismatch invalidates cached analysis.
    static func contentKey(for fileURL: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int else { return nil }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)-\(Int(mtime))"
    }

    // MARK: - Transcript cache

    private struct StoredTranscript: Codable {
        let contentKey: String
        let result: TranscriptionResult
    }

    private static func transcriptURL(assetId: String, projectURL: URL?) -> URL? {
        directory(projectURL: projectURL)?.appendingPathComponent("\(assetId).transcript.json")
    }

    static func loadTranscript(assetId: String, contentKey: String, projectURL: URL?) -> TranscriptionResult? {
        guard let url = transcriptURL(assetId: assetId, projectURL: projectURL),
              let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(StoredTranscript.self, from: data),
              stored.contentKey == contentKey else { return nil }
        return stored.result
    }

    static func saveTranscript(_ result: TranscriptionResult, assetId: String, contentKey: String, projectURL: URL?) {
        guard let url = transcriptURL(assetId: assetId, projectURL: projectURL) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(StoredTranscript(contentKey: contentKey, result: result))
            try data.write(to: url, options: .atomic)
        } catch {
            Log.search.warning("transcript cache write failed asset=\(assetId.prefix(8)): \(error.localizedDescription)")
        }
    }

    /// Cached transcript when fresh, otherwise transcribe and cache.
    /// Only default-option transcriptions are cached (no profanity filter, auto locale).
    static func cachedOrTranscribe(
        fileURL: URL,
        type: ClipType,
        assetId: String,
        projectURL: URL?
    ) async throws -> TranscriptionResult {
        let key = contentKey(for: fileURL)
        if let key, let cached = loadTranscript(assetId: assetId, contentKey: key, projectURL: projectURL) {
            return cached
        }
        let result = type == .video
            ? try await Transcription.transcribeVideoAudio(videoURL: fileURL)
            : try await Transcription.transcribe(fileURL: fileURL)
        if let key {
            saveTranscript(result, assetId: assetId, contentKey: key, projectURL: projectURL)
        }
        return result
    }
}
