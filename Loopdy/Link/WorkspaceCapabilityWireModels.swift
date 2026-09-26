import Foundation

/// Configuration units exposed by Hermes; executable tools are not skill documents.
enum HermesCapabilityKind: String, CaseIterable, Codable, Hashable, Sendable {
    case skill
    case plugin
    case mcpServer
    case toolset

    var title: String {
        switch self {
        case .skill: "Skills"
        case .plugin: "Plugins"
        case .mcpServer: "MCP Servers"
        case .toolset: "Tools"
        }
    }
}

struct HermesCapabilityControl: Equatable, Sendable {
    let agentID: String
    let kind: HermesCapabilityKind
    let itemID: String
    let isEnabled: Bool
    let canToggle: Bool
    let reason: String
    let scope: String
    let activation: String
    let revision: String
}

struct LoopdyLinkWorkspaceCapabilities: Decodable, Equatable, Sendable {
    let protocolVersion: Int
    let pluginVersion: String
    let features: [String]
    let operations: [String]

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, pluginVersion, features, operations
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        pluginVersion = try container.decode(String.self, forKey: .pluginVersion)
        features = try container.decode([String].self, forKey: .features)
        operations = try container.decode([String].self, forKey: .operations)
        func token(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 128 && value.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ".")
            }
        }
        guard protocolVersion == 1, token(pluginVersion),
              features.count <= 64, operations.count <= 256,
              features.allSatisfy(token), operations.allSatisfy(token) else {
            throw LoopdyLinkWireError.invalidValue
        }
    }

    func supports(capability: String) -> Bool {
        features.contains(capability)
    }

    func supports(_ operation: LoopdyLinkWorkspaceOperation) -> Bool {
        operations.contains(operation.rawValue)
    }
}
