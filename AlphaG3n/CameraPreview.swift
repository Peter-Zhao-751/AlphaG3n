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
            // Match the result-view detection boxes: same orange, the same 2pt
            // weight, and crisp (mitered) corners instead of rounded ones.
            l.lineWidth = 2
            l.lineCap = .butt
            l.lineJoin = .miter
            return l
        }()
        /// The crosshair brackets trace a box this much larger than the tracked
        /// region, so the corners sit outside the content with a clear margin.
        /// 0.10 → the traced box is 10% larger (≈5% added on each side).
        private let crosshairBoxMargin: CGFloat = 0.10
        private var lastDetections: [TrackedBox] = []

        override init(frame: CGRect) {
            super.init(frame: frame)
            layer.addSublayer(highlightLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
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
            let highlight = UIBezierPath()
            if let winnerIdx {
                highlight.append(cornerCrosshairPath(for: lastDetections[winnerIdx]))
            }
            // Avoid the implicit animation on `path` so the boxes track frames cleanly.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            highlightLayer.path = highlight.cgPath
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

        private func cornerCrosshairPath(for detection: TrackedBox) -> UIBezierPath {
            let quad = (detection.normalizedQuad ?? Quad(rect: detection.normalizedRect))
                .expanded(byFactor: crosshairBoxMargin)
            let viewPoints = quad.points.map(viewPoint(fromVisionPoint:))
            return cornerCrosshairPath(points: viewPoints)
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
