//
//  CameraPreview.swift
//  AlphaG3n
//
//  Created by Peter Zhao on 5/23/26.
//

import SwiftUI
import AVFoundation

/// Shows the live camera feed using Apple's `AVCaptureVideoPreviewLayer` —
/// the standard, GPU-efficient preview path, wrapped for SwiftUI. Optionally
/// draws saliency bounding boxes on top of the preview.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var detections: [TrackedBox] = []
    /// Rotation (degrees) for the preview layer's `AVCaptureConnection`.
    /// Driven by `CameraManager.previewRotationAngle` so the preview tracks
    /// device orientation the same way the captured photo does.
    var rotationAngle: CGFloat = 90

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        view.apply(rotationAngle: rotationAngle)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.apply(detections: detections)
        uiView.apply(rotationAngle: rotationAngle)
    }

    /// A UIView whose backing layer *is* the preview layer, so the feed always
    /// matches the view's bounds with no manual layout. A `CAShapeLayer` sits
    /// on top to draw the saliency boxes.
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }

        /// A box qualifies for the red highlight when its area is within
        /// `[highlightMinAreaFraction, highlightMaxAreaFraction]` of the frame
        /// AND every edge is at least `highlightEdgePadding` away from the
        /// frame's edges. If multiple boxes qualify on the same frame, only
        /// the single largest one is rendered.
        var highlightMinAreaFraction: CGFloat = 0.10
        var highlightMaxAreaFraction: CGFloat = 0.75
        var highlightEdgePadding: CGFloat = 0.03
        private let highlightLayer: CAShapeLayer = {
            let l = CAShapeLayer()
            l.fillColor = nil
            l.strokeColor = UIColor(LarpTheme.orange).cgColor
            // Match the result-view detection boxes: same orange and crisp
            // (mitered) corners, a touch bolder than their 2pt so the brackets
            // stay legible over the moving live feed.
            l.lineWidth = 3
            l.lineCap = .butt
            l.lineJoin = .miter
            return l
        }()
        /// Translucent accent fill of the region the brackets frame, sitting
        /// beneath `highlightLayer`. Same orange as the brackets, at low alpha.
        private let fillLayer: CAShapeLayer = {
            let l = CAShapeLayer()
            l.strokeColor = nil
            l.fillColor = UIColor(LarpTheme.orange).withAlphaComponent(0.4).cgColor
            return l
        }()
        private var lastDetections: [TrackedBox] = []

        override init(frame: CGRect) {
            super.init(frame: frame)
            layer.addSublayer(fillLayer)      // beneath the brackets
            layer.addSublayer(highlightLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            fillLayer.frame = bounds
            highlightLayer.frame = bounds
            rebuildPath()
        }

        func apply(detections: [TrackedBox]) {
            lastDetections = detections
            rebuildPath()
        }

        /// Rotate the preview layer's connection so the live feed matches
        /// the device's current orientation. Without this, the preview
        /// would always show the sensor's native landscape — which would
        /// look fine in landscape and rotated 90°/180° in portrait or
        /// upside-down portrait, exactly the way the captured photo used
        /// to be broken.
        func apply(rotationAngle angle: CGFloat) {
            guard let connection = videoPreviewLayer.connection,
                  connection.isVideoRotationAngleSupported(angle),
                  connection.videoRotationAngle != angle else { return }
            connection.videoRotationAngle = angle
        }

        private func rebuildPath() {
            // Pick the single largest qualifying box (if any) for the accent
            // highlight. Other tracked boxes stay tracked but are not rendered.
            let winnerIdx = pickHighlightIndex(lastDetections)
            let crosshair = UIBezierPath()
            let fill = UIBezierPath()
            if let winnerIdx {
                // Brackets and the translucent fill share the same expanded
                // corners, so the fill exactly covers the framed region.
                let corners = crosshairCornerPoints(for: lastDetections[winnerIdx])
                crosshair.append(cornerCrosshairPath(points: corners))
                fill.append(quadPath(points: corners))
            }
            // Avoid the implicit animation on `path` so the boxes track frames cleanly.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            highlightLayer.path = crosshair.cgPath
            fillLayer.path = fill.cgPath
            CATransaction.commit()
        }

        /// Returns the index of the largest box that satisfies `shouldHighlight`,
        /// or nil if no box qualifies on this frame.
        private func pickHighlightIndex(_ boxes: [TrackedBox]) -> Int? {
            var bestIdx: Int? = nil
            var bestArea: CGFloat = 0
            for (i, box) in boxes.enumerated() {
                guard shouldHighlight(box.normalizedRect) else { continue }
                let area = box.normalizedRect.width * box.normalizedRect.height
                if area > bestArea {
                    bestArea = area
                    bestIdx = i
                }
            }
            return bestIdx
        }

        /// `rect` is in Vision-normalized coords (origin bottom-left, [0, 1]).
        /// Delegates to `TrackedBox.isHighlightCandidate` so the preview and
        /// the photo-capture path share one predicate.
        private func shouldHighlight(_ rect: CGRect) -> Bool {
            TrackedBox.isHighlightCandidate(
                rect,
                minAreaFraction: highlightMinAreaFraction,
                maxAreaFraction: highlightMaxAreaFraction,
                edgePadding: highlightEdgePadding
            )
        }

        /// The expanded quad's four corners in view space — the region the
        /// crosshair brackets frame and the fill covers.
        private func crosshairCornerPoints(for detection: TrackedBox) -> [CGPoint] {
            // Trace the same region capture will crop: grow the quad by this
            // class's crop padding (YoloEClasses), so the brackets preview the
            // actual crop and looser-cropped classes (e.g. bottle, can) read
            // wider. Unknown/nil ids fall back to the table's default padding.
            let margin = YoloEClasses.cropPadding(for: detection.classId)
            let quad = (detection.normalizedQuad ?? Quad(rect: detection.normalizedRect))
                .expanded(byFactor: margin)
            return quad.points.map(viewPoint(fromVisionPoint:))
        }

        /// Closed polygon through `points` — the filled region inside the brackets.
        private func quadPath(points: [CGPoint]) -> UIBezierPath {
            let path = UIBezierPath()
            guard points.count == 4 else { return path }
            path.move(to: points[0])
            for i in 1..<4 { path.addLine(to: points[i]) }
            path.close()
            return path
        }

        private func cornerCrosshairPath(points: [CGPoint]) -> UIBezierPath {
            let path = UIBezierPath()
            guard points.count == 4 else { return path }

            let edgeLengths = (0..<4).map { i in
                distance(points[i], points[(i + 1) % 4])
            }
            let minEdge = edgeLengths.min() ?? 0
            let armLength = max(12, min(32, minEdge * 0.35))

            for i in 0..<4 {
                let corner = points[i]
                let prev = points[(i + 3) % 4]
                let next = points[(i + 1) % 4]
                // Draw each bracket as one bent stroke (prevEnd → corner → nextEnd)
                // so the mitered lineJoin renders a sharp right-angle corner — the
                // same crisp corner the result-view boxes have. Two separate arms
                // would instead meet as two independently capped segments.
                path.move(to: armEnd(from: corner, toward: prev, length: armLength))
                path.addLine(to: corner)
                path.addLine(to: armEnd(from: corner, toward: next, length: armLength))
            }
            return path
        }

        private func armEnd(
            from corner: CGPoint,
            toward neighbor: CGPoint,
            length: CGFloat
        ) -> CGPoint {
            let dx = neighbor.x - corner.x
            let dy = neighbor.y - corner.y
            let edgeLength = hypot(dx, dy)
            guard edgeLength > 0.001 else { return corner }

            let clampedLength = min(length, edgeLength * 0.45)
            let scale = clampedLength / edgeLength
            return CGPoint(x: corner.x + dx * scale, y: corner.y + dy * scale)
        }

        private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            hypot(b.x - a.x, b.y - a.y)
        }

        private func viewPoint(fromVisionPoint point: CGPoint) -> CGPoint {
            // Vision point: bottom-left origin. Capture-device point expects
            // top-left origin, so flip Y before converting to view space.
            let capturePoint = CGPoint(x: point.x, y: 1 - point.y)
            return videoPreviewLayer.layerPointConverted(fromCaptureDevicePoint: capturePoint)
        }
    }
}
