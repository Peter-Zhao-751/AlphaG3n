//
//  QRCodeDetector.swift
//  AlphaG3n
//
//  Finds QR codes in a scanned page and keeps only the ones that link to a
//  website — the result screen turns those into tappable targets that open a
//  spoken summary of the linked page (see WebSummaryView). Detection is
//  on-device Vision work done once at capture time; the website itself is never
//  visited until the user taps (see WebSummarizer).
//
//  Split so the testable logic compiles without a device:
//    • `webURL(fromPayload:)` + `pageRect(fromVisionNormalized:pageSize:)` are
//      pure Foundation/CoreGraphics and are smoke-tested by run_qr_geometry.swift.
//    • `detect(in:pageSize:)` is the Vision/UIKit pass, gated behind
//      `#if canImport(UIKit)` so the pure helpers build standalone.
//

import Foundation
import CoreGraphics

/// One QR code found in a scanned page that links to a website. `pageRect` is in
/// the document's page coordinate frame (top-left origin, same frame as
/// `VirtualDocument.Part.bbox`), so the result overlay positions its tap target
/// with the existing page→view scale.
struct DetectedQRCode: Sendable, Identifiable, Hashable {
    let url: URL
    /// The raw decoded QR string (kept for the accessibility label / debugging).
    let payload: String
    let pageRect: CGRect

    /// Stable across the value's lifetime and unique per (region, link), so it
    /// can drive a SwiftUI `ForEach` and `fullScreenCover(item:)`.
    var id: String {
        "\(pageRect.minX),\(pageRect.minY),\(pageRect.width),\(pageRect.height)|\(url.absoluteString)"
    }
}

enum QRCodeDetector {

    /// Turns a QR payload into an http/https `URL`, or `nil` when it isn't a
    /// website link. Rejects other URI schemes (mailto, tel, WIFI:, ftp, …) and
    /// free text; accepts a bare domain ("example.com") by assuming https, which
    /// is how site links are most often encoded without a scheme.
    static func webURL(fromPayload payload: String) -> URL? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // An explicit URI scheme (letter then letters/digits/+-. up to ':').
        // Only http/https survive; everything else is a non-web QR.
        if let schemeRange = trimmed.range(of: "^[A-Za-z][A-Za-z0-9+.\\-]*:",
                                           options: .regularExpression) {
            let scheme = trimmed[schemeRange].dropLast().lowercased()
            guard scheme == "http" || scheme == "https" else { return nil }
            guard let url = URL(string: trimmed), url.host != nil else { return nil }
            return url
        }

        // No scheme: only treat it as a link if it reads like a bare domain —
        // a dot and no whitespace. Otherwise it's plain text, not a URL.
        guard trimmed.contains("."),
              !trimmed.contains(where: { $0.isWhitespace }),
              let url = URL(string: "https://\(trimmed)"), url.host != nil
        else { return nil }
        return url
    }

    /// Converts a Vision bounding box (normalized [0,1], **bottom-left** origin)
    /// into a rect in page pixels with a **top-left** origin — the frame the OCR
    /// layout and the renderer use — flipping Y in the process.
    static func pageRect(fromVisionNormalized bb: CGRect, pageSize: CGSize) -> CGRect {
        CGRect(
            x: bb.minX * pageSize.width,
            y: (1 - bb.maxY) * pageSize.height,
            width: bb.width * pageSize.width,
            height: bb.height * pageSize.height
        )
    }
}

#if canImport(UIKit)
import UIKit
import Vision

extension QRCodeDetector {

    /// Runs Vision's QR detector over `image` (the OCR render source, upright and
    /// 1:1 with `pageSize`) and returns one `DetectedQRCode` per QR whose payload
    /// is an http/https URL. On-device and synchronous — no network. QRs that
    /// don't link to a website are dropped so the result screen never offers a
    /// tap that leads nowhere.
    static func detect(in image: UIImage, pageSize: CGSize) -> [DetectedQRCode] {
        guard pageSize.width > 0, pageSize.height > 0,
              let cgImage = uprightCGImage(image) else { return [] }

        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            print("QRCodeDetector: Vision request failed — \(error.localizedDescription)")
            return []
        }

        var seen = Set<String>()
        var out: [DetectedQRCode] = []
        for observation in request.results ?? [] {
            guard let payload = observation.payloadStringValue,
                  let url = webURL(fromPayload: payload) else { continue }
            let qr = DetectedQRCode(
                url: url,
                payload: payload,
                pageRect: pageRect(fromVisionNormalized: observation.boundingBox, pageSize: pageSize)
            )
            // Vision can report the same QR twice on a busy frame; de-dupe by id.
            if seen.insert(qr.id).inserted { out.append(qr) }
        }
        return out
    }

    /// The image's pixels as an upright (`.up`, scale 1) CGImage so Vision's
    /// normalized boxes map cleanly onto the page frame. Mirrors
    /// `BoundingBoxCropper`'s upright handling; `renderSource` already satisfies
    /// the fast path, but redrawing keeps a future non-upright source aligned.
    private static func uprightCGImage(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, image.scale == 1 { return image.cgImage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }.cgImage
    }
}
#endif
