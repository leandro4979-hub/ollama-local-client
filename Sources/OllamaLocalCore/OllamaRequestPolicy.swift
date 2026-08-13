import Foundation

public struct OllamaRequestPolicy: Sendable {
    public static let model = "gemma3:4b"
    public static let versionEndpoint = URL(string: "http://127.0.0.1:11434/api/version")!
    public static let tagsEndpoint = URL(string: "http://127.0.0.1:11434/api/tags")!
    public static let generateEndpoint = URL(string: "http://127.0.0.1:11434/api/generate")!

    public let maxPromptBytes: Int
    public let maxRequestBytes: Int
    public let maxResponseBytes: Int
    public let maxEventBytes: Int
    public let maxEvents: Int
    public let maxOutputTokens: Int
    public let requestTimeout: TimeInterval
    public let resourceTimeout: TimeInterval

    public init(
        maxPromptBytes: Int = 512 * 1_024,
        maxRequestBytes: Int = 768 * 1_024,
        maxResponseBytes: Int = 5 * 1_024 * 1_024,
        maxEventBytes: Int = 1 * 1_024 * 1_024,
        maxEvents: Int = 65_536,
        maxOutputTokens: Int = 4_096,
        requestTimeout: TimeInterval = 30,
        resourceTimeout: TimeInterval = 180
    ) {
        precondition((1...512 * 1_024).contains(maxPromptBytes))
        precondition((maxPromptBytes...1 * 1_024 * 1_024).contains(maxRequestBytes))
        precondition((1...5 * 1_024 * 1_024).contains(maxResponseBytes))
        precondition((1...maxResponseBytes).contains(maxEventBytes))
        precondition((2...65_536).contains(maxEvents))
        precondition((1...4_096).contains(maxOutputTokens))
        precondition((1...60).contains(requestTimeout))
        precondition((requestTimeout...300).contains(resourceTimeout))
        self.maxPromptBytes = maxPromptBytes
        self.maxRequestBytes = maxRequestBytes
        self.maxResponseBytes = maxResponseBytes
        self.maxEventBytes = maxEventBytes
        self.maxEvents = maxEvents
        self.maxOutputTokens = maxOutputTokens
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
    }

    func validateEndpoint(_ url: URL?) throws {
        guard let url,
              url.scheme?.lowercased() == "http",
              url.host == "127.0.0.1",
              url.port == 11_434,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              Self.allowedPaths.contains(url.path)
        else { throw PolicyError.nonLoopbackEndpoint }
    }

    func validatePrompt(_ prompt: String) throws {
        guard !prompt.isEmpty else { throw PolicyError.emptyPrompt }
        guard prompt.utf8.count <= maxPromptBytes else { throw PolicyError.promptOversized }
        guard !prompt.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw PolicyError.invalidPrompt
        }
    }

    private static let allowedPaths: Set<String> = [
        "/api/version", "/api/tags", "/api/generate"
    ]

    public enum PolicyError: Error, Equatable, Sendable {
        case nonLoopbackEndpoint
        case emptyPrompt
        case promptOversized
        case requestOversized
        case invalidPrompt
    }
}
