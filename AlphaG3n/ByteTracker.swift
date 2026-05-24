//
//  ByteTracker.swift
//  AlphaG3n
//
//  Created by Peter Zhao on 5/23/26.
//

import CoreGraphics

/// A single tracked object with a stable identity across frames.
struct TrackedBox: Sendable, Identifiable {
    let id: Int
    /// Normalized Vision-space rect (origin bottom-left, components in [0, 1]).
    let normalizedRect: CGRect
    /// Optional oriented quad for renderers that want a rotated outline.
    /// Non-nil if the source detector emitted one.
    let normalizedQuad: Quad?
    /// Confidence of the most recent detection that updated this track.
    let confidence: Float
    /// Class id of the most recent detection that updated this track. Nil for
    /// detectors that don't emit labels.
    let classId: Int?
}

/// ByteTrack-style multi-object tracker (https://arxiv.org/abs/2110.06864).
///
/// Two-stage greedy IoU association:
///   1. High-confidence detections are matched against every track.
///   2. Tracks that survived stage 1 unmatched get a second chance against
///      the low-confidence detections — that's what keeps occluded or briefly
///      faded objects alive instead of dropping and rebirthing them.
///
/// Unmatched high-confidence detections above `initThreshold` start new tracks;
/// tracks that go unmatched accumulate a `lost` counter and are dropped after
/// `maxLost` frames. No motion model — we compare new detections against each
/// track's last known position, which is fine for slow-moving subjects like
/// documents and signs.
final class ByteTracker {

    /// Detections above this score participate in the stage-1 match.
    var highThreshold: Float = 0.25
    /// Stage-2 detections must score at least this much (but less than
    /// `highThreshold`) to be eligible for matching surviving tracks.
    var lowThreshold: Float = 0.05
    /// A new track can only spawn from an unmatched detection scoring this high.
    /// Combined with `highThreshold`, the effective spawn floor is `max(high, init)`.
    /// Higher than `highThreshold` on purpose: existing tracks accept weak
    /// detections to survive occlusion, but new tracks only spawn from
    /// confident hits so the background doesn't bloom with phantom boxes.
    var initThreshold: Float = 0.4
    /// Minimum IoU for a detection↔track pair to count as a match. Lower =
    /// more forgiving when the detection jumps a bit between frames.
    var matchIOU: CGFloat = 0.2
    /// Drop a track entirely after this many consecutive frames without a match.
    /// 20 ≈ 0.7s at 30fps — long enough to keep the same ID through a brief
    /// occlusion, short enough to free up IDs quickly when an object leaves.
    var maxLost: Int = 20
    /// Stop *drawing* a track after this many consecutive frames without a
    /// match. The track stays alive internally until `maxLost`, so a re-detect
    /// inside `maxLost` re-acquires the same ID without flicker. Smaller =
    /// boxes disappear faster the moment the detector loses the object.
    var maxDisplayLost: Int = 3
    /// EMA smoothing on matched tracks. 1.0 = snap straight to the detection
    /// (jittery), 0.0 = never move. Lower means smoother and laggier.
    var smoothFactor: CGFloat = 0.3

    private var nextID: Int = 1
    private var tracks: [Track] = []

    private struct Track {
        var id: Int
        var rect: CGRect
        var quad: Quad?
        var confidence: Float
        var classId: Int?
        var lost: Int
    }

    @discardableResult
    func update(detections: [Detection]) -> [TrackedBox] {
        let indexed = Array(detections.enumerated())
        let highIdx = indexed
            .filter { $0.element.confidence >= highThreshold }
            .map(\.offset)
        let lowIdx = indexed
            .filter { $0.element.confidence >= lowThreshold && $0.element.confidence < highThreshold }
            .map(\.offset)

        var matchedTracks = Set<Int>()
        var matchedDetections = Set<Int>()

        // Stage 1: every track ↔ high-confidence detections.
        associate(
            trackIndices: Array(tracks.indices),
            detectionIndices: highIdx,
            detections: detections,
            matchedTracks: &matchedTracks,
            matchedDetections: &matchedDetections
        )

        // Stage 2: tracks that didn't match yet ↔ low-confidence detections.
        let survivors = tracks.indices.filter { !matchedTracks.contains($0) }
        associate(
            trackIndices: survivors,
            detectionIndices: lowIdx,
            detections: detections,
            matchedTracks: &matchedTracks,
            matchedDetections: &matchedDetections
        )

        // Age unmatched tracks; drop those that have been gone too long.
        tracks = tracks.enumerated().compactMap { (idx, track) in
            if matchedTracks.contains(idx) { return track }
            var aged = track
            aged.lost += 1
            return aged.lost <= maxLost ? aged : nil
        }

        // Birth new tracks from confident, unmatched detections.
        for di in highIdx where !matchedDetections.contains(di) {
            let det = detections[di]
            guard det.confidence >= initThreshold else { continue }
            tracks.append(Track(
                id: nextID,
                rect: det.normalizedRect,
                quad: det.normalizedQuad,
                confidence: det.confidence,
                classId: det.classId,
                lost: 0
            ))
            nextID += 1
        }

        // Emit tracks that are currently matched or only briefly lost. Tracks
        // beyond the display grace stay alive internally for re-association
        // (up to `maxLost`) but aren't drawn — so the box disappears promptly
        // when the object leaves, without losing the ID on a single bad frame.
        return tracks
            .filter { $0.lost <= maxDisplayLost }
            .map {
                TrackedBox(
                    id: $0.id,
                    normalizedRect: $0.rect,
                    normalizedQuad: $0.quad,
                    confidence: $0.confidence,
                    classId: $0.classId
                )
            }
    }

