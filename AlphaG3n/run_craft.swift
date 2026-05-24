// Standalone CRAFT runner — a UIKit-free port of CraftModel.swift's
// detect() path, so it can run on macOS as a command-line tool.
// usage: run_craft <CRAFT.mlmodelc> <image> [out.png]

import Foundation
import CoreML
import CoreGraphics
import ImageIO
import CoreVideo
import CoreImage
import UniformTypeIdentifiers

// Config — identical to CraftModel.swift.
let inputSize = 768
let textThreshold: Float = 0.7
let lowText: Float = 0.4
let linkThreshold: Float = 0.4
let minArea = 10

func die(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 3 else { die("usage: run_craft <CRAFT.mlmodelc> <image> [out.png]") }
let modelURL = URL(fileURLWithPath: args[1])
let imageURL = URL(fileURLWithPath: args[2])
let outURL = URL(fileURLWithPath: args.count >= 4 ? args[3] : "/tmp/craft_overlay.png")

// MARK: - Load image, baking EXIF orientation into pixels (like prepareForUpload).
func loadUprightCGImage(_ url: URL) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        die("cannot decode image: \(url.path)")
    }
    var orientation = 1
    if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
       let o = props[kCGImagePropertyOrientation] as? Int {
        orientation = o
    }
    if orientation == 1 { return cg }
    let ci = CIImage(cgImage: cg).oriented(forExifOrientation: Int32(orientation))
    guard let up = CIContext().createCGImage(ci, from: ci.extent) else { return cg }
    return up
}

let image = loadUprightCGImage(imageURL)
let imgW = image.width, imgH = image.height
FileHandle.standardError.write("image \(imgW)x\(imgH)\n".data(using: .utf8)!)

// MARK: - makePixelBuffer (aspect-preserving fit into 768x768, black pad, upright).
func makePixelBuffer(_ cg: CGImage, size: Int) -> (CVPixelBuffer, CGFloat)? {
    let scale = min(CGFloat(size) / CGFloat(cg.width), CGFloat(size) / CGFloat(cg.height))
    let contentW = CGFloat(cg.width) * scale
    let contentH = CGFloat(cg.height) * scale
    let attrs: [CFString: Any] = [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true
    ]
    var pb: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, size, size,
                              kCVPixelFormatType_32BGRA,
                              attrs as CFDictionary, &pb) == kCVReturnSuccess,
          let buffer = pb else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let bpr = CVPixelBufferGetBytesPerRow(buffer)
    memset(base, 0, bpr * size)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: base, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: bpr, space: cs,
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return nil }
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: 1, y: -1)
    context.draw(cg, in: CGRect(x: 0, y: 0, width: contentW, height: contentH))
    return (buffer, scale)
}

guard let (pixelBuffer, scale) = makePixelBuffer(image, size: inputSize) else {
    die("pixel buffer failed")
}

// MARK: - Model.
let config = MLModelConfiguration()
config.computeUnits = .all
guard let model = try? MLModel(contentsOf: modelURL, configuration: config) else {
    die("cannot load model: \(modelURL.path)")
}
FileHandle.standardError.write("model inputs: \(model.modelDescription.inputDescriptionsByName.keys.sorted())\n".data(using: .utf8)!)
FileHandle.standardError.write("model outputs: \(model.modelDescription.outputDescriptionsByName.keys.sorted())\n".data(using: .utf8)!)

let input = try! MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: pixelBuffer)])
guard let out = try? model.prediction(from: input) else { die("prediction failed") }
guard let region = out.featureValue(for: "region_score")?.multiArrayValue,
      let affinity = out.featureValue(for: "affinity_score")?.multiArrayValue else {
    die("missing region/affinity outputs; got \(out.featureNames)")
}

let h = region.shape[region.shape.count - 2].intValue
let w = region.shape[region.shape.count - 1].intValue

