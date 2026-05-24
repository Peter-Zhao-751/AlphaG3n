//
//  BoundingBoxCropper.swift
//  AlphaG3n
//
//  Crops a source image to a set of layout bounding boxes, padding each box by
//  a uniform margin first. Split into two halves on purpose:
//
//    • `paddedRect(_:margin:within:)` — pure CoreGraphics margin + clamp math,
//      compiled on every platform and unit-tested standalone (run_crop_geometry.swift).
//    • `croppedJPEGs(of:blocks:margin:)` — the UIKit image cropping, gated behind
//      `#if canImport(UIKit)` so it compiles out under a macOS command-line build
//      and the geometry can be verified without a device or simulator.
//

import Foundation
import CoreGraphics

#if canImport(UIKit)
import UIKit
#endif

enum BoundingBoxCropper {

    /// Expands `box` outward by `margin` on every side — `margin × box.width`
    /// left and right, `margin × box.height` top and bottom — then clamps the
    /// result to `bounds`. `margin` is a per-side fraction (0.05 == 5%); 0
    /// returns the box clamped to bounds. A box that lands fully outside
    /// `bounds` collapses to `.zero`, which callers read as "nothing to crop".
    static func paddedRect(_ box: CGRect, margin: CGFloat, within bounds: CGRect) -> CGRect {
        let dx = box.width * margin
        let dy = box.height * margin
        let clamped = box.insetBy(dx: -dx, dy: -dy).intersection(bounds)
        return clamped.isNull ? .zero : clamped
    }

    #if canImport(UIKit)

    /// One padded JPEG crop per block, in block order. Each block's
    /// `[x1, y1, x2, y2]` bbox is read in `image`'s own pixel frame (the OCR
    /// layout's `width × height`), padded by `margin`, and cut from the pixels.
    /// Blocks whose padded rect is degenerate or whose crop fails to encode are
    /// dropped, so the returned pairs stay index-aligned with anything the
    /// caller derives from them downstream (e.g. `OpenAIClient.readText`).
    static func croppedJPEGs(
        of image: UIImage,
        blocks: [VirtualDocument.PrunedResult.RawBlock],
        margin: CGFloat,
        quality: CGFloat = 0.9
    ) -> [(block: VirtualDocument.PrunedResult.RawBlock, jpeg: Data)] {
        guard !blocks.isEmpty, let source = uprightCGImage(image) else { return [] }
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)

        var out: [(block: VirtualDocument.PrunedResult.RawBlock, jpeg: Data)] = []
        out.reserveCapacity(blocks.count)
        for block in blocks {
            guard let box = Self.rect(fromBbox: block.blockBbox) else { continue }
            let padded = paddedRect(box, margin: margin, within: bounds).integral
            guard padded.width >= 1, padded.height >= 1,
                  let cropped = source.cropping(to: padded),
                  let jpeg = UIImage(cgImage: cropped).jpegData(compressionQuality: quality)
            else { continue }
            out.append((block, jpeg))
        }
        return out
    }

    /// `[x1, y1, x2, y2]` (top-left origin) → CGRect; nil when malformed or empty.
    private static func rect(fromBbox bbox: [Double]) -> CGRect? {
        guard bbox.count >= 4 else { return nil }
        let r = CGRect(x: bbox[0], y: bbox[1], width: bbox[2] - bbox[0], height: bbox[3] - bbox[1])
        return (r.width > 0 && r.height > 0) ? r : nil
    }

    /// The image's pixels as an upright (`.up`) CGImage, so bbox pixel
    /// coordinates from the OCR layout map straight onto it. Fast path returns
    /// the existing CGImage when the UIImage is already `.up` at scale 1 (the
    /// capture pipeline's invariant for `renderSource`); otherwise it redraws
    /// once at 1:1 so a future non-upright source can't silently misalign crops.
    private static func uprightCGImage(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, image.scale == 1 { return image.cgImage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }.cgImage
    }

    #endif
}
