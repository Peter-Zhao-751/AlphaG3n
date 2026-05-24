//
//  VirtualDocument.swift
//  AlphaG3n
//

import Foundation
import UIKit
import CoreGraphics

// MARK: - VirtualDocument

public struct VirtualDocument: @unchecked Sendable {
    public let image: UIImage
    public let pageSize: CGSize
    public let groups: [Group]

    public init(image: UIImage, pageSize: CGSize, groups: [Group]) {
        self.image = image
        self.pageSize = pageSize
        self.groups = groups
    }

    public var parts: [Part] { groups.flatMap(\.parts) }
}

// MARK: - Nested types

public extension VirtualDocument {

    enum BlockLabel: String, Sendable, Hashable {
        case docTitle = "doc_title"
        case paragraphTitle = "paragraph_title"
        case text
        case image
        case header
        case headerImage = "header_image"
        case footer
        case footerImage = "footer_image"
        case visionFootnote = "vision_footnote"
        case asideText = "aside_text"
        case footnote
        case number
        case table
        case formula
        case chart
        case seal
        case unknown

        init(apiValue: String) {
            self = BlockLabel(rawValue: apiValue) ?? .unknown
        }
    }

    struct Group: Sendable, Identifiable, Hashable {
        public let id: Int
        public let parts: [Part]

        public init(id: Int, parts: [Part]) {
            self.id = id
            self.parts = parts
        }
    }

    enum Part: Sendable, Identifiable, Hashable {
        case text(TextPart)
        case image(ImagePart)

        public var id: Int {
            switch self {
            case .text(let p):  return p.id
            case .image(let p): return p.id
            }
        }

        public var label: BlockLabel {
            switch self {
            case .text(let p):  return p.label
            case .image(let p): return p.label
            }
        }

        public var bbox: CGRect {
            switch self {
            case .text(let p):  return p.bbox
            case .image(let p): return p.bbox
            }
        }

        public var polygon: [CGPoint] {
            switch self {
            case .text(let p):  return p.polygon
            case .image(let p): return p.polygon
            }
        }

        public var order: Int? {
            switch self {
            case .text(let p):  return p.order
            case .image(let p): return p.order
            }
        }
    }

    struct TextPart: Sendable, Identifiable, Hashable {
        public let id: Int
        public let label: BlockLabel
        public let content: String
        public let bbox: CGRect
        public let polygon: [CGPoint]
        public let order: Int?

        public init(
            id: Int,
            label: BlockLabel,
            content: String,
            bbox: CGRect,
            polygon: [CGPoint],
            order: Int?
        ) {
            self.id = id
            self.label = label
            self.content = content
            self.bbox = bbox
            self.polygon = polygon
            self.order = order
        }
    }

    struct ImagePart: Sendable, Identifiable, Hashable {
        public let id: Int
        public let label: BlockLabel
        public let bbox: CGRect
        public let polygon: [CGPoint]
        public let order: Int?
        /// Relative path of the cropped image asset embedded by the API
        /// (e.g. `imgs/img_in_image_box_2300_1828_2879_2438.jpg`), parsed
        /// out of the block's markdown `<img src="…">` snippet.
        public let extractedImageRef: String?

        public init(
            id: Int,
            label: BlockLabel,
            bbox: CGRect,
            polygon: [CGPoint],
            order: Int?,
            extractedImageRef: String?
        ) {
            self.id = id
            self.label = label
            self.bbox = bbox
            self.polygon = polygon
            self.order = order
            self.extractedImageRef = extractedImageRef
        }
    }
}

// MARK: - Decoder for the API's prunedResult payload

public extension VirtualDocument {

    struct PrunedResult: Decodable, Sendable {
        public let width: Int
        public let height: Int
        public let parsingResList: [RawBlock]

        public struct RawBlock: Decodable, Sendable {
            public let blockLabel: String
            public let blockContent: String
            public let blockBbox: [Double]
            public let blockId: Int
            public let blockOrder: Int?
            public let groupId: Int
            public let blockPolygonPoints: [[Double]]?

            public init(
                blockLabel: String,
                blockContent: String,
                blockBbox: [Double],
                blockId: Int,
                blockOrder: Int?,
                groupId: Int,
                blockPolygonPoints: [[Double]]?
            ) {
                self.blockLabel = blockLabel
                self.blockContent = blockContent
                self.blockBbox = blockBbox
                self.blockId = blockId
                self.blockOrder = blockOrder
                self.groupId = groupId
                self.blockPolygonPoints = blockPolygonPoints
            }

