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

public struct OptionalPayload: Codable, Sendable {
    public var useDocOrientationClassify: Bool
    public var useDocUnwarping: Bool
    public var useChartRecognition: Bool

    public init(
        useDocOrientationClassify: Bool = false,
        useDocUnwarping: Bool = false,
        useChartRecognition: Bool = false
    ) {
        self.useDocOrientationClassify = useDocOrientationClassify
        self.useDocUnwarping = useDocUnwarping
        self.useChartRecognition = useChartRecognition
    }
}

public struct ExtractedPage: Sendable {
    public let pageIndex: Int
    public let markdown: String
    public let blocks: [TextBlock]
    public let inlineImages: [String: URL]
    public let outputImages: [String: URL]
    /// The full per-page JSON response from the API, kept around so callers can
    /// inspect any field PaddleOCR returns that we don't decode explicitly.
    public let rawJSON: String
}

public struct TextBlock: Sendable {
    /// PaddleOCR's category for the block (e.g. "text", "title", "table").
    public let label: String
    /// `[x1, y1, x2, y2]` in the source image's pixel coordinates.
    public let bbox: [Double]
    /// Text content for the block, if PaddleOCR returned one.
    public let content: String
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
}

nonisolated private struct LayoutParsingResult: Decodable {
    let markdown: MarkdownPayload
    let outputImages: [String: String]?
    let prunedResult: PrunedResult?
}

nonisolated private struct MarkdownPayload: Decodable {
    let text: String
    let images: [String: String]
}

/// Optional everywhere — PaddleOCR's field names are best-effort guesses
/// (camelCase to match the rest of the API). A missing field just means we
/// fall back to the raw JSON dump for that page.
nonisolated private struct PrunedResult: Decodable {
    let parsingResList: [ParsingResultBlock]?
}

nonisolated private struct ParsingResultBlock: Decodable {
    let blockLabel: String?
    let blockBbox: [Double]?
    let blockContent: String?
}

// MARK: - Multipart helper (plain struct; not an actor)

nonisolated private struct MultipartFormData {
    let boundary: String
    private var body = Data()

    init(boundary: String = "Boundary-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func appendField(name: String, value: String) {
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.appendString("\(value)\r\n")
    }

    mutating func appendFile(name: String, filename: String, mimeType: String, data fileData: Data) {
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        body.appendString("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        body.appendString("\r\n")
    }

    func finalize() -> Data {
        var finalBody = body
        finalBody.appendString("--\(boundary)--\r\n")
        return finalBody
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}

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

// MARK: - Client

public actor PaddleOCRClient {

    public struct Configuration: Sendable {
        public var jobURL: URL
        public var token: String
        public var model: PaddleOCRModel
        public var pollInterval: Duration
        public var maxConcurrentImageDownloads: Int

        public init(
            jobURL: URL = URL(string: "https://paddleocr.aistudio-app.com/api/v2/ocr/jobs")!,
            token: String,
            model: PaddleOCRModel = .paddleOCRVL15,
            pollInterval: Duration = .seconds(5),
            maxConcurrentImageDownloads: Int = 8
        ) {
            self.jobURL = jobURL
            self.token = token
            self.model = model
            self.pollInterval = pollInterval
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

    public init(configuration: Configuration, session: URLSession = .shared) {
        self.config = configuration
        self.session = session
    }

    // MARK: Public API

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

    // MARK: Submission

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
        request.httpBody = try encoder.encode(payload)
        return try await submit(request: request)
    }

    private func submit(fileURL: URL, optionalPayload: OptionalPayload) async throws -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw PaddleOCRError.fileNotFound(fileURL)
        }
        let fileData = try Data(contentsOf: fileURL)
        let optionalJSON = try encoder.encode(optionalPayload)
        let optionalString = String(data: optionalJSON, encoding: .utf8) ?? "{}"

        var form = MultipartFormData()
        form.appendField(name: "model", value: config.model.rawValue)
        form.appendField(name: "optionalPayload", value: optionalString)
        form.appendFile(
            name: "file",
            filename: fileURL.lastPathComponent,
            mimeType: mimeType(forPathExtension: fileURL.pathExtension),
            data: fileData
        )

        var request = URLRequest(url: config.jobURL)
        request.httpMethod = "POST"
        request.setValue("bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finalize()
        return try await submit(request: request)
    }

    private func submit(request: URLRequest) async throws -> String {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw PaddleOCRError.submissionFailed(
                status: status,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return try decoder.decode(JobSubmissionResponse.self, from: data).data.jobId
    }

    // MARK: Polling

    private func pollUntilDone(
        jobId: String,
        progress: (@Sendable (ProgressEvent) -> Void)?
    ) async throws -> URL {
        let statusURL = config.jobURL.appendingPathComponent(jobId)
        var request = URLRequest(url: statusURL)
        request.setValue("bearer \(config.token)", forHTTPHeaderField: "Authorization")

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

            try await Task.sleep(for: config.pollInterval)
        }
    }

    // MARK: Result download

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
            for parsing in parsed.result.layoutParsingResults {
                let page = try await writePage(
                    pageIndex: pageIndex,
                    parsing: parsing,
                    rawJSON: line,
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
        rawJSON: String,
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

        let inlineResults = try await downloadConcurrently(specs: inlineSpecs)
        let outputResults = try await downloadConcurrently(specs: outputSpecs)

        let blocks: [TextBlock] = (parsing.prunedResult?.parsingResList ?? []).compactMap { raw in
            guard let label = raw.blockLabel, let bbox = raw.blockBbox else { return nil }
            return TextBlock(label: label, bbox: bbox, content: raw.blockContent ?? "")
        }

        return ExtractedPage(
            pageIndex: pageIndex,
            markdown: parsing.markdown.text,
            blocks: blocks,
            inlineImages: inlineResults,
            outputImages: outputResults,
            rawJSON: rawJSON
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
