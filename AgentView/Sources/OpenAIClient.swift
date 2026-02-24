import Foundation
import os

final class OpenAIClient {
  struct OpenAIError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
  }

  struct StreamingResult: Equatable {
    let text: String
    let responseId: String?
  }

  private static let logger = Logger(subsystem: "AgentView", category: "OpenAIClient")
  private let maxAttempts = 2
  private let apiKey: String
  private let session: URLSession

  init(apiKey: String, session: URLSession = .agentViewDefault) {
    self.apiKey = apiKey
    self.session = session
  }

  private func debugLog(_ message: String) {
#if DEBUG
    Self.logger.debug("\(message, privacy: .public)")
#endif
  }

  func transcribeAudio(fileURL: URL) async throws -> String {
    guard let url = URL(string: "https://api.openai.com/v1/audio/transcriptions") else {
      throw OpenAIError(message: "Invalid OpenAI URL")
    }
    guard url.scheme == "https" else {
      throw OpenAIError(message: "Only HTTPS endpoints are allowed.")
    }

    let audioData = try Data(contentsOf: fileURL)
    if audioData.isEmpty { throw OpenAIError(message: "Voice note audio is empty.") }

    let boundary = "Boundary-\(UUID().uuidString)"
    var body = Data()

    func addField(name: String, value: String) {
      body.appendString("--\(boundary)\r\n")
      body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
      body.appendString("\(value)\r\n")
    }

    addField(name: "model", value: "gpt-4o-mini-transcribe")
    addField(name: "response_format", value: "json")

    body.appendString("--\(boundary)\r\n")
    body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"voice.m4a\"\r\n")
    body.appendString("Content-Type: audio/m4a\r\n\r\n")
    body.append(audioData)
    body.appendString("\r\n")
    body.appendString("--\(boundary)--\r\n")

    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.timeoutInterval = 120
    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    req.httpBody = body

    let (data, response) = try await session.data(for: req)
    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
      let serverMessage = (try? Self.extractErrorMessage(from: data)) ?? "HTTP \(http.statusCode)"
      throw OpenAIError(message: serverMessage)
    }

    let obj = try JSONSerialization.jsonObject(with: data, options: [])
    if let dict = obj as? [String: Any] {
      if let text = dict["text"] as? String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
      }
    }

    // Some formats can return plain text; try to decode it as UTF-8.
    if let raw = String(data: data, encoding: .utf8) {
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
    }

    throw OpenAIError(message: "Could not parse transcription response.")
  }

  /// Sends the screenshot (PNG) + optional user context to OpenAI using the Responses API.
  func describe(imagePNG: Data, userContext: String) async throws -> String {
    guard let url = URL(string: "https://api.openai.com/v1/responses") else {
      throw OpenAIError(message: "Invalid OpenAI URL")
    }
    guard url.scheme == "https" else {
      throw OpenAIError(message: "Only HTTPS endpoints are allowed.")
    }

    let dataURL = "data:image/png;base64," + imagePNG.base64EncodedString()
    let prompt = """
You are given a screenshot of a region the user selected.
Return a concise, helpful description of what’s in the image and any actionable insights.
If the user provided context, use it. If not, infer cautiously.
"""

    // Responses API body (kept flexible; we parse output robustly).
    let body: [String: Any] = [
      "model": "gpt-4.1-mini",
      "input": [
        [
          "role": "user",
          "content": [
            ["type": "input_text", "text": prompt + (userContext.isEmpty ? "" : "\n\nUser context:\n\(userContext)")],
            ["type": "input_image", "image_url": dataURL]
          ]
        ]
      ]
    ]

    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.timeoutInterval = 60
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

    var lastError: Error?
    for attempt in 1...maxAttempts {
      do {
        let (data, response) = try await session.data(for: req)
        let http = response as? HTTPURLResponse

        if let http, !(200...299).contains(http.statusCode) {
          let serverMessage = (try? Self.extractErrorMessage(from: data)) ?? "HTTP \(http.statusCode)"
          throw OpenAIError(message: serverMessage)
        }

        // Try multiple extraction strategies for resilience across API/client variants.
        if let outputText = try? Self.extractOutputText(from: data) {
          return outputText
        }
        throw OpenAIError(message: "Could not parse OpenAI response.")
      } catch {
        lastError = error
        guard attempt < maxAttempts, Self.isRetryable(error) else { break }
        try await Task.sleep(for: .milliseconds(600))
      }
    }

    throw lastError ?? OpenAIError(message: "OpenAI request failed.")
  }

  /// Streams the model output incrementally.
  /// Calls `onDelta` on the main actor for each text delta received.
  func captureThreadStreaming(
    imagePNG: Data?,
    userText: String,
    previousResponseId: String?,
    onDelta: @escaping @MainActor (String) -> Void,
    onDebug: (@MainActor (String) -> Void)? = nil
  ) async throws -> StreamingResult {
    guard let url = URL(string: "https://api.openai.com/v1/responses") else {
      throw OpenAIError(message: "Invalid OpenAI URL")
    }
    guard url.scheme == "https" else {
      throw OpenAIError(message: "Only HTTPS endpoints are allowed.")
    }

    let prompt = """
You are given a screenshot of a region the user selected.
Return a concise, helpful description of what’s in the image and any actionable insights.
If the user provided context, use it. If not, infer cautiously.
"""

    var body: [String: Any] = [
      "model": "gpt-4.1-mini",
      "stream": true,
    ]

    if let previousResponseId, !previousResponseId.isEmpty {
      body["previous_response_id"] = previousResponseId
    }

    if let imagePNG {
      debugLog("Starting capture thread (model=gpt-4.1-mini, imageBytes=\(imagePNG.count), userChars=\(userText.count), previous=\(previousResponseId ?? "<nil>"))")
      await onDebug?("Starting request (imageBytes=\(imagePNG.count), userChars=\(userText.count), previous=\(previousResponseId ?? "<nil>"))")

      let dataURL = "data:image/png;base64," + imagePNG.base64EncodedString()
      let text = prompt + (userText.isEmpty ? "" : "\n\nUser context:\n\(userText)")
      body["input"] = [
        [
          "role": "user",
          "content": [
            ["type": "input_text", "text": text],
            ["type": "input_image", "image_url": dataURL]
          ]
        ]
      ]
    } else {
      debugLog("Starting follow-up thread (model=gpt-4.1-mini, userChars=\(userText.count), previous=\(previousResponseId ?? "<nil>"))")
      await onDebug?("Starting follow-up (userChars=\(userText.count), previous=\(previousResponseId ?? "<nil>"))")
      body["input"] = [
        [
          "role": "user",
          "content": userText
        ]
      ]
    }

    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.timeoutInterval = 120
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

    var lastError: Error?
    for attempt in 1...maxAttempts {
      do {
        // Stream SSE.
        let (bytes, response) = try await session.bytes(for: req)
        let http = response as? HTTPURLResponse
        debugLog("HTTP status = \((http?.statusCode).map(String.init) ?? "<none>")")
        await onDebug?("HTTP status = \((http?.statusCode).map(String.init) ?? "<none>")")
        if let http, !(200...299).contains(http.statusCode) {
          // Attempt to read a small body if the server responds with JSON instead of SSE.
          var data = Data()
          data.reserveCapacity(64 * 1024)
          for try await byte in bytes {
            if data.count >= 1_000_000 { break }
            data.append(byte)
          }
          let serverMessage = (try? Self.extractErrorMessage(from: data)) ?? "HTTP \(http.statusCode)"
          debugLog("Non-2xx response. status=\(http.statusCode)")
          await onDebug?("Non-2xx response: \(serverMessage)")
          throw OpenAIError(message: serverMessage)
        }

        var full = ""
        var dataLines: [String] = []
        var deltas = 0
        var sawAnyEvent = false
        var lastEventJSON: Data?
        var responseId: String?
        var rawLogged = 0
        let start = Date()
        for try await line in bytes.lines {
          // SSE event delimiter: blank line means "dispatch event".
          if line.isEmpty {
            if dataLines.isEmpty { continue }
            let payload = dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true)

            try await Self.processSSEPayload(
              payload,
              full: &full,
              deltas: &deltas,
              sawAnyEvent: &sawAnyEvent,
              lastEventJSON: &lastEventJSON,
              responseId: &responseId,
              rawLogged: &rawLogged,
              onDelta: onDelta,
              onDebug: onDebug
            )
            continue
          }

          // Ignore other SSE fields; only collect data lines (supports multi-line data payloads).
          if line.hasPrefix("data:") {
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            // Some servers omit blank-line delimiters; handle "one JSON per data line" as well.
            if !payload.isEmpty {
              try await Self.processSSEPayload(
                payload,
                full: &full,
                deltas: &deltas,
                sawAnyEvent: &sawAnyEvent,
                lastEventJSON: &lastEventJSON,
                responseId: &responseId,
                rawLogged: &rawLogged,
                onDelta: onDelta,
                onDebug: onDebug
              )
            } else {
              dataLines.append(payload)
            }
          }
        }

        let trimmed = full.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
          debugLog("Completed stream but got no text deltas.")
          await onDebug?("Completed stream but got no text deltas.")

          // Some stream variants may only send a final response event with the whole text.
          if let lastEventJSON, let outputText = try? Self.extractOutputText(from: lastEventJSON) {
            let cleaned = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
              await onDebug?("Recovered output_text from final event (chars=\(cleaned.count)).")
              let rid = responseId ?? Self.extractResponseId(from: lastEventJSON)
              return .init(text: cleaned, responseId: rid)
            }
          }

          if !sawAnyEvent {
            throw OpenAIError(message: "No SSE events received from OpenAI (streaming).")
          }
          throw OpenAIError(message: "No output text received from OpenAI (streaming).")
        }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        debugLog("Completed stream (deltas=\(deltas), totalChars=\(trimmed.count), timeMs=\(ms))")
        await onDebug?("Completed (deltas=\(deltas), totalChars=\(trimmed.count), timeMs=\(ms))")
        let rid = responseId ?? (lastEventJSON.flatMap(Self.extractResponseId(from:)))
        return .init(text: trimmed, responseId: rid)
      } catch {
        lastError = error
        guard attempt < maxAttempts, Self.isRetryable(error) else { break }
        await onDebug?("Transient failure. Retrying request…")
        try await Task.sleep(for: .milliseconds(600))
      }
    }

    throw lastError ?? OpenAIError(message: "OpenAI streaming request failed.")
  }

  func describeStreaming(
    imagePNG: Data,
    userContext: String,
    onDelta: @escaping @MainActor (String) -> Void,
    onDebug: (@MainActor (String) -> Void)? = nil
  ) async throws -> String {
    let result = try await captureThreadStreaming(
      imagePNG: imagePNG,
      userText: userContext,
      previousResponseId: nil,
      onDelta: onDelta,
      onDebug: onDebug
    )
    return result.text
  }

  private static func processSSEPayload(
    _ payload: String,
    full: inout String,
    deltas: inout Int,
    sawAnyEvent: inout Bool,
    lastEventJSON: inout Data?,
    responseId: inout String?,
    rawLogged: inout Int,
    onDelta: @escaping @MainActor (String) -> Void,
    onDebug: (@MainActor (String) -> Void)?
  ) async throws {
    let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return }
    if trimmed == "[DONE]" { return }

    sawAnyEvent = true

    if rawLogged < 6 {
      rawLogged += 1
      await onDebug?("SSE event \(rawLogged) received")
    }

    guard let jsonData = trimmed.data(using: .utf8) else { return }
    lastEventJSON = jsonData
    if responseId == nil {
      responseId = Self.extractResponseId(from: jsonData)
    }

    // Try delta extraction first (best UX).
    if let delta = try? Self.extractDeltaText(from: jsonData), !delta.isEmpty {
      full += delta
      deltas += 1
      if deltas == 1 {
        await onDebug?("Received first delta (\(delta.count) chars)")
      }
      await onDelta(delta)
      return
    }

    // If this is a completion event that contains full output, stash it.
    if let output = try? Self.extractOutputText(from: jsonData), !output.isEmpty {
      // Only use this if we didn't already get deltas (otherwise we'd duplicate).
      if deltas == 0 {
        full += output
      }
    }
  }

  private static func extractResponseId(from data: Data) -> String? {
    guard let obj = try? JSONSerialization.jsonObject(with: data, options: []),
          let dict = obj as? [String: Any] else {
      return nil
    }

    if let response = dict["response"] as? [String: Any],
       let id = response["id"] as? String,
       id.hasPrefix("resp_") {
      return id
    }

    if let id = dict["id"] as? String, id.hasPrefix("resp_") {
      return id
    }

    if let id = dict["response_id"] as? String, id.hasPrefix("resp_") {
      return id
    }

    return nil
  }

  private static func extractErrorMessage(from data: Data) throws -> String {
    let obj = try JSONSerialization.jsonObject(with: data, options: [])
    guard let dict = obj as? [String: Any] else { return "OpenAI error" }

    if let err = dict["error"] as? [String: Any] {
      if let message = err["message"] as? String { return message }
      return String(describing: err)
    }
    return String(describing: dict)
  }

  private static func extractOutputText(from data: Data) throws -> String {
    let obj = try JSONSerialization.jsonObject(with: data, options: [])
    guard let dict = obj as? [String: Any] else { throw OpenAIError(message: "Bad JSON") }

    // Some SDKs expose `output_text` directly.
    if let outputText = dict["output_text"] as? String, !outputText.isEmpty {
      return outputText
    }

    // Otherwise walk `output[*].content[*]` for text-like payloads.
    if let output = dict["output"] as? [[String: Any]] {
      var chunks: [String] = []

      for item in output {
        if let content = item["content"] as? [[String: Any]] {
          for c in content {
            if let text = c["text"] as? String, !text.isEmpty {
              chunks.append(text)
            } else if let text = c["output_text"] as? String, !text.isEmpty {
              chunks.append(text)
            }
          }
        }
      }

      let joined = chunks.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      if !joined.isEmpty { return joined }
    }

    throw OpenAIError(message: "No output text found")
  }

  private static func extractDeltaText(from data: Data) throws -> String {
    let obj = try JSONSerialization.jsonObject(with: data, options: [])
    guard let dict = obj as? [String: Any] else { return "" }

    // Some events can include errors.
    if let error = dict["error"] as? [String: Any] {
      if let message = error["message"] as? String { throw OpenAIError(message: message) }
      throw OpenAIError(message: String(describing: error))
    }

    // Typical Responses streaming event:
    // { "type": "response.output_text.delta", "delta": "..." }
    if let type = dict["type"] as? String,
       type.contains("output_text.delta"),
       let deltaAny = dict["delta"] {
      if let delta = deltaAny as? String { return delta }
      if let deltaDict = deltaAny as? [String: Any] {
        if let text = deltaDict["text"] as? String { return text }
      }
    }

    // Some variants:
    // { "type": "response.delta", "delta": { "output_text": "..." } }
    if let type = dict["type"] as? String,
       type.contains("response.delta"),
       let deltaDict = dict["delta"] as? [String: Any] {
      if let t = deltaDict["output_text"] as? String { return t }
      if let t = deltaDict["text"] as? String { return t }
    }

    // Fallback: sometimes the delta may be nested.
    if let delta = dict["delta"] as? String { return delta }
    if let deltaDict = dict["delta"] as? [String: Any], let text = deltaDict["text"] as? String { return text }
    return ""
  }

  func validateCredentials() async throws -> Bool {
    guard let url = URL(string: "https://api.openai.com/v1/models"), url.scheme == "https" else {
      throw OpenAIError(message: "Invalid OpenAI URL")
    }
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.timeoutInterval = 20
    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    let (_, response) = try await session.data(for: req)
    guard let http = response as? HTTPURLResponse else {
      throw OpenAIError(message: "Invalid response while validating key.")
    }
    guard (200...299).contains(http.statusCode) else {
      throw OpenAIError(message: "API key validation failed (HTTP \(http.statusCode)).")
    }
    return true
  }

  private static func isRetryable(_ error: Error) -> Bool {
    if let urlError = error as? URLError {
      switch urlError.code {
      case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
        return true
      default:
        break
      }
    }

    let text = String(describing: error).lowercased()
    return text.contains("http 429") || text.contains("http 500") || text.contains("http 502")
      || text.contains("http 503") || text.contains("http 504")
  }
}

private extension URLSession {
  static let agentViewDefault: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 60
    config.timeoutIntervalForResource = 180
    config.waitsForConnectivity = true
    return URLSession(configuration: config)
  }()
}

private extension Data {
  mutating func appendString(_ string: String) {
    if let data = string.data(using: .utf8) {
      append(data)
    }
  }
}


