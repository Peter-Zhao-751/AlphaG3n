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

        /// True only for CRAFT-augmented text parts; the renderer draws these red.
        public var isFromCraft: Bool {
            switch self {
            case .text(let p):  return p.isFromCraft
            case .image:        return false
            }
        }

        /// Transcribed text for text parts; the concise figure caption for image
        /// parts (empty when none was produced). The renderer draws this centered
        /// in the box for readable-text labels only — figure captions are spoken
        /// via VoiceOver, not painted onto the overlay.
        public var content: String {
            switch self {
            case .text(let p):  return p.content
            case .image(let p): return p.description
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
        /// True when this part came from CRAFT layout augmentation; the renderer
        /// draws these red to mark text the OCR API missed.
        public let isFromCraft: Bool

        public init(
            id: Int,
            label: BlockLabel,
            content: String,
            bbox: CGRect,
            polygon: [CGPoint],
            order: Int?,
            isFromCraft: Bool = false
        ) {
            self.id = id
            self.label = label
            self.content = content
            self.bbox = bbox
            self.polygon = polygon
            self.order = order
            self.isFromCraft = isFromCraft
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
        /// Concise, low-detail caption from `OpenAIClient.describeFigures`, used
        /// as the figure's spoken VoiceOver label. Empty when captioning was
        /// skipped or failed; callers fall back to the block's type name.
        public let description: String

        public init(
            id: Int,
            label: BlockLabel,
            bbox: CGRect,
            polygon: [CGPoint],
            order: Int?,
            extractedImageRef: String?,
            description: String = ""
        ) {
            self.id = id
            self.label = label
            self.bbox = bbox
            self.polygon = polygon
            self.order = order
            self.extractedImageRef = extractedImageRef
            self.description = description
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

            /// True for blocks injected by CRAFT layout augmentation rather than
            /// decoded from the OCR API. Deliberately absent from `CodingKeys`,
            /// so the API decoder ignores it and it defaults to `false`; only
            /// `LayoutAugmentation.extraBlocks` sets it `true`.
            public var isFromCraft: Bool = false

            /// Concise figure caption from `OpenAIClient.describeFigures`, spliced
            /// in by the OCR pass for graphics blocks (see `VirtualDocument.figureLabels`).
            /// Like `isFromCraft`, it's deliberately absent from `CodingKeys` — the
            /// API never sends it — and defaults to `nil`. Surfaced only through
            /// `ImagePart`, never from raw `blockContent`, so Baidu's `<img>`
            /// markdown can't leak into the spoken label.
            public var figureDescription: String? = nil

            public init(
                blockLabel: String,
                blockContent: String,
                blockBbox: [Double],
                blockId: Int,
                blockOrder: Int?,
                groupId: Int,
                blockPolygonPoints: [[Double]]?,
                isFromCraft: Bool = false,
                figureDescription: String? = nil
            ) {
                self.blockLabel = blockLabel
                self.blockContent = blockContent
                self.blockBbox = blockBbox
                self.blockId = blockId
                self.blockOrder = blockOrder
                self.groupId = groupId
                self.blockPolygonPoints = blockPolygonPoints
                self.isFromCraft = isFromCraft
                self.figureDescription = figureDescription
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

            /// Copy of this block with `blockContent` swapped out — used to splice
            /// an OpenAI transcription back into a decoded block before rendering.
            func replacingContent(_ newContent: String) -> RawBlock {
                RawBlock(
                    blockLabel: blockLabel,
                    blockContent: newContent,
                    blockBbox: blockBbox,
                    blockId: blockId,
                    blockOrder: blockOrder,
                    groupId: groupId,
                    blockPolygonPoints: blockPolygonPoints,
                    isFromCraft: isFromCraft,
                    figureDescription: figureDescription
                )
            }

            /// Copy of this block carrying a concise figure caption (see
            /// `figureDescription`) — used to splice an `OpenAIClient.describeFigures`
            /// result into a graphics block before rendering.
            func settingFigureDescription(_ description: String) -> RawBlock {
                var copy = self
                copy.figureDescription = description
                return copy
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

    /// Graphics regions captioned by a concise figure description rather than
    /// OCR'd: the `imageLabels` plus charts and seals. Every one of these becomes
    /// an `ImagePart` (so its raw markdown is dropped, never spoken) and surfaces
    /// its caption through VoiceOver. Keep in sync with `imageLabels`.
    static let figureLabels: Set<BlockLabel> = imageLabels.union([.chart, .seal])

    /// Labels whose crops carry readable prose worth sending to the OCR reader
    /// and, once read, drawing as centered text. Pure graphics (image /
    /// header_image / footer_image, chart, seal) and `unknown` are excluded.
    /// CRAFT boxes arrive labeled `.text`, so they pass this set too.
    static let readableTextLabels: Set<BlockLabel> = [
        .text, .docTitle, .paragraphTitle, .header, .footer,
        .footnote, .visionFootnote, .asideText, .number, .table, .formula
    ]

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

        if VirtualDocument.figureLabels.contains(label) {
            return .image(.init(
                id: raw.blockId,
                label: label,
                bbox: bbox,
                polygon: polygon,
                order: raw.blockOrder,
                extractedImageRef: extractImageRef(from: raw.blockContent),
                description: raw.figureDescription ?? ""
            ))
        }
        return .text(.init(
            id: raw.blockId,
            label: label,
            content: raw.blockContent,
            bbox: bbox,
            polygon: polygon,
            order: raw.blockOrder,
            isFromCraft: raw.isFromCraft
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
        /// Hard cap on points kept per overlay polygon. Polygons larger than
        /// this are simplified with Douglas-Peucker; values around 8 stay
        /// faithful to rotated text quads while throwing away noisy detours.
        public var maxPolygonPoints: Int
        /// Fraction of each polygon's bbox diagonal used as the simplification
        /// tolerance. Smaller values keep more wobble; larger values flatten
        /// the outline more aggressively.
        public var polygonSimplifyFraction: CGFloat
        /// Color of transcribed text drawn inside a box.
        public var textColor: RGBA
        /// Opaque chip drawn behind transcribed text so it stays legible over
        /// the photographed page.
        public var chipColor: RGBA
        /// Alpha of that chip. High enough to read against busy backgrounds.
        public var chipAlpha: CGFloat
        /// Text-chip corner radius, as a fraction of the chip's own height.
        public var chipCornerFraction: CGFloat
        /// Largest in-box font size tried, as a fraction of the box height.
        public var maxFontFraction: CGFloat
        /// Floor for in-box text size, in image pixels. Below this the text is
        /// truncated with an ellipsis rather than shrunk further.
        public var minFontSize: CGFloat
        /// Inset between the box edge and its text chip, as a fraction of the
        /// smaller box dimension.
        public var textPaddingFraction: CGFloat

        public init(
            lineWidth: CGFloat = 8,
            fillAlpha: CGFloat = 0.18,
            cornerRadius: CGFloat = 16,
            maxPolygonPoints: Int = 8,
            polygonSimplifyFraction: CGFloat = 0.01,
            textColor: RGBA = RGBA(r: 0.10, g: 0.10, b: 0.12),
            chipColor: RGBA = RGBA(r: 1, g: 1, b: 1),
            chipAlpha: CGFloat = 0.90,
            chipCornerFraction: CGFloat = 0.18,
            maxFontFraction: CGFloat = 0.62,
            minFontSize: CGFloat = 9,
            textPaddingFraction: CGFloat = 0.06
        ) {
            self.lineWidth = lineWidth
            self.fillAlpha = fillAlpha
            self.cornerRadius = cornerRadius
            self.maxPolygonPoints = maxPolygonPoints
            self.polygonSimplifyFraction = polygonSimplifyFraction
            self.textColor = textColor
            self.chipColor = chipColor
            self.chipAlpha = chipAlpha
            self.chipCornerFraction = chipCornerFraction
            self.maxFontFraction = maxFontFraction
            self.minFontSize = minFontSize
            self.textPaddingFraction = textPaddingFraction
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

        let rectsByID = Dictionary(uniqueKeysWithValues: parts.map {
            ($0.id, Self.axisAlignedRect(for: $0))
        })

        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: canvasSize))

            for group in groups {
                for part in group.parts {
                    guard let pageRect = rectsByID[part.id] else { continue }
                    // CRAFT-augmented boxes (text the OCR API missed) draw red;
                    // every other block is colored by its layout type.
                    let rgba = part.isFromCraft
                        ? RGBA(r: 1, g: 0, b: 0)
                        : Self.color(for: part.label)
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

                    // A readable transcription rides on an opaque chip in the box
                    // center so it stays legible over the photographed page.
                    // Graphics blocks (and unknown) carry no drawable text.
                    if Self.readableTextLabels.contains(part.label) {
                        let text = part.content.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            let boxRect = CGRect(
                                x: pageRect.minX * scaleX,
                                y: pageRect.minY * scaleY,
                                width: pageRect.width  * scaleX,
                                height: pageRect.height * scaleY
                            )
                            Self.drawCenteredText(text, in: boxRect, style: style)
                        }
                    }
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

    /// Fixed color per layout type. Red is deliberately absent — it's reserved
    /// for CRAFT-augmented boxes (text the OCR API missed) — so a type color can
    /// never be mistaken for a CRAFT box. Related types share a hue family
    /// (titles violet-ish, images magenta-ish) while staying individually
    /// distinct. Exhaustive over `BlockLabel`, so a new case forces a choice here.
    static func color(for label: BlockLabel) -> RGBA {
        switch label {
        case .text:           return RGBA(r: 0.20, g: 0.48, b: 0.95) // blue
        case .docTitle:       return RGBA(r: 0.36, g: 0.20, b: 0.80) // indigo
        case .paragraphTitle: return RGBA(r: 0.60, g: 0.30, b: 0.90) // violet
        case .header:         return RGBA(r: 0.20, g: 0.70, b: 0.95) // sky
        case .footer:         return RGBA(r: 0.40, g: 0.55, b: 0.72) // steel
        case .footnote:       return RGBA(r: 0.10, g: 0.62, b: 0.60) // teal
        case .visionFootnote: return RGBA(r: 0.22, g: 0.75, b: 0.52) // mint
        case .asideText:      return RGBA(r: 0.15, g: 0.78, b: 0.82) // cyan
        case .number:         return RGBA(r: 0.50, g: 0.55, b: 0.62) // slate
        case .table:          return RGBA(r: 0.20, g: 0.70, b: 0.30) // green
        case .formula:        return RGBA(r: 0.62, g: 0.70, b: 0.18) // olive
        case .image:          return RGBA(r: 0.62, g: 0.25, b: 0.72) // purple
        case .headerImage:    return RGBA(r: 0.85, g: 0.30, b: 0.70) // magenta
        case .footerImage:    return RGBA(r: 0.95, g: 0.45, b: 0.65) // pink
        case .chart:          return RGBA(r: 0.95, g: 0.72, b: 0.15) // gold
        case .seal:           return RGBA(r: 0.95, g: 0.55, b: 0.15) // orange
        case .unknown:        return RGBA(r: 0.55, g: 0.55, b: 0.55) // gray
        }
    }

    /// Draws `text` centered in `box` on an opaque rounded chip. The font is the
    /// largest size (capped at `maxFontFraction` of the box height) at which the
    /// wrapped text still fits; below `minFontSize` it stops shrinking and
    /// truncates with an ellipsis. The chip hugs the laid-out text — not the
    /// whole box — so a short reading gets a small label, not a giant fill.
    static func drawCenteredText(_ text: String, in box: CGRect, style: RenderStyle) {
        let pad = max(2, min(box.width, box.height) * style.textPaddingFraction)
        let avail = CGSize(width: max(1, box.width - 2 * pad),
                           height: max(1, box.height - 2 * pad))
        guard avail.width > 4, avail.height > 4 else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail

        let (font, textSize) = bestFont(for: text, fitting: avail, style: style, paragraph: paragraph)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: style.textColor.uiColor(alpha: 1),
            .paragraphStyle: paragraph
        ]

        // Chip hugs the text, clamped to the available area, centered in the box.
        let chipW = min(avail.width,  textSize.width  + 2 * pad)
        let chipH = min(avail.height, textSize.height + 2 * pad)
        let chipRect = CGRect(x: box.midX - chipW / 2,
                              y: box.midY - chipH / 2,
                              width: chipW,
                              height: chipH)
        let chipPath = UIBezierPath(roundedRect: chipRect,
                                    cornerRadius: chipH * style.chipCornerFraction)
        style.chipColor.uiColor(alpha: style.chipAlpha).setFill()
        chipPath.fill()

        // Vertically center the (possibly multi-line) text within the chip.
        let textRect = CGRect(x: chipRect.minX + pad,
                              y: chipRect.midY - textSize.height / 2,
                              width: chipRect.width - 2 * pad,
                              height: textSize.height)
        (text as NSString).draw(with: textRect,
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: attributes,
                                context: nil)
    }

    /// Largest font (≤ `maxFontFraction` of `avail.height`, ≥ `minFontSize`) at
    /// which `text` wraps to fit `avail`, plus the wrapped text's measured size.
    /// Shrinks geometrically; at the floor it returns `minFontSize` regardless
    /// and the caller's truncating draw handles any remaining overflow.
    private static func bestFont(
        for text: String,
        fitting avail: CGSize,
        style: RenderStyle,
        paragraph: NSParagraphStyle
    ) -> (UIFont, CGSize) {
        var size = max(style.minFontSize, avail.height * style.maxFontFraction)
        var measured = CGSize.zero
        var attempts = 0
        while attempts < 12 {
            let font = UIFont.systemFont(ofSize: size, weight: .medium)
            let bounds = (text as NSString).boundingRect(
                with: CGSize(width: avail.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font, .paragraphStyle: paragraph],
                context: nil
            )
            measured = CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
            if measured.height <= avail.height || size <= style.minFontSize {
                return (font, CGSize(width: min(measured.width, avail.width),
                                     height: min(measured.height, avail.height)))
            }
            size = max(style.minFontSize, size * 0.82)
            attempts += 1
        }
        let font = UIFont.systemFont(ofSize: style.minFontSize, weight: .medium)
        return (font, CGSize(width: min(measured.width, avail.width),
                             height: min(measured.height, avail.height)))
    }
}
