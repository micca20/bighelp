import Foundation

/// Optional transport seam used only before an admission mutation. It proves
/// the existing socket is live (or completes its bounded reconnect) without
/// replaying the caller's prompt.
@MainActor
protocol DirectHermesAdmissionPreparing: AnyObject {
    func prepareForAdmission() async throws
}

/// A conversation lease on the existing authenticated socket, not a second
/// connection. Retiring it cannot disconnect unrelated feature consumers.
@MainActor
final class DirectHermesOwnedRPC: DirectHermesRPC, DirectHermesAuthenticatedHTTP,
    DirectHermesAdmissionPreparing {
    var onEvent: ((DirectHermesEvent) -> Void)?

    private let base: any DirectHermesRPC
    private let owner: WorkspaceOwner
    private let currentOwner: @MainActor () -> WorkspaceOwner?
    private var retired = false

    init(base: any DirectHermesRPC, owner: WorkspaceOwner,
         currentOwner: @escaping @MainActor () -> WorkspaceOwner?) throws {
        guard owner.authority.kind == .direct else { throw WorkspaceClientError.ownerChanged }
        self.base = base
        self.owner = owner
        self.currentOwner = currentOwner
    }

    func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        try checkOwner()
        do {
            let result = try await base.request(method, params: params)
            try checkOwner()
            return result
        } catch {
            try checkOwner()
            throw error
        }
    }

    func request(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        try checkOwner()
        guard let http = base as? any DirectHermesAuthenticatedHTTP else {
            throw DirectHermesError.unsupportedAuthentication
        }
        do {
            let result = try await http.request(request)
            try checkOwner()
            return result
        } catch {
            try checkOwner()
            throw error
        }
    }

    func prepareForAdmission() async throws {
        try checkOwner()
        guard let preparer = base as? any DirectHermesAdmissionPreparing else { return }
        try await preparer.prepareForAdmission()
        try checkOwner()
    }

    func receive(_ event: DirectHermesEvent) {
        guard !retired, currentOwner() == owner else { return }
        onEvent?(event)
    }

    func disconnect() async {
        retired = true
        onEvent = nil
    }

    private func checkOwner() throws {
        try Task.checkCancellation()
        guard !retired, currentOwner() == owner else { throw WorkspaceClientError.ownerChanged }
    }
}
