import Foundation

final class OllamaHTTPClient: NSObject, @unchecked Sendable {
    private final class TaskHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var cancelled = false

        func install(_ task: URLSessionTask) -> Bool {
            lock.withLock {
                self.task = task
                return !cancelled
            }
        }

        func cancel() {
            let task = lock.withLock { () -> URLSessionTask? in
                cancelled = true
                return self.task
            }
            task?.cancel()
        }
    }

    private final class Pending: @unchecked Sendable {
        let limit: Int
        let continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
        var data = Data()
        var response: HTTPURLResponse?

        init(limit: Int, continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) {
            self.limit = limit
            self.continuation = continuation
        }
    }

    private let policy: OllamaRequestPolicy
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var session: URLSession!

    init(policy: OllamaRequestPolicy, configuration: URLSessionConfiguration? = nil) {
        self.policy = policy
        super.init()
        let config = configuration ?? .ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = policy.requestTimeout
        config.timeoutIntervalForResource = policy.resourceTimeout
        config.httpMaximumConnectionsPerHost = 2
        config.connectionProxyDictionary = [:]
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    deinit { session?.invalidateAndCancel() }

    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try policy.validateEndpoint(request.url)
        guard request.httpMethod == "GET" || request.httpMethod == "POST" else {
            throw ClientError.invalidRequest
        }
        guard request.httpBody?.count ?? 0 <= policy.maxRequestBytes else {
            throw OllamaRequestPolicy.PolicyError.requestOversized
        }

        let handle = TaskHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                lock.withLock {
                    pending[task.taskIdentifier] = Pending(
                        limit: policy.maxResponseBytes,
                        continuation: continuation
                    )
                }
                if !handle.install(task) || Task.isCancelled {
                    task.cancel()
                    finish(taskID: task.taskIdentifier, result: .failure(ClientError.cancelled))
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }

    private func finish(
        taskID: Int,
        result: Result<(Data, HTTPURLResponse), Error>
    ) {
        let item = lock.withLock { pending.removeValue(forKey: taskID) }
        item?.continuation.resume(with: result)
    }

    enum ClientError: Error, Equatable, Sendable {
        case invalidRequest
        case redirectBlocked
        case invalidResponse
        case httpStatus(Int)
        case oversizedResponse
        case cancelled
        case transport(URLError.Code)
    }
}

extension OllamaHTTPClient: URLSessionDataDelegate, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        task.cancel()
        finish(taskID: task.taskIdentifier, result: .failure(ClientError.redirectBlocked))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(taskID: dataTask.taskIdentifier, result: .failure(ClientError.invalidResponse))
            return
        }
        do { try policy.validateEndpoint(http.url) }
        catch {
            completionHandler(.cancel)
            finish(taskID: dataTask.taskIdentifier, result: .failure(ClientError.invalidResponse))
            return
        }
        guard (200...299).contains(http.statusCode) else {
            completionHandler(.cancel)
            finish(taskID: dataTask.taskIdentifier, result: .failure(ClientError.httpStatus(http.statusCode)))
            return
        }
        lock.withLock { pending[dataTask.taskIdentifier]?.response = http }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let oversized = lock.withLock { () -> Bool in
            guard let item = pending[dataTask.taskIdentifier] else { return false }
            guard data.count <= item.limit - item.data.count else { return true }
            item.data.append(data)
            return false
        }
        if oversized {
            dataTask.cancel()
            finish(taskID: dataTask.taskIdentifier, result: .failure(ClientError.oversizedResponse))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let urlError = error as? URLError {
            let mapped: ClientError = urlError.code == .cancelled
                ? .cancelled
                : .transport(urlError.code)
            finish(
                taskID: task.taskIdentifier,
                result: .failure(mapped)
            )
            return
        }
        if error != nil {
            finish(taskID: task.taskIdentifier, result: .failure(ClientError.invalidResponse))
            return
        }
        let result: Result<(Data, HTTPURLResponse), Error> = lock.withLock {
            guard let item = pending[task.taskIdentifier], let response = item.response else {
                return .failure(ClientError.invalidResponse)
            }
            return .success((item.data, response))
        }
        finish(taskID: task.taskIdentifier, result: result)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
