//
//  AnalysisView.swift
//  AlphaG3n
//
//  The result screen, in the LARP visual language. Draws the captured photo
//  with a box over EVERY detected region — exactly the coverage the old
//  `VirtualDocument.render()` produced — but as live overlays on the raw photo
//  rather than a baked bitmap. Each box traces the region's actual polygon
//  (the slanted quad the Modal API returns), colored by layout type with
//  CRAFT-augmented boxes in red, so nothing is squared off to an upright
//  rectangle. Text blocks with two or more sentences and website QR codes are
//  real Buttons that drill in (sentence reader / website summary); every other
//  detected region is drawn for context but isn't a tap target — matching the
//  old "see everything, tap the multi-sentence ones" behavior.
//

import SwiftUI
import Foundation

struct AnalysisView: View {
    let document: VirtualDocument
    let qrCodes: [DetectedQRCode]
    /// Discards this scan and returns to the live camera.
    let onRecapture: () -> Void

    @State private var drilldown: Drilldown?
    @State private var mounted = false

    var body: some View {
        ZStack {
            LarpTheme.bg0.ignoresSafeArea()

            VStack(spacing: 0) {
                LarpBackBar(
                    title: "Recapture",
                    accessibilityHint: "Discards this scan and returns to the camera",
                    action: onRecapture
                )
                stage
            }
        }
        .opacity(mounted ? 1 : 0)
        .onAppear { withAnimation(.easeOut(duration: 0.32)) { mounted = true } }
        .fullScreenCover(item: $drilldown) { item in
            switch item {
            case .reading(let target):
                ChunkDetailScreen(
                    title: target.title,
                    accent: target.accent,
                    sentences: target.sentences
                ) { drilldown = nil }
            case .summary(let qr):
                WebSummaryView(url: qr.url) { drilldown = nil }
            }
        }
    }

    // MARK: - Photo + detection overlay

