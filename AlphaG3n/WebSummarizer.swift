//
//  WebSummarizer.swift
//  AlphaG3n
//
//  Visits a QR code's linked website and turns it into a short spoken-friendly
//  summary. This is the ONLY place a linked site is fetched — it runs when the
//  user taps a QR target on the result screen (see WebSummaryView), never at
//  scan time. So a site is opened only if the user chooses to.
//
//  Pipeline: GET the URL → decode bytes to text → HTMLTextExtractor strips the
//  markup → OpenAIClient summarizes. Every failure mode collapses to a short,
//  read-aloud-friendly `SummaryError` the UI can speak verbatim.
//

import Foundation

struct WebSummarizer: Sendable {

    /// Read-aloud-friendly failures. Each `errorDescription` is a single plain
    /// sentence suitable for VoiceOver to speak as-is.
    enum SummaryError: Error, LocalizedError {
        case notConfigured
        case unreachable
        case emptyPage
        case summarizationFailed

        var errorDescription: String? {
            switch self {
            case .notConfigured:       return "Website summaries aren't set up on this device."
            case .unreachable:         return "This website couldn't be opened."
            case .emptyPage:           return "There was no readable text on this website."
            case .summarizationFailed: return "This website couldn't be summarized."
            }
        }
    }

    /// Hard cap on page text handed to the model (characters). Keeps token cost
    /// and latency bounded on large pages; matches the reference pipeline.
    var maxTextChars = 120_000
    /// Per-request network timeout, in seconds.
    var timeout: TimeInterval = 15

    /// Fetches `url` and returns a brief summary, or throws a `SummaryError`
    /// (or `CancellationError`). Checks for cancellation between the network and
    /// model steps so dismissing the screen mid-load doesn't fire a model call.
    func summary(of url: URL, session: URLSession = .shared) async throws -> String {
        guard let apiKey = Secrets.openAIAPIKey else { throw SummaryError.notConfigured }

        // 1. Fetch. A User-Agent keeps sites that gate empty agents from 403ing.
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Mozilla/5.0 (compatible; AlphaG3n/1.0)",
                         forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw SummaryError.unreachable
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw SummaryError.unreachable
        }

        try Task.checkCancellation()

        // 2. Decode bytes → string. UTF-8 first; fall back to Latin-1 so a
        //    mislabeled or legacy page still yields readable-ish text.
        let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""

        // 3. Strip markup down to reading text.
        let text = HTMLTextExtractor.plainText(fromHTML: html, maxChars: maxTextChars)
        guard !text.isEmpty else { throw SummaryError.emptyPage }

        try Task.checkCancellation()

        // 4. Summarize. gpt-5-nano via the OpenAI Responses API.
        do {
            let client = OpenAIClient(apiKey: apiKey)
            let summary = try await client.summarizeWebPage(text: text, session: session)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else { throw SummaryError.summarizationFailed }
            return summary
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw SummaryError.summarizationFailed
        }
    }
}
