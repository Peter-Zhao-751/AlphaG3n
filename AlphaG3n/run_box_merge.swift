// Standalone smoke test for BoxMerge.merge (pure CoreGraphics).
//
// Mirrors the repo's run_*.swift convention: compile the REAL source file
// together with this @main entry point and run it.
//
// usage:
//   swiftc BoxMerge.swift run_box_merge.swift \
//       -o /tmp/box_merge && /tmp/box_merge

import Foundation
import CoreGraphics

@main
struct BoxMergeTest {

    static var failures = 0

    static func sortKey(_ r: CGRect) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        (r.minX, r.minY, r.maxX, r.maxY)
    }

    static func eq(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1e-6 && abs(a.minY - b.minY) < 1e-6
            && abs(a.maxX - b.maxX) < 1e-6 && abs(a.maxY - b.maxY) < 1e-6
    }

    // Order of merged output isn't significant, so compare as sorted sets.
    static func expect(_ actual: [CGRect], _ expected: [CGRect], _ name: String) {
        let a = actual.sorted { sortKey($0) < sortKey($1) }
        let e = expected.sorted { sortKey($0) < sortKey($1) }
        if a.count == e.count && zip(a, e).allSatisfy({ eq($0, $1) }) {
            print("  ✓ \(name)")
        } else {
            failures += 1
            print("  ✗ \(name)\n      expected \(e)\n      got      \(a)")
        }
    }

    static func main() {
        // 1. Boxes too far apart to overlap even after ×1.3 stay separate.
        expect(
            BoxMerge.merge([CGRect(x: 0, y: 0, width: 100, height: 100),
                            CGRect(x: 200, y: 0, width: 100, height: 100)],
                           enlargement: 0.30),
            [CGRect(x: 0, y: 0, width: 100, height: 100),
             CGRect(x: 200, y: 0, width: 100, height: 100)],
            "far-apart boxes stay separate")

        // 2. A 20px gap is bridged by the 30% enlargement; the unified box is the
        //    union of the ORIGINAL boxes (x 0…220), not the enlarged ones.
        expect(
            BoxMerge.merge([CGRect(x: 0, y: 0, width: 100, height: 100),
                            CGRect(x: 120, y: 0, width: 100, height: 100)],
                           enlargement: 0.30),
            [CGRect(x: 0, y: 0, width: 220, height: 100)],
            "gap bridged by enlargement merges to union of originals")

        // 3. Transitive: A–B and B–C overlap once enlarged, A–C don't; all merge.
        expect(
            BoxMerge.merge([CGRect(x: 0, y: 0, width: 100, height: 100),
                            CGRect(x: 120, y: 0, width: 100, height: 100),
                            CGRect(x: 240, y: 0, width: 100, height: 100)],
                           enlargement: 0.30),
            [CGRect(x: 0, y: 0, width: 340, height: 100)],
            "transitive overlap merges the whole chain")

        // 4. Already-overlapping boxes merge even with zero enlargement.
        expect(
            BoxMerge.merge([CGRect(x: 0, y: 0, width: 100, height: 100),
                            CGRect(x: 50, y: 0, width: 100, height: 100)],
                           enlargement: 0),
            [CGRect(x: 0, y: 0, width: 150, height: 100)],
            "overlapping boxes merge with zero enlargement")

        if failures == 0 {
            print("\nall merge checks passed")
            exit(0)
        } else {
            print("\n\(failures) merge check(s) failed")
            exit(1)
        }
    }
}