            enum CodingKeys: String, CodingKey {
                case blockLabel = "block_label"
                case blockContent = "block_content"
                case blockBbox = "block_bbox"
                case blockId = "block_id"
                case blockOrder = "block_order"
                case groupId = "group_id"
                case blockPolygonPoints = "block_polygon_points"
            }
        }

        public init(width: Int, height: Int, parsingResList: [RawBlock]) {
            self.width = width
            self.height = height
            self.parsingResList = parsingResList
        }

        enum CodingKeys: String, CodingKey {
            case width
            case height
            case parsingResList = "parsing_res_list"
        }
    }
}

// MARK: - Factory

public extension VirtualDocument {

    static let imageLabels: Set<BlockLabel> = [.image, .footerImage, .headerImage]

    static func make(from pruned: PrunedResult, image: UIImage) -> VirtualDocument {
        let pageSize = CGSize(width: pruned.width, height: pruned.height)

        var groupOrder: [Int] = []
        var grouped: [Int: [PrunedResult.RawBlock]] = [:]
        for block in pruned.parsingResList {
            if grouped[block.groupId] == nil {
                grouped[block.groupId] = []
                groupOrder.append(block.groupId)
            }
            grouped[block.groupId]?.append(block)
        }

        var groups: [Group] = groupOrder.map { gid in
            let blocks = (grouped[gid] ?? []).sorted { lhs, rhs in
                let l = lhs.blockOrder ?? .max
                let r = rhs.blockOrder ?? .max
                if l != r { return l < r }
                return lhs.blockId < rhs.blockId
            }
            return Group(id: gid, parts: blocks.map(Part.from(raw:)))
        }

        // Groups with at least one ordered block come first (in reading order);
        // unordered groups (images, decoration) sort to the end by group id.
        groups.sort { lhs, rhs in
            let l = lhs.parts.compactMap(\.order).min() ?? .max
            let r = rhs.parts.compactMap(\.order).min() ?? .max
            if l != r { return l < r }
            return lhs.id < rhs.id
        }

        return VirtualDocument(image: image, pageSize: pageSize, groups: groups)
    }
}

private extension VirtualDocument.Part {
    static func from(raw: VirtualDocument.PrunedResult.RawBlock) -> VirtualDocument.Part {
        let label = VirtualDocument.BlockLabel(apiValue: raw.blockLabel)
        let bbox = CGRect.from(bbox: raw.blockBbox)
        let polygon = (raw.blockPolygonPoints ?? []).compactMap { pair -> CGPoint? in
            guard pair.count >= 2 else { return nil }
            return CGPoint(x: pair[0], y: pair[1])
        }

        if VirtualDocument.imageLabels.contains(label) {
            return .image(.init(
                id: raw.blockId,
                label: label,
                bbox: bbox,
                polygon: polygon,
                order: raw.blockOrder,
                extractedImageRef: extractImageRef(from: raw.blockContent)
            ))
        }
        return .text(.init(
            id: raw.blockId,
            label: label,
            content: raw.blockContent,
            bbox: bbox,
            polygon: polygon,
            order: raw.blockOrder
        ))
    }
}

private func extractImageRef(from content: String) -> String? {
    guard let srcRange = content.range(of: "src=\"") else { return nil }
    let after = content[srcRange.upperBound...]
    guard let closing = after.firstIndex(of: "\"") else { return nil }
    return String(after[..<closing])
}

private extension CGRect {
    static func from(bbox: [Double]) -> CGRect {
        guard bbox.count >= 4 else { return .zero }
        let (x, y, r, b) = (bbox[0], bbox[1], bbox[2], bbox[3])
        return CGRect(x: x, y: y, width: r - x, height: b - y)
    }
}

// MARK: - Rendering

public extension VirtualDocument {

    /// Sendable color triple. UIColor isn't Sendable under strict concurrency,
    /// so the palette is stored as RGBA and materialised to UIColor at draw time.
    struct RGBA: Sendable, Hashable {
        public var r: CGFloat
        public var g: CGFloat
        public var b: CGFloat

        public init(r: CGFloat, g: CGFloat, b: CGFloat) {
            self.r = r; self.g = g; self.b = b
        }

        public func uiColor(alpha: CGFloat = 1) -> UIColor {
            UIColor(red: r, green: g, blue: b, alpha: alpha)
        }
    }

