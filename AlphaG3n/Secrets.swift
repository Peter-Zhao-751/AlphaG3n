//
//  Secrets.swift
//  AlphaG3n
//
//  API tokens are injected into the app's Info.plist at build time via
//  `secrets.xcconfig` (gitignored). The keys live in the bundle as plain
//  Info.plist strings, and this file is the single place that reads them.
//

import Foundation

enum Secrets {
    static var jinaAPIKey: String? { value(for: "JINA_API_KEY") }
    static var paddleAPIKey: String? { value(for: "PADDLE_API_KEY") }

    /// Returns the trimmed Info.plist value, or `nil` if the key is missing,
    /// empty, or still the unresolved `$(VAR)` placeholder (which happens when
    /// the xcconfig variable wasn't set during the build).
    private static func value(for key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("$(") { return nil }
        return trimmed
    }
}

// MARK: - Client defaults

extension PaddleOCRClient {
    static var isAPIKeyConfigured: Bool { Secrets.paddleAPIKey != nil }

    /// Builds a client using the token baked into the app bundle.
    /// Returns a client with an empty token if the key is missing — callers
    /// should gate work on `isAPIKeyConfigured` first.
    static func makeDefault() -> PaddleOCRClient {
        PaddleOCRClient(configuration: .init(token: Secrets.paddleAPIKey ?? ""))
    }
}

extension JinaSegmenterClient {
    static var isAPIKeyConfigured: Bool { Secrets.jinaAPIKey != nil }

    /// Builds a client using the token baked into the app bundle.
    /// Returns a client with an empty token if the key is missing — callers
    /// should gate work on `isAPIKeyConfigured` first.
    static func makeDefault() -> JinaSegmenterClient {
        JinaSegmenterClient(configuration: .init(token: Secrets.jinaAPIKey ?? ""))
    }
}
