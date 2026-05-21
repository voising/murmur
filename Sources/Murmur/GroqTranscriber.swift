import Foundation

class GroqTranscriber {
    private static let apiKeyAccount = "GroqAPIKey"
    private static let endpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    private static let maxAttempts = 3

    /// Dedicated session with explicit timeouts. The default shared session
    /// waits 60s before giving up, which feels like a hang; we want to fail
    /// fast and retry instead.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30   // per-request inactivity
        config.timeoutIntervalForResource = 90  // hard ceiling per attempt
        config.waitsForConnectivity = true      // ride out brief offline blips
        return URLSession(configuration: config)
    }()

    static var apiKey: String? {
        get {
            // One-time migration from UserDefaults to Keychain
            if let legacy = UserDefaults.standard.string(forKey: apiKeyAccount) {
                Keychain.set(legacy, account: apiKeyAccount)
                UserDefaults.standard.removeObject(forKey: apiKeyAccount)
                return legacy
            }
            return Keychain.get(account: apiKeyAccount)
        }
        set { Keychain.set(newValue, account: apiKeyAccount) }
    }

    func transcribe(wavData: Data) async throws -> String {
        guard let key = Self.apiKey else {
            throw TranscriptionError.noAPIKey
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // file field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        body.append(wavData)
        body.append("\r\n")

        // model field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.append("whisper-large-v3-turbo\r\n")

        // language field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
        body.append("en\r\n")

        // response_format field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        body.append("json\r\n")

        body.append("--\(boundary)--\r\n")

        request.httpBody = body

        var lastError: Error = TranscriptionError.invalidResponse

        for attempt in 1...Self.maxAttempts {
            do {
                let (data, response) = try await Self.session.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw TranscriptionError.invalidResponse
                }

                // Retry transient server-side conditions: rate limit + 5xx.
                if httpResponse.statusCode == 429 || (500...599).contains(httpResponse.statusCode) {
                    let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                    lastError = TranscriptionError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
                    if attempt < Self.maxAttempts {
                        try await Self.backoff(attempt: attempt)
                        continue
                    }
                    throw lastError
                }

                guard httpResponse.statusCode == 200 else {
                    let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                    throw TranscriptionError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
                }

                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard let text = json?["text"] as? String else {
                    throw TranscriptionError.parseError
                }

                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch let error as URLError where Self.isTransient(error) {
                lastError = error
                if attempt < Self.maxAttempts {
                    try await Self.backoff(attempt: attempt)
                    continue
                }
                throw error
            }
        }

        throw lastError
    }

    /// Network conditions worth retrying rather than surfacing immediately.
    private static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
             .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost:
            return true
        default:
            return false
        }
    }

    /// Exponential backoff with jitter: ~0.5s, ~1s, ... before the next try.
    private static func backoff(attempt: Int) async throws {
        let base = 0.5 * pow(2.0, Double(attempt - 1))
        let jitter = Double.random(in: 0...0.25)
        let nanos = UInt64((base + jitter) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanos)
    }
}

enum TranscriptionError: LocalizedError {
    case noAPIKey
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case parseError

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "No API key set"
        case .invalidResponse: return "Invalid response from server"
        case .apiError(let code, let msg): return "API error \(code): \(msg)"
        case .parseError: return "Failed to parse response"
        }
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
