import Foundation

struct GitHubHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
    let url: URL
    let headers: [String: String]

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// User-token primary budgets are shared by GitHub user, not per App installation.
/// Search has a separate primary bucket; secondary throttling pauses both. Header
/// deadlines win over our fallback, and no provider-requested wait is shortened.
struct GitHubRateLimitBudget: Sendable {
    private var coreUntil = Date.distantPast
    private var searchUntil = Date.distantPast
    private var secondaryUntil = Date.distantPast
    private var secondaryFailures = 0

    func blockedUntil(search: Bool) -> Date {
        max(secondaryUntil, search ? searchUntil : coreUntil)
    }

    mutating func record(_ response: GitHubHTTPResponse, search: Bool, now: Date) -> Date? {
        let rejected = response.statusCode == 403 || response.statusCode == 429
        let exhausted = response.header("X-RateLimit-Remaining") == "0"
        if exhausted {
            let reset = response.header("X-RateLimit-Reset").flatMap { Double($0) }
            let until = reset.flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
                .map { max(now.addingTimeInterval(1), $0) } ?? now.addingTimeInterval(60)
            let bucket = response.header("X-RateLimit-Resource")
            if bucket == "search" || (bucket != "core" && search) { searchUntil = max(searchUntil, until) }
            else { coreUntil = max(coreUntil, until) }
        }
        guard rejected else {
            if (200...299).contains(response.statusCode), now >= secondaryUntil { secondaryFailures = 0 }
            return nil
        }
        let retry = response.header("Retry-After").flatMap { Self.retryDate($0, now: now) }
        let body = try? GitHubJSON.parse(response.data).object()
        let message = (try? body?.required("message").string(max: 4096))?.lowercased() ?? ""
        let secondary = response.statusCode == 429 || retry != nil || (!exhausted &&
            (message.contains("rate limit") || message.contains("abuse detection")))
        if secondary {
            let fallback = min(3_600, 60 * pow(2, Double(min(secondaryFailures, 6))))
            secondaryFailures = min(secondaryFailures + 1, 6)
            secondaryUntil = max(secondaryUntil, retry ?? now.addingTimeInterval(fallback))
        }
        return exhausted || secondary ? blockedUntil(search: search) : nil
    }

    private static func retryDate(_ raw: String, now: Date) -> Date? {
        if let seconds = Double(raw), seconds.isFinite, seconds >= 0 {
            let date = now.addingTimeInterval(seconds)
            return date.timeIntervalSince1970.isFinite ? max(now.addingTimeInterval(1), date) : nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: raw).map { max(now.addingTimeInterval(1), $0) }
    }
}

protocol GitHubTransport: Sendable {
    func send(_ request: URLRequest) async throws -> GitHubHTTPResponse
}

protocol GitHubClock: Sendable {
    func now() -> Date
    func sleep(seconds: TimeInterval) async throws
}

struct GitHubSystemClock: GitHubClock {
    func now() -> Date { Date() }
    func sleep(seconds: TimeInterval) async throws {
        guard seconds > 0 else { try Task.checkCancellation(); return }
        try await Task.sleep(for: .seconds(seconds))
    }
}

/// Direct GitHub.com only. No shared cookie jar, URLCache, credential storage,
/// redirects, automatic retries, Link transport or third-party proxy endpoint.
final class GitHubURLSessionTransport: GitHubTransport, Sendable {
    private let session: URLSession
    private let redirectPolicy = NoRedirects()
    static let maximumResponseBytes = 2_097_152

    /// protocolClasses is an interception seam for parent-owned URLProtocol tests.
    /// The production default remains an unmodified ephemeral transport.
    init(protocolClasses: [AnyClass]? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> GitHubHTTPResponse {
        try Self.validate(request)
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: redirectPolicy)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse,
                  let responseURL = http.url, responseURL == request.url, !(300...399).contains(http.statusCode)
            else { throw GitHubError.invalidResponse }
            if (200...299).contains(http.statusCode) {
                guard let type = http.value(forHTTPHeaderField: "Content-Type"),
                      type.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces) == "application/json"
                else { throw GitHubError.invalidResponse }
            }
            guard http.expectedContentLength <= Self.maximumResponseBytes else {
                throw GitHubError.responseTooLarge
            }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < Self.maximumResponseBytes else { throw GitHubError.responseTooLarge }
                data.append(byte)
            }
            var headers: [String: String] = [:]
            // Retain only headers required by the contract, not arbitrary provider diagnostics.
            for name in ["Content-Type", "Retry-After", "X-RateLimit-Remaining", "X-RateLimit-Reset", "X-RateLimit-Resource", "ETag"] {
                if let value = http.value(forHTTPHeaderField: name), value.utf8.count < 1024 {
                    headers[name] = value
                }
            }
            return GitHubHTTPResponse(data: data, statusCode: http.statusCode, url: responseURL, headers: headers)
        } catch {
            throw GitHubError.safe(error)
        }
    }

    static func validate(_ request: URLRequest) throws {
        guard let url = request.url,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.percentEncodedPath == parts.path,
              parts.path.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." })
        else { throw GitHubError.invalidInput }
        if parts.host == "github.com" {
            guard GitHubURLPolicy.isOrigin(parts, host: "github.com"), request.httpMethod == "POST",
                  ["/login/device/code", "/login/oauth/access_token"].contains(parts.path),
                  request.value(forHTTPHeaderField: "Authorization") == nil
            else { throw GitHubError.invalidInput }
        } else {
            guard GitHubURLPolicy.isOrigin(parts, host: "api.github.com", allowQuery: true),
                  request.httpMethod == "GET", request.httpBody == nil,
                  parts.path.range(
                    of: #"^(?:/user|/user/repos|/user/installations|/user/installations/[1-9][0-9]*/repositories|/search/issues|/repos/[A-Za-z0-9-]+/[A-Za-z0-9_.-]+(?:/(?:issues|pulls)/[1-9][0-9]*)?)$"#,
                    options: .regularExpression
                  ) != nil,
                  (parts.queryItems ?? []).allSatisfy({ ["page", "per_page", "q", "sort", "order"].contains($0.name) })
            else { throw GitHubError.invalidInput }
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
