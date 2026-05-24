//
//  OpenAIClient.swift
//  AlphaG3n
//
//  Minimal OpenAI **Responses API** client for image (vision) prompts.
//  Transport only — the prompt wording lives with the caller (e.g. CraftModel),
//  so the model / detail / temperature knobs are here and the wording is there.
//
//    • single image      → `vision(system:user:jpeg:)`
//    • many concurrently → `visionBatch(system:user:images:)`
//    • OCR convenience    → `readText(in:)`  (bakes a "read the text" prompt)
//
//  Uses POST /v1/responses (the current format for GPT-5.x). The response
//  `output` array may include a `reasoning` item ahead of the `message`, so we
//  select the message item(s) and concatenate their `output_text` parts.
//

import Foundation

public struct OpenAIClient: Sendable {

    /// Vision image detail. `.high` markedly improves small-text OCR but costs
    /// more tokens; `.low` is cheaper/faster; `.auto` lets the API decide.
    public enum ImageDetail: String, Sendable { case low, high, auto }

    /// How the model should shape its reply (Responses API `text.format`).
    ///   • `.text`       — free-form text.
    ///   • `.jsonObject` — any valid JSON object (the prompt must mention "JSON").
    ///   • `.jsonSchema` — Structured Outputs: the reply is GUARANTEED to match
    ///     `schemaJSON` (a JSON-schema string), so it decodes cleanly.
    public enum ResponseFormat: Sendable {
        case text
        case jsonObject
        case jsonSchema(name: String, schemaJSON: String)
    }

    /// GPT-5.x reasoning budget. Lower = faster + cheaper; `.minimal` suits
    /// mechanical work like OCR. Omitted from the request when `nil` (the model
    /// default, usually `.medium`). Non-reasoning models (e.g. gpt-4o) ignore
    /// reasoning, so leave this `nil` for them.
    public enum ReasoningEffort: String, Sendable {
        case minimal, low, medium, high
    }

    public var apiKey: String
    public var model: String
    /// Omitted from the request when `nil`. GPT-5.x reasoning models reject an
    /// explicit `temperature`, so leave this `nil` for them; set it (e.g. 0)
    /// only for 4o-class models that still accept it.
    public var temperature: Double?
    public var imageDetail: ImageDetail
    /// Shape of the model's reply. Defaults to `.jsonObject` (back-compatible
    /// with the previous `jsonObjectResponse = true`).
    public var responseFormat: ResponseFormat
    /// GPT-5.x reasoning budget; `nil` uses the model default. See `ReasoningEffort`.
    public var reasoningEffort: ReasoningEffort?
    public var endpoint: URL

    public init(apiKey: String,
                model: String = "gpt-5-nano-2025-08-07",
                temperature: Double? = nil,
                imageDetail: ImageDetail = .auto,
                responseFormat: ResponseFormat = .jsonObject,
                reasoningEffort: ReasoningEffort? = nil,
                endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!) {
        self.apiKey = apiKey
        self.model = model
        self.temperature = temperature
        self.imageDetail = imageDetail
        self.responseFormat = responseFormat
        self.reasoningEffort = reasoningEffort
        self.endpoint = endpoint
    }

    public enum OpenAIError: Error, LocalizedError, Sendable {
        case http(Int, String)
        case transport(String)
        case badResponse(String)

        public var errorDescription: String? {
            switch self {
            case .http(let code, let body): return "OpenAI HTTP \(code): \(body)"
            case .transport(let msg):       return "OpenAI request failed: \(msg)"
            case .badResponse(let body):    return "Unexpected OpenAI response shape: \(body)"
            }
        }
    }

    // MARK: - Single image

    /// Sends a system + user prompt with one JPEG image to the Responses API and
    /// returns the model's text output (a JSON string when `responseFormat` is
    /// `.jsonObject` / `.jsonSchema`). Throws `OpenAIError` on any failure.
    public func vision(system: String,
                       user: String,
                       jpeg: Data,
                       session: URLSession = .shared) async throws -> String {
        let dataURL = "data:image/jpeg;base64,\(jpeg.base64EncodedString())"

        var body: [String: Any] = [
            "model": model,
            "input": [
                ["role": "system",
                 "content": [["type": "input_text", "text": system]]],
                ["role": "user",
                 "content": [
                    ["type": "input_text", "text": user],
                    ["type": "input_image",
                     "image_url": dataURL,
                     "detail": imageDetail.rawValue]
                 ]]
            ]
        ]
        applyOptions(to: &body)
        return try await send(body, session: session)
    }

    // MARK: - Text-only

