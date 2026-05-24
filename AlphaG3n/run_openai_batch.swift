// Standalone smoke test for OpenAIClient's concurrent image-OCR path.
//
// It compiles the REAL OpenAIClient.swift (which is Foundation-only) together
// with this entry point, synthesizes a handful of tiny blank-but-VALID JPEGs,
// fires them all concurrently through `readText(in:)` against the live
// Responses API, and prints one structured result per image. Because the test
// images are blank, each should come back classified status=empty — which also
// demonstrates the new triage flagging (empty / unreadable / irrelevant). A
// clean run (all .success) proves the concurrency + per-image handler + auth +
// Structured-Outputs wiring all work end to end.
//
// usage:
//   swiftc OpenAIClient.swift run_openai_batch.swift \
//       -o /tmp/openai_batch && /tmp/openai_batch
//
//   # optional args:  /tmp/openai_batch [model] [count]
//   #   model defaults to the client's default (gpt-5-nano), count defaults to 5
//
// The OpenAI key is read from the OPENAI_API_KEY environment variable.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main
struct OpenAIBatchTest {

    /// A tiny blank white JPEG — a valid image the Responses API accepts, with
    /// no text on it (so a correct pass classifies it status=empty).
    /// 1x1 is degenerate enough that some pipelines balk, so we use a small tile.
    static func makeBlankJPEG(side: Int = 32) -> Data? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        guard let cg = ctx.makeImage() else { return nil }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    static func fail(_ msg: String) -> Never {
        FileHandle.standardError.write(Data((msg + "\n").utf8))
        exit(1)
    }

    static func main() async {
        guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
              !key.trimmingCharacters(in: .whitespaces).isEmpty else {
            fail("error: OPENAI_API_KEY is not set in the environment.")
        }

        let args = CommandLine.arguments
        let count = args.count > 2 ? (Int(args[2]) ?? 5) : 5
        guard let jpeg = makeBlankJPEG() else { fail("error: could not synthesize test JPEG.") }
        let images = Array(repeating: jpeg, count: count)

        var client = OpenAIClient(apiKey: key)
        if args.count > 1, !args[1].isEmpty { client.model = args[1] }

        print("→ \(images.count) concurrent OCR requests")
        print("    endpoint: \(client.endpoint.absoluteString)")
        print("    model:    \(client.model)")
        print("    image:    \(jpeg.count)-byte blank JPEG (no text)\n")

        let start = Date()
        let results = await client.readText(in: images)
        let elapsed = Date().timeIntervalSince(start)

        var ok = 0, failed = 0
        for (i, result) in results.enumerated() {
            switch result {
            case .success(let reading):
                ok += 1
                switch reading.status {
                case .readable:
                    let shown = reading.text.replacingOccurrences(of: "\n", with: " / ")
                    print("  [\(i)] ✓ readable — \"\(shown)\"")
                default:
                    // empty / unreadable / irrelevant: the note explains what's wrong.
                    print("  [\(i)] ✓ \(reading.status.rawValue) — \(reading.note)")
                }
            case .failure(let error):
                failed += 1
                print(String(format: "  [%d] ✗ FAILURE: %@", i, error.localizedDescription))
            }
        }

        print(String(format: "\n%d/%d succeeded, %d failed — %.2fs wall clock",
                     ok, results.count, failed, elapsed))
        // Non-zero exit if any request failed, so this is CI/script friendly.
        exit(failed == 0 ? 0 : 2)
    }
}
