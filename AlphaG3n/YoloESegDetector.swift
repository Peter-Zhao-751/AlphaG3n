//
//  YoloESegDetector.swift
//  AlphaG3n
//
//  Created by Peter Zhao on 5/23/26.
//

import Accelerate
import CoreImage
import CoreML
import Vision

/// Runs the YOLOE-26L segmentation model and returns each detection as a
/// `Detection` whose `normalizedQuad` is the oriented (rotated-rectangle)
/// bounding box of the instance mask. The axis-aligned `normalizedRect` is
/// preserved alongside so ByteTrack's IoU matching keeps working unchanged.
///
/// Pipeline per frame:
///   1. `VNCoreMLRequest` runs the model with `.scaleFit` letterboxing (matches
///      Ultralytics' training preprocessing).
///   2. We pull two raw `MLMultiArray`s out of the request — one of shape
///      `[1, N, 38]` (per-row `[x1,y1,x2,y2, score, class_id, 32 mask coeffs]`,
///      in 640×640 pixel space, no NMS) and one of shape `[1, 32, 160, 160]`
///      (32 prototype masks).
///   3. NMS by axis-aligned bbox IoU.
///   4. For each survivor, build the per-instance mask:
///      `sigmoid(sum_i(coef[i] * proto[i]))`, crop to the detection's bbox in
///      proto space (160×160), threshold at 0.5.
///   5. Image moments on the binary mask give the principal axis; projecting
///      mask pixels onto that axis and its perpendicular yields the 4 corners
///      of the minimum-area oriented rectangle (OBB).
///   6. Unmap the bbox and quad corners from 640×640 letterboxed space back
///      into the original image's normalized Vision coords.
final class YoloESegDetector {

    /// Drop detections below this score after parsing the model output.
    /// Set low so weak hits can still feed the tracker's stage-2 (occlusion
    /// preservation). Spurious new-track creation is gated separately by
    /// `ByteTracker.initThreshold`.
    var minConfidence: Float = 0.15
    /// IoU threshold for our post-model NMS.
    var nmsIOU: CGFloat = 0.5
    /// Threshold applied to the per-instance sigmoid mask. 0.5 is conventional.
    var maskBinarizationThreshold: Float = 0.5
    /// Discard everything but the largest connected component before computing
    /// the OBB. Kills the speckle outliers that otherwise stretch the trapezoid
    /// out to meet a stray foreground pixel. Turn off if you ever want the
    /// raw mask shape (e.g. for objects that really do come in two disjoint
    /// pieces, though those are rare).
    var useLargestComponentOnly: Bool = true
    /// If the mask's covariance eigenvalue ratio (minor/major) exceeds this,
    /// the shape is too round for `atan2`-based orientation to be stable. We
    /// emit an axis-aligned quad in that case. 1.0 = perfect circle; 0.0 = line.
    var isotropyThreshold: Double = 0.85

    private let request: VNCoreMLRequest

    init(model: VNCoreMLModel) {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFit
        self.request = request
    }

    static func makeDefault(resource: String = "yoloe-26x-seg") -> YoloESegDetector? {
        for ext in ["mlmodelc", "mlpackage"] {
            guard let url = Bundle.main.url(forResource: resource, withExtension: ext) else { continue }
            do {
                let model = try MLModel(contentsOf: url)
                let vision = try VNCoreMLModel(for: model)
                return YoloESegDetector(model: vision)
            } catch {
                print("YoloESegDetector: failed to load \(resource).\(ext): \(error)")
            }
        }
        print("YoloESegDetector: \(resource) not found in app bundle")
        return nil
    }

    func detect(in image: CIImage) -> [Detection] {
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }

        guard
            let observations = request.results as? [VNCoreMLFeatureValueObservation],
            let (detsArray, protoArray) = pickOutputs(observations)
        else {
            return []
        }

        // Letterbox parameters for unmapping model coords → original image coords.
        let letterbox = Letterbox(imageSize: image.extent.size, modelSize: 640)

        // 1. Parse + filter raw detections.
        let candidates = parseDetections(detsArray, minConfidence: minConfidence)
        guard !candidates.isEmpty else { return [] }

        // 2. NMS in model space.
        let surviving = nms(candidates, iou: nmsIOU)
        guard !surviving.isEmpty else { return [] }

