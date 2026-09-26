import Foundation

struct RuntimeReasoningOption: Identifiable, Equatable, Sendable {
    var id: String { value }
    let value: String
    let label: String
    let detail: String
    let isCurrent: Bool
}

struct RecentModelChoice: Identifiable, Equatable, Sendable {
    var id: String { "\(providerID):\(modelID)" }
    let providerID: String
    let providerName: String
    let modelID: String
    let isCurrent: Bool
}

enum SessionRuntimeSelectionStep: Equatable, Sendable {
    case models
    case reasoning

    var scrollAnchorID: String {
        switch self {
        case .models:
            "chat.session-controls.models-top"
        case .reasoning:
            "chat.session-controls.reasoning-top"
        }
    }
}

struct SessionRuntimeSelectionDraft: Equatable, Sendable {
    private(set) var originalProviderID: String?
    private(set) var originalModelID: String?
    private(set) var originalReasoningValue: String?

    private(set) var providerID: String?
    private(set) var modelID: String?
    private(set) var reasoningValue: String?
    private(set) var step: SessionRuntimeSelectionStep = .models

    init(providerID: String?, modelID: String?, reasoningValue: String?) {
        originalProviderID = providerID
        originalModelID = modelID
        originalReasoningValue = reasoningValue
        self.providerID = providerID
        self.modelID = modelID
        self.reasoningValue = reasoningValue
    }

    var hasChanges: Bool {
        providerID != originalProviderID
            || modelID != originalModelID
            || reasoningValue != originalReasoningValue
    }

    mutating func reconcile(providerID: String?, modelID: String?, reasoningValue: String?) {
        let editedModel = self.providerID != originalProviderID || self.modelID != originalModelID
        let editedReasoning = self.reasoningValue != originalReasoningValue
        if let providerID, let modelID {
            if !editedModel { self.providerID = providerID; self.modelID = modelID }
            originalProviderID = providerID
            originalModelID = modelID
        }
        if let reasoningValue {
            if !editedReasoning { self.reasoningValue = reasoningValue }
            originalReasoningValue = reasoningValue
        }
    }

    mutating func selectModel(providerID: String, modelID: String) {
        self.providerID = providerID
        self.modelID = modelID
        step = .reasoning
    }

    mutating func selectReasoning(_ value: String) {
        reasoningValue = value
        step = .models
    }

    mutating func showModels() {
        step = .models
    }
}
