//
//  LayoutAugmentation.swift
//  AlphaG3n
//
//  Merges CRAFT-detected text regions into a PaddleOCR `PrunedResult`,
//  keeping only the CRAFT boxes that don't substantially overlap an
//  existing Baidu *text* block. Figures / images / charts are skipped: the
//  API never transcribes them, so CRAFT text buried inside a figure is kept
//  rather than silently dropped. Catches text Baidu missed — CRAFT is
//  sensitive to character-level regions but doesn't transcribe, so the
//  survivors enter the document with empty content for now.
//

import Foundation
import CoreGraphics

public enum LayoutAugmentation {

    /// Default coverage threshold. A CRAFT box is dropped when, against the
    /// Baidu *text* blocks (figures/images are not considered — see
    /// `extraBlocks`), either:
    ///   * `intersection / area(craft) ≥ threshold` (CRAFT box is mostly
    ///     redrawing a Baidu text block, possibly across multiple of them), or
    ///   * any single Baidu text box is itself ≥ `threshold` covered by the
    ///     CRAFT box (CRAFT swallowed a Baidu detection).
    /// 0.6 sits in a sweet spot: tight enough to discard obvious dupes,
    /// loose enough to keep CRAFT boxes that genuinely extend past Baidu's
    /// outline.
    public static let defaultCoverageThreshold: CGFloat = 0.6

    /// CRAFT survivor boxes are grown by this fraction (after merging, before
    /// they become blocks) so the per-crop OCR gets a little margin around tight
    /// character regions. 0.10 == 10% larger (×1.1, 5% per side).
    public static let craftBoxEnlargement: CGFloat = 0.10

    /// Returns the CRAFT survivors as new `RawBlock`s ready to be appended
    /// to the Baidu `parsingResList`. Survivors are first enlarged by
    /// `mergeEnlargement` and fused where their grown forms overlap (see
    /// `BoxMerge`), so neighbouring fragments collapse into one region. IDs and
    /// group IDs continue past the highest existing values; every block gets its
    /// own group so the reading-order sort in `VirtualDocument.make` sends them
    /// to the end (they have no `blockOrder`, since CRAFT doesn't know reading
    /// order).
    public static func extraBlocks(
        craftBoxes: [CGRect],
        existing: [VirtualDocument.PrunedResult.RawBlock],
        pageSize: CGSize,
        coverageThreshold: CGFloat = defaultCoverageThreshold,
        mergeEnlargement: CGFloat = BoxMerge.defaultEnlargement,
        boxEnlargement: CGFloat = craftBoxEnlargement
    ) -> [VirtualDocument.PrunedResult.RawBlock] {
        guard !craftBoxes.isEmpty else { return [] }

        // Only blocks the OCR API will itself transcribe (text, titles, tables,
        // …) may suppress a CRAFT box — there a CRAFT detection is a genuine
        // duplicate. Figures / images / charts are never transcribed, so CRAFT
        // text that lands inside one is text the page would otherwise lose; let
        // it survive. (The id/group bases below still derive from *all* existing
        // blocks, so a new block id can't collide with a figure's.)
        let textRects = existing
            .filter { VirtualDocument.readableTextLabels.contains(
                VirtualDocument.BlockLabel(apiValue: $0.blockLabel)) }
            .map { Self.rect(fromBbox: $0.blockBbox) }
        let survivors = filterSurvivors(
            craftBoxes: craftBoxes,
            against: textRects,
            pageSize: pageSize,
            threshold: coverageThreshold
        )
        guard !survivors.isEmpty else { return [] }

        // Enlarge each survivor and fuse any whose grown forms overlap into one
        // box (the bounding rect of the pre-enlarged originals), so character /
        // word fragments collapse into a single region.
        let merged = BoxMerge.merge(survivors, enlargement: mergeEnlargement)

        // Grow the final CRAFT boxes a little so tight character regions aren't
        // clipped when cropped for OCR; clamp back inside the page.
        let pageBounds = CGRect(origin: .zero, size: pageSize)
        let finalBoxes: [CGRect] = boxEnlargement <= 0 ? merged : merged.map { box in
            let grown = box.insetBy(dx: -box.width * boxEnlargement / 2,
                                    dy: -box.height * boxEnlargement / 2)
            let clamped = grown.intersection(pageBounds)
            return clamped.isNull ? box : clamped
        }

        let baseID = (existing.map(\.blockId).max() ?? -1) + 1
        let baseGroup = (existing.map(\.groupId).max() ?? -1) + 1

        return finalBoxes.enumerated().map { offset, rect in
            VirtualDocument.PrunedResult.RawBlock(
                blockLabel: "text",
                blockContent: "",
                blockBbox: [
                    Double(rect.minX),
                    Double(rect.minY),
                    Double(rect.maxX),
                    Double(rect.maxY)
                ],
                blockId: baseID + offset,
                blockOrder: nil,
                groupId: baseGroup + offset,
                blockPolygonPoints: [
                    [Double(rect.minX), Double(rect.minY)],
                    [Double(rect.maxX), Double(rect.minY)],
                    [Double(rect.maxX), Double(rect.maxY)],
                    [Double(rect.minX), Double(rect.maxY)]
                ],
                isFromCraft: true
            )
        }
    }