        // 3. Build per-instance masks + OBBs.
        let protoFlat = flatten(prototypes: protoArray)  // [32 * 160 * 160] contiguous Float
        return surviving.compactMap { candidate in
            let rawMask = makeInstanceMask(
                coefficients: candidate.maskCoefs,
                prototypes: protoFlat,
                bbox640: candidate.bbox640
            )
            // Drop speckle outliers before the OBB sees them — otherwise a
            // single stray foreground pixel stretches the trapezoid to meet it.
            let maskData: [Float]
            if useLargestComponentOnly {
                maskData = keepLargestComponent(
                    rawMask.data,
                    width: rawMask.width,
                    height: rawMask.height,
                    threshold: maskBinarizationThreshold
                )
            } else {
                maskData = rawMask.data
            }
            // Find 4 corners by hull-based fitting (boundary → convex hull →
            // 4 hull vertices maximizing enclosed quadrilateral area). For
            // near-circular masks where no real corners exist we fall back to
            // axis-aligned. For trapezoidal / perspective shapes this returns
            // a true quad with independent side lengths.
            let quad640 = hullQuad(
                fromMask: maskData,
                size: (rawMask.width, rawMask.height),
                origin: rawMask.origin,
                threshold: maskBinarizationThreshold,
                isotropyThreshold: isotropyThreshold
            ) ?? axisAlignedQuad640(from: candidate.bbox640)

            let normalizedBox = letterbox.unmap(rect640: candidate.bbox640)
            let normalizedQuad = letterbox.unmap(quad640: quad640)
            return Detection(
                normalizedRect: normalizedBox,
                normalizedQuad: normalizedQuad,
                confidence: candidate.score,
                classId: candidate.classId
            )
        }
    }

    // MARK: - Output picking

    /// Robust to re-exports (the auto-generated `var_*` names can change):
    /// pick by shape. Detection tensor is rank-3 with last dim 6 + mask_dim;
    /// prototypes are rank-4 with the 32-channel mask basis.
    private func pickOutputs(
        _ observations: [VNCoreMLFeatureValueObservation]
    ) -> (detections: MLMultiArray, prototypes: MLMultiArray)? {
        var dets: MLMultiArray?
        var proto: MLMultiArray?
        for obs in observations {
            guard let array = obs.featureValue.multiArrayValue else { continue }
            let shape = array.shape.map(\.intValue)
            if shape.count == 3, shape.last == 38 {
                dets = array
            } else if shape.count == 4, shape.contains(32), shape.contains(160) {
                proto = array
            }
        }
        guard let d = dets, let p = proto else { return nil }
        return (d, p)
    }

    // MARK: - Detection parsing

    private struct Candidate {
        let bbox640: CGRect      // pixel rect in 640×640 model space, top-left origin
        let score: Float
        let classId: Int
        let maskCoefs: [Float]   // 32 elements
    }

    private func parseDetections(_ array: MLMultiArray, minConfidence: Float) -> [Candidate] {
        guard array.dataType == .float32 else { return [] }
        let shape = array.shape.map(\.intValue)
        guard shape.count == 3, shape[2] == 38 else { return [] }
        let numDets = shape[1]

        let base = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
        let rowStride = array.strides[1].intValue
        let colStride = array.strides[2].intValue

        var out: [Candidate] = []
        out.reserveCapacity(numDets)
        for i in 0..<numDets {
            let row = base.advanced(by: i * rowStride)
            let score = row[4 * colStride]
            guard score >= minConfidence else { continue }
            let x1 = CGFloat(row[0 * colStride])
            let y1 = CGFloat(row[1 * colStride])
            let x2 = CGFloat(row[2 * colStride])
            let y2 = CGFloat(row[3 * colStride])
            let classId = Int(row[5 * colStride])
            var coefs = [Float](repeating: 0, count: 32)
            for k in 0..<32 {
                coefs[k] = row[(6 + k) * colStride]
            }
            let bbox = CGRect(
                x: x1,
                y: y1,
                width: max(0, x2 - x1),
                height: max(0, y2 - y1)
            )
            out.append(Candidate(bbox640: bbox, score: score, classId: classId, maskCoefs: coefs))
        }
        return out
    }

    private func nms(_ candidates: [Candidate], iou: CGFloat) -> [Candidate] {
        let sorted = candidates.sorted { $0.score > $1.score }
        var kept: [Candidate] = []
        for c in sorted {
            let duplicate = kept.contains { $0.bbox640.iou(c.bbox640) > iou }
            if !duplicate { kept.append(c) }
        }
        return kept
    }

    // MARK: - Mask reconstruction

    /// Copies the prototype tensor into a flat contiguous `[Float]` of length
    /// 32 * 160 * 160 in `[proto_index][y][x]` order, so the linear
    /// combination below is just 32 vDSP adds over slabs of length 25600.
    private func flatten(prototypes array: MLMultiArray) -> [Float] {
        let count = array.count
        let base = array.dataPointer.bindMemory(to: Float.self, capacity: count)
        // The exported model uses contiguous CHW layout for proto, so a single
        // copy is enough. If a future export uses a non-contiguous layout, this
        // would need a per-element copy honoring `strides`.
        return Array(UnsafeBufferPointer(start: base, count: count))
    }

    private struct InstanceMask {
        let data: [Float]   // length = width * height, foreground = >threshold
        let width: Int
        let height: Int
        /// Top-left of the cropped mask in the 160×160 proto plane (top-left origin).
        let origin: (x: Int, y: Int)
    }

    private func makeInstanceMask(
        coefficients: [Float],
        prototypes: [Float],
        bbox640: CGRect
    ) -> InstanceMask {
        let protoSide = 160
        let protoArea = protoSide * protoSide

        // 1. Build the full 160×160 mask: mask = sum_i coef[i] * proto[i], then sigmoid.
        var full = [Float](repeating: 0, count: protoArea)
        prototypes.withUnsafeBufferPointer { protoPtr in
            full.withUnsafeMutableBufferPointer { fullPtr in
                for i in 0..<32 {
                    var coef = coefficients[i]
                    vDSP_vsma(
                        protoPtr.baseAddress!.advanced(by: i * protoArea), 1,
                        &coef,
                        fullPtr.baseAddress!, 1,
                        fullPtr.baseAddress!, 1,
                        vDSP_Length(protoArea)
                    )
                }
            }
        }
        // Sigmoid in place via vForce: sigmoid(x) = 1 / (1 + exp(-x))
        var n = Int32(protoArea)
        var negOne: Float = -1
        vDSP_vsmul(full, 1, &negOne, &full, 1, vDSP_Length(protoArea))
        vvexpf(&full, full, &n)
        var one: Float = 1
        vDSP_vsadd(full, 1, &one, &full, 1, vDSP_Length(protoArea))
        var ones = [Float](repeating: 1, count: protoArea)
        vDSP_vdiv(full, 1, &ones, 1, &full, 1, vDSP_Length(protoArea))

        // 2. Crop to the bbox in proto space (proto is 1/4 model resolution).
        let scale: CGFloat = CGFloat(protoSide) / 640.0
        let x0 = max(0, Int(floor(bbox640.minX * scale)))
        let y0 = max(0, Int(floor(bbox640.minY * scale)))
        let x1 = min(protoSide, Int(ceil(bbox640.maxX * scale)))
        let y1 = min(protoSide, Int(ceil(bbox640.maxY * scale)))
        let w = max(1, x1 - x0)
        let h = max(1, y1 - y0)

        var cropped = [Float](repeating: 0, count: w * h)
        for row in 0..<h {
            let srcStart = (y0 + row) * protoSide + x0
            let dstStart = row * w
            for col in 0..<w {
                cropped[dstStart + col] = full[srcStart + col]
            }
        }
        return InstanceMask(data: cropped, width: w, height: h, origin: (x0, y0))
    }

    // MARK: - Oriented bounding box

    /// 4-connected flood fill: returns a binary mask containing only the
    /// largest connected blob of foreground (pixels ≥ `threshold` in the
    /// input). Surviving pixels are set to 1.0, everything else to 0.0.
    /// Iterative DFS so we don't blow the stack on big blobs.
    private func keepLargestComponent(
        _ mask: [Float],
        width: Int,
        height: Int,
        threshold: Float
    ) -> [Float] {
        let count = width * height
        var visited = [Bool](repeating: false, count: count)
        var largestComponent: [Int] = []
        var stack: [Int] = []
        stack.reserveCapacity(count)

        for start in 0..<count {
            if visited[start] || mask[start] < threshold { continue }
            var component: [Int] = []
            stack.append(start)
            visited[start] = true
            while let i = stack.popLast() {
                component.append(i)
                let x = i % width
                let y = i / width
                // 4 neighbors. Each is enqueued at most once thanks to `visited`.
                if x > 0 {
                    let n = i - 1
                    if !visited[n], mask[n] >= threshold { visited[n] = true; stack.append(n) }
                }
                if x < width - 1 {
                    let n = i + 1
                    if !visited[n], mask[n] >= threshold { visited[n] = true; stack.append(n) }
                }
                if y > 0 {
                    let n = i - width
                    if !visited[n], mask[n] >= threshold { visited[n] = true; stack.append(n) }
                }
                if y < height - 1 {
                    let n = i + width
                    if !visited[n], mask[n] >= threshold { visited[n] = true; stack.append(n) }
                }
            }
            if component.count > largestComponent.count {
                largestComponent = component
            }
        }

        var filtered = [Float](repeating: 0, count: count)
        for i in largestComponent { filtered[i] = 1 }
        return filtered
    }

    /// Builds the 4-corner axis-aligned quad from the YOLO bbox in model coords.
    /// Used as the fallback when an OBB can't be computed reliably (round or
    /// empty masks).
    private func axisAlignedQuad640(from rect: CGRect) -> Quad {
        Quad(
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        )
    }

    /// Boundary → convex hull → best 4-corner inscribed quadrilateral. This
    /// is the algorithm that actually produces trapezoidal / perspective
    /// shapes when the mask boundary is non-rectangular: we work on hull
    /// vertices (the actual outline corners) rather than pixel extrema, and
    /// pick the 4 that maximize enclosed area.
    ///
    /// Returns nil if:
    ///   - the mask has fewer than 4 foreground pixels,
    ///   - the mask is too isotropic (round) for any consistent orientation —
    ///     in that case the caller uses the axis-aligned bbox so we don't
    ///     get a spinning inscribed-square for circular blobs,
    ///   - the convex hull degenerates to fewer than 4 vertices.
    ///
    /// Corners are emitted in 640×640 model-space pixel coords (top-left
    /// origin), CCW (math frame) starting from the leftmost hull vertex.
    private func hullQuad(
        fromMask mask: [Float],
        size: (width: Int, height: Int),
        origin: (x: Int, y: Int),
        threshold: Float,
        isotropyThreshold: Double
    ) -> Quad? {
        let w = size.width, h = size.height

        // First pass: counts + first-order moments (centroid in proto coords).
        var count = 0.0
        var sumX = 0.0, sumY = 0.0
        for y in 0..<h {
            let rowBase = y * w
            for x in 0..<w where mask[rowBase + x] >= threshold {
                count += 1
                sumX += Double(x)
                sumY += Double(y)
            }
        }
        guard count >= 4 else { return nil }
        let cx = sumX / count
        let cy = sumY / count

        // Second pass: second-order central moments → eigenvalues → isotropy.
        // We don't need the principal axis itself (the hull picker doesn't use
        // an oriented frame), only the aspect ratio for the round-shape bail.
        var mxx = 0.0, myy = 0.0, mxy = 0.0
        for y in 0..<h {
            let rowBase = y * w
            let dy = Double(y) - cy
            for x in 0..<w where mask[rowBase + x] >= threshold {
                let dx = Double(x) - cx
                mxx += dx * dx
                myy += dy * dy
                mxy += dx * dy
            }
        }
        mxx /= count; myy /= count; mxy /= count

        let trace = mxx + myy
        let det = mxx * myy - mxy * mxy
        let disc = sqrt(max(0, trace * trace - 4 * det))
        let lambdaMax = (trace + disc) / 2
        let lambdaMin = (trace - disc) / 2
        guard lambdaMax > 1e-9 else { return nil }
        let aspect = sqrt(max(0, lambdaMin / lambdaMax))
        if aspect > isotropyThreshold { return nil }

        // Extract only boundary pixels (foreground with ≥1 background neighbor
        // or sitting on the mask edge). The hull only depends on these, and
        // scanning here is much faster than handing every foreground pixel to
        // the hull builder.
        var boundary: [(Double, Double)] = []
        boundary.reserveCapacity(Int(count.squareRoot()) * 4)
        for y in 0..<h {
            let rowBase = y * w
            for x in 0..<w where mask[rowBase + x] >= threshold {
                let onEdge = x == 0 || y == 0 || x == w - 1 || y == h - 1
                let touchesBg = !onEdge && (
                    mask[(y - 1) * w + x] < threshold ||
                    mask[(y + 1) * w + x] < threshold ||
                    mask[rowBase + (x - 1)] < threshold ||
                    mask[rowBase + (x + 1)] < threshold
                )
                if onEdge || touchesBg {
                    boundary.append((Double(x), Double(y)))
                }
            }
        }
        guard boundary.count >= 4 else { return nil }

        let hull = convexHull(of: boundary)
        guard hull.count >= 4 else { return nil }

        let cornersUV = pickFourMaxAreaCorners(hull: hull)

        // Map proto-space coords → 640 model coords (proto is 1/4 scale).
        let scale = 640.0 / 160.0
        let oX = Double(origin.x), oY = Double(origin.y)
        let points = cornersUV.map { (u, v) -> CGPoint in
            CGPoint(x: (u + oX) * scale, y: (v + oY) * scale)
        }
        return Quad(points: points)
    }

    /// Andrew's monotone chain. Returns hull vertices in CCW order (math
    /// frame, y-up). O(n log n).
    private func convexHull(of points: [(Double, Double)]) -> [(Double, Double)] {
        if points.count < 3 { return points }
        let sorted = points.sorted { $0.0 < $1.0 || ($0.0 == $1.0 && $0.1 < $1.1) }

        func cross(_ o: (Double, Double), _ a: (Double, Double), _ b: (Double, Double)) -> Double {
            (a.0 - o.0) * (b.1 - o.1) - (a.1 - o.1) * (b.0 - o.0)
        }

        var lower: [(Double, Double)] = []
        for p in sorted {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }
        var upper: [(Double, Double)] = []
        for p in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }

    /// Brute-force pick of 4 hull vertices (in their CCW order) that maximize
    /// the enclosed quadrilateral area. O(n⁴) over the hull — fine because
    /// typical YOLO seg hulls have 10–40 vertices. For a 4-vertex hull this
    /// just returns the input.
    private func pickFourMaxAreaCorners(hull: [(Double, Double)]) -> [(Double, Double)] {
        let n = hull.count
        if n == 4 { return hull }

        var bestArea = -1.0
        var best = (0, 1, 2, 3)
        for i in 0..<(n - 3) {
            for j in (i + 1)..<(n - 2) {
                for k in (j + 1)..<(n - 1) {
                    for l in (k + 1)..<n {
                        let a = quadArea(hull[i], hull[j], hull[k], hull[l])
                        if a > bestArea {
                            bestArea = a
                            best = (i, j, k, l)
                        }
                    }
                }
            }
        }
        return [hull[best.0], hull[best.1], hull[best.2], hull[best.3]]
    }

    /// Shoelace formula for a quadrilateral visited a → b → c → d.
    private func quadArea(
        _ a: (Double, Double),
        _ b: (Double, Double),
        _ c: (Double, Double),
        _ d: (Double, Double)
    ) -> Double {
        let s = a.0 * b.1 - b.0 * a.1
              + b.0 * c.1 - c.0 * b.1
              + c.0 * d.1 - d.0 * c.1
              + d.0 * a.1 - a.0 * d.1
        return abs(s) * 0.5
    }
}

