//
//  CraftModel.swift
//  AlphaG3n
//
//  Self-contained CRAFT text-region detector. Wraps the Core ML model
//  (CRAFT.mlpackage -> CRAFT.mlmodelc in the app bundle) and the score-map
//  post-processing that the Python `craft_postprocess.get_boxes` did, so the
//  whole "image in -> numbered boxes out" pipeline lives in one file.
//
//  The Core ML model takes a 768x768 RGB image and returns two heatmaps:
//    region_score   [1,1,384,384]  - per-pixel "is character" score
//    affinity_score [1,1,384,384]  - per-pixel "links to neighbor" score
//  Box extraction (threshold -> connected components -> bounding box) is plain
//  image processing and runs here, on the CPU, after the model.
//

import Foundation
import CoreML
import UIKit
import CoreVideo

public final class CraftModel {

    // CRAFT input is a fixed square; must match the size used at conversion.
    public static let inputSize = 768

    // Same thresholds as the Python reference.
    public var textThreshold: Float = 0.7   // a component must contain at least one pixel this strong
    public var lowText: Float = 0.4         // region pixels above this count as "text"
    public var linkThreshold: Float = 0.4   // affinity pixels above this count as "link"
    public var minArea = 10                 // drop specks smaller than this (in score-map pixels)

    private var model: MLModel?

    public init() {}

    /// A detected text region, in the coordinate space of the image passed to `detect`.
    public struct Box {
        public let index: Int
        public let rect: CGRect
    }

    public enum CraftError: Error, LocalizedError {
        case modelNotFound
        case pixelBufferFailed
        case missingOutput
        case encodeFailed
        case openAI(String)

        public var errorDescription: String? {
            switch self {
            case .modelNotFound:    return "CRAFT.mlmodelc not found in the app bundle. Add CRAFT.mlpackage to the target."
            case .pixelBufferFailed:return "Could not build the model input pixel buffer."
            case .missingOutput:    return "CRAFT model did not return region/affinity score maps."
            case .encodeFailed:     return "Could not JPEG-encode the overlay image."
            case .openAI(let m):    return "OpenAI error: \(m)"
            }
        }
    }

    // MARK: - Public API

    /// Runs CRAFT on `image` and returns numbered text-region boxes
    /// in `image`'s own coordinate space (points).
    public func detect(in image: UIImage) throws -> [Box] {
        let model = try loadModel()

        guard let pb = Self.makePixelBuffer(from: image,
                                            width: Self.inputSize,
                                            height: Self.inputSize) else {
            throw CraftError.pixelBufferFailed
        }

        let input = try MLDictionaryFeatureProvider(
            dictionary: ["image": MLFeatureValue(pixelBuffer: pb)])
        let out = try model.prediction(from: input)

        guard let region = out.featureValue(for: "region_score")?.multiArrayValue,
              let affinity = out.featureValue(for: "affinity_score")?.multiArrayValue else {
            throw CraftError.missingOutput
        }

        // Score maps are [1,1,H,W]; pull H and W from the shape.
        let h = region.shape[region.shape.count - 2].intValue
        let w = region.shape[region.shape.count - 1].intValue

        let regionBuf = Self.flatFloats(region, count: h * w)
        let affinityBuf = Self.flatFloats(affinity, count: h * w)

        let rawBoxes = extractBoxes(region: regionBuf, affinity: affinityBuf, w: w, h: h)

        // Map score-map coords -> 768 input coords (x2) -> original image points.
        let sx = image.size.width  / CGFloat(Self.inputSize)
        let sy = image.size.height / CGFloat(Self.inputSize)

        return rawBoxes.enumerated().map { i, r in
            let scaled = CGRect(
                x: r.minX * 2 * sx,
                y: r.minY * 2 * sy,
                width:  r.width  * 2 * sx,
                height: r.height * 2 * sy)
            return Box(index: i, rect: scaled)
        }
    }

    /// Draws each box on `image` with its index number, returning the overlay.
    /// This is the image you send to the vision API.
    public func renderNumbered(_ boxes: [Box], on image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)

