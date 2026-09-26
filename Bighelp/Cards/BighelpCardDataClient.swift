import Foundation

protocol BighelpCardHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

protocol BighelpCardDataFetching: Sendable {
    func fetch(_ url: URL) async throws -> BighelpJSONValue
}

enum BighelpCardStaticDataError: Error, Equatable {
    case liveDataUnavailable
}

struct BighelpCardStaticDataClient: BighelpCardDataFetching {
    func fetch(_ url: URL) async throws -> BighelpJSONValue {
        throw BighelpCardStaticDataError.liveDataUnavailable
    }
}

enum BighelpCardDataClientError: Error, Equatable {
    case invalidResponse
    case unsupportedContentType
    case responseTooLarge
    case invalidJSON
    case jsonLimitExceeded
}

actor BighelpCardDataClient: BighelpCardDataFetching {
    static let shared = BighelpCardDataClient()

    private static let maximumResponseBytes = 2_000_000
    private static let maximumJSONDepth = 24
    private static let maximumJSONNodes = 10_000

    private let transport: any BighelpCardHTTPTransport
    private var inFlight: [URL: Task<BighelpJSONValue, Error>] = [:]

    init(transport: any BighelpCardHTTPTransport = BighelpCardURLSessionTransport()) {
        self.transport = transport
    }

    func fetch(_ url: URL) async throws -> BighelpJSONValue {
        let validated = try BighelpCardNetworkPolicy.validate(url)
        if let task = inFlight[validated.url] {
            return try await task.value
        }

        let transport = transport
        let task = Task<BighelpJSONValue, Error> {
            var request = URLRequest(
                url: validated.url,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: 15
            )
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("bighelp/iOS", forHTTPHeaderField: "User-Agent")
            request.httpShouldHandleCookies = false

            let (data, response) = try await transport.data(for: request)
            guard (200...299).contains(response.statusCode),
                  let finalURL = response.url,
                  (try? BighelpCardNetworkPolicy.validate(finalURL)) != nil else {
                throw BighelpCardDataClientError.invalidResponse
            }
            if response.expectedContentLength > Self.maximumResponseBytes {
                throw BighelpCardDataClientError.responseTooLarge
            }
            guard data.count <= Self.maximumResponseBytes else {
                throw BighelpCardDataClientError.responseTooLarge
            }
            guard Self.isJSONContentType(response.value(forHTTPHeaderField: "Content-Type")) else {
                throw BighelpCardDataClientError.unsupportedContentType
            }
            let value: BighelpJSONValue
            do {
                value = try JSONDecoder().decode(BighelpJSONValue.self, from: data)
            } catch {
                throw BighelpCardDataClientError.invalidJSON
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
        _ value: BighelpJSONValue,
        depth: Int,
        nodeCount: inout Int
    ) throws {
        guard depth <= maximumJSONDepth else { throw BighelpCardDataClientError.jsonLimitExceeded }
        nodeCount += 1
        guard nodeCount <= maximumJSONNodes else { throw BighelpCardDataClientError.jsonLimitExceeded }
        switch value {
        case .array(let values):
            for value in values { try validateJSON(value, depth: depth + 1, nodeCount: &nodeCount) }
        case .object(let values):
            for value in values.values { try validateJSON(value, depth: depth + 1, nodeCount: &nodeCount) }
        case .string(let value):
            guard value.count <= 100_000 else { throw BighelpCardDataClientError.jsonLimitExceeded }
        default:
            break
        }
    }
}

final class BighelpCardURLSessionTransport: NSObject, BighelpCardHTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
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
            throw BighelpCardDataClientError.invalidResponse
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
              (try? BighelpCardNetworkPolicy.validate(url)) != nil else {
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
