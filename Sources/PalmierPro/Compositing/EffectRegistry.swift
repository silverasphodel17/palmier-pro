import CoreImage
import Foundation

struct EffectParamSpec: Sendable {
    let key: String
    let label: String
    let range: ClosedRange<Double>
    let defaultValue: Double
    /// Display unit ("EV", "%", "px"); empty for unitless.
    let unit: String
}

/// Numeric/string param values resolved for one frame, with descriptor defaults applied.
struct ResolvedEffectParams: Sendable {
    let values: [String: Double]
    let strings: [String: String]
    /// Clip-relative frame, for deterministic time-varying effects (grain).
    let frameOffset: Int

    func value(_ key: String) -> Double { values[key] ?? 0 }
    func string(_ key: String) -> String? { strings[key] }
}

/// Declarative effect definition: the catalog grows as data, not engine code.
struct EffectDescriptor: Identifiable, Sendable {
    let id: String
    let displayName: String
    let category: String
    let params: [EffectParamSpec]
    /// Wrap the chain in sRGB→linear / linear→sRGB tone curves. The render pipeline is
    /// color-management-off (gamma bytes) for stock-compositor parity; effects whose math
    /// is only meaningful in linear light (exposure) opt in.
    let linearizes: Bool
    /// True for effects carrying a file resource (LUT) — drives the inspector row.
    let resourceKey: String?
    let apply: @Sendable (CIImage, ResolvedEffectParams, CGRect) -> CIImage

    init(id: String, displayName: String, category: String,
         params: [EffectParamSpec], linearizes: Bool = false, resourceKey: String? = nil,
         apply: @escaping @Sendable (CIImage, ResolvedEffectParams, CGRect) -> CIImage) {
        self.id = id
        self.displayName = displayName
        self.category = category
        self.params = params
        self.linearizes = linearizes
        self.resourceKey = resourceKey
        self.apply = apply
    }

    /// Default Effect instance for "Add Effect".
    func makeEffect() -> Effect {
        Effect(type: id, params: params.reduce(into: [:]) {
            $0[$1.key] = EffectParam(value: $1.defaultValue)
        })
    }

    func resolve(_ effect: Effect, atOffset offset: Int) -> ResolvedEffectParams {
        var values: [String: Double] = [:]
        for spec in params {
            let raw = effect.params[spec.key]?.resolved(at: offset, default: spec.defaultValue)
                ?? spec.defaultValue
            values[spec.key] = min(spec.range.upperBound, max(spec.range.lowerBound, raw))
        }
        let strings = effect.params.compactMapValues(\.string)
        return ResolvedEffectParams(values: values, strings: strings, frameOffset: offset)
    }

    /// Full application incl. optional linear-light wrapping.
    func render(_ image: CIImage, effect: Effect, atOffset offset: Int) -> CIImage {
        let params = resolve(effect, atOffset: offset)
        let extent = image.extent
        var working = image
        if linearizes {
            working = working.applyingFilter("CISRGBToneCurveToLinear")
        }
        working = apply(working, params, extent)
        if linearizes {
            working = working.applyingFilter("CILinearToSRGBToneCurve")
        }
        return working
    }
}

enum EffectRegistry {

    static let all: [EffectDescriptor] = color + lut + blur + stylize

