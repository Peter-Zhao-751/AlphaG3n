//
//  Detection.swift
//  AlphaG3n
//
//  Created by Peter Zhao on 5/23/26.
//

import CoreGraphics

/// A 4-corner polygon in Vision-normalized coordinates (origin bottom-left,
/// components in [0, 1]). Stored as 4 points in counter-clockwise order so the
/// renderer can stroke them directly.
struct Quad: Sendable, Equatable {
    /// Counter-clockwise corners. Length is always 4.
    let points: [CGPoint]

    init(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) {
        self.points = [p0, p1, p2, p3]
    }

    init(points: [CGPoint]) {
        precondition(points.count == 4, "Quad needs exactly 4 corners, got \(points.count)")
        self.points = points
    }

    /// Axis-aligned quad covering `rect`, with corners in CCW order
    /// (BL → BR → TR → TL) matching what the segmentation detector emits.
    /// Used as a fallback when a tracked detection has no oriented outline.
    init(rect: CGRect) {
        self.points = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
        ]
    }

    /// Axis-aligned bounding rect of the quad — what ByteTrack does IoU on.
    var boundingBox: CGRect {
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Per-corner linear interpolation toward `target`. Used by the tracker for
    /// smoothing. Corners are paired by index, so this assumes the producer
    /// emits its corners in a consistent order across frames.
    func lerp(towards target: Quad, alpha: CGFloat) -> Quad {
        let a = max(0, min(1, alpha))
        let pts = (0..<4).map { i -> CGPoint in
            let s = points[i], t = target.points[i]
            return CGPoint(x: s.x * (1 - a) + t.x * a, y: s.y * (1 - a) + t.y * a)
        }
        return Quad(points: pts)
    }

    /// Returns a quad scaled outward from its centroid. `factor = 0.10`
    /// means each side grows by 10% (5% added at each end), preserving the
    /// quad's shape and orientation. Used at capture time to pad the crop so
    /// the segmentation model's tight masks don't clip edges/text of the
    /// physical object.
    func expanded(byFactor factor: CGFloat) -> Quad {
        guard factor != 0 else { return self }
        let cx = points.map(\.x).reduce(0, +) / CGFloat(points.count)
        let cy = points.map(\.y).reduce(0, +) / CGFloat(points.count)
        let scale = 1 + factor
        let grown = points.map { p in
            CGPoint(x: cx + (p.x - cx) * scale,
                    y: cy + (p.y - cy) * scale)
        }
        return Quad(points: grown)
    }
}

/// One detected region. The tracker matches on `normalizedRect`; the renderer
/// draws `normalizedQuad` if it's present, otherwise the rect.
struct Detection: Sendable {
    /// Normalized Vision-space axis-aligned rect (origin bottom-left, [0, 1]).
    let normalizedRect: CGRect
    /// Optional oriented quad in the same coordinate space. Non-nil when the
    /// detector can produce a rotated outline (e.g. segmentation models).
    let normalizedQuad: Quad?
    /// Vision's confidence score in [0, 1].
    let confidence: Float
    /// Class id the detector emitted for this region. Nil for detectors that
    /// don't produce labels. Capture-time logic in `CameraManager` uses it to
    /// look up per-class crop padding via `YoloEClasses`.
    let classId: Int?
}

extension Detection {
    /// Greedy non-max suppression on the axis-aligned bounding rects.
    /// Keep highest-confidence first; drop anything overlapping a kept entry
    /// above `iou`. Used to dedupe results when multiple detectors are combined.
    static func nonMaxSuppress(_ detections: [Detection], iou: CGFloat = 0.5) -> [Detection] {
        let sorted = detections.sorted { $0.confidence > $1.confidence }
        var kept: [Detection] = []
        for d in sorted {
            let duplicate = kept.contains { $0.normalizedRect.iou(d.normalizedRect) > iou }
            if !duplicate { kept.append(d) }
        }
        return kept
    }
}
