//
//  JinaSegmenterModel.swift
//  AlphaG3n
//
//  Created by Owen Gregson on 5/23/26.
//

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Public types

public enum JinaTokenizer: String, Sendable, Codable {
    case cl100kBase = "cl100k_base"
    case o200kBase = "o200k_base"
    case p50kBase = "p50k_base"
    case r50kBase = "r50k_base"
    case p50kEdit = "p50k_edit"
    case gpt2 = "gpt2"
}

public struct SegmentRequestOptions: Sendable {
    public var tokenizer: JinaTokenizer
    public var returnTokens: Bool
    public var returnChunks: Bool
    public var maxChunkLength: Int?
    public var head: Int?
    public var tail: Int?

    public init(
        tokenizer: JinaTokenizer = .cl100kBase,
        returnTokens: Bool = false,
        returnChunks: Bool = true,
        maxChunkLength: Int? = 1000,
        head: Int? = nil,
        tail: Int? = nil
    ) {
        self.tokenizer = tokenizer
        self.returnTokens = returnTokens
        self.returnChunks = returnChunks
        self.maxChunkLength = maxChunkLength
        self.head = head
        self.tail = tail
    }
}

public struct SegmentChunk: Sendable {
    public let index: Int
    public let text: String
    public let startOffset: Int
    public let endOffset: Int
}

public struct SegmentToken: Sendable {
    public let text: String
    public let ids: [Int]
}

public struct SegmentResult: Sendable {
    public let numTokens: Int
    public let tokenizer: String
    public let usageTokens: Int
    public let numChunks: Int
    public let chunks: [SegmentChunk]
    public let tokens: [SegmentToken]
}

public enum JinaSegmenterError: Error, CustomStringConvertible {
    case emptyContent
    case requestFailed(status: Int, body: String)
    case invalidResponseBody
    case malformedChunkPositions

    public var description: String {
        switch self {
        case .emptyContent:
            return "Segmenter content must not be empty"
        case .requestFailed(let status, let body):
            return "Segment request failed (HTTP \(status)): \(body)"
        case .invalidResponseBody:
            return "Response body could not be decoded"
        case .malformedChunkPositions:
            return "Chunk positions array did not match the chunks array"
        }
    }
}

// MARK: - Wire types

nonisolated private struct SegmentRequestPayload: Encodable {
    let content: String
    let tokenizer: String
    let returnTokens: Bool
    let returnChunks: Bool
    let maxChunkLength: Int?
    let head: Int?
    let tail: Int?

    enum CodingKeys: String, CodingKey {
        case content
        case tokenizer
        case returnTokens = "return_tokens"
        case returnChunks = "return_chunks"
        case maxChunkLength = "max_chunk_length"
        case head
        case tail
    }
}

nonisolated private struct SegmentResponse: Decodable {
    let numTokens: Int?
    let tokenizer: String?
    let usage: Usage?
    let numChunks: Int?
    let chunkPositions: [[Int]]?
    let chunks: [String]?
    let tokens: [[TokenEntry]]?

    struct Usage: Decodable {
        let tokens: Int?
    }

    enum CodingKeys: String, CodingKey {
        case numTokens = "num_tokens"
        case tokenizer
        case usage
        case numChunks = "num_chunks"
        case chunkPositions = "chunk_positions"
        case chunks
        case tokens
    }

    // Jina returns each token as a heterogeneous array: [string, [int, ...], ...].
    // We only care about the leading string and the integer-id array.
    enum TokenEntry: Decodable {
        case string(String)
        case ids([Int])
        case other

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let s = try? container.decode(String.self) {
                self = .string(s)
            } else if let ids = try? container.decode([Int].self) {
                self = .ids(ids)
            } else {
                self = .other
            }
        }
    }
}

// MARK: - Client

public actor JinaSegmenterClient {

    public struct Configuration: Sendable {
        public var endpoint: URL
        public var token: String
        public var defaultOptions: SegmentRequestOptions
        public var timeout: TimeInterval

        public init(
            endpoint: URL = URL(string: "https://api.jina.ai/v1/segment")!,
            token: String,
            defaultOptions: SegmentRequestOptions = SegmentRequestOptions(),
            timeout: TimeInterval = 30
        ) {
            self.endpoint = endpoint
            self.token = token
            self.defaultOptions = defaultOptions
            self.timeout = timeout
        }
    }

    private let config: Configuration
    private let session: URLSession
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    public init(configuration: Configuration, session: URLSession = .shared) {
        self.config = configuration
        self.session = session
    }

    // MARK: Public API

    /// Tokenize and segment `content` into attention-sized chunks.
    public func segment(
        content: String,
        options: SegmentRequestOptions? = nil
    ) async throws -> SegmentResult {
        guard !content.isEmpty else { throw JinaSegmenterError.emptyContent }

        let opts = options ?? config.defaultOptions
        let payload = SegmentRequestPayload(
            content: content,
            tokenizer: opts.tokenizer.rawValue,
            returnTokens: opts.returnTokens,
            returnChunks: opts.returnChunks,
            maxChunkLength: opts.maxChunkLength,
            head: opts.head,
            tail: opts.tail
        )

        var request = URLRequest(url: config.endpoint, timeoutInterval: config.timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try encoder.encode(payload)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw JinaSegmenterError.requestFailed(
                status: status,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        let decoded: SegmentResponse
        do {
            decoded = try decoder.decode(SegmentResponse.self, from: data)
        } catch {
            throw JinaSegmenterError.invalidResponseBody
        }

        return try makeResult(from: decoded)
    }

    /// Convenience: return only the segmented chunk strings, in order.
    public func chunks(
        for content: String,
        options: SegmentRequestOptions? = nil
    ) async throws -> [String] {
        let result = try await segment(content: content, options: options)
        return result.chunks.map(\.text)
    }

    // MARK: Result assembly

    private func makeResult(from response: SegmentResponse) throws -> SegmentResult {
        let chunkStrings = response.chunks ?? []
        let positions = response.chunkPositions ?? []

        if !chunkStrings.isEmpty, !positions.isEmpty,
           chunkStrings.count != positions.count {
            throw JinaSegmenterError.malformedChunkPositions
        }

        var chunks: [SegmentChunk] = []
        chunks.reserveCapacity(chunkStrings.count)
        for (i, text) in chunkStrings.enumerated() {
            let pair = i < positions.count ? positions[i] : []
            let start = pair.count > 0 ? pair[0] : 0
            let end = pair.count > 1 ? pair[1] : start + text.count
            chunks.append(SegmentChunk(
                index: i,
                text: text,
                startOffset: start,
                endOffset: end
            ))
        }

        let tokens: [SegmentToken] = (response.tokens ?? []).compactMap { entries in
            var text: String?
            var ids: [Int] = []
            for entry in entries {
                switch entry {
                case .string(let s) where text == nil:
                    text = s
                case .ids(let arr) where ids.isEmpty:
                    ids = arr
                default:
                    continue
                }
            }
            guard let t = text else { return nil }
            return SegmentToken(text: t, ids: ids)
        }

        return SegmentResult(
            numTokens: response.numTokens ?? 0,
            tokenizer: response.tokenizer ?? "",
            usageTokens: response.usage?.tokens ?? 0,
            numChunks: response.numChunks ?? chunks.count,
            chunks: chunks,
            tokens: tokens
        )
    }
}