func flatFloats(_ arr: MLMultiArray, _ count: Int) -> [Float] {
    if arr.dataType == .float32 {
        let p = arr.dataPointer.bindMemory(to: Float.self, capacity: count)
        return Array(UnsafeBufferPointer(start: p, count: count))
    }
    var o = [Float](repeating: 0, count: count)
    for i in 0..<count { o[i] = arr[i].floatValue }
    return o
}
let regionBuf = flatFloats(region, h * w)
let affinityBuf = flatFloats(affinity, h * w)

// MARK: - extractBoxes (port of craft_postprocess.get_boxes).
func extractBoxes(region: [Float], affinity: [Float], w: Int, h: Int) -> [CGRect] {
    var mask = [Bool](repeating: false, count: w * h)
    for i in 0..<(w * h) { mask[i] = region[i] > lowText || affinity[i] > linkThreshold }
    var labels = [Int](repeating: 0, count: w * h)
    var boxes: [CGRect] = []
    var current = 0
    var stack: [Int] = []
    for start in 0..<(w * h) where mask[start] && labels[start] == 0 {
        current += 1
        labels[start] = current
        stack.removeAll(keepingCapacity: true)
        stack.append(start)
        var minX = w, minY = h, maxX = 0, maxY = 0, area = 0
        var maxRegion: Float = 0
        while let p = stack.popLast() {
            let x = p % w, y = p / w
            area += 1
            if x < minX { minX = x }; if x > maxX { maxX = x }
            if y < minY { minY = y }; if y > maxY { maxY = y }
            if region[p] > maxRegion { maxRegion = region[p] }
            if x > 0     { let n = p - 1; if mask[n] && labels[n] == 0 { labels[n] = current; stack.append(n) } }
            if x < w - 1 { let n = p + 1; if mask[n] && labels[n] == 0 { labels[n] = current; stack.append(n) } }
            if y > 0     { let n = p - w; if mask[n] && labels[n] == 0 { labels[n] = current; stack.append(n) } }
            if y < h - 1 { let n = p + w; if mask[n] && labels[n] == 0 { labels[n] = current; stack.append(n) } }
        }
        if area < minArea { continue }
        if maxRegion < textThreshold { continue }
        let bw = maxX - minX + 1, bh = maxY - minY + 1
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

let rawBoxes = extractBoxes(region: regionBuf, affinity: affinityBuf, w: w, h: h)
let f = 2 / scale   // score-map pixel -> input pixel (x2), then undo the fit scale.
let bounds = CGRect(x: 0, y: 0, width: imgW, height: imgH)
let mapped = rawBoxes.compactMap { r -> CGRect? in
    let rect = CGRect(x: r.minX * f, y: r.minY * f, width: r.width * f, height: r.height * f).intersection(bounds)
    return (rect.isNull || rect.isEmpty) ? nil : rect
}

print("score map \(w)x\(h) | raw components: \(rawBoxes.count) | mapped boxes: \(mapped.count)")
for (i, r) in mapped.prefix(40).enumerated() {
    print(String(format: "  [%2d] x=%.0f y=%.0f w=%.0f h=%.0f", i, r.minX, r.minY, r.width, r.height))
}
if mapped.count > 40 { print("  ... and \(mapped.count - 40) more") }

// MARK: - Draw red boxes onto the upright image and save a PNG.
let cs = CGColorSpaceCreateDeviceRGB()
guard let octx = CGContext(data: nil, width: imgW, height: imgH,
                           bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    die("overlay context failed")
}
octx.translateBy(x: 0, y: CGFloat(imgH))   // flip to top-left origin so box coords match.
octx.scaleBy(x: 1, y: -1)
octx.draw(image, in: bounds)
octx.setStrokeColor(red: 1, green: 0, blue: 0, alpha: 1)
octx.setLineWidth(max(2, CGFloat(imgW) / 300))
for r in mapped { octx.stroke(r) }
guard let overlay = octx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    die("overlay image/dest failed")
}
CGImageDestinationAddImage(dest, overlay, nil)
guard CGImageDestinationFinalize(dest) else { die("png write failed") }
print("overlay -> \(outURL.path)")
