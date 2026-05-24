//
//  BoxMerge.swift
//  AlphaG3n
//
//  Enlarge-then-merge for CRAFT survivor boxes. Each box is grown by a fixed
//  fraction, boxes whose grown forms overlap are grouped (transitively), and
//  each group collapses to the bounding rect of its ORIGINAL (pre-enlarged)
//  boxes. The enlargement only decides what merges — it never inflates the
//  result. Pure CoreGraphics so it can be unit-tested standalone
//  (run_box_merge.swift).
//

import Foundation
import CoreGraphics

public enum BoxMerge {

    /// Default proximity enlargement: 0.30 == 30% larger (×1.3, 15% per side).
    public static let defaultEnlargement: CGFloat = 0.30

    public static func merge(_ boxes: [CGRect], enlargement: CGFloat = defaultEnlargement) -> [CGRect] {
        guard boxes.count > 1 else { return boxes }

        // Grow each box by `enlargement` total (centered): width → width·(1+f).
        let grown = boxes.map { $0.insetBy(dx: -$0.width * enlargement / 2,
                                           dy: -$0.height * enlargement / 2) }

        // Union-find: connect boxes whose grown forms intersect, transitively.
        var parent = Array(0..<boxes.count)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for i in 0..<boxes.count {
            for j in (i + 1)..<boxes.count where grown[i].intersects(grown[j]) {
                parent[find(i)] = find(j)
            }
        }

        // Each group collapses to the bounding rect of its ORIGINAL boxes.
        var unified: [Int: CGRect] = [:]
        for i in 0..<boxes.count {
            let root = find(i)
            unified[root] = unified[root]?.union(boxes[i]) ?? boxes[i]
        }
        return Array(unified.values)
    }
}