    private static let color: [EffectDescriptor] = [
        EffectDescriptor(
            id: "color.exposure", displayName: "Exposure", category: "Color",
            params: [EffectParamSpec(key: "ev", label: "Exposure", range: -3...3,
                                     defaultValue: 0, unit: "EV")],
            linearizes: true,
            apply: { image, p, _ in
                image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: p.value("ev")])
            }
        ),
        EffectDescriptor(
            id: "color.contrast", displayName: "Contrast", category: "Color",
            params: [EffectParamSpec(key: "amount", label: "Contrast", range: 0.5...1.5,
                                     defaultValue: 1, unit: "")],
            apply: { image, p, _ in
                image.applyingFilter("CIColorControls", parameters: [
                    kCIInputContrastKey: p.value("amount"),
                ])
            }
        ),
        EffectDescriptor(
            id: "color.saturation", displayName: "Saturation", category: "Color",
            params: [EffectParamSpec(key: "amount", label: "Saturation", range: 0...2,
                                     defaultValue: 1, unit: "")],
            apply: { image, p, _ in
                image.applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: p.value("amount"),
                ])
            }
        ),
        EffectDescriptor(
            id: "color.temperature", displayName: "Temperature & Tint", category: "Color",
            params: [
                EffectParamSpec(key: "temperature", label: "Temperature", range: 2000...11000,
                                defaultValue: 6500, unit: "K"),
                EffectParamSpec(key: "tint", label: "Tint", range: -100...100,
                                defaultValue: 0, unit: ""),
            ],
            apply: { image, p, _ in
                image.applyingFilter("CITemperatureAndTint", parameters: [
                    "inputNeutral": CIVector(x: p.value("temperature"), y: p.value("tint")),
                    "inputTargetNeutral": CIVector(x: 6500, y: 0),
                ])
            }
        ),
        EffectDescriptor(
            id: "color.highlightsShadows", displayName: "Highlights & Shadows", category: "Color",
            params: [
                EffectParamSpec(key: "highlights", label: "Highlights", range: 0.3...1,
                                defaultValue: 1, unit: ""),
                EffectParamSpec(key: "shadows", label: "Shadows", range: -1...1,
                                defaultValue: 0, unit: ""),
            ],
            apply: { image, p, _ in
                image.applyingFilter("CIHighlightShadowAdjust", parameters: [
                    "inputHighlightAmount": p.value("highlights"),
                    "inputShadowAmount": p.value("shadows"),
                ])
            }
        ),
    ]

    private static let lut: [EffectDescriptor] = [
        EffectDescriptor(
            id: "color.lut", displayName: "LUT", category: "Color",
            params: [EffectParamSpec(key: "intensity", label: "Intensity", range: 0...1,
                                     defaultValue: 1, unit: "")],
            resourceKey: "path",
            apply: { image, p, _ in
                guard let path = p.string("path"), let cube = LUTLoader.load(path: path) else {
                    return image
                }
                let graded = image.applyingFilter("CIColorCube", parameters: [
                    "inputCubeDimension": cube.dimension,
                    "inputCubeData": cube.data,
                ])
                let intensity = p.value("intensity")
                guard intensity < 1 else { return graded }
                return graded.applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputImageKey: image,
                    kCIInputTargetImageKey: graded,
                    kCIInputTimeKey: intensity,
                ])
            }
        ),
    ]

    private static let blur: [EffectDescriptor] = [
        EffectDescriptor(
            id: "blur.gaussian", displayName: "Gaussian Blur", category: "Blur & Sharpen",
            params: [EffectParamSpec(key: "radius", label: "Radius", range: 0...100,
                                     defaultValue: 8, unit: "px")],
            apply: { image, p, extent in
                let radius = p.value("radius")
                guard radius > 0 else { return image }
                return image.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                    .cropped(to: extent)
            }
        ),
        EffectDescriptor(
            id: "blur.sharpen", displayName: "Sharpen", category: "Blur & Sharpen",
            params: [EffectParamSpec(key: "amount", label: "Sharpness", range: 0...2,
                                     defaultValue: 0.4, unit: "")],
            apply: { image, p, extent in
                image.clampedToExtent()
                    .applyingFilter("CISharpenLuminance", parameters: [
                        kCIInputSharpnessKey: p.value("amount"),
                    ])
                    .cropped(to: extent)
            }
        ),
    ]

    private static let stylize: [EffectDescriptor] = [
        EffectDescriptor(
            id: "stylize.vignette", displayName: "Vignette", category: "Stylize",
            params: [
                EffectParamSpec(key: "intensity", label: "Intensity", range: 0...2,
                                defaultValue: 1, unit: ""),
                EffectParamSpec(key: "radius", label: "Radius", range: 0...2.5,
                                defaultValue: 1.5, unit: ""),
            ],
            apply: { image, p, _ in
                image.applyingFilter("CIVignette", parameters: [
                    kCIInputIntensityKey: p.value("intensity"),
                    kCIInputRadiusKey: p.value("radius"),
                ])
            }
        ),
        EffectDescriptor(
            id: "stylize.pixelate", displayName: "Pixelate", category: "Stylize",
            params: [EffectParamSpec(key: "scale", label: "Scale", range: 1...200,
                                     defaultValue: 20, unit: "px")],
            apply: { image, p, extent in
                image.clampedToExtent()
                    .applyingFilter("CIPixellate", parameters: [
                        kCIInputScaleKey: p.value("scale"),
                        // Grid anchored at the frame corner, like FCP.
                        kCIInputCenterKey: CIVector(x: extent.origin.x, y: extent.origin.y),
                    ])
                    .cropped(to: extent)
            }
        ),
    ]

    static let byId: [String: EffectDescriptor] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) }
    )

    static func descriptor(id: String) -> EffectDescriptor? { byId[id] }
}