    func reset() {
        tracks.removeAll()
        nextID = 1
    }

    /// Greedy IoU association: enumerate every candidate pair, sort by IoU
    /// descending, and accept pairs whose track and detection are both still
    /// free. Updates `matchedTracks` / `matchedDetections` in place and snaps
    /// the matched track to its detection.
    private func associate(
        trackIndices: [Int],
        detectionIndices: [Int],
        detections: [Detection],
        matchedTracks: inout Set<Int>,
        matchedDetections: inout Set<Int>
    ) {
        var pairs: [(track: Int, detection: Int, iou: CGFloat)] = []
        for ti in trackIndices {
            let trackRect = tracks[ti].rect
            for di in detectionIndices where !matchedDetections.contains(di) {
                let iou = trackRect.iou(detections[di].normalizedRect)
                if iou >= matchIOU {
                    pairs.append((ti, di, iou))
                }
            }
        }
        pairs.sort { $0.iou > $1.iou }
        for pair in pairs {
            if matchedTracks.contains(pair.track) || matchedDetections.contains(pair.detection) {
                continue
            }
            let det = detections[pair.detection]
            tracks[pair.track].rect = tracks[pair.track].rect.lerp(towards: det.normalizedRect, alpha: smoothFactor)
            // Lerp the quad too when both sides have one. If a track was born
            // without a quad it adopts the detection's; if a detection drops
            // its quad we keep the last known one.
            if let oldQuad = tracks[pair.track].quad, let newQuad = det.normalizedQuad {
                tracks[pair.track].quad = oldQuad.lerp(towards: newQuad, alpha: smoothFactor)
            } else if let newQuad = det.normalizedQuad {
                tracks[pair.track].quad = newQuad
            }
            tracks[pair.track].confidence = det.confidence
            tracks[pair.track].classId = det.classId ?? tracks[pair.track].classId
            tracks[pair.track].lost = 0
            matchedTracks.insert(pair.track)
            matchedDetections.insert(pair.detection)
        }
    }
}

extension TrackedBox {
    /// A box "is the subject" — eligible for the red highlight in the preview
    /// and used as the crop target at capture time — when its normalized area
    /// is in `[minAreaFraction, maxAreaFraction]` AND every edge is at least
    /// `edgePadding` away from the frame edge. Centered, takes up most of the
    /// view, not clipped. Defaults mirror `CameraPreview.PreviewView`.
    static func isHighlightCandidate(
        _ normalizedRect: CGRect,
        minAreaFraction: CGFloat = 0.10,
        maxAreaFraction: CGFloat = 0.75,
        edgePadding: CGFloat = 0.03
    ) -> Bool {
        let area = normalizedRect.width * normalizedRect.height
        guard area >= minAreaFraction, area <= maxAreaFraction else {
            return false
        }
        return normalizedRect.minX >= edgePadding
            && normalizedRect.maxX <= 1 - edgePadding
            && normalizedRect.minY >= edgePadding
            && normalizedRect.maxY <= 1 - edgePadding
    }

    /// Picks the single tracked box that the preview overlay would draw red on
    /// the current frame: the largest box that satisfies `isHighlightCandidate`,
    /// or nil if none qualify. Used at capture time to decide what to crop to.
    static func highlightWinner(in boxes: [TrackedBox]) -> TrackedBox? {
        boxes
            .filter { isHighlightCandidate($0.normalizedRect) }
            .max { lhs, rhs in
                (lhs.normalizedRect.width * lhs.normalizedRect.height)
                    < (rhs.normalizedRect.width * rhs.normalizedRect.height)
            }
    }

    /// Display-only filter: drops boxes whose axis-aligned rect is mostly
    /// inside a strictly larger sibling. The tracker state is unaffected —
    /// hidden tracks keep their ID and pop back if the larger box goes away.
    ///
    /// `containmentThreshold` is the minimum fraction of the smaller box's
    /// area that must lie inside the larger box for the smaller one to be
    /// hidden (0.6 = 60%). Equal-area boxes are both kept.
    static func removingContained(
        _ boxes: [TrackedBox],
        containmentThreshold: CGFloat = 0.9
    ) -> [TrackedBox] {
        let areas = boxes.map { $0.normalizedRect.width * $0.normalizedRect.height }
        return boxes.indices.compactMap { i -> TrackedBox? in
            let myArea = areas[i]
            guard myArea > 0 else { return nil }
            for j in boxes.indices where j != i {
                guard areas[j] > myArea else { continue }
                let inter = boxes[i].normalizedRect.intersection(boxes[j].normalizedRect)
                guard !inter.isNull, !inter.isEmpty else { continue }
                let interArea = inter.width * inter.height
                if interArea / myArea >= containmentThreshold {
                    return nil
                }
            }
            return boxes[i]
        }
    }
}

extension CGRect {
    /// Intersection-over-union with another rect. Returns 0 for non-overlapping
    /// or degenerate inputs.
    func iou(_ other: CGRect) -> CGFloat {
        let inter = intersection(other)
        if inter.isNull || inter.isEmpty { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = width * height + other.width * other.height - interArea
        return unionArea > 0 ? interArea / unionArea : 0
    }

    /// Linearly interpolates each edge towards `target`. `alpha = 1` returns
    /// `target` (snap), `alpha = 0` returns `self` (no change).
    func lerp(towards target: CGRect, alpha: CGFloat) -> CGRect {
        let a = max(0, min(1, alpha))
        return CGRect(
            x: minX * (1 - a) + target.minX * a,
            y: minY * (1 - a) + target.minY * a,
            width: width * (1 - a) + target.width * a,
            height: height * (1 - a) + target.height * a
        )
    }
}
