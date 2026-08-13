import Foundation
import XCTest
@testable import OllamaLocalCore

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    enum Behavior: Sendable {
        case response(status: Int, data: Data)
        case chunks(status: Int, chunks: [Data])
        case redirect(URL)
        case wait
    }

    nonisolated(unsafe) static var behavior: Behavior?
    nonisolated(unsafe) static var observer: (@Sendable (URLRequest) -> Void)?
    private static let lock = NSLock()
    private var stopped = false

    static func configure(_ behavior: Behavior, observer: (@Sendable (URLRequest) -> Void)? = nil) {
        lock.lock()
        Self.behavior = behavior
        Self.observer = observer
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        behavior = nil
        observer = nil
        lock.unlock()
    }

    private static func snapshot() -> (Behavior?, (@Sendable (URLRequest) -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        return (behavior, observer)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (behavior, observer) = Self.snapshot()
        observer?(request)
        guard let behavior else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        switch behavior {
        case let .response(status, data): deliver(status: status, chunks: [data])
        case let .chunks(status, chunks): deliver(status: status, chunks: chunks)
        case let .redirect(url):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
                headerFields: ["Location": url.absoluteString]
            )!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: url), redirectResponse: response)
        case .wait: break
        }
    }

    override func stopLoading() { stopped = true }

    private func deliver(status: Int, chunks: [Data]) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/x-ndjson"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks where !stopped { client?.urlProtocol(self, didLoad: chunk) }
        if !stopped { client?.urlProtocolDidFinishLoading(self) }
    }
}

private actor Capture {
    struct Snapshot: Sendable { let url: URL?; let body: Data? }
    private(set) var value: Snapshot?
    func set(_ value: Snapshot) { self.value = value }
}

private func snapshot(_ request: URLRequest) -> Capture.Snapshot {
    if let body = request.httpBody { return .init(url: request.url, body: body) }
    guard let stream = request.httpBodyStream else { return .init(url: request.url, body: nil) }
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        result.append(buffer, count: count)
    }
    return .init(url: request.url, body: result)
}

final class OllamaLocalCoreTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testRejectsEveryEndpointMutation() throws {
        let policy = OllamaRequestPolicy()
        let invalid = [
            "http://localhost:11434/api/version",
            "http://[::1]:11434/api/version",
            "https://127.0.0.1:11434/api/version",
            "http://127.0.0.1/api/version",
            "http://127.0.0.1:11435/api/version",
            "http://127.0.0.1:11434/api/chat",
            "http://127.0.0.1:11434/api/version?x=1",
            "http://user@127.0.0.1:11434/api/version"
        ]
        for value in invalid {
            XCTAssertThrowsError(try policy.validateEndpoint(URL(string: value)), value)
        }
    }

    func testRedirectIsBlocked() async {
        MockURLProtocol.configure(.redirect(URL(string: "http://127.0.0.1:11434/api/tags")!))
        await assertThrows(OllamaHTTPClient.ClientError.redirectBlocked) {
            _ = try await self.makeHTTP().execute(Self.versionRequest())
        }
    }

    func testOversizedResponseIsStoppedDuringChunking() async {
        let policy = OllamaRequestPolicy(maxResponseBytes: 1_024, maxEventBytes: 512)
        MockURLProtocol.configure(.chunks(status: 200, chunks: [
            Data(repeating: 1, count: 800), Data(repeating: 2, count: 800)
        ]))
        await assertThrows(OllamaHTTPClient.ClientError.oversizedResponse) {
            _ = try await self.makeHTTP(policy).execute(Self.versionRequest())
        }
    }

    func testNon2xxBodyIsNeverReturned() async {
        MockURLProtocol.configure(.response(status: 500, data: Data("untrusted".utf8)))
        await assertThrows(OllamaHTTPClient.ClientError.httpStatus(500)) {
            _ = try await self.makeHTTP().execute(Self.versionRequest())
        }
    }

    func testMalformedVersionJSONFails() async {
        MockURLProtocol.configure(.response(status: 200, data: Data("{}".utf8)))
        await assertThrows(OllamaLocalClient.ClientError.malformedVersionResponse) {
            _ = try await self.makeClient().status()
        }
    }

    func testMalformedNDJSONFails() async {
        MockURLProtocol.configure(.response(status: 200, data: Data("not-json\n".utf8)))
        await assertThrows(OllamaLocalClient.ClientError.malformedStream) {
            _ = try await self.makeClient().ask(prompt: "hello")
        }
    }

    func testMissingTerminalEventFails() async {
        let body = Data(#"{"model":"gemma3:4b","response":"x","done":false}"#.appending("\n").utf8)
        MockURLProtocol.configure(.response(status: 200, data: body))
        await assertThrows(OllamaLocalClient.ClientError.incompleteStream) {
            _ = try await self.makeClient().ask(prompt: "hello")
        }
    }

    func testModelSubstitutionFails() async {
        let body = Self.stream([
            ["model": "other:latest", "response": "x", "done": false],
            ["model": "other:latest", "response": "", "done": true]
        ])
        MockURLProtocol.configure(.response(status: 200, data: body))
        await assertThrows(OllamaLocalClient.ClientError.modelMismatch) {
            _ = try await self.makeClient().ask(prompt: "hello")
        }
    }

    func testValidStreamReturnsTextAndUsesFixedRequest() async throws {
        let capture = Capture()
        let body = Self.stream([
            ["model": "gemma3:4b", "response": "po", "done": false],
            ["model": "gemma3:4b", "response": "ng", "done": false],
            ["model": "gemma3:4b", "response": "", "done": true]
        ])
        MockURLProtocol.configure(.response(status: 200, data: body)) { request in
            let value = snapshot(request)
            Task { await capture.set(value) }
        }
        let result = try await makeClient().ask(prompt: "ping")
        XCTAssertEqual(result, "pong")
        let captured = await waitForCapture(capture)
        XCTAssertEqual(captured?.url, OllamaRequestPolicy.generateEndpoint)
        let data = try XCTUnwrap(captured?.body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "gemma3:4b")
        XCTAssertEqual(object["stream"] as? Bool, true)
    }

    func testCancellationIsPerRequest() async {
        MockURLProtocol.configure(.wait)
        let http = makeHTTP()
        let request = Self.versionRequest()
        let task = Task.detached { try await http.execute(request) }
        await Task.yield()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch let error as OllamaHTTPClient.ClientError {
            XCTAssertEqual(error, .cancelled)
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    private func makeHTTP(_ policy: OllamaRequestPolicy = .init()) -> OllamaHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return OllamaHTTPClient(policy: policy, configuration: configuration)
    }

    private func makeClient(_ policy: OllamaRequestPolicy = .init()) -> OllamaLocalClient {
        OllamaLocalClient(policy: policy, http: makeHTTP(policy))
    }

    private func assertThrows<E: Error & Equatable, T>(
        _ expected: E,
        operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)")
        } catch let error as E { XCTAssertEqual(error, expected) }
        catch { XCTFail("Expected \(expected), got \(error)") }
    }

    private func waitForCapture(_ capture: Capture) async -> Capture.Snapshot? {
        for _ in 0..<100 {
            if let value = await capture.value { return value }
            await Task.yield()
        }
        return await capture.value
    }

    private static func versionRequest() -> URLRequest {
        var request = URLRequest(url: OllamaRequestPolicy.versionEndpoint)
        request.httpMethod = "GET"
        return request
    }

    private static func stream(_ objects: [[String: Any]]) -> Data {
        var data = Data()
        for object in objects {
            data.append(try! JSONSerialization.data(withJSONObject: object))
            data.append(0x0A)
        }
        return data
    }
}
