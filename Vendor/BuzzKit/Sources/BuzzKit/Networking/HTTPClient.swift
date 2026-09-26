import Foundation

final class BoundedHTTPDataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Pending {
        let continuation: CheckedContinuation<(Data, URLResponse), any Error>
        let maximumBytes: Int
        var response: HTTPURLResponse?
        var data = Data()
        var failure: (any Error)?
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]

    func data(
        using session: URLSession,
        request: URLRequest,
        maximumBytes: Int
    ) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                withLock {
                    pending[task.taskIdentifier] = Pending(
                        continuation: continuation,
                        maximumBytes: maximumBytes
                    )
                }
                if Task.isCancelled { task.cancel() }
                else { task.resume() }
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let disposition = withLock { () -> URLSession.ResponseDisposition in
            guard var request = pending[dataTask.taskIdentifier],
                  let response = response as? HTTPURLResponse else { return .cancel }
            request.response = response
            if response.expectedContentLength > Int64(request.maximumBytes) {
                request.failure = BuzzKitError.invalidResponse
                pending[dataTask.taskIdentifier] = request
                return .cancel
            }
            pending[dataTask.taskIdentifier] = request
            return .allow
        }
        completionHandler(disposition)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let overflow = withLock { () -> Bool in
            guard var request = pending[dataTask.taskIdentifier], request.failure == nil else { return false }
            let remaining = request.maximumBytes - request.data.count
            let accepted = min(data.count, max(0, remaining))
            if accepted > 0 { request.data.append(data.prefix(accepted)) }
            guard accepted == data.count else {
                request.failure = BuzzKitError.invalidResponse
                pending[dataTask.taskIdentifier] = request
                return true
            }
            pending[dataTask.taskIdentifier] = request
            return false
        }
        if overflow { dataTask.cancel() }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let request = withLock({ pending.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let failure = request.failure ?? error {
            request.continuation.resume(throwing: failure)
        } else if let response = request.response {
            request.continuation.resume(returning: (request.data, response))
        } else {
            request.continuation.resume(throwing: BuzzKitError.invalidResponse)
        }
    }

    private func withLock<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

struct HTTPRequest: Sendable {
    enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
        case patch = "PATCH"
        case delete = "DELETE"
    }

    var method: Method
    var path: String
    var body: Data?
    var headers: [String: String]
}

actor HTTPClient {
    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession
    private let boundedDelegate: BoundedHTTPDataDelegate?
    private let logger: BKLogger
    private let maxAttempts: Int
    private let sleep: @Sendable (UInt64) async -> Void

    init(
        baseURL: URL,
        apiKey: String,
        logger: BKLogger,
        session: URLSession? = nil,
        maxAttempts: Int = 3,
        sleep: @escaping @Sendable (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        if let session {
            self.session = session
            boundedDelegate = nil
        } else {
            let delegate = BoundedHTTPDataDelegate()
            boundedDelegate = delegate
            self.session = URLSession(
                configuration: HTTPClient.makeConfiguration(),
                delegate: delegate,
                delegateQueue: nil
            )
        }
        self.logger = logger
        self.maxAttempts = maxAttempts
        self.sleep = sleep
    }

    static func makeSession() -> URLSession {
        URLSession(configuration: makeConfiguration())
    }

    private static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        return configuration
    }

    func send<Value: Decodable & Sendable>(
        _ request: HTTPRequest,
        as type: Value.Type
    ) async throws -> Value {
        let data = try await perform(request)
        let envelope: Envelope<Value>
        do {
            envelope = try JSONCoding.decoder.decode(Envelope<Value>.self, from: data)
        } catch {
            logger.error("Undecodable response for \(request.path): \(error)")
            throw BuzzKitError.invalidResponse
        }
        if let value = envelope.data, envelope.success {
            return value
        }
        if let problem = envelope.error {
            throw BuzzKitError.api(code: problem.code, message: problem.message)
        }
        throw BuzzKitError.invalidResponse
    }

    func sendList<Element: Decodable & Sendable>(
        _ request: HTTPRequest,
        of type: Element.Type
    ) async throws -> [Element] {
        try await send(request, as: ListPayload<Element>.self).items
    }

    private func perform(_ request: HTTPRequest) async throws -> Data {
        var attempt = 0
        var lastError: Error = BuzzKitError.invalidResponse
        while attempt < maxAttempts {
            attempt += 1
            do {
                let urlRequest = urlRequest(for: request)
                let data: Data
                let response: URLResponse
                if let boundedDelegate {
                    (data, response) = try await boundedDelegate.data(
                        using: session,
                        request: urlRequest,
                        maximumBytes: 262_144
                    )
                } else {
                    (data, response) = try await session.data(for: urlRequest)
                }
                guard let http = response as? HTTPURLResponse,
                      http.url == urlRequest.url else { throw BuzzKitError.invalidResponse }
                if http.statusCode < 500, http.statusCode != 429 {
                    return data
                }
                logger.warn("\(request.method.rawValue) \(request.path) answered \(http.statusCode)")
                if attempt < maxAttempts {
                    await sleep(retryDelay(for: attempt, response: http))
                    continue
                }
                throw BuzzKitError.network(underlying: URLError(.badServerResponse))
            } catch let error as BuzzKitError {
                throw error
            } catch {
                lastError = error
                logger.warn("\(request.method.rawValue) \(request.path) failed: \(error.localizedDescription)")
                if attempt < maxAttempts {
                    await sleep(retryDelay(for: attempt, response: nil))
                }
            }
        }
        throw BuzzKitError.network(underlying: lastError)
    }

    private func urlRequest(for request: HTTPRequest) -> URLRequest {
        var url = URLRequest(url: baseURL.appendingPathComponent(request.path))
        url.httpMethod = request.method.rawValue
        url.httpBody = request.body
        url.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        url.setValue("application/json", forHTTPHeaderField: "Content-Type")
        url.setValue(SDKInfo.userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in request.headers {
            url.setValue(value, forHTTPHeaderField: name)
        }
        return url
    }

    private func retryDelay(for attempt: Int, response: HTTPURLResponse?) -> UInt64 {
        if let after = response?.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(after) {
            return UInt64(min(seconds, 30) * 1_000_000_000)
        }
        let base = pow(2, Double(attempt - 1))
        let jitter = Double.random(in: 0...0.4)
        return UInt64(min(base + jitter, 20) * 1_000_000_000)
    }
}

enum JSONCoding {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = ISO8601.date(from: raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date: \(raw)")
            }
            return date
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, container in
            var single = container.singleValueContainer()
            try single.encode(ISO8601.string(from: date))
        }
        return encoder
    }()
}

enum ISO8601 {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle()

    static func date(from string: String) -> Date? {
        (try? fractional.parse(string)) ?? (try? plain.parse(string))
    }

    static func string(from date: Date) -> String {
        fractional.format(date)
    }
}

enum SDKInfo {
    static let version = "1.0.0"
    static var userAgent: String {
        "buzzkit-ios/\(version)"
    }
}
