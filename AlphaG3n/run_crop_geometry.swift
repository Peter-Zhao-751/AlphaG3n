// Standalone smoke test for BoundingBoxCropper.paddedRect (pure CoreGraphics).
//
// Mirrors the repo's run_*.swift convention: compile the REAL source file
// together with this entry point and run it. On macOS the UIKit-only crop
// helpers in BoundingBoxCropper compile out via `#if canImport(UIKit)`,
// leaving the pure margin/clamp geometry to exercise here.
//
// usage:
//   swiftc BoundingBoxCropper.swift run_crop_geometry.swift \
//       -o /tmp/crop_geometry && /tmp/crop_geometry

import Foundation
import CoreGraphics

@main
struct CropGeometryTest {

    static var failures = 0

    static func expect(_ actual: CGRect, _ expected: CGRect, _ name: String) {
        let eq = abs(actual.minX - expected.minX) < 1e-6
            && abs(actual.minY - expected.minY) < 1e-6
            && abs(actual.width - expected.width) < 1e-6
            && abs(actual.height - expected.height) < 1e-6
        if eq {
            print("  ✓ \(name)")
        } else {
            failures += 1
            print("  ✗ \(name)\n      expected \(expected)\n      got      \(actual)")
        }
    }

    static func main() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)

        // 1. An interior box grows by margin × its own dimensions on every side:
        //    dx = 0.05 × 200 = 10, dy = 0.05 × 100 = 5.
        expect(
            BoundingBoxCropper.paddedRect(CGRect(x: 100, y: 100, width: 200, height: 100),
                                          margin: 0.05, within: bounds),
            CGRect(x: 90, y: 95, width: 220, height: 110),
            "interior box grows 5% per side")

        // 2. margin 0 leaves an interior box unchanged.
        expect(
            BoundingBoxCropper.paddedRect(CGRect(x: 100, y: 100, width: 200, height: 100),
                                          margin: 0, within: bounds),
            CGRect(x: 100, y: 100, width: 200, height: 100),
            "margin 0 is identity for an interior box")

        // 3. Growth past the top-left edge clamps to bounds.
        expect(
            BoundingBoxCropper.paddedRect(CGRect(x: 0, y: 0, width: 100, height: 100),
                                          margin: 0.1, within: bounds),
            CGRect(x: 0, y: 0, width: 110, height: 110),
            "growth past top-left edge clamps to bounds")

        // 4. Growth past the bottom-right edge clamps too.
        expect(
            BoundingBoxCropper.paddedRect(CGRect(x: 900, y: 900, width: 100, height: 100),
                                          margin: 0.1, within: bounds),
            CGRect(x: 890, y: 890, width: 110, height: 110),
            "growth past bottom-right edge clamps to bounds")

        if failures == 0 {
            print("\nall geometry checks passed")
            exit(0)
        } else {
            print("\n\(failures) geometry check(s) failed")
            exit(1)
        }
    }
}
