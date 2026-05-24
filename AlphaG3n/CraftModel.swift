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

    /// OpenAI knobs (passed through to `OpenAIClient`). `imageDetail = .high`
    /// is best for small text; drop to `.low` to cut cost. `temperature = 0`
    /// keeps transcription deterministic.
    public var imageDetail: OpenAIClient.ImageDetail = .high
    public var temperature: Double = 0

    /// Builds the (system, user) prompt for the OCR call given the box count.
    /// Override this to prompt-engineer without touching the pipeline, e.g.:
    ///   craftModel.promptBuilder = { n in (system: "...", user: "... \(n) ...") }
    public var promptBuilder: (_ boxCount: Int) -> (system: String, user: String)
        = CraftModel.defaultPrompt

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

        public var errorDescription: String? {
            switch self {
            case .modelNotFound:    return "CRAFT.mlmodelc not found in the app bundle. Add CRAFT.mlpackage to the target."
            case .pixelBufferFailed:return "Could not build the model input pixel buffer."
            case .missingOutput:    return "CRAFT model did not return region/affinity score maps."
            case .encodeFailed:     return "Could not JPEG-encode the overlay image."
            }
        }
    }

    // MARK: - Public API

    /// Runs CRAFT on `image` and returns numbered text-region boxes
    /// in `image`'s own coordinate space (points).
    public func detect(in image: UIImage) throws -> [Box] {
        let model = try loadModel()

        guard let prepared = Self.makePixelBuffer(from: image, size: Self.inputSize) else {
            throw CraftError.pixelBufferFailed
        }

        let input = try MLDictionaryFeatureProvider(
            dictionary: ["image": MLFeatureValue(pixelBuffer: prepared.buffer)])
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

        // Score-map pixel -> input pixel is ×2 (score map is half resolution).
        // Input pixel -> image point divides out the fit factor that
        // `makePixelBuffer` used when placing the image into the square.
        let imagePerScoreMapPixel = 2 / prepared.scale
        let bounds = CGRect(origin: .zero, size: image.size)

        let mapped = rawBoxes.compactMap { r -> CGRect? in
            let rect = CGRect(
                x: r.minX * imagePerScoreMapPixel,
                y: r.minY * imagePerScoreMapPixel,
                width:  r.width  * imagePerScoreMapPixel,
                height: r.height * imagePerScoreMapPixel
            ).intersection(bounds)
            return (rect.isNull || rect.isEmpty) ? nil : rect
        }

        return mapped.enumerated().map { Box(index: $0.offset, rect: $0.element) }
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
            let prompts = promptBuilder(boxes.count)
            let client = OpenAIClient(apiKey: apiKey,
                                      model: model,
                                      temperature: temperature,
                                      imageDetail: imageDetail)
            let raw = try await client.vision(system: prompts.system,
                                              user: prompts.user,
                                              jpeg: jpeg)
            perBox = Self.parseResponse(raw)
        }

        let pruned = try buildPrunedResult(boxes: boxes, texts: perBox, image: image)
        let markdown = boxes
            .map { "\($0.index): \(perBox[$0.index] ?? "")" }
            .joined(separator: "\n")

        let blocks: [TextBlock] = pruned.parsingResList.map { raw in
            TextBlock(label: raw.blockLabel, bbox: raw.blockBbox, content: raw.blockContent)
        }

        let page = ExtractedPage(
            pageIndex: 0,
            markdown: markdown,
            blocks: blocks,
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

    /// Parses the model's reply into [index: text]. Expects a JSON object
    /// {"0":"...","1":"..."}; tolerates stray code fences, and falls back to
    /// line format "0: text" if JSON parsing fails.
    private static func parseResponse(_ raw: String) -> [Int: String] {
        // Strip ```json fences if the model added them despite instructions.
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: "```json", with: "")
                 .replacingOccurrences(of: "```", with: "")
                 .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Primary: JSON object of index -> text.
        if let data = s.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var out: [Int: String] = [:]
            for (k, v) in obj {
                guard let idx = Int(k) else { continue }
                if let str = v as? String {
                    out[idx] = str
                } else {
                    out[idx] = String(describing: v)
                }
            }
            if !out.isEmpty { return out }
        }

        // Fallback: line format "0: text".
        var out: [Int: String] = [:]
        for line in s.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let lhs = line[..<colon].trimmingCharacters(in: .whitespaces)
            let rhs = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let idx = Int(lhs) { out[idx] = rhs }
        }
        return out
    }

    /// Default (system, user) prompt for the numbered-box OCR call. Override
    /// `promptBuilder` to change wording without editing the pipeline.
    public static func defaultPrompt(boxCount: Int) -> (system: String, user: String) {
        let lastIndex = boxCount - 1

        let system = """
        You are a precise OCR transcription engine. You transcribe only the text \
        that is visibly printed inside the marked regions of the image. You never \
        translate, spell-correct, summarize, reorder, complete, or invent text. \
        You output only the JSON object that is requested — no prose, no code fences.
        """

        let user = """
        The image has red rectangular boxes. Each box is tagged with an integer \
        label (0 through \(lastIndex)) drawn at its top-left corner. Each box marks \
        one region of text that was detected in the image.

        For every index from 0 to \(lastIndex), transcribe the text inside that box \
        following these rules exactly:
        - Reproduce the characters as written: keep original casing, punctuation, \
        accents/diacritics, digits, and symbols. Do NOT translate or normalize.
        - The red integer tag is an overlay added by us — it is NOT part of the \
        text. Ignore it.
        - Transcribe only what is inside that specific box. Ignore text outside it \
        and text belonging to other boxes.
        - A box may contain a single word, a fragment, or a few words — transcribe \
        exactly what it bounds, partial words included.
        - If a box contains no legible text, use an empty string "".
        - If characters are present but unreadable, transcribe your best guess and \
        wrap the uncertain part in «». Do not drop it.

        Respond with ONLY a JSON object whose keys are the box indices as strings \
        and whose values are the transcriptions. Include every index from 0 to \
        \(lastIndex). No commentary, no markdown, no code fences.
        Example for 2 boxes: {"0": "Invoice", "1": "Total: $42.00"}
        """

        return (system, user)
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

            // Per-component dilation from the Python reference:
            //   niter = int(sqrt(area * min(bw,bh) / (bw*bh)) * 2)
            // The previous hardcoded pad=2 produced boxes so tight that the
            // downstream IOU filter in LayoutAugmentation threw them away as
            // duplicates of slightly larger Baidu blocks.
            let bw = maxX - minX + 1
            let bh = maxY - minY + 1
            let bboxArea = bw * bh
            let niter = bboxArea > 0
                ? Int((Double(area * min(bw, bh)) / Double(bboxArea)).squareRoot() * 2)
                : 0
            let bx = max(0, minX - niter)
            let by = max(0, minY - niter)
            let bxE = min(w - 1, maxX + niter)
            let byE = min(h - 1, maxY + niter)
            boxes.append(CGRect(x: bx, y: by, width: bxE - bx + 1, height: byE - by + 1))
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

    /// Renders `image` into a square `size`×`size` BGRA pixel buffer using
    /// CRAFT's aspect-preserving fit: a single ratio scales the image so its
    /// long side equals `size`, the result is placed at image-display (0,0),
    /// and the remaining strip is zero-padded. The previous implementation
    /// stretched non-uniformly to fill the square, which squashed characters
    /// on landscape camera frames badly enough that the detector missed them.
    ///
    /// Also flips the context up-front so the model sees the image upright.
    /// A raw CGBitmapContext has its origin at the bottom-left, so calling
    /// `draw(cg, in:)` against it mirrors the image vertically — which the
    /// previous version was unintentionally doing.
    ///
    /// Returns the buffer paired with the fit ratio, so the caller can
    /// invert it when mapping score-map boxes back into image coordinates.
    private static func makePixelBuffer(from image: UIImage,
                                        size: Int) -> (buffer: CVPixelBuffer, scale: CGFloat)? {
        guard let cg = image.cgImage else { return nil }

        let scale = min(CGFloat(size) / image.size.width,
                        CGFloat(size) / image.size.height)
        let contentW = image.size.width * scale
        let contentH = image.size.height * scale

        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, size, size,
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary, &pb)
        guard status == kCVReturnSuccess, let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        // CVPixelBufferCreate leaves the backing store uninitialized, so the
        // padded strip would otherwise contain arbitrary bytes. CRAFT was
        // trained against black padding.
        memset(base, 0, bytesPerRow * size)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: base,
            width: size, height: size,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.translateBy(x: 0, y: CGFloat(size))
        context.scaleBy(x: 1, y: -1)
        context.draw(cg, in: CGRect(x: 0, y: 0, width: contentW, height: contentH))

        return (buffer, scale)
    }
}
