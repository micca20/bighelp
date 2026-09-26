import Foundation

/// Host-advertised behavior that can be translated into the app's neutral
/// capability model without teaching central composition about raw RPC names.
struct DirectHermesCapabilityManifest: Equatable, Sendable {
    let perSessionExclusiveSubmit: Bool
    let operationAvailability: [WorkspaceCapability: WorkspaceAvailability]

    var supportedOperations: Set<WorkspaceCapability> {
        Set(operationAvailability.compactMap { $0.value == .available ? $0.key : nil })
    }

    static func decode(_ value: BighelpJSONValue) throws -> Self {
        guard let object = value.object,
              let perSessionExclusiveSubmit = object["per_session_exclusive_submit"]?.boolean else {
            throw WorkspaceClientError.invalidResponse
        }

        var supported = DirectHermesReleaseContract.operationsIndependentOfExclusiveSubmit
        if perSessionExclusiveSubmit {
            supported.formUnion(DirectHermesReleaseContract.exclusiveSubmissionOperations)
        }
        let availability = Dictionary(uniqueKeysWithValues: WorkspaceCapability.allCases.map { capability in
            let value: WorkspaceAvailability
            if supported.contains(capability) {
                value = .available
            } else if DirectHermesReleaseContract.exclusiveSubmissionOperations.contains(capability) {
                value = .unavailable(.unsupportedHost)
            } else {
                value = .unavailable(.unsupportedOperation)
            }
            return (capability, value)
        })
        return Self(
            perSessionExclusiveSubmit: perSessionExclusiveSubmit,
            operationAvailability: availability
        )
    }

    @MainActor
    static func discover(using rpc: any DirectHermesRPC) async throws -> Self {
        try decode(try await rpc.request("gateway.capabilities", params: [:]))
    }

    func workspaceCapabilities(owner: WorkspaceOwner) -> WorkspaceCapabilities {
        WorkspaceCapabilities(owner: owner, values: operationAvailability)
    }
}