    struct RenderStyle: Sendable {
        public var lineWidth: CGFloat
        public var fillAlpha: CGFloat
        public var cornerRadius: CGFloat
        /// HSL saturation for generated pastel colors. ~0.40 produces soft pastels.
        public var saturation: CGFloat
        /// HSL lightness for generated pastel colors. ~0.82 keeps fills airy.
        public var lightness: CGFloat
        /// Two parts whose rectangles are within this fraction of the page
        /// diagonal are considered neighbors that must receive contrasting hues.
        public var adjacencyFraction: CGFloat
        /// Number of distinct pastel hues used by the contrast-aware palette.
        /// 48 keeps consecutive selections well-separated without bloating the
        /// per-part picker loop.
        public var paletteSize: Int
        /// Hard cap on points kept per overlay polygon. Polygons larger than
        /// this are simplified with Douglas-Peucker; values around 8 stay
        /// faithful to rotated text quads while throwing away noisy detours.
        public var maxPolygonPoints: Int
        /// Fraction of each polygon's bbox diagonal used as the simplification
        /// tolerance. Smaller values keep more wobble; larger values flatten
        /// the outline more aggressively.
        public var polygonSimplifyFraction: CGFloat

        public init(
            lineWidth: CGFloat = 8,
            fillAlpha: CGFloat = 0.25,
            cornerRadius: CGFloat = 16,
            saturation: CGFloat = 0.42,
            lightness: CGFloat = 0.82,
            adjacencyFraction: CGFloat = 0.12,
            paletteSize: Int = 48,
            maxPolygonPoints: Int = 8,
            polygonSimplifyFraction: CGFloat = 0.01
        ) {
            self.lineWidth = lineWidth
            self.fillAlpha = fillAlpha
            self.cornerRadius = cornerRadius
            self.saturation = saturation
            self.lightness = lightness
            self.adjacencyFraction = adjacencyFraction
            self.paletteSize = paletteSize
            self.maxPolygonPoints = maxPolygonPoints
            self.polygonSimplifyFraction = polygonSimplifyFraction
        }

        public static let `default` = RenderStyle()
    }

