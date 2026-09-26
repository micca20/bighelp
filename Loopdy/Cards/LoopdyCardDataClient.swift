import Foundation

protocol LoopdyCardHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

protocol LoopdyCardDataFetching: Sendable {
    func fetch(_ url: URL) async throws -> LoopdyJSONValue
}

enum LoopdyCardStaticDataError: Error, Equatable {
    case liveDataUnavailable
}

struct LoopdyCardStaticDataClient: LoopdyCardDataFetching {
    func fetch(_ url: URL) async throws -> LoopdyJSONValue {
        throw LoopdyCardStaticDataError.liveDataUnavailable
    }
}

enum LoopdyCardDataClientError: Error, Equatable {
    case invalidResponse
    case unsupportedContentType
    case responseTooLarge
    case invalidJSON
    case jsonLimitExceeded
}

actor LoopdyCardDataClient: LoopdyCardDataFetching {
    static let shared = LoopdyCardDataClient()

    private static let maximumResponseBytes = 2_000_000
    private static let maximumJSONDepth = 24
    private static let maximumJSONNodes = 10_000

    private let transport: any LoopdyCardHTTPTransport
    private var inFlight: [URL: Task<LoopdyJSONValue, Error>] = [:]

    init(transport: any LoopdyCardHTTPTransport = LoopdyCardURLSessionTransport()) {
        self.transport = transport
    }

    func fetch(_ url: URL) async throws -> LoopdyJSONValue {
        let validated = try LoopdyCardNetworkPolicy.validate(url)
        if let task = inFlight[validated.url] {
            return try await task.value
        }

        let transport = transport
        let task = Task<LoopdyJSONValue, Error> {
            var request = URLRequest(
                url: validated.url,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: 15
            )
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Loopdy/iOS", forHTTPHeaderField: "User-Agent")
            request.httpShouldHandleCookies = false

            let (data, response) = try await transport.data(for: request)
            guard (200...299).contains(response.statusCode),
                  let finalURL = response.url,
                  (try? LoopdyCardNetworkPolicy.validate(finalURL)) != nil else {
                throw LoopdyCardDataClientError.invalidResponse
            }
            if response.expectedContentLength > Self.maximumResponseBytes {
                throw LoopdyCardDataClientError.responseTooLarge
            }
            guard data.count <= Self.maximumResponseBytes else {
                throw LoopdyCardDataClientError.responseTooLarge
            }
            guard Self.isJSONContentType(response.value(forHTTPHeaderField: "Content-Type")) else {
                throw LoopdyCardDataClientError.unsupportedContentType
            }
            let value: LoopdyJSONValue
            do {
                value = try JSONDecoder().decode(LoopdyJSONValue.self, from: data)
            } catch {
                throw LoopdyCardDataClientError.invalidJSON
            }
            var nodeCount = 0
            try Self.validateJSON(value, depth: 0, nodeCount: &nodeCount)
            return value
        }

        inFlight[validated.url] = task
        defer { inFlight[validated.url] = nil }
        return try await task.value
    }

    private static func isJSONContentType(_ rawValue: String?) -> Bool {
        guard let rawValue else { return false }
        let type = rawValue.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return type == "application/json" || (type.hasPrefix("application/") && type.hasSuffix("+json"))
    }

    private static func validateJSON(
        _ value: LoopdyJSONValue,
        depth: Int,
        nodeCount: inout Int
    ) throws {
        guard depth <= maximumJSONDepth else { throw LoopdyCardDataClientError.jsonLimitExceeded }
        nodeCount += 1
        guard nodeCount <= maximumJSONNodes else { throw LoopdyCardDataClientError.jsonLimitExceeded }
        switch value {
        case .array(let values):
            for value in values { try validateJSON(value, depth: depth + 1, nodeCount: &nodeCount) }
        case .object(let values):
            for value in values.values { try validateJSON(value, depth: depth + 1, nodeCount: &nodeCount) }
        case .string(let value):
            guard value.count <= 100_000 else { throw LoopdyCardDataClientError.jsonLimitExceeded }
        default:
            break
        }
    }
}

final class LoopdyCardURLSessionTransport: NSObject, LoopdyCardHTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var redirectCounts: [Int: Int] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw LoopdyCardDataClientError.invalidResponse
        }
        return (data, response)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let count = lock.withLock {
            let next = redirectCounts[task.taskIdentifier, default: 0] + 1
            redirectCounts[task.taskIdentifier] = next
            return next
        }
        guard count <= 5,
              request.httpMethod == "GET",
              let url = request.url,
              (try? LoopdyCardNetworkPolicy.validate(url)) != nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        lock.withLock { redirectCounts[task.taskIdentifier] = nil }
    }
}