    // MARK: - Filtering

    /// Spatial-grid filter. Each CRAFT box only checks Baidu boxes sharing a
    /// grid cell with it, dropping pairwise comparison from O(N·M) to O(N+M)
    /// expected when boxes are well-distributed. Cell size is sized to the
    /// page, not the box population, so the grid stays sparse even on
    /// scribble-dense documents.
    private static func filterSurvivors(
        craftBoxes: [CGRect],
        against baiduRects: [CGRect],
        pageSize: CGSize,
        threshold: CGFloat
    ) -> [CGRect] {
        guard !baiduRects.isEmpty else { return craftBoxes }

        let cellSize = max(pageSize.width, pageSize.height) / 30
        let cell = max(cellSize, 1)

        var grid: [GridKey: [Int]] = [:]
        for (idx, rect) in baiduRects.enumerated() {
            for key in cellsCovered(by: rect, cellSize: cell) {
                grid[key, default: []].append(idx)
            }
        }

        var survivors: [CGRect] = []
        survivors.reserveCapacity(craftBoxes.count)
        var seen = Set<Int>()

        for craft in craftBoxes {
            let craftArea = craft.width * craft.height
            guard craftArea > 0 else { continue }

            seen.removeAll(keepingCapacity: true)
            for key in cellsCovered(by: craft, cellSize: cell) {
                guard let bucket = grid[key] else { continue }
                for idx in bucket { seen.insert(idx) }
            }

            var totalIntersection: CGFloat = 0
            var baiduSwallowed = false

            for idx in seen {
                let baidu = baiduRects[idx]
                let inter = craft.intersection(baidu)
                guard !inter.isNull, !inter.isEmpty else { continue }
                let interArea = inter.width * inter.height
                totalIntersection += interArea

                let baiduArea = baidu.width * baidu.height
                if baiduArea > 0, interArea / baiduArea >= threshold {
                    baiduSwallowed = true
                    break
                }
            }

            if baiduSwallowed { continue }
            if totalIntersection / craftArea >= threshold { continue }
            survivors.append(craft)
        }

        return survivors
    }

    // MARK: - Geometry helpers

    private struct GridKey: Hashable {
        let x: Int
        let y: Int
    }

    private static func cellsCovered(by rect: CGRect, cellSize: CGFloat) -> [GridKey] {
        guard rect.width > 0, rect.height > 0 else { return [] }
        let minCx = Int(floor(rect.minX / cellSize))
        let maxCx = Int(floor(rect.maxX / cellSize))
        let minCy = Int(floor(rect.minY / cellSize))
        let maxCy = Int(floor(rect.maxY / cellSize))
        var keys: [GridKey] = []
        keys.reserveCapacity((maxCx - minCx + 1) * (maxCy - minCy + 1))
        for cx in minCx...maxCx {
            for cy in minCy...maxCy {
                keys.append(GridKey(x: cx, y: cy))
            }
        }
        return keys
    }

    /// Matches the layout used by `VirtualDocument` internally: `[x, y, r, b]`
    /// in page coords, with the right/bottom being absolute (not width/height).
    private static func rect(fromBbox bbox: [Double]) -> CGRect {
        guard bbox.count >= 4 else { return .zero }
        return CGRect(
            x: bbox[0],
            y: bbox[1],
            width: bbox[2] - bbox[0],
            height: bbox[3] - bbox[1]
        )
    }
}
