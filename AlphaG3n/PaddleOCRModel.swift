//
//  PaddleOCRModel.swift
//  AlphaG3n
//
//  Created by Owen Gregson on 5/23/26.
//

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Public types

public enum PaddleOCRModel: String, Sendable {
    case paddleOCRVL15 = "PaddleOCR-VL-1.5"
}

/// Full Baidu request payload. Keys are camelCase to match the API's wire
/// format; `JSONEncoder`'s default key strategy preserves the Swift property
/// names verbatim, so the JSON sent over the wire matches `optional_payload`
/// from the Baidu reference docs.
///
/// All fields are non-optional with explicit defaults so two different
/// captures send identical request shapes — the server can pool / cache
/// requests with consistent envelopes more efficiently, and absent fields
/// can't accidentally trigger different server-side codepaths.
public struct OptionalPayload: Codable, Sendable {
    public var markdownIgnoreLabels: [String]
    public var useDocOrientationClassify: Bool
    public var useDocUnwarping: Bool
    public var useLayoutDetection: Bool
    public var useChartRecognition: Bool
    public var useSealRecognition: Bool
    public var useOcrForImageBlock: Bool
    public var mergeTables: Bool
    public var relevelTitles: Bool
    public var layoutShapeMode: String
    public var promptLabel: String
    public var repetitionPenalty: Double
    public var temperature: Double
    public var topP: Double
    /// Lower bound on resize. The server upsamples below this; staying well
    /// above it (we send ~2.8 MP) keeps text legible.
    public var minPixels: Int
    /// Upper bound on the server-side resize. We pre-shrink the upload to
    /// fit this so we don't waste bandwidth and the server doesn't have to
    /// decode + downsample on hot CPU.
    public var maxPixels: Int
    public var layoutNms: Bool
    public var restructurePages: Bool

    nonisolated public init(
        markdownIgnoreLabels: [String] = [
            "header",
            "header_image",
            "footer",
            "footer_image",
            "number",
            "footnote",
            "aside_text"
        ],
        useDocOrientationClassify: Bool = true,
        useDocUnwarping: Bool = false,
        useLayoutDetection: Bool = true,
        useChartRecognition: Bool = false,
        useSealRecognition: Bool = true,
        useOcrForImageBlock: Bool = false,
        mergeTables: Bool = true,
        relevelTitles: Bool = true,
        layoutShapeMode: String = "rect",
        promptLabel: String = "ocr",
        repetitionPenalty: Double = 1,
        temperature: Double = 0.15,
        topP: Double = 1,
        minPixels: Int = 147_384,
        maxPixels: Int = 2_822_400,
        layoutNms: Bool = true,
        restructurePages: Bool = true
    ) {
        self.markdownIgnoreLabels = markdownIgnoreLabels
        self.useDocOrientationClassify = useDocOrientationClassify
        self.useDocUnwarping = useDocUnwarping
        self.useLayoutDetection = useLayoutDetection
        self.useChartRecognition = useChartRecognition
        self.useSealRecognition = useSealRecognition
        self.useOcrForImageBlock = useOcrForImageBlock
        self.mergeTables = mergeTables
        self.relevelTitles = relevelTitles
        self.layoutShapeMode = layoutShapeMode
        self.promptLabel = promptLabel
        self.repetitionPenalty = repetitionPenalty
        self.temperature = temperature
        self.topP = topP
        self.minPixels = minPixels
        self.maxPixels = maxPixels
        self.layoutNms = layoutNms
        self.restructurePages = restructurePages
    }
}

public struct TextBlock: Sendable {
    /// Raw layout label from PaddleOCR (e.g. `text`, `doc_title`, `table`).
    public let label: String
    /// `[x1, y1, x2, y2]` in the preprocessed image's pixel coordinates.
    public let bbox: [Double]
    /// Recognized text content for this block (empty if PaddleOCR didn't return any).
    public let content: String

    public init(label: String, bbox: [Double], content: String) {
        self.label = label
        self.bbox = bbox
        self.content = content
    }
}