    private var stage: some View {
        GeometryReader { geo in
            let fitted = fittedImageRect(in: geo.size)
            let matches = figureQRMatches
            ZStack(alignment: .topLeading) {
                Image(uiImage: document.image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)
                    // The analyzed photo is a backdrop only; the detection
                    // boxes layered on top are the tap targets. allowsHitTesting
                    // stops touches, but VoiceOver hit-tests the accessibility
                    // tree separately — so accessibilityHidden is what actually
                    // keeps VoiceOver from landing on the image. Same "inert"
                    // pairing the context boxes below use.
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                // Every detected region, drawn as its true (possibly slanted)
                // polygon. Interactive ones sit on top so their taps win.
                ForEach(document.parts) { part in
                    partBox(part, absorbingQR: matches.figureToQR[part.id], in: fitted)
                }
                ForEach(qrCodes.filter { !matches.absorbed.contains($0.id) }) { qr in
                    qrBox(qr, in: fitted)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(LarpTheme.bg1)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(LarpTheme.line, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 25, y: 20)
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 28)
    }

    @ViewBuilder
    private func partBox(_ part: VirtualDocument.Part, absorbingQR: DetectedQRCode?, in fitted: CGRect) -> some View {
        let screen = screenPoints(quad(for: part), in: fitted)
        let bounds = Self.bounds(of: screen)
        if bounds.width >= 2, bounds.height >= 2 {
            let rel = screen.map { CGPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY) }
            let palette = colors(for: part)
            let shape = PolygonShape(points: rel)

            if let qr = absorbingQR {
                // This figure is (mostly) a QR code — the QR detector and the
                // layout detector boxed the same region. The standalone QR box
                // is suppressed (see `figureQRMatches`); the figure itself
                // becomes the interactive QR, tapping into the website summary.
                Button {
                    drilldown = .summary(qr)
                } label: {
                    ZStack(alignment: .topLeading) {
                        shape.fill(LarpTheme.orange.opacity(0.18))
                        shape.stroke(LarpTheme.orange, lineWidth: 2)
                        tag("QR", badge: nil, color: LarpTheme.orange)
                    }
                    .frame(width: bounds.width, height: bounds.height)
                    .contentShape(shape)
                }
                .buttonStyle(.plain)
                .position(x: bounds.midX, y: bounds.midY)
                .accessibilityLabel("QR code linking to \(qr.url.host ?? "a website")")
                .accessibilityHint("Double tap to open a summary of the linked website")
                .accessibilityAddTraits(.isButton)
            } else if isInteractive(part) {
                let sentences = SentenceSplitter.sentences(in: part.content)
                let hint = sentences.count > 1
                    ? "Double tap to read sentence by sentence"
                    : "Double tap to read it and check its block type"
                Button {
                    drilldown = .reading(ReadingTarget(
                        id: part.id,
                        title: Self.displayName(for: part.label),
                        accent: palette.stroke,
                        sentences: sentences
                    ))
                } label: {
                    ZStack(alignment: .topLeading) {
                        shape.fill(palette.fill)
                        shape.stroke(palette.stroke, lineWidth: 2)
                        tag(Self.displayName(for: part.label), badge: "\(sentences.count)", color: palette.stroke)
                    }
                    .frame(width: bounds.width, height: bounds.height)
                    // Hit area = the quad, evaluated in the framed space (so it
                    // must come AFTER .frame): a slanted block taps anywhere
                    // inside its four corners, just like a rectangular one.
                    .contentShape(shape)
                }
                .buttonStyle(.plain)
                .position(x: bounds.midX, y: bounds.midY)
                .accessibilityLabel(part.content)
                .accessibilityHint(hint)
                .accessibilityAddTraits(.isButton)
            } else {
                ZStack {
                    shape.fill(palette.fill)
                    shape.stroke(palette.stroke, lineWidth: 1.5)
                }
                .frame(width: bounds.width, height: bounds.height)
                .position(x: bounds.midX, y: bounds.midY)
                // Not a drill-in target (single sentence / title / figure), but
                // still a VoiceOver element that speaks its text — so a blind
                // user reads EVERY detected region by swiping, not just the
                // multi-sentence ones. Static text, not a button (no dead-end
                // action). Touch stays off so it can't block an interactive box
                // beneath it; that alone doesn't remove it from VoiceOver, which
                // is exactly why it must be an accessibilityElement (not hidden).
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityLabel(accessibilityText(for: part))
                .accessibilityAddTraits(.isStaticText)
            }
        }
    }

    @ViewBuilder
    private func qrBox(_ qr: DetectedQRCode, in fitted: CGRect) -> some View {
        let r = screenRect(for: qr.pageRect, in: fitted)
        if r.width >= 2, r.height >= 2 {
            let stroke = LarpTheme.orange
            Button {
                drilldown = .summary(qr)
            } label: {
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(stroke.opacity(0.18))
                    Rectangle().stroke(stroke, lineWidth: 2)
                    tag("QR", badge: nil, color: stroke)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: r.width, height: r.height)
            .position(x: r.midX, y: r.midY)
            .accessibilityLabel("QR code linking to \(qr.url.host ?? "a website")")
            .accessibilityHint("Double tap to open a summary of the linked website")
            .accessibilityAddTraits(.isButton)
        }
    }

    private func tag(_ label: String, badge: String?, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label.uppercased())
                .font(LarpTheme.mono(9, weight: .bold))
                .tracking(1)
            if let badge {
                Text(badge)
                    .font(LarpTheme.mono(8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .frame(minHeight: 12)
                    .background(LarpTheme.bg0)
            }
        }
        .foregroundStyle(LarpTheme.bg0)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(color)
        .accessibilityHidden(true)
    }

    // MARK: - Geometry

    /// The aspect-fit rectangle the photo occupies inside `container`, so the
    /// page-space boxes land exactly on the displayed pixels even when
    /// `scaledToFit` letterboxes the image.
    private func fittedImageRect(in container: CGSize) -> CGRect {
        let img = document.image.size
        guard img.width > 0, img.height > 0, container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let imgAspect = img.width / img.height
        let containerAspect = container.width / container.height
        if imgAspect > containerAspect {
            let w = container.width
            let h = w / imgAspect
            return CGRect(x: 0, y: (container.height - h) / 2, width: w, height: h)
        } else {
            let h = container.height
            let w = h * imgAspect
            return CGRect(x: (container.width - w) / 2, y: 0, width: w, height: h)
        }
    }

    /// The 4-corner quad a region is drawn and hit-tested with, in page space.
    /// Detection polygons can be many-sided, organic outlines (and the odd
    /// concave one), which neither read cleanly nor make reliable tap targets —
    /// so each is reduced to its oriented 4-corner quad (the region's corners in
    /// its own rotation). Stays slanted with unequal sides, but is a convex,
    /// fully hit-testable quadrilateral. Falls back to the axis-aligned bbox
    /// corners when there's no usable polygon.
    private func quad(for part: VirtualDocument.Part) -> [CGPoint] {
        if let q = Self.orientedQuad(part.polygon) { return q }
        let b = part.bbox
        return [
            CGPoint(x: b.minX, y: b.minY),
            CGPoint(x: b.maxX, y: b.minY),
            CGPoint(x: b.maxX, y: b.maxY),
            CGPoint(x: b.minX, y: b.maxY),
        ]
    }

    /// Reduces an arbitrary region polygon to a 4-corner quad without losing its
    /// orientation: find the principal axis (second moments), de-rotate the
    /// points so the region is roughly axis-aligned, pick the four extreme
    /// corners (min/max of x±y), then map those original points back. Returns
    /// nil for degenerate input (fewer than 3 points, or corners that collapse).
    private static func orientedQuad(_ p: [CGPoint]) -> [CGPoint]? {
        guard p.count >= 3 else { return nil }
        let n = CGFloat(p.count)
        let cx = p.map(\.x).reduce(0, +) / n
        let cy = p.map(\.y).reduce(0, +) / n
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for q in p {
            let dx = Double(q.x - cx), dy = Double(q.y - cy)
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
        }
        let theta = 0.5 * atan2(2 * sxy, sxx - syy)
        let c = CGFloat(cos(theta)), s = CGFloat(sin(theta))
        func deRot(_ q: CGPoint) -> CGPoint {
            let dx = q.x - cx, dy = q.y - cy
            return CGPoint(x: dx * c + dy * s, y: -dx * s + dy * c)
        }
        let r = p.map(deRot)
        var tl = 0, tr = 0, br = 0, bl = 0
        for i in 0..<p.count {
            let sum = r[i].x + r[i].y, dif = r[i].x - r[i].y
            if sum < r[tl].x + r[tl].y { tl = i }
            if sum > r[br].x + r[br].y { br = i }
            if dif > r[tr].x - r[tr].y { tr = i }
            if dif < r[bl].x - r[bl].y { bl = i }
        }
        let idx = [tl, tr, br, bl]
        guard Set(idx).count == 4 else { return nil }
        return idx.map { p[$0] }
    }

    /// Maps page-space points onto the fitted image rect.
    private func screenPoints(_ pts: [CGPoint], in fitted: CGRect) -> [CGPoint] {
        let page = document.pageSize
        guard page.width > 0, page.height > 0 else { return [] }
        let sx = fitted.width / page.width
        let sy = fitted.height / page.height
        return pts.map { CGPoint(x: fitted.minX + $0.x * sx, y: fitted.minY + $0.y * sy) }
    }

    /// Maps a page-space rect onto the fitted image rect (used for QR codes,
    /// which carry an axis-aligned rect rather than a polygon).
    private func screenRect(for pageRect: CGRect, in fitted: CGRect) -> CGRect {
        let page = document.pageSize
        guard page.width > 0, page.height > 0 else { return .zero }
        let sx = fitted.width / page.width
        let sy = fitted.height / page.height
        return CGRect(
            x: fitted.minX + pageRect.minX * sx,
            y: fitted.minY + pageRect.minY * sy,
            width: pageRect.width * sx,
            height: pageRect.height * sy
        )
    }

    private static func bounds(of pts: [CGPoint]) -> CGRect {
        guard let first = pts.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in pts.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - Classification

    /// Text blocks worth drilling into: real text parts whose transcription
    /// holds two or more sentences. Single-sentence blocks, titles, numbers and
    /// image parts are still drawn, but stay non-interactive so there are no
    /// dead-end taps — the same rule the old result screen used.
    private func isInteractive(_ part: VirtualDocument.Part) -> Bool {
        guard case .text = part else { return false }
        // Any text block with content is a drill-in target now — even a single
        // sentence (tapping reads the line and reveals its block type).
        return !part.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isFigure(_ part: VirtualDocument.Part) -> Bool {
        VirtualDocument.imageLabels.contains(part.label)
    }

    /// Pairs each QR code with a figure it (mostly) fills, so a QR that the
    /// layout detector also boxed as a figure isn't drawn twice. A QR is
    /// "absorbed" by a figure when their overlap covers more than half the
    /// figure's area — then the figure becomes the interactive QR and the
    /// standalone QR box is dropped. A small QR inside a large photo stays its
    /// own box (the photo is genuinely a separate region).
    private var figureQRMatches: (figureToQR: [Int: DetectedQRCode], absorbed: Set<DetectedQRCode.ID>) {
        var figureToQR: [Int: DetectedQRCode] = [:]
        var absorbed: Set<DetectedQRCode.ID> = []
        let figures = document.parts.filter(isFigure)
        for qr in qrCodes {
            for figure in figures {
                let figureArea = figure.bbox.width * figure.bbox.height
                guard figureArea > 0 else { continue }
                let overlap = figure.bbox.intersection(qr.pageRect)
                guard !overlap.isNull else { continue }
                if (overlap.width * overlap.height) / figureArea > 0.5 {
                    figureToQR[figure.id] = qr
                    absorbed.insert(qr.id)
                    break
                }
            }
        }
        return (figureToQR, absorbed)
    }

    /// VoiceOver label for a non-interactive region: its transcription if it has
    /// one, otherwise its layout type (e.g. a figure with no text reads as
    /// "Figure"). Ensures every drawn box is a spoken element, never silent.
    private func accessibilityText(for part: VirtualDocument.Part) -> String {
        let content = part.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? Self.displayName(for: part.label) : content
    }

    /// Stroke + translucent fill for a part: its layout-type color, or red for
    /// CRAFT-augmented boxes — mirroring `VirtualDocument.render()`.
    private func colors(for part: VirtualDocument.Part) -> (stroke: Color, fill: Color) {
        let rgba = part.isFromCraft
            ? VirtualDocument.RGBA(r: 1, g: 0, b: 0)
            : VirtualDocument.color(for: part.label)
        let c = Color(red: Double(rgba.r), green: Double(rgba.g), blue: Double(rgba.b))
        return (c, c.opacity(0.18))
    }

    /// Short, human display name for a layout block type.
    private static func displayName(for label: VirtualDocument.BlockLabel) -> String {
        switch label {
        case .docTitle, .paragraphTitle: return "Title"
        case .text: return "Text"
        case .header: return "Header"
        case .footer: return "Footer"
        case .footnote, .visionFootnote: return "Footnote"
        case .asideText: return "Aside"
        case .number: return "Number"
        case .table: return "Table"
        case .formula: return "Formula"
        case .chart: return "Chart"
        case .seal: return "Seal"
        case .image, .headerImage, .footerImage: return "Figure"
        case .unknown: return "Block"
        }
    }
}

// MARK: - Polygon shape

/// Strokes/fills a closed polygon from points given in the view's own
/// coordinate space (relative to the box frame's origin). Used to draw the
/// slanted detection quads faithfully instead of an axis-aligned rectangle.
private struct PolygonShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count >= 2 else {
            path.addRect(rect)
            return path
        }
        path.move(to: points[0])
        for p in points.dropFirst() { path.addLine(to: p) }
        path.closeSubpath()
        return path
    }
}

// MARK: - Drilldown

/// A region the user drilled into from the analysis screen — a text block's
/// sentences (carrying the display title + accent of the tapped box), or a QR
/// code's website summary. Mutually exclusive, so one full-screen cover
/// binding drives both.
enum Drilldown: Identifiable {
    case reading(ReadingTarget)
    case summary(DetectedQRCode)

