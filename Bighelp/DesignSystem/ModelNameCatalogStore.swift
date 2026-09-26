import Foundation
import Observation

@MainActor
@Observable
final class ModelNameCatalogStore {
    static let shared = ModelNameCatalogStore(
        cacheURL: ModelNameCatalogStore.persistentCacheURL,
        bundledData: ModelNameCatalogStore.bundledCatalogData,
        loader: { try await ModelNameCatalogRemoteLoader.load() }
    )

    private(set) var isRefreshing = false
    private(set) var statusMessage: String?

    private var catalog: ModelNameCatalog
    private let cacheURL: URL?
    private let loader: @Sendable () async throws -> Data

    init(
        cacheURL: URL?,
        bundledData: Data,
        loader: @escaping @Sendable () async throws -> Data
    ) {
        self.cacheURL = cacheURL
        self.loader = loader

        let bundledCatalog = (try? ModelNameCatalog.decode(bundledData)) ?? .empty
        if
            let cacheURL,
            let cachedData = Self.validSizedData(at: cacheURL),
            let cachedCatalog = try? ModelNameCatalog.decode(cachedData)
        {
            catalog = cachedCatalog
        } else {
            catalog = bundledCatalog
        }
    }

    func displayName(for modelID: String) -> String {
        catalog.displayName(for: modelID)
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        statusMessage = nil
        defer { isRefreshing = false }

        do {
            let data = try await loader()
            try Task.checkCancellation()
            let refreshedCatalog = try ModelNameCatalog.decode(data)
            try Task.checkCancellation()

            if let cacheURL {
                try Self.persist(data, to: cacheURL)
            }

            catalog = refreshedCatalog
            statusMessage = "Model names updated."
        } catch is CancellationError {
            statusMessage = "Model names weren’t changed."
        } catch {
            statusMessage = "Model names couldn’t be updated. Your current names were kept."
        }
    }

    private static let bundledCatalogData: Data = {
        guard
            let url = Bundle.main.url(forResource: "model-names", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            data.count <= ModelNameCatalog.maximumBytes
        else {
            return Data(#"{"version":1,"revision":"built-in","models":{}}"#.utf8)
        }
        return data
    }()

    private static let persistentCacheURL: URL? = {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return applicationSupport
            .appendingPathComponent("Loopdy", isDirectory: true)
            .appendingPathComponent("ModelNames", isDirectory: true)
            .appendingPathComponent("model-names.json", isDirectory: false)
    }()

    private static func validSizedData(at url: URL) -> Data? {
        guard
            let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
            let fileSize = values.fileSize,
            fileSize <= ModelNameCatalog.maximumBytes,
            let data = try? Data(contentsOf: url),
            data.count <= ModelNameCatalog.maximumBytes
        else { return nil }
        return data
    }

    private static func persist(_ data: Data, to url: URL) throws {
        guard data.count <= ModelNameCatalog.maximumBytes else {
            throw ModelNameCatalogError.payloadTooLarge
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}

private enum ModelNameCatalogRemoteLoader {
    static let sourceURL = URL(
        string: "https://raw.githubusercontent.com/promptclickrun/bighelp-plugin/main/model-names.json"
    )!

    static func load() async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil

        let delegate = ModelNameCatalogRedirectDelegate(allowedURL: sourceURL)
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        var request = URLRequest(
            url: sourceURL,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 20
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        request.setValue(nil, forHTTPHeaderField: "Cookie")

        let (bytes, response) = try await session.bytes(for: request)
        guard
            let response = response as? HTTPURLResponse,
            response.statusCode == 200,
            response.url == sourceURL,
            response.expectedContentLength <= Int64(ModelNameCatalog.maximumBytes)
                || response.expectedContentLength == NSURLSessionTransferSizeUnknown
        else {
            throw ModelNameCatalogRemoteError.invalidResponse
        }

        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(Int(response.expectedContentLength))
        }
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < ModelNameCatalog.maximumBytes else {
                throw ModelNameCatalogError.payloadTooLarge
            }
            data.append(byte)
        }
        return data
    }
}

private final class ModelNameCatalogRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let allowedURL: URL

    init(allowedURL: URL) {
        self.allowedURL = allowedURL
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url == allowedURL ? request : nil)
    }
}

private enum ModelNameCatalogRemoteError: Error {
    case invalidResponse
}
