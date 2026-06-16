import Foundation

extension ToolExecutor {

    /// Replace the effect stack on one or more clips (set_keyframes-style semantics).
    func setEffects(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["clipIds", "effects"], path: "set_effects")
        let clipIds = args.stringArray("clipIds")
        guard !clipIds.isEmpty else {
            throw ToolError("Missing required field 'clipIds' (must be a non-empty array of clip IDs)")
        }
        guard let rows = args["effects"] as? [Any] else {
            throw ToolError("Missing required field 'effects' (must be an array; empty clears the stack)")
        }

        for id in clipIds {
            guard let loc = editor.findClip(id: id) else { throw ToolError("Clip not found: \(id)") }
            let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
            guard clip.mediaType != .text, clip.mediaType != .audio else {
                throw ToolError("Clip \(id) is \(clip.mediaType.rawValue) — effects apply to video/image clips only")
            }
        }

        let effects = try rows.enumerated().map { index, raw in
            try Self.parseEffect(raw, path: "effects[\(index)]")
        }

        try withUndoGroup(editor, actionName: "Set Effects (Agent)") {
            for id in clipIds {
                editor.commitClipProperty(clipId: id) {
                    $0.effects = effects.isEmpty ? nil : effects
                }
            }
        }

        let summary = effects.isEmpty
            ? "cleared effects"
            : "set \(effects.count) effect(s): \(effects.map(\.type).joined(separator: ", "))"
        return .ok("\(summary) on \(clipIds.count) clip(s)")
    }

    private static func parseEffect(_ raw: Any, path: String) throws -> Effect {
        guard let dict = raw as? [String: Any] else {
            throw ToolError("\(path): expected an object {type, enabled?, params?}")
        }
        try validateUnknownKeys(dict, allowed: ["type", "enabled", "params"], path: path)
        let type = try dict.requireString("type")
        guard let descriptor = EffectRegistry.descriptor(id: type) else {
            let available = EffectRegistry.all.map(\.id).joined(separator: ", ")
            throw ToolError("\(path): unknown effect type '\(type)'. Available: \(available)")
        }

        var effect = descriptor.makeEffect()
        effect.enabled = dict.bool("enabled") ?? true

        if let params = dict["params"] as? [String: Any] {
            for (key, value) in params {
                if key == descriptor.resourceKey {
                    guard let path_ = value as? String else {
                        throw ToolError("\(path).params.\(key): expected a file path string")
                    }
                    guard FileManager.default.fileExists(atPath: path_) else {
                        throw ToolError("\(path).params.\(key): file not found: \(path_)")
                    }
                    effect.params[key] = EffectParam(string: path_)
                    continue
                }
                guard let spec = descriptor.params.first(where: { $0.key == key }) else {
                    let valid = (descriptor.params.map(\.key) + [descriptor.resourceKey].compactMap(\.self))
                        .joined(separator: ", ")
                    throw ToolError("\(path).params: unknown param '\(key)' for \(type). Valid: \(valid)")
                }
                guard let number = (value as? NSNumber)?.doubleValue, number.isFinite else {
                    throw ToolError("\(path).params.\(key): expected a finite number")
                }
                let clamped = min(spec.range.upperBound, max(spec.range.lowerBound, number))
                effect.params[key] = EffectParam(value: clamped)
            }
        }
        return effect
    }
}
