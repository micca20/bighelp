import Foundation

/// The native media surface is intentionally keyed only from authenticated
/// Hermes tool coordinates. Display prose and result text are never classifiers.
enum GeneratedMediaKind: String, Codable, Equatable, Sendable {
    case image
    case video
}

enum GeneratedMediaProjection {
    private static let canonicalKinds: [String: GeneratedMediaKind] = [
        "image_generate": .image,
        "video_generate": .video,
        "xai_video_edit": .video,
        "xai_video_extend": .video,
    ]

    static func kind(for event: ChatActivityEvent) -> GeneratedMediaKind? {
        guard event.kind == .tool, let toolName = event.toolName else { return nil }
        if let kind = canonicalKinds[toolName] { return kind }
        guard toolName == "tool_call",
              let arguments = event.arguments?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: arguments) as? [String: Any],
              let innerName = object["name"] as? String else { return nil }
        return canonicalKinds[innerName]
    }
}

struct GeneratedMediaResolution: Codable, Equatable, Sendable {
    enum State: String, Codable, Equatable, Sendable {
        case ready
        case unavailable
        case oversized
    }

    static let maximumArtifactCount = 8
    static let maximumTotalBytes = 32 * 1_024 * 1_024

    let state: State
    let attachments: [ChatAttachment]
    let omittedCount: Int

    init(state: State, attachments: [ChatAttachment] = [], omittedCount: Int = 0) {
        self.state = state
        self.attachments = attachments
        self.omittedCount = max(0, omittedCount)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let state = try container.decode(State.self, forKey: .state)
        let attachments = try container.decode([ChatAttachment].self, forKey: .attachments)
        let omittedCount = try container.decode(Int.self, forKey: .omittedCount)
        var totalBytes = 0
        var overflowed = false
        for attachment in attachments {
            let sum = totalBytes.addingReportingOverflow(attachment.data.count)
            totalBytes = sum.partialValue
            overflowed = overflowed || sum.overflow
        }
        guard !overflowed,
              attachments.count <= Self.maximumArtifactCount,
              totalBytes <= Self.maximumTotalBytes,
              attachments.allSatisfy(Self.isValid),
              omittedCount >= 0,
              (state == .ready) == !attachments.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .attachments,
                in: container,
                debugDescription: "Generated media resolution is invalid"
            )
        }
        self.state = state
        self.attachments = attachments
        self.omittedCount = omittedCount
    }

    private static func isValid(_ attachment: ChatAttachment) -> Bool {
        (16...128).contains(attachment.id.count)
            && attachment.id.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
            }
            && (1...ChatAttachment.maximumAgentBytes).contains(attachment.data.count)
            && !attachment.fileName.isEmpty
            && attachment.fileName == URL(fileURLWithPath: attachment.fileName).lastPathComponent
            && (attachment.mimeType.hasPrefix("image/") || attachment.mimeType.hasPrefix("video/"))
    }
}

@MainActor
protocol GeneratedMediaResolving: AnyObject {
    func resolve(
        agentID: String,
        storedID: String,
        event: ChatActivityEvent
    ) async throws -> GeneratedMediaResolution
}
