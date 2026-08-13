import Foundation

public actor OllamaLocalClient {
    private let policy: OllamaRequestPolicy
    private let http: OllamaHTTPClient

    public init(policy: OllamaRequestPolicy = .init()) {
        self.policy = policy
        http = OllamaHTTPClient(policy: policy)
    }

    init(policy: OllamaRequestPolicy, http: OllamaHTTPClient) {
        self.policy = policy
        self.http = http
    }

    public func status() async throws -> Status {
        var request = URLRequest(url: OllamaRequestPolicy.versionEndpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = min(5, policy.requestTimeout)
        let (data, _) = try await http.execute(request)
        let decoded: VersionResponse
        do { decoded = try JSONDecoder().decode(VersionResponse.self, from: data) }
        catch { throw ClientError.malformedVersionResponse }
        guard !decoded.version.isEmpty, decoded.version.count <= 128 else {
            throw ClientError.malformedVersionResponse
        }
        return Status(version: decoded.version, endpoint: OllamaRequestPolicy.versionEndpoint)
    }

    public func verify() async throws -> Verification {
        let result = try await generate(prompt: "Reply with exactly: pong", maxTokens: 16)
        guard result.eventCount >= 2 else { throw ClientError.streamingNotObserved }
        return Verification(
            model: OllamaRequestPolicy.model,
            eventCount: result.eventCount,
            responseBytes: result.responseBytes
        )
    }

    public func ask(prompt: String) async throws -> String {
        try await generate(prompt: prompt, maxTokens: policy.maxOutputTokens).text
    }

    private func generate(prompt: String, maxTokens: Int) async throws -> GenerationResult {
        try policy.validatePrompt(prompt)
        let body = GenerateRequest(
            model: OllamaRequestPolicy.model,
            prompt: prompt,
            stream: true,
            options: .init(numPredict: maxTokens)
        )
        let encoded = try JSONEncoder().encode(body)
        guard encoded.count <= policy.maxRequestBytes else {
            throw OllamaRequestPolicy.PolicyError.requestOversized
        }

        var request = URLRequest(url: OllamaRequestPolicy.generateEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = policy.resourceTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        request.httpBody = encoded
        let (data, _) = try await http.execute(request)
        return try decodeStream(data)
    }

    private func decodeStream(_ data: Data) throws -> GenerationResult {
        var text = ""
        var count = 0
        var sawNonterminal = false
        var sawTerminal = false

        for rawLine in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard rawLine.count <= policy.maxEventBytes else { throw ClientError.eventOversized }
            count += 1
            guard count <= policy.maxEvents else { throw ClientError.tooManyEvents }
            let event: GenerateEvent
            do { event = try JSONDecoder().decode(GenerateEvent.self, from: Data(rawLine)) }
            catch { throw ClientError.malformedStream }
            guard event.model == nil || event.model == OllamaRequestPolicy.model else {
                throw ClientError.modelMismatch
            }
            guard event.error == nil else { throw ClientError.localGenerationFailed }
            if event.done {
                guard !sawTerminal else { throw ClientError.malformedStream }
                sawTerminal = true
            } else {
                guard !sawTerminal else { throw ClientError.malformedStream }
                sawNonterminal = true
            }
            if let response = event.response { text.append(response) }
        }

        guard count > 0, sawTerminal else { throw ClientError.incompleteStream }
        guard sawNonterminal else { throw ClientError.streamingNotObserved }
        guard !text.isEmpty else { throw ClientError.emptyResponse }
        return GenerationResult(text: text, eventCount: count, responseBytes: data.count)
    }

    public struct Status: Sendable, Equatable {
        public let version: String
        public let endpoint: URL
    }

    public struct Verification: Sendable, Equatable {
        public let model: String
        public let eventCount: Int
        public let responseBytes: Int
    }

    public enum ClientError: Error, Equatable, Sendable {
        case malformedVersionResponse
        case malformedStream
        case incompleteStream
        case streamingNotObserved
        case eventOversized
        case tooManyEvents
        case modelMismatch
        case localGenerationFailed
        case emptyResponse
    }
}

private struct VersionResponse: Decodable { let version: String }

private struct GenerateRequest: Encodable {
    struct Options: Encodable {
        let numPredict: Int
        enum CodingKeys: String, CodingKey { case numPredict = "num_predict" }
    }
    let model: String
    let prompt: String
    let stream: Bool
    let options: Options
}

private struct GenerateEvent: Decodable {
    let model: String?
    let response: String?
    let done: Bool
    let error: String?
}

private struct GenerationResult {
    let text: String
    let eventCount: Int
    let responseBytes: Int
}
