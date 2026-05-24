//
//  OpenAIClient.swift
//  AlphaG3n
//
//  Minimal OpenAI chat-completions client for single-image vision prompts.
//  This is transport only — the prompt text lives with the caller (CraftModel),
//  so the model/temperature/detail knobs are here and the wording is there.
//

import Foundation

public struct OpenAIClient {

    /// Vision image detail. `.high` markedly improves small-text OCR but costs
    /// more tokens; `.low` is cheaper/faster; `.auto` lets the API decide.
    public enum ImageDetail: String, Sendable { case low, high, auto }

    public var apiKey: String
    public var model: String
    public var temperature: Double
    public var imageDetail: ImageDetail
    /// When true, requests a strict JSON-object response (`response_format`).
    public var jsonObjectResponse: Bool
    public var endpoint: URL

    public init(apiKey: String,
                model: String = "gpt-4o",
                temperature: Double = 0,
                imageDetail: ImageDetail = .high,
                jsonObjectResponse: Bool = true,
                endpoint: URL = URL(string: "https://api.openai.com/v1/chat/completions")!) {
        self.apiKey = apiKey
        self.model = model
        self.temperature = temperature
        self.imageDetail = imageDetail
        self.jsonObjectResponse = jsonObjectResponse
        self.endpoint = endpoint
    }

    public enum OpenAIError: Error, LocalizedError {
        case http(Int, String)
        case badResponse

        public var errorDescription: String? {
            switch self {
            case .http(let code, let body): return "OpenAI HTTP \(code): \(body)"
            case .badResponse:              return "Unexpected OpenAI response shape."
            }
        }
    }

    /// Sends a system + user prompt with one JPEG image and returns the model's
    /// message content (a JSON object string when `jsonObjectResponse` is true).
    public func vision(system: String,
                       user: String,
                       jpeg: Data,
                       session: URLSession = .shared) async throws -> String {
        let dataURL = "data:image/jpeg;base64,\(jpeg.base64EncodedString())"

        var body: [String: Any] = [
            "model": model,
            "temperature": temperature,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": [
                    ["type": "text", "text": user],
                    ["type": "image_url",
                     "image_url": ["url": dataURL, "detail": imageDetail.rawValue]]
                ]]
            ]
        ]
        if jsonObjectResponse {
            body["response_format"] = ["type": "json_object"]
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw OpenAIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw OpenAIError.badResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