    var id: String {
        switch self {
        case .reading(let target): return "reading-\(target.id)"
        case .summary(let qr): return "summary-\(qr.id)"
        }
    }
}

/// Precomputed payload for the sentence reader: the tapped block's id (for
/// cover identity), its display title, accent color, and split sentences.
struct ReadingTarget {
    let id: Int
    let title: String
    let accent: Color
    let sentences: [String]
}

// MARK: - Chunk detail screen

/// Full-screen sentence reader opened from a text chunk: the dark detail
/// surface with a Back-to-scan bar above the shared `SentenceListView`, which
/// it drops straight into so VoiceOver lands on the first sentence.
struct ChunkDetailScreen: View {
    let title: String
    let accent: Color
    let sentences: [String]
    let onDone: () -> Void

    var body: some View {
        ZStack {
            LarpTheme.bg0.ignoresSafeArea()
            VStack(spacing: 0) {
                LarpBackBar(
                    title: "Back to scan",
                    accessibilityHint: "Closes the reader and returns to the document",
                    action: onDone
                )
                // The block type ("Title" / "Text" …) rides at the BOTTOM of the
                // list, after every sentence, so a blind user reads the block
                // then learns what kind of block it was. `focusOnAppear` lands
                // VoiceOver on the first sentence (or the type card, when a
                // single-sentence block collapses to just it) rather than the
                // Back bar above.
                SentenceListView(sentences: sentences, accent: accent, typeFooter: title, focusOnAppear: true)
            }
        }
    }
}