    /// System prompt for summarizing a fetched web page for someone who cannot
    /// see it. Wording matches the app's other read-aloud summaries.
    public static let webPageSummarySystemPrompt = """
    You are an assistant that summarizes the content of a web page for a user \
    who cannot view it. Identify the main topics and subtopics, mention \
    important lists or form elements and their purposes, and communicate the \
    main purpose of the page. Be thorough so the user fully understands the \
    page's content and purpose. Respond in a straightforward, confident manner \
    (e.g., "The page is about..."). Provide output as plain text with no \
    special formatting.
    """

    /// Sends a system + user prompt with **no image** and returns the model's
    /// text output. Same transport and options as `vision(...)`, minus the image
    /// part of the user turn.
    public func respondText(system: String,
                            user: String,
                            session: URLSession = .shared) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "input": [
                ["role": "system",
                 "content": [["type": "input_text", "text": system]]],
                ["role": "user",
                 "content": [["type": "input_text", "text": user]]]
            ]
        ]
        applyOptions(to: &body)
        return try await send(body, session: session)
    }

    /// Summarizes already-extracted web-page `text` into a brief, spoken-friendly
    /// blurb (the "summarized" abstraction: 2–3 sentences). Forces a free-form
    /// text reply; leaves the reasoning budget at the model default since a good
    /// summary benefits from some reasoning. Throws `OpenAIError` on failure.
    public func summarizeWebPage(text: String,
                                 session: URLSession = .shared) async throws -> String {
        var client = self
        client.responseFormat = .text
        let system = Self.webPageSummarySystemPrompt + " Output a brief 2–3 sentence summary."
        return try await client.respondText(
            system: system,
            user: "Summarize this web page content:\n\n\(text)",
            session: session)
    }

    /// Applies the shared model knobs (temperature, reasoning effort, response
    /// format) onto a Responses request body.
    private func applyOptions(to body: inout [String: Any]) {
        if let temperature { body["temperature"] = temperature }
        if let reasoningEffort { body["reasoning"] = ["effort": reasoningEffort.rawValue] }
        switch responseFormat {
        case .text:
            break
        case .jsonObject:
            body["text"] = ["format": ["type": "json_object"]]
        case .jsonSchema(let name, let schemaJSON):
            if let schema = try? JSONSerialization.jsonObject(with: Data(schemaJSON.utf8)) {
                body["text"] = ["format": [
                    "type": "json_schema",
                    "name": name,
                    "strict": true,
                    "schema": schema
                ]]
            }
        }
    }

    /// POSTs a prepared Responses body and returns the assistant text. Shared
    /// transport for `vision(...)` and `respondText(...)`.
    private func send(_ body: [String: Any],
                      session: URLSession) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OpenAIError.transport(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw OpenAIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try Self.extractOutputText(from: data)
    }

    /// Pulls the assistant text out of a Responses-API payload. The `output`
    /// array can carry non-message items (e.g. a `reasoning` item on GPT-5.x),
    /// so we keep only `message` items and join their `output_text` parts.
    static func extractOutputText(from data: Data) throws -> String {
        let raw = String(data: data, encoding: .utf8) ?? ""
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAIError.badResponse(raw)
        }
        // Some payloads also surface a top-level `output_text` convenience field.
        if let top = json["output_text"] as? String {
            let trimmed = top.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        guard let output = json["output"] as? [[String: Any]] else {
            throw OpenAIError.badResponse(raw)
        }
        var text = ""
        for item in output where (item["type"] as? String) == "message" {
            guard let content = item["content"] as? [[String: Any]] else { continue }
            for part in content where (part["type"] as? String) == "output_text" {
                if let t = part["text"] as? String { text += t }
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Concurrent batch

    /// System prompt used by `readText(in:)`. Transcribes text as natural,
    /// reflowed prose (no mid-sentence line breaks from visual wrapping), or
    /// flags the image as empty / unreadable / irrelevant. `unreadable` gets no `note`.
    public static let readTextSystemPrompt = """
    Transcribe the image's text the way a person would read it aloud, then set status:

    • readable — legible, meaningful text. Put it in `text` as flowing prose: \
    merge lines that belong to the same sentence or paragraph, and do NOT break \
    text apart just because it wrapped onto separate lines in the image. Keep \
    real paragraph breaks only. When a word or character is hard to make out, \
    transcribe your best guess — never write "[unclear]", "?", "...", brackets, \
    or any note about uncertainty. Just commit to the most likely reading. \
    Leave `note` empty.
    • empty — no text at all. Leave `text` empty; in `note`, briefly say no text was found.
    • unreadable — text present but too blurry, dark, or small to even guess at. \
    Use this ONLY when you are not confident enough to guess; if you can guess, \
    stay readable. Leave `text` and `note` empty.
    • irrelevant — not real text to read aloud (keyboard, buttons, logos, labels). \
    Leave `text` empty; in `note`, briefly say what the image shows.

    Keep any `note` to one short spoken sentence.
    """

    /// Fires one Responses request per image **concurrently** (at most
    /// `maxConcurrent` in flight) and returns one result per image, IN INPUT
    /// ORDER. A single image's failure is captured as `.failure(...)` and never
    /// sinks the rest of the batch — this is the "accept all the responses"
    /// handler. Does not throw.
    public func visionBatch(system: String,
                            user: String,
                            images: [Data],
                            maxConcurrent: Int = 5,
                            session: URLSession = .shared) async -> [Result<String, Error>] {
        guard !images.isEmpty else { return [] }
        let limit = max(1, maxConcurrent)

        let collected: [Result<String, OpenAIError>] = await withTaskGroup(
            of: (Int, Result<String, OpenAIError>).self
        ) { group in
            var results = [Result<String, OpenAIError>?](repeating: nil, count: images.count)
            var next = 0

            func schedule(_ index: Int) {
                let jpeg = images[index]
                group.addTask {
                    do {
                        let text = try await self.vision(system: system, user: user,
                                                         jpeg: jpeg, session: session)
                        return (index, .success(text))
                    } catch let error as OpenAIError {
                        return (index, .failure(error))
                    } catch {
                        return (index, .failure(.transport(error.localizedDescription)))
                    }
                }
            }

            // Prime the window, then top it up as each request finishes.
            while next < min(limit, images.count) { schedule(next); next += 1 }
            while let (index, result) = await group.next() {
                results[index] = result
                if next < images.count { schedule(next); next += 1 }
            }
            return results.map { $0 ?? .failure(.badResponse("missing result")) }
        }

        return collected.map { $0.mapError { $0 as Error } }
    }

    /// Concurrent OCR convenience: uploads `images` with the built-in triage
    /// prompt and returns, per image and IN ORDER, a structured `TextReading` —
    /// the transcription plus a `status` that flags when the text is missing,
    /// unreadable, or irrelevant (e.g. a keyboard). Uses Structured Outputs so
    /// the JSON is guaranteed to decode into `TextReading`. Does not throw.
    public func readText(in images: [Data],
                         maxConcurrent: Int = 5,
                         session: URLSession = .shared) async -> [Result<TextReading, Error>] {
        var structured = self
        structured.responseFormat = .jsonSchema(name: "text_reading",
                                                schemaJSON: TextReading.schemaJSON)
        // OCR is mechanical, not a reasoning task — minimal effort is much faster.
        // Caller can override by setting `reasoningEffort` to something higher.
        if structured.reasoningEffort == nil { structured.reasoningEffort = .minimal }
        let rawResults = await structured.visionBatch(
            system: Self.readTextSystemPrompt,
            user: "Read the text in this image.",
            images: images,
            maxConcurrent: maxConcurrent,
            session: session)

        let decoder = JSONDecoder()
        return rawResults.map { result in
            result.flatMap { jsonString in
                do {
                    return .success(try decoder.decode(TextReading.self, from: Data(jsonString.utf8)))
                } catch {
                    return .failure(OpenAIError.badResponse(
                        "could not decode TextReading (\(error.localizedDescription)): \(jsonString)"))
                }
            }
        }
    }

    /// One image's reading: the transcription plus a flag describing whether the
    /// text is usable. Produced by `readText(in:)` via Structured Outputs.
    public struct TextReading: Sendable, Codable, Equatable {
        public enum Status: String, Sendable, Codable {
            case readable      // legible, meaningful text was transcribed into `text`
            case empty         // the image contains no text at all
            case unreadable    // text is present but too blurry/dark/small to read
            case irrelevant    // markings aren't real text (e.g. a keyboard, logos, UI)
        }
        /// Which of the four cases this image fell into.
        public let status: Status
        /// The transcription. Empty unless `status == .readable`.
        public let text: String
        /// A short, plain, read-aloud-friendly explanation. Empty when `readable`,
        /// otherwise says why (e.g. "The image is too blurry to read.").
        public let note: String

        /// JSON schema (as a string) handed to the Responses API for strict
        /// Structured Outputs — keep it in sync with the properties above.
        public static let schemaJSON = """
        {
          "type": "object",
          "properties": {
            "status": { "type": "string", "enum": ["readable", "empty", "unreadable", "irrelevant"] },
            "text":   { "type": "string" },
            "note":   { "type": "string" }
          },
          "required": ["status", "text", "note"],
          "additionalProperties": false
        }
        """
    }
}
