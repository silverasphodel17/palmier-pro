import Foundation

/// One entry in a clip's ordered effect stack. `type` names an EffectRegistry
/// descriptor; unknown types are preserved on save so newer projects survive
/// older builds.
struct Effect: Codable, Sendable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var type: String
    var enabled: Bool = true
    var params: [String: EffectParam] = [:]

    init(id: String = UUID().uuidString, type: String, enabled: Bool = true,
         params: [String: EffectParam] = [:]) {
        self.id = id
        self.type = type
        self.enabled = enabled
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, enabled, params
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString,
            type: try c.decode(String.self, forKey: .type),
            enabled: (try? c.decode(Bool.self, forKey: .enabled)) ?? true,
            params: (try? c.decode([String: EffectParam].self, forKey: .params)) ?? [:]
        )
    }
}

/// A single effect parameter. `track` is reserved for per-param keyframes (always
/// nil in V1); `resolved(at:)` already samples it so animation slots in without
/// engine changes.
struct EffectParam: Codable, Sendable, Equatable {
    var value: Double?
    /// Resource-style params (e.g. LUT relative path).
    var string: String?
    var track: KeyframeTrack<Double>?

    init(value: Double? = nil, string: String? = nil, track: KeyframeTrack<Double>? = nil) {
        self.value = value
        self.string = string
        self.track = track
    }

    /// Effective numeric value at a clip-relative frame offset.
    func resolved(at offset: Int, default defaultValue: Double) -> Double {
        if let track, track.isActive {
            return track.sample(at: offset, fallback: value ?? defaultValue)
        }
        return value ?? defaultValue
    }
}

extension Effect {
    /// Convenience for static numeric params.
    static func make(_ type: String, _ values: [String: Double] = [:]) -> Effect {
        Effect(type: type, params: values.mapValues { EffectParam(value: $0) })
    }
}

extension [Effect] {
    /// Mutable lookup by effect id; assigning nil removes the entry.
    subscript(safeId id: String) -> Effect? {
        get { first { $0.id == id } }
        set {
            guard let index = firstIndex(where: { $0.id == id }) else { return }
            if let newValue { self[index] = newValue } else { remove(at: index) }
        }
    }
}
