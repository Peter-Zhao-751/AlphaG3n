//
//  ModalOCRClient.swift
//  AlphaG3n
//
//  Talks to the self-hosted PaddleOCR-VL deployment on Modal instead of the
//  Baidu cloud API. Drop-in alternative to `PaddleOCRClient`: same
//  `process(imageData:...) -> [ExtractedPage]` surface and the same
//  `makeDefault()` / `isAPIKeyConfigured` convention, so `CameraManager` can
//  swap one for the other with a single property change.
//
//  The Modal endpoint (see modal_paddleocr_vl.py) accepts:
//      POST { "image_base64": "<base64 jpeg/png bytes>" }
//  and returns:
//      { "pages": [ { "markdown": "...", "raw": { "res": <PrunedResult-shaped> } } ] }
//  The "raw"."res" object already matches VirtualDocument.PrunedResult's wire
//  format (width / height / parsing_res_list with block_label/_content/_bbox),
//  so it decodes straight into the existing type — no remapping needed.
//

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class ModalOCRClient: @unchecked Sendable {

    public struct Configuration: Sendable {
        /// The Pipeline.parse web endpoint from your Modal deployment, e.g.
        /// https://<you>--paddleocr-vl-pipeline-parse.modal.run
        public var endpoint: URL
        /// Optional bearer token if you put auth in front of the endpoint.
        /// Leave nil for an unauthenticated Modal web endpoint.
        public var token: String?
        public var requestTimeout: TimeInterval
        public var resourceTimeout: TimeInterval

        public init(
            endpoint: URL,
            token: String? = nil,
            requestTimeout: TimeInterval = 30,
            resourceTimeout: TimeInterval = 180
        ) {
            self.endpoint = endpoint
            self.token = token
            self.requestTimeout = requestTimeout
            self.resourceTimeout = resourceTimeout
        }
    }

    public enum ModalOCRError: Error, CustomStringConvertible {
        case requestFailed(status: Int, body: String)
        case invalidResponseBody
        case serverError(String)

        public var description: String {
            switch self {
            case .requestFailed(let status, let body):
                return "Modal OCR request failed (HTTP \(status)): \(body)"
            case .invalidResponseBody:
                return "Modal OCR response could not be decoded"
            case .serverError(let message):
                return "Modal OCR server error: \(message)"
            }
        }
    }

    private let config: Configuration
    private let session: URLSession
    private let decoder = JSONDecoder()

    public init(configuration: Configuration, session: URLSession? = nil) {
        self.config = configuration
        self.session = session ?? Self.makeDefaultSession(config: configuration)
    }

    private static func makeDefaultSession(config: Configuration) -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = config.requestTimeout
        cfg.timeoutIntervalForResource = config.resourceTimeout
        cfg.waitsForConnectivity = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpAdditionalHeaders = ["Accept-Encoding": "gzip, deflate"]
        return URLSession(configuration: cfg)
    }

    // MARK: - Wire types (Modal endpoint response)

    private struct ModalResponse: Decodable {
        let pages: [ModalPage]?
        let error: String?
    }

    private struct ModalPage: Decodable {
        let markdown: String
        let raw: RawWrapper?
    }

    /// The endpoint nests the pruned result under "raw"."res".
    private struct RawWrapper: Decodable {
        let res: VirtualDocument.PrunedResult?
    }

    // MARK: - Public API (mirrors PaddleOCRClient)

    /// Warm the TLS socket so the first capture isn't slowed by the handshake.
    public func warmUp() async {
        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        _ = try? await session.data(for: request)
    }

    /// Submit raw image bytes to the Modal endpoint and return the parsed pages.
    /// `outputDirectory` is accepted for signature-parity with `PaddleOCRClient`
    /// but unused — the Modal path returns inline data, nothing to write to disk.
    public func process(
        imageData: Data,
        filename: String = "capture.jpg",
        mimeType: String = "image/jpeg",
        outputDirectory: URL? = nil
    ) async throws -> [ExtractedPage] {
        let b64 = imageData.base64EncodedString()
        let body = try JSONSerialization.data(withJSONObject: ["image_base64": b64])

        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = config.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.upload(for: request, from: body)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw ModalOCRError.requestFailed(
                status: status,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        let decoded: ModalResponse
        do {
            decoded = try decoder.decode(ModalResponse.self, from: data)
        } catch {
            throw ModalOCRError.invalidResponseBody
        }
        if let message = decoded.error {
            throw ModalOCRError.serverError(message)
        }

        let pages = decoded.pages ?? []
        return pages.enumerated().map { index, page in
            let pruned = page.raw?.res
            let blocks: [TextBlock] = (pruned?.parsingResList ?? []).map { raw in
                TextBlock(label: raw.blockLabel, bbox: raw.blockBbox, content: raw.blockContent)
            }
            return ExtractedPage(
                pageIndex: index,
                markdown: page.markdown,
                blocks: blocks,
                inlineImages: [:],
                outputImages: [:],
                prunedResult: pruned,
                preprocessedImageURL: nil
            )
        }
    }
}

// MARK: - Client defaults (parallels the PaddleOCRClient extension in Secrets.swift)

extension ModalOCRClient {
    /// The Modal endpoint host is configured in secrets.xcconfig as
    /// MODAL_OCR_URL — stored *without* the `https://` scheme on purpose:
    /// xcconfig reads `//` as the start of a comment, so a full URL would be
    /// silently truncated to `https:`. `makeDefault()` prepends the scheme.
    static var isEndpointConfigured: Bool { Secrets.modalOCRURL != nil }

    /// Builds a client from the endpoint baked into the app bundle.
    /// Returns nil if the endpoint isn't configured — callers should gate on
    /// `isEndpointConfigured` first, mirroring PaddleOCRClient's pattern.
    static func makeDefault() -> ModalOCRClient? {
        guard let host = Secrets.modalOCRURL,
              let url = URL(string: "https://\(host)") else { return nil }
        return ModalOCRClient(configuration: .init(
            endpoint: url,
            token: Secrets.modalOCRToken
        ))
    }
}