    /// Draws the source image with a color-coded overlay for each part.
    /// Coordinates from the API are in `pageSize` space; they're scaled to the
    /// underlying image's pixel size at draw time.
    func render(style: RenderStyle = .default) -> UIImage {
        let canvasSize = image.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true

        let scaleX = pageSize.width  > 0 ? canvasSize.width  / pageSize.width  : 1
        let scaleY = pageSize.height > 0 ? canvasSize.height / pageSize.height : 1

        let allParts = parts
        let rectsByID = Dictionary(uniqueKeysWithValues: allParts.map {
            ($0.id, Self.axisAlignedRect(for: $0))
        })
        let colors = Self.assignColors(parts: allParts, rects: rectsByID, pageSize: pageSize, style: style)

        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: canvasSize))

            for group in groups {
                for part in group.parts {
                    guard let pageRect = rectsByID[part.id] else { continue }
                    let rgba = colors[part.id] ?? RGBA(r: 0.5, g: 0.5, b: 0.5)
                    let path = Self.overlayPath(
                        for: part,
                        bboxFallback: pageRect,
                        scaleX: scaleX,
                        scaleY: scaleY,
                        style: style
                    )

                    rgba.uiColor(alpha: style.fillAlpha).setFill()
                    path.fill()
                    rgba.uiColor(alpha: 1).setStroke()
                    path.lineWidth = style.lineWidth
                    path.stroke()
                }
            }
        }
    }

    /// Page-coordinate axis-aligned rectangle for a part. Used as a cheap
    /// proximity proxy when picking contrast colors — *not* the drawn shape.
    /// The drawn outline comes from `overlayPath(for:...)` and follows the
    /// polygon so tilted blocks don't get inflated to a loose AABB.
    static func axisAlignedRect(for part: Part) -> CGRect {
        if part.polygon.count >= 2 {
            let xs = part.polygon.map(\.x)
            let ys = part.polygon.map(\.y)
            if let minX = xs.min(), let maxX = xs.max(),
               let minY = ys.min(), let maxY = ys.max(),
               maxX > minX, maxY > minY {
                return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }
        }
        return part.bbox
    }

    /// Bezier path traced from the polygon (Douglas-Peucker simplified to at
    /// most `style.maxPolygonPoints`). Falls back to a rounded rectangle of
    /// `bboxFallback` when no polygon is provided, since a single axis-aligned
    /// box is the best we can do without corner data.
    static func overlayPath(
        for part: Part,
        bboxFallback: CGRect,
        scaleX: CGFloat,
        scaleY: CGFloat,
        style: RenderStyle
    ) -> UIBezierPath {
        let simplified = smartPolygon(
            part.polygon,
            maxPoints: max(3, style.maxPolygonPoints),
            simplifyFraction: max(0, style.polygonSimplifyFraction)
        )
        guard simplified.count >= 3 else {
            let r = CGRect(
                x: bboxFallback.minX * scaleX,
                y: bboxFallback.minY * scaleY,
                width: bboxFallback.width  * scaleX,
                height: bboxFallback.height * scaleY
            )
            return UIBezierPath(roundedRect: r, cornerRadius: style.cornerRadius)
        }
        let path = UIBezierPath()
        let scaled = simplified.map { CGPoint(x: $0.x * scaleX, y: $0.y * scaleY) }
        path.move(to: scaled[0])
        for p in scaled.dropFirst() { path.addLine(to: p) }
        path.close()
        return path
    }

    /// Drops collinear and near-duplicate points, then applies Douglas-Peucker
    /// with a tolerance derived from the polygon's own bbox so the per-block
    /// budget scales with how big the block actually is. The returned polygon
    /// is the original outline pared down to its most meaningful vertices —
    /// a 4-point quad survives intact; an OCR scribble with dozens of points
    /// collapses to a handful.
    static func smartPolygon(
        _ points: [CGPoint],
        maxPoints: Int,
        simplifyFraction: CGFloat
    ) -> [CGPoint] {
        guard points.count >= 3 else { return points }

        let cleaned = dropConsecutiveDuplicates(points)
        guard cleaned.count >= 3 else { return cleaned }
        if cleaned.count <= maxPoints {
            // Already sparse; only strip strictly collinear vertices so the
            // path renderer doesn't waste segments on straight runs.
            let pruned = dropCollinear(cleaned, epsilon: 0.5)
            return pruned.count >= 3 ? pruned : cleaned
        }

        // Diagonal of the polygon's own bounding box drives epsilon. Without
        // this, a small block and a full-page block would share the same
        // absolute tolerance, which over-simplifies the small one.
        var minX = cleaned[0].x, maxX = cleaned[0].x
        var minY = cleaned[0].y, maxY = cleaned[0].y
        for p in cleaned.dropFirst() {
            if p.x < minX { minX = p.x }
            if p.x > maxX { maxX = p.x }
            if p.y < minY { minY = p.y }
            if p.y > maxY { maxY = p.y }
        }
        let diag = sqrt((maxX - minX) * (maxX - minX) + (maxY - minY) * (maxY - minY))
        var epsilon = max(0.5, diag * simplifyFraction)

        var result = douglasPeuckerClosed(cleaned, epsilon: epsilon)
        // Bounded retries: if simplification didn't get under the cap, grow
        // the tolerance geometrically. Capped iterations so this can never run
        // away even on pathological inputs.
        var attempts = 0
        while result.count > maxPoints && attempts < 8 {
            epsilon *= 1.7
            result = douglasPeuckerClosed(cleaned, epsilon: epsilon)
            attempts += 1
        }
        return result.count >= 3 ? result : cleaned
    }

    private static func dropConsecutiveDuplicates(_ points: [CGPoint]) -> [CGPoint] {
        guard let first = points.first else { return points }
        var out: [CGPoint] = [first]
        out.reserveCapacity(points.count)
        for p in points.dropFirst() where !nearlyEqual(p, out.last ?? p) {
            out.append(p)
        }
        if out.count > 1, nearlyEqual(out.first!, out.last!) { out.removeLast() }
        return out
    }

    private static func dropCollinear(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard points.count >= 3 else { return points }
        var out: [CGPoint] = []
        out.reserveCapacity(points.count)
        let n = points.count
        for i in 0..<n {
            let prev = points[(i + n - 1) % n]
            let curr = points[i]
            let next = points[(i + 1) % n]
            if perpendicularDistance(curr, lineStart: prev, lineEnd: next) > epsilon {
                out.append(curr)
            }
        }
        return out.count >= 3 ? out : points
    }

    /// Douglas-Peucker on a closed polygon: split at the two points farthest
    /// from the diameter, then simplify each half as an open polyline.
    private static func douglasPeuckerClosed(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard points.count >= 3 else { return points }
        // Pick two anchor points roughly opposite each other to seed the split.
        var maxDist: CGFloat = -1
        var anchorA = 0
        var anchorB = 0
        for i in 0..<points.count {
            for j in (i + 1)..<points.count {
                let dx = points[i].x - points[j].x
                let dy = points[i].y - points[j].y
                let d = dx * dx + dy * dy
                if d > maxDist {
                    maxDist = d
                    anchorA = i
                    anchorB = j
                }
            }
        }
        if anchorA == anchorB { return points }
        let (lo, hi) = anchorA < anchorB ? (anchorA, anchorB) : (anchorB, anchorA)
        let forward = Array(points[lo...hi])
        let backward = Array(points[hi..<points.count]) + Array(points[0...lo])
        let fSimp = douglasPeucker(forward, epsilon: epsilon)
        let bSimp = douglasPeucker(backward, epsilon: epsilon)
        // Both halves share the anchors; drop the duplicated endpoint when stitching.
        let stitched = fSimp + bSimp.dropFirst().dropLast()
        return stitched
    }

    private static func douglasPeucker(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        let first = points.first!
        let last = points.last!
        var maxDist: CGFloat = 0
        var index = 0
        for i in 1..<(points.count - 1) {
            let d = perpendicularDistance(points[i], lineStart: first, lineEnd: last)
            if d > maxDist {
                maxDist = d
                index = i
            }
        }
        if maxDist > epsilon, index > 0 {
            let left = douglasPeucker(Array(points[0...index]), epsilon: epsilon)
            let right = douglasPeucker(Array(points[index..<points.count]), epsilon: epsilon)
            return left + right.dropFirst()
        }
        return [first, last]
    }

    private static func perpendicularDistance(_ p: CGPoint, lineStart a: CGPoint, lineEnd b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        if lenSq <= .ulpOfOne {
            let ex = p.x - a.x
            let ey = p.y - a.y
            return sqrt(ex * ex + ey * ey)
        }
        let num = abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x)
        return num / sqrt(lenSq)
    }

    private static func nearlyEqual(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5
    }

    /// Welsh-Powell graph coloring on a pre-built pastel palette. Parts that
    /// sit near each other on the page get palette indices whose minimum
    /// cyclic distance to neighbors is maximised, so adjacent overlays stay
    /// visually distinct without falling back to a fixed label-keyed lookup.
    /// Adjacency is built with a spatial grid so total cost is roughly O(N)
    /// expected even for documents with thousands of blocks.
    static func assignColors(
        parts: [Part],
        rects: [Int: CGRect],
        pageSize: CGSize,
        style: RenderStyle
    ) -> [Int: RGBA] {
        guard !parts.isEmpty else { return [:] }

        let diagonal = sqrt(pageSize.width * pageSize.width + pageSize.height * pageSize.height)
        let threshold = max(1, diagonal * style.adjacencyFraction)
        let neighbors = buildAdjacency(parts: parts, rects: rects, threshold: threshold)

        let paletteSize = max(8, style.paletteSize)
        let goldenStep: CGFloat = 0.6180339887498949
        let palette: [RGBA] = (0..<paletteSize).map { i in
            let hue = (CGFloat(i) * goldenStep).truncatingRemainder(dividingBy: 1)
            return pastelRGBA(hue: hue, saturation: style.saturation, lightness: style.lightness)
        }

        // Welsh-Powell: highest-degree parts first, stable id tiebreak.
        let order = parts.sorted { lhs, rhs in
            let ln = neighbors[lhs.id]?.count ?? 0
            let rn = neighbors[rhs.id]?.count ?? 0
            if ln != rn { return ln > rn }
            return lhs.id < rhs.id
        }

        var assigned: [Int: Int] = [:]
        assigned.reserveCapacity(parts.count)
        for (rank, part) in order.enumerated() {
            let used = (neighbors[part.id] ?? []).reduce(into: Set<Int>()) { acc, n in
                if let idx = assigned[n] { acc.insert(idx) }
            }
            assigned[part.id] = pickPaletteIndex(
                avoiding: used,
                paletteSize: paletteSize,
                fallback: rank
            )
        }

        return assigned.mapValues { palette[$0] }
    }

    /// Spatial-hash adjacency: bucket each rect into grid cells sized by the
    /// proximity threshold, then only compare rects sharing a cell. Expected
    /// O(N) when blocks are well-distributed.
    private static func buildAdjacency(
        parts: [Part],
        rects: [Int: CGRect],
        threshold: CGFloat
    ) -> [Int: [Int]] {
        var neighbors: [Int: [Int]] = [:]
        let cell = max(threshold, 1)

        var grid: [GridKey: [Int]] = [:]
        var partCells: [Int: [GridKey]] = [:]
        partCells.reserveCapacity(parts.count)

        for part in parts {
            guard let r = rects[part.id] else { continue }
            let minCx = Int(floor((r.minX - threshold) / cell))
            let maxCx = Int(floor((r.maxX + threshold) / cell))
            let minCy = Int(floor((r.minY - threshold) / cell))
            let maxCy = Int(floor((r.maxY + threshold) / cell))
            var keys: [GridKey] = []
            keys.reserveCapacity((maxCx - minCx + 1) * (maxCy - minCy + 1))
            for cx in minCx...maxCx {
                for cy in minCy...maxCy {
                    let key = GridKey(x: cx, y: cy)
                    keys.append(key)
                    grid[key, default: []].append(part.id)
                }
            }
            partCells[part.id] = keys
        }

        let thresholdSq = threshold * threshold
        for part in parts {
            guard let a = rects[part.id], let keys = partCells[part.id] else { continue }
            var seen = Set<Int>()
            seen.insert(part.id)
            var partNeighbors: [Int] = []
            for key in keys {
                guard let bucket = grid[key] else { continue }
                for otherID in bucket where seen.insert(otherID).inserted {
                    guard let b = rects[otherID] else { continue }
                    if rectGapSquared(a, b) <= thresholdSq {
                        partNeighbors.append(otherID)
                    }
                }
            }
            if !partNeighbors.isEmpty {
                neighbors[part.id] = partNeighbors
            }
        }
        return neighbors
    }

    private struct GridKey: Hashable {
        let x: Int
        let y: Int
    }

    /// Squared edge-to-edge distance between two axis-aligned rectangles.
    /// Avoids a `sqrt` on the hot adjacency path. Overlap returns 0.
    private static func rectGapSquared(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = max(0, max(a.minX - b.maxX, b.minX - a.maxX))
        let dy = max(0, max(a.minY - b.maxY, b.minY - a.maxY))
        return dx * dx + dy * dy
    }

    /// Picks the palette index whose minimum cyclic distance to any used
    /// index is maximised. Falls back to `rank` (modulo palette size) when no
    /// neighbors have been colored yet so disconnected components spread out.
    private static func pickPaletteIndex(
        avoiding used: Set<Int>,
        paletteSize: Int,
        fallback: Int
    ) -> Int {
        if used.isEmpty {
            return ((fallback % paletteSize) + paletteSize) % paletteSize
        }
        var bestIdx = 0
        var bestDist = -1
        for c in 0..<paletteSize {
            if used.contains(c) { continue }
            var minDist = paletteSize
            for u in used {
                let raw = abs(c - u)
                let d = min(raw, paletteSize - raw)
                if d < minDist { minDist = d }
            }
            if minDist > bestDist {
                bestDist = minDist
                bestIdx = c
            }
        }
        return bestIdx
    }

    /// HSL→RGB. Combined with low saturation and high lightness this yields a
    /// procedurally unbounded pastel palette.
    private static func pastelRGBA(hue: CGFloat, saturation: CGFloat, lightness: CGFloat) -> RGBA {
        let h = ((hue.truncatingRemainder(dividingBy: 1)) + 1).truncatingRemainder(dividingBy: 1)
        let c = (1 - abs(2 * lightness - 1)) * saturation
        let hp = h * 6
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let m = lightness - c / 2
        let (r1, g1, b1): (CGFloat, CGFloat, CGFloat)
        switch hp {
        case ..<1: (r1, g1, b1) = (c, x, 0)
        case ..<2: (r1, g1, b1) = (x, c, 0)
        case ..<3: (r1, g1, b1) = (0, c, x)
        case ..<4: (r1, g1, b1) = (0, x, c)
        case ..<5: (r1, g1, b1) = (x, 0, c)
        default:   (r1, g1, b1) = (c, 0, x)
        }
        return RGBA(r: r1 + m, g: g1 + m, b: b1 + m)
    }
}
