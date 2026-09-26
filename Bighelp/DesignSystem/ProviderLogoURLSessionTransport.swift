import Foundation

/// An unauthenticated, ephemeral, fixed-origin GET transport. Its delegate enforces
/// the byte limit as chunks arrive, rather than after URLSession allocates a body.
struct ProviderLogoURLSessionTransport: ProviderLogoFetching {
    func data(from url: URL, maximumBytes: Int) async throws -> Data {
        guard ProviderLogoPolicy.isAllowedURL(url), maximumBytes > 0,
              maximumBytes <= ProviderLogoPolicy.maximumImageBytes else {
            throw ProviderLogoError.invalidURL
        }
        let isManifest = url.absoluteString == ProviderLogoPolicy.manifestURL.absoluteString
        let limit = min(maximumBytes, isManifest
            ? ProviderLogoPolicy.maximumManifestBytes
            : ProviderLogoPolicy.maximumImageBytes)
        return try await ProviderLogoRequest(
            url: url,
            maximumBytes: limit,
            contentType: isManifest ? "application/json" : "image/png"
        ).load()
    }
}

/// URLSession delegates and cancellation can run concurrently. All mutable request
/// state is lock-protected; completion extracts it once and resumes outside the lock.
private final class ProviderLogoRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let maximumBytes: Int
    private let contentType: String
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    private var session: URLSession?
    private var received = Data()
    private var acceptedResponse = false
    private var completed = false

    init(url: URL, maximumBytes: Int, contentType: String) {
        self.url = url
        self.maximumBytes = maximumBytes
        self.contentType = contentType
    }

    func load() async throws -> Data {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.urlCache = nil
                configuration.urlCredentialStorage = nil
                configuration.httpCookieStorage = nil
                configuration.httpShouldSetCookies = false
                configuration.httpCookieAcceptPolicy = .never
                configuration.httpAdditionalHeaders = [:]
                configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                configuration.timeoutIntervalForRequest = 20
                configuration.timeoutIntervalForResource = 60
                configuration.waitsForConnectivity = false
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                queue.qualityOfService = .utility
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20)
                request.httpMethod = "GET"
                request.httpShouldHandleCookies = false
                request.setValue(contentType, forHTTPHeaderField: "Accept")
                let task = session.dataTask(with: request)
                let cancelled = lock.withLock {
                    guard !completed else { return true }
                    self.continuation = continuation
                    self.session = session
                    return false
                }
                if cancelled {
                    session.invalidateAndCancel()
                    continuation.resume(throwing: CancellationError())
                } else {
                    // Cancellation after registration invalidates this same session,
                    // including a task that has not yet been resumed.
                    task.resume()
                }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        finish(.failure(ProviderLogoError.redirected))
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge, completionHandler: completionHandler)
    }

    private func handle(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Use normal TLS trust evaluation, never account credentials, client
        // certificates, saved HTTP authentication, or interactive auth prompts.
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
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse,
              response.url?.absoluteString == url.absoluteString,
              response.statusCode == 200,
              response.mimeType?.lowercased() == contentType else {
            completionHandler(.cancel)
            finish(.failure(ProviderLogoError.invalidResponse))
            return
        }
        if let header = response.value(forHTTPHeaderField: "Content-Length") {
            guard let length = Int64(header), length >= 0, length <= Int64(maximumBytes) else {
                completionHandler(.cancel)
                finish(.failure(ProviderLogoError.tooLarge))
                return
            }
        }
        guard response.expectedContentLength <= Int64(maximumBytes) else {
            completionHandler(.cancel)
            finish(.failure(ProviderLogoError.tooLarge))
            return
        }
        let accept = lock.withLock {
            guard !completed else { return false }
            acceptedResponse = true
            return true
        }
        completionHandler(accept ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let failure = lock.withLock { () -> ProviderLogoError? in
            guard !completed else { return nil }
            guard acceptedResponse else { return .invalidResponse }
            guard data.count <= maximumBytes - received.count else { return .tooLarge }
            received.append(data)
            return nil
        }
        if let failure { finish(.failure(failure)) }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        willCacheResponse proposedResponse: CachedURLResponse,
        completionHandler: @escaping (CachedURLResponse?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            finish(.failure(error))
            return
        }
        let result = lock.withLock { () -> Result<Data, any Error> in
            guard acceptedResponse, !received.isEmpty else { return .failure(ProviderLogoError.invalidResponse) }
            return .success(received)
        }
        finish(result)
    }

    private func finish(_ result: Result<Data, any Error>) {
        let state = lock.withLock { () -> (CheckedContinuation<Data, any Error>?, URLSession?) in
            guard !completed else { return (nil, nil) }
            completed = true
            let state = (continuation, session)
            continuation = nil
            session = nil
            received = Data()
            return state
        }
        // A cancelled request may finish before its continuation is registered.
        // load() detects completed and resumes that continuation itself.
        switch result {
        case .success: state.1?.finishTasksAndInvalidate()
        case .failure: state.1?.invalidateAndCancel()
        }
        state.0?.resume(with: result)
    }
}
