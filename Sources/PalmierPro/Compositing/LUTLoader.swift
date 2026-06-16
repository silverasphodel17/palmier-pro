import Foundation

/// Parses .cube 3D LUT files into CIColorCube-ready RGBA float data.
/// Cached by path + mtime, like AlphaVideoNormalizer's tag scheme.
enum LUTLoader {

    struct CubeLUT {
        let dimension: Int
        let data: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (mtime: Date, lut: CubeLUT)] = [:]

    static func load(path: String) -> CubeLUT? {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
            .flatMap { $0 } ?? .distantPast

        lock.lock()
        if let entry = cache[path], entry.mtime == mtime {
            lock.unlock()
            return entry.lut
        }
        lock.unlock()

        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let lut = parse(text) else { return nil }

        lock.lock()
        cache[path] = (mtime, lut)
        lock.unlock()
        return lut
    }

    static func parse(_ text: String) -> CubeLUT? {
        var dimension = 0
        var domainMin: [Float] = [0, 0, 0]
        var domainMax: [Float] = [1, 1, 1]
        var values: [Float] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let first = parts.first else { continue }
            switch first.uppercased() {
            case "TITLE", "LUT_1D_SIZE":
                if first.uppercased() == "LUT_1D_SIZE" { return nil }
            case "LUT_3D_SIZE":
                dimension = Int(parts.last.map(String.init) ?? "") ?? 0
            case "DOMAIN_MIN":
                domainMin = parts.dropFirst().compactMap { Float($0) }
            case "DOMAIN_MAX":
                domainMax = parts.dropFirst().compactMap { Float($0) }
            default:
                guard parts.count >= 3 else { continue }
                let rgb = parts.prefix(3).compactMap { Float($0) }
                guard rgb.count == 3 else { return nil }
                values.append(contentsOf: rgb)
            }
        }

        guard dimension > 1, dimension <= 64,
              values.count == dimension * dimension * dimension * 3,
              domainMin.count == 3, domainMax.count == 3 else { return nil }

        // Normalize domain and pack as RGBA float32 (r fastest), as CIColorCube expects.
        var rgba = [Float]()
        rgba.reserveCapacity(dimension * dimension * dimension * 4)
        for i in 0..<(values.count / 3) {
            for c in 0..<3 {
                let span = max(0.0001, domainMax[c] - domainMin[c])
                rgba.append(min(1, max(0, (values[i * 3 + c] - domainMin[c]) / span)))
            }
            rgba.append(1)
        }
        return CubeLUT(dimension: dimension, data: rgba.withUnsafeBufferPointer { Data(buffer: $0) })
    }
}
