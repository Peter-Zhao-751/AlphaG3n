// Standalone smoke test for QRCodeDetector's PURE helpers — URL classification
// and Vision→page coordinate conversion. The Vision/UIKit detect(in:) path is
// gated behind `#if canImport(UIKit)`, so it compiles out here and only the
// pure logic is exercised (mirrors run_crop_geometry.swift).
//
// usage:
//   swiftc QRCodeDetector.swift run_qr_geometry.swift \
//       -o /tmp/qr_geometry && /tmp/qr_geometry

import Foundation
import CoreGraphics

@main
struct QRGeometryTest {

    static var failures = 0

    static func expectWeb(_ payload: String, scheme: String, host: String, _ name: String) {
        guard let url = QRCodeDetector.webURL(fromPayload: payload) else {
            failures += 1
            print("  ✗ \(name)\n      expected a \(scheme) URL, got nil")
            return
        }
        if url.scheme?.lowercased() == scheme && url.host == host {
            print("  ✓ \(name)")
        } else {
            failures += 1
            print("  ✗ \(name)\n      expected scheme=\(scheme) host=\(host)\n      got      scheme=\(url.scheme ?? "nil") host=\(url.host ?? "nil")")
        }
    }

    static func expectNotWeb(_ payload: String, _ name: String) {
        if let url = QRCodeDetector.webURL(fromPayload: payload) {
            failures += 1
            print("  ✗ \(name)\n      expected nil, got \(url.absoluteString)")
        } else {
            print("  ✓ \(name)")
        }
    }

    static func expectRect(_ actual: CGRect, _ expected: CGRect, _ name: String) {
        let e: CGFloat = 0.001
        if abs(actual.minX - expected.minX) < e, abs(actual.minY - expected.minY) < e,
           abs(actual.width - expected.width) < e, abs(actual.height - expected.height) < e {
            print("  ✓ \(name)")
        } else {
            failures += 1
            print("  ✗ \(name)\n      expected \(expected)\n      got      \(actual)")
        }
    }

    static func main() {
        print("QRCodeDetector pure-helper smoke test")

        // --- webURL: explicit http/https schemes pass ---
        expectWeb("https://example.com", scheme: "https", host: "example.com", "https URL")
        expectWeb("http://example.com/path?q=1", scheme: "http", host: "example.com", "http URL with path")
        expectWeb("HTTPS://Example.com", scheme: "https", host: "Example.com", "scheme is case-insensitive")
        expectWeb("  https://example.com  ", scheme: "https", host: "example.com", "surrounding whitespace trimmed")

        // --- webURL: schemeless but domain-like → assume https ---
        expectWeb("example.com", scheme: "https", host: "example.com", "bare domain → https")
        expectWeb("www.example.com/foo", scheme: "https", host: "www.example.com", "bare www domain with path")

        // --- webURL: non-web payloads rejected ---
        expectNotWeb("mailto:a@b.com", "mailto rejected")
        expectNotWeb("WIFI:S:net;T:WPA;P:pass;;", "wifi config rejected")
        expectNotWeb("tel:+15551234", "tel rejected")
        expectNotWeb("ftp://server/file", "ftp rejected")
        expectNotWeb("Just some plain text", "plain text rejected")
        expectNotWeb("hello", "single word rejected")
        expectNotWeb("", "empty rejected")

        // --- pageRect: Vision normalized (bottom-left) → page pixels (top-left) ---
        let page = CGSize(width: 1000, height: 800)
        expectRect(QRCodeDetector.pageRect(fromVisionNormalized: CGRect(x: 0, y: 0, width: 1, height: 1), pageSize: page),
                   CGRect(x: 0, y: 0, width: 1000, height: 800), "full frame maps to full page")
        expectRect(QRCodeDetector.pageRect(fromVisionNormalized: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), pageSize: page),
                   CGRect(x: 0, y: 400, width: 500, height: 400), "Vision bottom-left → page bottom-left (Y flipped)")
        expectRect(QRCodeDetector.pageRect(fromVisionNormalized: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.5), pageSize: page),
                   CGRect(x: 250, y: 0, width: 500, height: 400), "Vision top-middle → page top-middle")

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