        return renderer.image { ctx in
            image.draw(in: CGRect(origin: .zero, size: image.size))
            let cg = ctx.cgContext

            let stroke = UIColor.red
            let lineWidth = max(2, image.size.width / 300)
            let fontSize = max(14, image.size.width / 60)
            let font = UIFont.boldSystemFont(ofSize: fontSize)

            for box in boxes {
                stroke.setStroke()
                let path = UIBezierPath(rect: box.rect)
                path.lineWidth = lineWidth
                path.stroke()

                let label = "\(box.index)" as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: UIColor.white
                ]
                let textSize = label.size(withAttributes: attrs)
                let tagRect = CGRect(
                    x: box.rect.minX,
                    y: max(0, box.rect.minY - textSize.height),
                    width: textSize.width + 6,
                    height: textSize.height)
                cg.setFillColor(stroke.cgColor)
                cg.fill(tagRect)
                label.draw(at: CGPoint(x: tagRect.minX + 3, y: tagRect.minY),
                           withAttributes: attrs)
            }
        }
    }

    // MARK: - Full pipeline (returns the same [ExtractedPage] format as PaddleOCRClient.process)

    /// End-to-end: detect text regions, draw the numbered overlay, send it to
    /// the OpenAI vision API, and return the result in the SAME shape as
    /// `PaddleOCRClient.process` — an array of `ExtractedPage`, each carrying a
    /// `VirtualDocument.PrunedResult` so it flows through `VirtualDocument.make`
    /// / `render()` exactly like the PaddleOCR path.
    ///
    /// One text block per detected box: `block_content` is the OpenAI
    /// transcription, `block_label` is "text", and group/order follow box order.
    public func recognize(in image: UIImage,
                          apiKey: String,
                          model: String = "gpt-4o") async throws -> [ExtractedPage] {
        let boxes = try detect(in: image)
        let overlay = renderNumbered(boxes, on: image)

        var perBox: [Int: String] = [:]
        if !boxes.isEmpty, let jpeg = overlay.jpegData(compressionQuality: 0.9) {
            let raw = try await requestOpenAIVision(jpeg: jpeg,
                                                    boxCount: boxes.count,
                                                    apiKey: apiKey,
                                                    model: model)
            perBox = Self.parseNumberedLines(raw)
        }

        let pruned = try buildPrunedResult(boxes: boxes, texts: perBox, image: image)
        let markdown = boxes
            .map { "\($0.index): \(perBox[$0.index] ?? "")" }
            .joined(separator: "\n")

        let page = ExtractedPage(
            pageIndex: 0,
            markdown: markdown,
            inlineImages: [:],
            outputImages: [:],
            prunedResult: pruned,
            preprocessedImageURL: nil)
        return [page]
    }

    /// Builds a `VirtualDocument.PrunedResult` from the detected boxes + texts.
    /// Constructed as JSON and decoded through PrunedResult's own Decodable path,
    /// so the shape is identical to what the PaddleOCR API would have produced.
    private func buildPrunedResult(boxes: [Box], texts: [Int: String],
                                   image: UIImage) throws -> VirtualDocument.PrunedResult {
        let blocks: [[String: Any]] = boxes.map { box in
            let r = box.rect
            return [
                "block_label": "text",
                "block_content": texts[box.index] ?? "",
                "block_bbox": [Double(r.minX), Double(r.minY), Double(r.maxX), Double(r.maxY)],
                "block_id": box.index,
                "block_order": box.index,
                "group_id": box.index,
                "block_polygon_points": [
                    [Double(r.minX), Double(r.minY)],
                    [Double(r.maxX), Double(r.minY)],
                    [Double(r.maxX), Double(r.maxY)],
                    [Double(r.minX), Double(r.maxY)]
                ]
            ]
        }
        let json: [String: Any] = [
            "width": Int(image.size.width),
            "height": Int(image.size.height),
            "parsing_res_list": blocks
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(VirtualDocument.PrunedResult.self, from: data)
    }

    /// Parses "0: HELLO\n1: WORLD" into [0: "HELLO", 1: "WORLD"].
    private static func parseNumberedLines(_ raw: String) -> [Int: String] {
        var out: [Int: String] = [:]
        for line in raw.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let lhs = line[..<colon].trimmingCharacters(in: .whitespaces)
            let rhs = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let idx = Int(lhs) { out[idx] = rhs }
        }
        return out
    }

    /// Posts the numbered overlay image to the OpenAI chat-completions endpoint
    /// and returns the model's "<number>: <text>" lines.
    private func requestOpenAIVision(jpeg: Data, boxCount: Int,
                                     apiKey: String, model: String) async throws -> String {
        let dataURL = "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
        let prompt = """
        This image has red numbered boxes drawn around regions of text, numbered \
        starting at 0 (there are \(boxCount) boxes). Read the text inside each \
        numbered box exactly. Reply with one line per box in the form \
        '<number>: <text>'. If a box has no readable text, write '<number>: [none]'.
        """

        let body: [String: Any] = [
            "model": model,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": prompt],
                    ["type": "image_url", "image_url": ["url": dataURL]]
                ]
            ]]
        ]

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let msg = String(data: data, encoding: .utf8) ?? "status \(http.statusCode)"
            throw CraftError.openAI(msg)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw CraftError.openAI("Unexpected response shape.")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Box extraction (port of craft_postprocess.get_boxes)

    private func extractBoxes(region: [Float], affinity: [Float],
                              w: Int, h: Int) -> [CGRect] {
        // Binary mask: region above lowText OR affinity above linkThreshold.
        var mask = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) {
            mask[i] = region[i] > lowText || affinity[i] > linkThreshold
        }

        var labels = [Int](repeating: 0, count: w * h)   // 0 == unlabeled
        var boxes: [CGRect] = []
        var current = 0
        var stack: [Int] = []

        for start in 0..<(w * h) where mask[start] && labels[start] == 0 {
            current += 1
            labels[start] = current
            stack.removeAll(keepingCapacity: true)
            stack.append(start)

            var minX = w, minY = h, maxX = 0, maxY = 0
            var area = 0
            var maxRegion: Float = 0

            while let p = stack.popLast() {
                let x = p % w
                let y = p / w
                area += 1
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
                if region[p] > maxRegion { maxRegion = region[p] }

                // 4-connected neighbors
                if x > 0     { let n = p - 1; if mask[n] && labels[n] == 0 { labels[n] = current; stack.append(n) } }
                if x < w - 1 { let n = p + 1; if mask[n] && labels[n] == 0 { labels[n] = current; stack.append(n) } }
                if y > 0     { let n = p - w; if mask[n] && labels[n] == 0 { labels[n] = current; stack.append(n) } }
                if y < h - 1 { let n = p + w; if mask[n] && labels[n] == 0 { labels[n] = current; stack.append(n) } }
            }

            if area < minArea { continue }
            if maxRegion < textThreshold { continue }

            // small padding to mimic CRAFT's dilation step
            let pad = 2
            let bx = max(0, minX - pad)
            let by = max(0, minY - pad)
            let bw = min(w - 1, maxX + pad) - bx + 1
            let bh = min(h - 1, maxY + pad) - by + 1
            boxes.append(CGRect(x: bx, y: by, width: bw, height: bh))
        }
        return boxes
    }

    // MARK: - Helpers

    private func loadModel() throws -> MLModel {
        if let model { return model }
        guard let url = Bundle.main.url(forResource: "CRAFT", withExtension: "mlmodelc") else {
            throw CraftError.modelNotFound
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let m = try MLModel(contentsOf: url, configuration: config)
        self.model = m
        return m
    }

    /// Reads an MLMultiArray into a flat [Float] regardless of its dtype.
    private static func flatFloats(_ arr: MLMultiArray, count: Int) -> [Float] {
        if arr.dataType == .float32 {
            let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: count)
            return Array(UnsafeBufferPointer(start: ptr, count: count))
        }
        // Float16 / Double / other: go through NSNumber (slower but safe).
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count { out[i] = arr[i].floatValue }
        return out
    }

    /// Renders a UIImage into a square BGRA CVPixelBuffer for the Core ML image input.
    private static func makePixelBuffer(from image: UIImage,
                                        width: Int, height: Int) -> CVPixelBuffer? {
        guard let cg = image.cgImage else { return nil }

        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary, &pb)
        guard status == kCVReturnSuccess, let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: base,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // Resize (stretch) into the square the model expects, matching the
        // non-aspect-preserving resize used in the Python pipeline.
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
