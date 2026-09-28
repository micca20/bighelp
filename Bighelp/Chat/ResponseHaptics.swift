import Foundation
import SwiftUI
import UIKit

/// Ephemeral delivery evidence, not transcript state. Never persisted or replayed.
struct ResponseTextGrowth: Equatable, Sendable {
    let conversationID: String
    let messageID: String
}

enum ResponseHapticsPolicy {
    /// Both answer and commentary use the live assistant-message path. Activity
    /// events (including reasoning and tools) never enter this policy.
    static func isGrowing(from previous: TimelineItem?, to item: TimelineItem) -> Bool {
        guard item.role == .assistant,
              item.sender.kind == .agent,
              case .message(let text) = item.content,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text != "Preparing attachment…" else { return false }
        guard let previous else { return true }
        guard previous.id == item.id,
              previous.role == item.role,
              previous.sender.kind == item.sender.kind,
              previous.sender.id == item.sender.id,
              case .message(let oldText) = previous.content else { return false }
        return text.utf8.count > oldText.utf8.count && text.utf8.starts(with: oldText.utf8)
    }
}

/// Owned by the visible chat destination, never by a retained session model.
/// Delivery is synchronous: throttled events are dropped, not scheduled.
@MainActor
final class ResponseHapticsController {
    private let clock: () -> TimeInterval
    private let supportsHaptics: Bool
    private let output: (() -> Void)?
    private let minimumInterval: TimeInterval
    private var lastPulseTime: TimeInterval?
    #if !os(visionOS)
    private var generator: UIImpactFeedbackGenerator?
    #endif
    weak var surface: UIView? {
        didSet {
            guard oldValue !== surface else { return }
            #if !os(visionOS)
            generator = nil
            #endif
            prepareGenerator()
        }
    }

    init(
        minimumInterval: TimeInterval = 0.18,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        supportsHaptics: Bool? = nil,
        output: (() -> Void)? = nil
    ) {
        self.minimumInterval = minimumInterval
        self.clock = clock
        // UIKit decides whether this feedback can play on the current device.
        // Core Haptics capabilities are not a gate for UIKit feedback delivery.
        self.supportsHaptics = supportsHaptics ?? true
        self.output = output
    }

    func receive(
        _ event: ResponseTextGrowth,
        conversationID: String,
        isEnabled: Bool,
        isSceneActive: Bool,
        isVisible: Bool
    ) {
        guard supportsHaptics, isEnabled, isSceneActive, isVisible,
              event.conversationID == conversationID else { return }
        let now = clock()
        guard now.isFinite,
              lastPulseTime.map({ now - $0 >= minimumInterval }) ?? true else { return }
        lastPulseTime = now
        if let output {
            output()
        } else {
            #if !os(visionOS)
            prepareGenerator()
            generator?.impactOccurred(intensity: 0.5)
            generator?.prepare()
            #endif
        }
    }

    private func prepareGenerator() {
        #if !os(visionOS) // Vision Pro has no haptics.
        guard output == nil, generator == nil, let surface else { return }
        if #available(iOS 17.5, *) {
            generator = UIImpactFeedbackGenerator(style: .light, view: surface)
        } else {
            generator = UIImpactFeedbackGenerator(style: .light)
        }
        generator?.prepare()
        #endif
    }

    /// Check UIKit at delivery time as child sheets can be owned inside ChatView
    /// rather than by ChatDestinationView's SwiftUI presentation state.
    var isSurfaceUncovered: Bool {
        guard let surface, let window = surface.window,
              window.windowScene?.activationState == .foregroundActive,
              surface.bounds.width > 0, surface.bounds.height > 0,
              surface.convert(surface.bounds, to: window).intersects(window.bounds)
        else { return false }
        var ancestor: UIView? = surface
        while let view = ancestor {
            if view.isHidden || view.alpha <= 0 { return false }
            ancestor = view.superview
        }
        guard let root = window.rootViewController else { return false }
        return !Self.hasCoveringPresentation(root, surface: surface)
    }

    private static func hasCoveringPresentation(_ controller: UIViewController, surface: UIView) -> Bool {
        if let presented = controller.presentedViewController {
            // A presentation containing this chat is not a cover over it.
            // Nor is a controller retained after its view left the window.
            if let view = presented.viewIfLoaded, view.window === surface.window,
               !view.isHidden, view.alpha > 0 {
                if !surface.isDescendant(of: view) { return true }
                return hasCoveringPresentation(presented, surface: surface)
            }
        }
        // Ignore inactive navigation destinations and sibling controllers.
        return controller.children.contains { child in
            guard let view = child.viewIfLoaded, surface.isDescendant(of: view) else { return false }
            return hasCoveringPresentation(child, surface: surface)
        }
    }
}

/// A noninteractive probe on the real chat canvas, also covering child modals.
@MainActor
struct ResponseHapticsSurface: UIViewRepresentable {
    let controller: ResponseHapticsController

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        controller.surface = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        controller.surface = uiView
    }
}
