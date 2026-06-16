import AVFoundation
import CoreImage

/// Pure Core Image compositing core. Reproduces what the stock AVFoundation compositor
/// did via layer-instruction ramps — crop, transform, opacity×fade, bottom→top stacking —
/// but samples keyframe curves exactly per frame instead of pre-baked linear ramps.
enum FrameRenderer {

    static func render(
        instruction: CompositorInstruction,
        sourceFrame: (CMPersistentTrackID) -> CVPixelBuffer?,
        compositionTime: CMTime,
        into output: CVPixelBuffer,
        context: CIContext
    ) {
        let renderRect = CGRect(origin: .zero, size: instruction.renderSize)
        let frame = Int((compositionTime.seconds * Double(instruction.fps)).rounded())

        var accum = CIImage(color: .black).cropped(to: renderRect)
        for layer in instruction.layers {
            guard let buffer = sourceFrame(layer.trackID) else { continue }
            if let image = composedLayer(layer, buffer: buffer, frame: frame,
                                         renderSize: instruction.renderSize) {
                accum = image.composited(over: accum)
            }
        }
        context.render(accum, to: output, bounds: renderRect, colorSpace: nil)
        tag709(output)
    }

    /// Declare Rec. 709 like the stock path's videoComposition tags did, so players,
    /// encoders, and image generators interpret our bytes identically. Buffer-level
    /// only — writer-level color keys zero ProRes 4444 alpha on macOS 26.
    private static func tag709(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    private static func composedLayer(
        _ layer: LayerPlan,
        buffer: CVPixelBuffer,
        frame: Int,
        renderSize: CGSize
    ) -> CIImage? {
        let clip = layer.clip
        let alpha = min(1.0, max(0.0, clip.opacityAt(frame: frame)))
        guard alpha > 0 else { return nil }

        // Sources are premultiplied BGRA, but with color management off CI treats
        // pixels as unpremultiplied and premultiplies at composite time — declare
        // the source representation so the composite reconstructs stock's blend.
        var image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
            .unpremultiplyingAlpha()
        let srcHeight = CGFloat(CVPixelBufferGetHeight(buffer))

        let crop = clip.cropAt(frame: frame)
        if !crop.isIdentity {
            // Display-space insets mapped to unoriented source pixels (same math as emitCrop),
            // then to CI's bottom-left origin.
            let avRect = CGRect(
                x: crop.left * layer.natSize.width,
                y: crop.top * layer.natSize.height,
                width: max(1, crop.visibleWidthFraction * layer.natSize.width),
                height: max(1, crop.visibleHeightFraction * layer.natSize.height)
            ).applying(layer.preferredTransform.inverted())
            image = image.cropped(to: CGRect(
                x: avRect.origin.x,
                y: srcHeight - avRect.origin.y - avRect.height,
                width: avRect.width,
                height: avRect.height
            ))
        }

        // Effects apply in source-pixel space: after crop, before placement.
        if let effects = clip.effects, !effects.isEmpty {
            let offset = frame - clip.startFrame
            for effect in effects where effect.enabled {
                guard let descriptor = EffectRegistry.descriptor(id: effect.type) else { continue }
                image = descriptor.render(image, effect: effect, atOffset: offset)
            }
        }

        // Stock-path quirk preserved: transformAt drops flips, so flips only apply
        // on the static (non-animated) branch.
        let t = clip.hasTransformAnimation ? clip.transformAt(frame: frame) : clip.transform
        let av = layer.preferredTransform.concatenating(
            CompositionBuilder.affineTransform(for: t, natSize: layer.natSize, renderSize: renderSize)
        )
        // Conjugate the AV top-left-origin mapping into CI's bottom-left space.
        let ci = flipY(srcHeight).concatenating(av).concatenating(flipY(renderSize.height))
        image = image.transformed(by: ci)

        if alpha < 1 {
            // Scale alpha only: CIColorMatrix runs on unpremultiplied pixels and
            // re-premultiplies by the result's alpha — touching RGB doubles the fade.
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha),
            ])
        }
        return image
    }

    private static func flipY(_ height: CGFloat) -> CGAffineTransform {
        CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
    }
}
