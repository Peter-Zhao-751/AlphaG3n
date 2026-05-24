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
        /// the single largest one is rendered red — the others stay cyan.
        var highlightMinAreaFraction: CGFloat = 0.20
        var highlightMaxAreaFraction: CGFloat = 0.75
        var highlightEdgePadding: CGFloat = 0.03

        private let regularLayer: CAShapeLayer = {
            let l = CAShapeLayer()
            l.fillColor = nil
            l.strokeColor = UIColor.systemCyan.cgColor
            l.lineWidth = 2
            return l
        }()
        private let highlightLayer: CAShapeLayer = {
            let l = CAShapeLayer()
            l.fillColor = nil
            l.strokeColor = UIColor.systemRed.cgColor
            l.lineWidth = 3
            return l
        }()
        private var lastDetections: [TrackedBox] = []

        override init(frame: CGRect) {
            super.init(frame: frame)
            layer.addSublayer(regularLayer)
            layer.addSublayer(highlightLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            regularLayer.frame = bounds
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
            // Pick the single largest qualifying box (if any) for the red
            // highlight; everyone else — including other qualifying boxes —
            // renders as regular cyan.
            let winnerIdx = pickHighlightIndex(lastDetections)

            let regular = UIBezierPath()
            let highlight = UIBezierPath()
            for (i, detection) in lastDetections.enumerated() {
                let target = (i == winnerIdx) ? highlight : regular
                // Upright rect overlay; the oriented quad is kept on the
                // detection for capture-time perspective correction only.
                target.append(rectPath(detection.normalizedRect))
            }
            // Avoid the implicit animation on `path` so the boxes track frames cleanly.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            regularLayer.path = regular.cgPath
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

        private func rectPath(_ visionRect: CGRect) -> UIBezierPath {
            // Vision rect: bottom-left origin. Metadata rect (what
            // `layerRectConverted` wants): top-left origin. Flip Y.
            let metadataRect = CGRect(
                x: visionRect.minX,
                y: 1 - visionRect.minY - visionRect.height,
                width: visionRect.width,
                height: visionRect.height
            )
            let viewRect = videoPreviewLayer.layerRectConverted(fromMetadataOutputRect: metadataRect)
            return UIBezierPath(rect: viewRect)
        }
    }
}