public struct ExtractedPage: Sendable {
    public let pageIndex: Int
    public let markdown: String
    public let blocks: [TextBlock]
    public let inlineImages: [String: URL]
    public let outputImages: [String: URL]
    /// Rich layout data (bboxes, labels, polygons) used to build a `VirtualDocument`.
    /// `nil` only if the API omitted it for this page.
    public let prunedResult: VirtualDocument.PrunedResult?
    /// Local path to the post-processed / deskewed source image whose
    /// coordinate space matches `prunedResult` bboxes. `nil` if the API
    /// didn't return one (e.g. all preprocessing flags off).
    public let preprocessedImageURL: URL?
}

public enum PaddleOCRError: Error, CustomStringConvertible {
    case fileNotFound(URL)
    case submissionFailed(status: Int, body: String)
    case statusRequestFailed(status: Int, body: String)
    case jobFailed(message: String)
    case missingResultURL
    case invalidResponseBody
    case imageDownloadFailed(URL, status: Int)

    public var description: String {
        switch self {
        case .fileNotFound(let url):
            return "File not found at \(url.path)"
        case .submissionFailed(let status, let body):
            return "Job submission failed (HTTP \(status)): \(body)"
        case .statusRequestFailed(let status, let body):
            return "Job status request failed (HTTP \(status)): \(body)"
        case .jobFailed(let message):
            return "Job failed: \(message)"
        case .missingResultURL:
            return "Job completed but no result URL was returned"
        case .invalidResponseBody:
            return "Response body could not be decoded"
        case .imageDownloadFailed(let url, let status):
            return "Image download failed for \(url.absoluteString) (HTTP \(status))"
        }
    }
}

nonisolated private struct JobSubmissionURLPayload: Encodable {
    let fileUrl: String
    let model: String
    let optionalPayload: OptionalPayload
}

nonisolated private struct JobSubmissionResponse: Decodable {
    struct DataPayload: Decodable { let jobId: String }
    let data: DataPayload
}

nonisolated private enum JobState: String, Decodable {
    case pending, running, done, failed
}

nonisolated private struct ExtractProgress: Decodable {
    let totalPages: Int?
    let extractedPages: Int?
    let startTime: String?
    let endTime: String?
}

nonisolated private struct ResultURL: Decodable {
    let jsonUrl: String?
}

nonisolated private struct JobStatusResponse: Decodable {
    struct DataPayload: Decodable {
        let state: JobState
        let extractProgress: ExtractProgress?
        let resultUrl: ResultURL?
        let errorMsg: String?
    }
    let data: DataPayload
}

nonisolated private struct LayoutResultLine: Decodable {
    let result: LayoutResult
}

nonisolated private struct LayoutResult: Decodable {
    let layoutParsingResults: [LayoutParsingResult]
    let preprocessedImages: [String]?
}

nonisolated private struct LayoutParsingResult: Decodable {
    let prunedResult: VirtualDocument.PrunedResult?
    let markdown: MarkdownPayload
    let outputImages: [String: String]?
}

nonisolated private struct MarkdownPayload: Decodable {
    let text: String
    let images: [String: String]
}

// MARK: - MIME helpers

nonisolated private func mimeType(forPathExtension ext: String) -> String {
    switch ext.lowercased() {
    case "pdf": return "application/pdf"
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "tif", "tiff": return "image/tiff"
    case "bmp": return "image/bmp"
    case "webp": return "image/webp"
    default: return "application/octet-stream"
    }
}

// MARK: - Multipart builder

/// Inline multipart body builder. Pre-sizes the buffer to avoid the resize
/// thrash that a naive `body.append(...)` loop produces on multi-MB image
/// uploads — every doubling memcpy is wall-time during submit.
nonisolated private func buildMultipartBody(
    boundary: String,
    fields: [(name: String, value: String)],
    file: (name: String, filename: String, mimeType: String, data: Data)
) -> Data {
    let estimate = file.data.count
        + boundary.utf8.count * (fields.count + 2) * 2
        + 512
        + fields.reduce(0) { $0 + $1.name.utf8.count + $1.value.utf8.count + 64 }
        + file.name.utf8.count
        + file.filename.utf8.count
        + file.mimeType.utf8.count
    var body = Data(capacity: estimate)

    let dashes = "--\(boundary)\r\n"
    for field in fields {
        body.appendString(dashes)
        body.appendString("Content-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n")
        body.appendString("\(field.value)\r\n")
    }

    body.appendString(dashes)
    body.appendString("Content-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.filename)\"\r\n")
    body.appendString("Content-Type: \(file.mimeType)\r\n\r\n")
    body.append(file.data)
    body.appendString("\r\n")
    body.appendString("--\(boundary)--\r\n")
    return body
}