// MARK: - Letterbox geometry

/// Maps coordinates between the original image and the 640×640 letterboxed
/// frame fed to the model (matches `VNCoreMLRequest`'s `.scaleFit` behavior).
private struct Letterbox {
    let imageSize: CGSize
    let modelSize: CGFloat
    /// Scale factor (modelPx / imagePx) shared by both axes under .scaleFit.
    let ratio: CGFloat
    /// Letterbox padding inside the 640×640 frame.
    let padX: CGFloat
    let padY: CGFloat

    init(imageSize: CGSize, modelSize: CGFloat) {
        self.imageSize = imageSize
        self.modelSize = modelSize
        let r = min(modelSize / imageSize.width, modelSize / imageSize.height)
        self.ratio = r
        self.padX = (modelSize - imageSize.width * r) / 2
        self.padY = (modelSize - imageSize.height * r) / 2
    }

    /// Convert a (640-space, top-left origin) point to Vision normalized
    /// (bottom-left origin, [0, 1] in the original image).
    private func unmap(point640: CGPoint) -> CGPoint {
        let imgX = (point640.x - padX) / ratio
        let imgY = (point640.y - padY) / ratio
        return CGPoint(
            x: imgX / imageSize.width,
            y: 1 - imgY / imageSize.height
        )
    }

    func unmap(rect640: CGRect) -> CGRect {
        let topLeft = unmap(point640: CGPoint(x: rect640.minX, y: rect640.minY))
        let bottomRight = unmap(point640: CGPoint(x: rect640.maxX, y: rect640.maxY))
        // After the Y flip, the "top-left" of the model rect becomes the
        // upper-y corner in Vision coords. Normalize to a positive-extent rect.
        let minX = min(topLeft.x, bottomRight.x)
        let maxX = max(topLeft.x, bottomRight.x)
        let minY = min(topLeft.y, bottomRight.y)
        let maxY = max(topLeft.y, bottomRight.y)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    func unmap(quad640: Quad) -> Quad {
        Quad(points: quad640.points.map { unmap(point640: $0) })
    }
}
