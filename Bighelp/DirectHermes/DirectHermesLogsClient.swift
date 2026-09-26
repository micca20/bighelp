import Foundation

@MainActor
final class DirectHermesLogsClient: HermesLogsReading {
    private let http: any DirectHermesAuthenticatedHTTP
    private let scope: DirectHermesCoreRequestScope

    init(
        http: any DirectHermesAuthenticatedHTTP,
        workspace: any WorkspaceOperationPerforming,
        owner: WorkspaceOwner,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?
    ) {
        self.http = http
        scope = DirectHermesCoreRequestScope(
            workspace: workspace,
            owner: owner,
            currentOwner: currentOwner
        )
    }

    var owner: WorkspaceOwner? {
        guard (try? scope.check()) != nil else { return nil }
        return scope.owner
    }

    func read(_ query: HermesLogQuery) async throws -> HermesLogPage {
        try scope.check()
        let request = DirectHermesHTTPRequest(
            path: "/api/logs",
            method: .get,
            query: queryItems(query),
            maximumResponseBytes: 2_097_152
        )
        let response: BighelpJSONValue
        do {
            response = try await http.request(request)
        } catch {
            try scope.check()
            throw Self.safeError(error)
        }
        try scope.check()
        guard let object = response.object,
              object["file"]?.string == query.file.rawValue,
              let values = object["lines"]?.array,
              values.count <= query.lineLimit else {
            throw HermesLogsClientError.invalidResponse
        }
        let entries = try values.enumerated().map { index, value -> HermesLogEntry in
            guard let line = value.string else { throw HermesLogsClientError.invalidResponse }
            return try HermesLogCodec.entry(line, id: index)
        }
        try scope.check()
        return HermesLogPage(query: query, entries: entries)
    }

    private func queryItems(_ query: HermesLogQuery) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "file", value: query.file.rawValue),
            URLQueryItem(name: "lines", value: String(query.lineLimit)),
        ]
        if let level = query.level.queryValue {
            items.append(URLQueryItem(name: "level", value: level))
        }
        if let component = query.component.queryValue {
            items.append(URLQueryItem(name: "component", value: component))
        }
        if let search = query.search {
            items.append(URLQueryItem(name: "search", value: search))
        }
        return items
    }

    private static func safeError(_ error: any Error) -> any Error {
        if error is CancellationError || error is WorkspaceClientError || error is HermesLogsClientError {
            return error
        }
        guard let direct = error as? DirectHermesError else {
            return WorkspaceClientError.transportUnavailable
        }
        switch direct {
        case .unsupportedAuthentication:
            // DirectHermesHTTP maps fixed-route 404/405 responses to this case.
            return HermesLogsClientError.unsupported
        case .invalidCredentials, .authenticationRequired:
            return WorkspaceClientError.authenticationRequired
        case .invalidResponse:
            return HermesLogsClientError.invalidResponse
        case .messageTooLarge, .tooManyRequests, .rateLimited:
            return WorkspaceClientError.capacityExceeded
        default:
            return WorkspaceClientError.transportUnavailable
        }
    }
}