private extension Data {
    mutating func appendString(_ string: String) {
        // String → contiguous UTF-8 → Data avoids the extra Data allocation
        // that `string.data(using: .utf8)` performs internally.
        var s = string
        s.withUTF8 { append($0.baseAddress!, count: $0.count) }
    }
}

// MARK: - Client

/// Stateless after construction: every stored property is either a `Sendable`
/// value type (`Configuration`) or a well-known thread-safe reference type
/// (`URLSession`, `JSONEncoder`, `JSONDecoder`). Marked `@unchecked Sendable`
/// because Foundation's coder types aren't formally `Sendable` until the
/// SDK version that ships them as such, but they're documented as safe for
/// concurrent reads after init.
///
/// Previously an `actor`, which serialised every request behind a single
/// executor and forced every callsite to pay an executor-hop. Concurrent
/// callers now overlap their work freely.
public final class PaddleOCRClient: @unchecked Sendable {

    public struct Configuration: Sendable {
        public var jobURL: URL
        public var token: String
        public var model: PaddleOCRModel
        /// Wait before the first status poll. Most jobs complete inside a
        /// handful of seconds — starting at 500 ms lands the first hit on
        /// quick jobs before the network round-trip even matters.
        public var pollInitialDelay: Duration
        /// Ceiling for the exponential backoff. Long-running jobs can sit at
        /// this cadence indefinitely without spamming the server.
        public var pollMaxDelay: Duration
        /// Multiplier applied to the current delay after each poll. 1.6 ≈
        /// "double every two polls" which balances responsiveness and load.
        public var pollBackoffFactor: Double
        public var maxConcurrentImageDownloads: Int

        public init(
            jobURL: URL = URL(string: "https://paddleocr.aistudio-app.com/api/v2/ocr/jobs")!,
            token: String,
            model: PaddleOCRModel = .paddleOCRVL15,
            pollInitialDelay: Duration = .milliseconds(300),
            pollMaxDelay: Duration = .seconds(4),
            pollBackoffFactor: Double = 1.5,
            maxConcurrentImageDownloads: Int = 8
        ) {
            self.jobURL = jobURL
            self.token = token
            self.model = model
            self.pollInitialDelay = pollInitialDelay
            self.pollMaxDelay = pollMaxDelay
            self.pollBackoffFactor = pollBackoffFactor
            self.maxConcurrentImageDownloads = maxConcurrentImageDownloads
        }
    }

    public enum ProgressEvent: Sendable {
        case submitted(jobId: String)
        case pending
        case running(extracted: Int?, total: Int?)
        case completed(extractedPages: Int, startTime: String?, endTime: String?)
    }

    private let config: Configuration
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(configuration: Configuration, session: URLSession? = nil) {
        self.config = configuration
        self.session = session ?? Self.makeDefaultSession()
    }

    /// Per-client `URLSession` rather than `.shared`. Tuned for image upload
    /// + status polling: shorter request timeout to surface stalls quickly,
    /// long resource timeout to cover real OCR jobs, and 8 connections per
    /// host to support the concurrent image download fan-out at the end.
    private static func makeDefaultSession() -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 180
        cfg.httpMaximumConnectionsPerHost = 8
        cfg.waitsForConnectivity = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpAdditionalHeaders = ["Accept-Encoding": "gzip, deflate"]
        return URLSession(configuration: cfg)
    }

    // MARK: - Public API

    /// Fire a cheap request against the OCR endpoint so the TCP socket +
    /// TLS session are warm by the time the user takes their first photo.
    /// First-capture latency without this is ~200-500 ms higher because
    /// the TLS handshake (2 RTTs on TLS 1.2, 1 RTT on TLS 1.3) lands on
    /// the upload-the-actual-photo path. Best-effort: any failure is
    /// silently ignored — the worst case is what we had before.
    public func warmUp() async {
        var request = URLRequest(url: config.jobURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        _ = try? await session.data(for: request)
    }

    /// Submit a local file, poll, and download all extracted markdown + images.
    public func process(
        fileURL: URL,
        optionalPayload: OptionalPayload = OptionalPayload(),
        outputDirectory: URL,
        progress: (@Sendable (ProgressEvent) -> Void)? = nil
    ) async throws -> [ExtractedPage] {
        let jobId = try await submit(fileURL: fileURL, optionalPayload: optionalPayload)
        progress?(.submitted(jobId: jobId))
        let resultURL = try await pollUntilDone(jobId: jobId, progress: progress)
        return try await downloadResults(resultURL: resultURL, outputDirectory: outputDirectory)
    }

    /// Submit a remote URL, poll, and download all extracted markdown + images.
    public func process(
        remoteURL: URL,
        optionalPayload: OptionalPayload = OptionalPayload(),
        outputDirectory: URL,
        progress: (@Sendable (ProgressEvent) -> Void)? = nil
    ) async throws -> [ExtractedPage] {
        let jobId = try await submit(remoteURL: remoteURL, optionalPayload: optionalPayload)
        progress?(.submitted(jobId: jobId))
        let resultURL = try await pollUntilDone(jobId: jobId, progress: progress)
        return try await downloadResults(resultURL: resultURL, outputDirectory: outputDirectory)
    }

    /// Submit raw image bytes (no disk round-trip), poll, and download all
    /// extracted markdown + images. Used by the camera capture path so the
    /// JPEG never has to touch the filesystem between capture and upload.
    public func process(
        imageData: Data,
        filename: String,
        mimeType: String,
        optionalPayload: OptionalPayload = OptionalPayload(),
        outputDirectory: URL,
        progress: (@Sendable (ProgressEvent) -> Void)? = nil
    ) async throws -> [ExtractedPage] {
        let jobId = try await submit(
            imageData: imageData,
            filename: filename,
            mimeType: mimeType,
            optionalPayload: optionalPayload
        )
        progress?(.submitted(jobId: jobId))
        let resultURL = try await pollUntilDone(jobId: jobId, progress: progress)
        return try await downloadResults(resultURL: resultURL, outputDirectory: outputDirectory)
    }

    // MARK: - Submission

    private func submit(remoteURL: URL, optionalPayload: OptionalPayload) async throws -> String {
        let payload = JobSubmissionURLPayload(
            fileUrl: remoteURL.absoluteString,
            model: config.model.rawValue,
            optionalPayload: optionalPayload
        )
        var request = URLRequest(url: config.jobURL)
        request.httpMethod = "POST"
        request.setValue("bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = try encoder.encode(payload)
        return try await submit(uploadRequest: request, body: body)
    }

    private func submit(fileURL: URL, optionalPayload: OptionalPayload) async throws -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw PaddleOCRError.fileNotFound(fileURL)
        }
        // `.mappedIfSafe` avoids materialising the file in heap memory for
        // anything large enough to mmap; APFS will fault pages in lazily as
        // `Data` is consumed by the multipart writer.
        let fileData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        return try await submit(
            imageData: fileData,
            filename: fileURL.lastPathComponent,
            mimeType: mimeType(forPathExtension: fileURL.pathExtension),
            optionalPayload: optionalPayload
        )
    }

    private func submit(
        imageData: Data,
        filename: String,
        mimeType: String,
        optionalPayload: OptionalPayload
    ) async throws -> String {
        let optionalJSON = try encoder.encode(optionalPayload)
        let optionalString = String(data: optionalJSON, encoding: .utf8) ?? "{}"

        let boundary = "Boundary-\(UUID().uuidString)"
        let body = buildMultipartBody(
            boundary: boundary,
            fields: [
                (name: "model", value: config.model.rawValue),
                (name: "optionalPayload", value: optionalString)
            ],
            file: (
                name: "file",
                filename: filename,
                mimeType: mimeType,
                data: imageData
            )
        )

        var request = URLRequest(url: config.jobURL)
        request.httpMethod = "POST"
        request.setValue("bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        return try await submit(uploadRequest: request, body: body)
    }

    /// Uses `upload(for:from:)` rather than stuffing the body into
    /// `URLRequest.httpBody`. Two reasons: the upload variant streams the
    /// body to the socket without first copying it into the request, and it
    /// participates in NSURLSession's background-transfer machinery.
    private func submit(uploadRequest: URLRequest, body: Data) async throws -> String {
        let (data, response) = try await session.upload(for: uploadRequest, from: body)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw PaddleOCRError.submissionFailed(
                status: status,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return try decoder.decode(JobSubmissionResponse.self, from: data).data.jobId
    }

    // MARK: - Polling

    /// Exponential backoff polling. Starts aggressive so short jobs finish
    /// without an unnecessary several-second sleep, and tapers off so long
    /// jobs don't hammer the status endpoint.
    private func pollUntilDone(
        jobId: String,
        progress: (@Sendable (ProgressEvent) -> Void)?
    ) async throws -> URL {
        let statusURL = config.jobURL.appendingPathComponent(jobId)
        var request = URLRequest(url: statusURL)
        request.setValue("bearer \(config.token)", forHTTPHeaderField: "Authorization")

        var delay = config.pollInitialDelay
        let maxDelay = config.pollMaxDelay
        let factor = config.pollBackoffFactor

        while true {
            try Task.checkCancellation()

            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                throw PaddleOCRError.statusRequestFailed(
                    status: status,
                    body: String(data: data, encoding: .utf8) ?? ""
                )
            }
            let decoded = try decoder.decode(JobStatusResponse.self, from: data)

            switch decoded.data.state {
            case .pending:
                progress?(.pending)
            case .running:
                progress?(.running(
                    extracted: decoded.data.extractProgress?.extractedPages,
                    total: decoded.data.extractProgress?.totalPages
                ))
            case .done:
                guard
                    let urlString = decoded.data.resultUrl?.jsonUrl,
                    let url = URL(string: urlString)
                else {
                    throw PaddleOCRError.missingResultURL
                }
                progress?(.completed(
                    extractedPages: decoded.data.extractProgress?.extractedPages ?? 0,
                    startTime: decoded.data.extractProgress?.startTime,
                    endTime: decoded.data.extractProgress?.endTime
                ))
                return url
            case .failed:
                throw PaddleOCRError.jobFailed(message: decoded.data.errorMsg ?? "unknown")
            }

            try await Task.sleep(for: delay)
            delay = Self.backoff(current: delay, factor: factor, max: maxDelay)
        }
    }

    /// Multiplies `current` by `factor`, capped at `max`. Pulled out so the
    /// inner loop reads cleanly and the conversion through nanoseconds is
    /// confined to one place.
    private static func backoff(current: Duration, factor: Double, max: Duration) -> Duration {
        // `Duration.components.attoseconds` is the fractional part in 10⁻¹⁸ s;
        // squashing the whole thing through nanoseconds is precise enough for
        // a polling cadence and avoids overflowing `Int64` on long delays.
        let currentNs =
            current.components.seconds * 1_000_000_000
            + current.components.attoseconds / 1_000_000_000
        let maxNs =
            max.components.seconds * 1_000_000_000
            + max.components.attoseconds / 1_000_000_000
        let nextNs = Int64(Double(currentNs) * factor)
        let cappedNs = Swift.min(nextNs, maxNs)
        return .nanoseconds(cappedNs)
    }

    // MARK: - Result download

    private func downloadResults(
        resultURL: URL,
        outputDirectory: URL
    ) async throws -> [ExtractedPage] {
        let (jsonlData, _) = try await session.data(from: resultURL)
        guard let text = String(data: jsonlData, encoding: .utf8) else {
            throw PaddleOCRError.invalidResponseBody
        }

        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

        var pages: [ExtractedPage] = []
        var pageIndex = 0

        for line in lines {
            guard let data = line.data(using: .utf8) else { continue }
            let parsed = try decoder.decode(LayoutResultLine.self, from: data)
            let preprocessed = parsed.result.preprocessedImages
            for (localIndex, parsing) in parsed.result.layoutParsingResults.enumerated() {
                let preprocessedURLString: String? =
                    (preprocessed != nil && localIndex < preprocessed!.count)
                    ? preprocessed![localIndex] : nil
                let page = try await writePage(
                    pageIndex: pageIndex,
                    parsing: parsing,
                    preprocessedImageURLString: preprocessedURLString,
                    outputDirectory: outputDirectory
                )
                pages.append(page)
                pageIndex += 1
            }
        }

        return pages
    }

    private func writePage(
        pageIndex: Int,
        parsing: LayoutParsingResult,
        preprocessedImageURLString: String?,
        outputDirectory: URL
    ) async throws -> ExtractedPage {
        let mdURL = outputDirectory.appendingPathComponent("doc_\(pageIndex).md")
        try parsing.markdown.text.write(to: mdURL, atomically: true, encoding: .utf8)

        let inlineSpecs: [(String, URL, URL)] = parsing.markdown.images.compactMap { (relativePath, urlString) in
            guard let remote = URL(string: urlString) else { return nil }
            return (relativePath, remote, outputDirectory.appendingPathComponent(relativePath))
        }

        let outputSpecs: [(String, URL, URL)] = (parsing.outputImages ?? [:]).compactMap { (name, urlString) in
            guard let remote = URL(string: urlString) else { return nil }
            return (name, remote, outputDirectory.appendingPathComponent("\(name)_\(pageIndex).jpg"))
        }

        let preprocessedSpecs: [(String, URL, URL)] = {
            guard
                let urlString = preprocessedImageURLString,
                let remote = URL(string: urlString)
            else { return [] }
            return [(
                "preprocessed",
                remote,
                outputDirectory.appendingPathComponent("preprocessed_\(pageIndex).jpg")
            )]
        }()

        // Fan all three download buckets out in parallel — they're
        // independent and otherwise serialise on this method's await chain.
        async let inlineResults = downloadConcurrently(specs: inlineSpecs)
        async let outputResults = downloadConcurrently(specs: outputSpecs)
        async let preprocessedResults = downloadConcurrently(specs: preprocessedSpecs)

        let (inline, outputs, preprocessed) = try await (inlineResults, outputResults, preprocessedResults)

        let blocks: [TextBlock] = (parsing.prunedResult?.parsingResList ?? []).map { raw in
            TextBlock(label: raw.blockLabel, bbox: raw.blockBbox, content: raw.blockContent)
        }

        return ExtractedPage(
            pageIndex: pageIndex,
            markdown: parsing.markdown.text,
            blocks: blocks,
            inlineImages: inline,
            outputImages: outputs,
            prunedResult: parsing.prunedResult,
            preprocessedImageURL: preprocessed["preprocessed"]
        )
    }

    private func downloadConcurrently(
        specs: [(String, URL, URL)]
    ) async throws -> [String: URL] {
        guard !specs.isEmpty else { return [:] }
        let limit = config.maxConcurrentImageDownloads
        let session = self.session

        return try await withThrowingTaskGroup(of: (String, URL).self) { group in
            var results: [String: URL] = [:]
            results.reserveCapacity(specs.count)
            var iterator = specs.makeIterator()
            var inFlight = 0

            @discardableResult
            func enqueueNext() -> Bool {
                guard let next = iterator.next() else { return false }
                let (key, remote, dest) = next
                group.addTask {
                    let parent = dest.deletingLastPathComponent()
                    try FileManager.default.createDirectory(
                        at: parent,
                        withIntermediateDirectories: true
                    )
                    let (data, response) = try await session.data(from: remote)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                    guard (200..<300).contains(status) else {
                        throw PaddleOCRError.imageDownloadFailed(remote, status: status)
                    }
                    try data.write(to: dest, options: .atomic)
                    return (key, dest)
                }
                return true
            }

            while inFlight < limit, enqueueNext() {
                inFlight += 1
            }
            while let (key, url) = try await group.next() {
                results[key] = url
                if !enqueueNext() { inFlight -= 1 }
            }
            return results
        }
    }
}
