import SwiftUI
import UIKit

// Mac mouse and keyboard. On the Mac a click lands only where a plain button
// draws (a glyph's pixels, a line of text), toolbar icons take clicks only on
// the glyph inside their glass, and nothing reacts to the pointer. These
// helpers fix that one control at a time. Each one changes nothing on iPhone,
// iPad or Vision Pro, which keep their touch and gaze behavior.

/// Pointer target sizes on the Mac, at Settings › Appearance › Button size.
enum BighelpPointer {
    /// The smallest comfortable mouse target, each way.
    static var minimumTarget: CGFloat { BighelpTokens.scaled(28) }
    /// Icon-only controls, which have no text to aim at.
    static var minimumIconTarget: CGFloat { BighelpTokens.scaled(32) }
}

/// The outline a control lights up in under the pointer.
enum BighelpPointerOutline: Sendable {
    case rounded(CGFloat)
    case capsule
    case circle

    static let standard = rounded(8)
}

/// A view's frame grown, centered, to at least `minimum` each way (plus
/// `padding`): a bigger click and hover area that doesn't move the layout.
struct BighelpPointerShape: Shape {
    var outline: BighelpPointerOutline = .standard
    var minimum: CGFloat = 0
    var padding: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let grown = rect.insetBy(
            dx: -max(padding, (minimum - rect.width) / 2),
            dy: -max(padding, (minimum - rect.height) / 2)
        )
        switch outline {
        case .rounded(let radius):
            return Path(roundedRect: grown, cornerRadius: radius, style: .continuous)
        case .capsule:
            return Path(roundedRect: grown, cornerRadius: min(grown.width, grown.height) / 2, style: .continuous)
        case .circle:
            let side = max(grown.width, grown.height)
            return Path(ellipseIn: CGRect(x: grown.midX - side / 2, y: grown.midY - side / 2, width: side, height: side))
        }
    }
}

extension View {
    /// Mac: this view takes clicks across its whole frame (grown to `minimum`
    /// each way when it's smaller) and lights up softly under the pointer. Put
    /// it inside a button's `label:` or before `.onTapGesture`: on the outside
    /// of a Button it changes what VoiceOver measures, not what takes the click.
    /// For a whole plain button, use `.bighelpPlainButtonStyle()` instead.
    func bighelpPointer(
        _ outline: BighelpPointerOutline = .standard,
        minimum: CGFloat? = nil,
        padding: CGFloat = 0,
        highlights: Bool = true
    ) -> some View {
        modifier(BighelpPointerModifier(
            outline: outline, minimum: minimum, padding: padding, highlights: highlights
        ))
    }

    /// `.buttonStyle(.plain)` that is easy to click on the Mac: the label's whole
    /// frame takes the click (grown to `minimum` each way), not just its glyph or
    /// text, and it lights up under the pointer. Elsewhere it is exactly `.plain`.
    func bighelpPlainButtonStyle(
        _ outline: BighelpPointerOutline = .standard,
        minimum: CGFloat? = nil,
        padding: CGFloat = 0
    ) -> some View {
        bighelpPointerButtonStyle(.plain, outline: outline, minimum: minimum, padding: padding)
    }

    /// Any button style (`.borderless`, `.bighelpTilePress`…) with the Mac pointer
    /// helpers on its label, as `bighelpPlainButtonStyle` does for `.plain`.
    /// Elsewhere it is exactly `.buttonStyle(style)`.
    func bighelpPointerButtonStyle<Style: PrimitiveButtonStyle>(
        _ style: Style,
        outline: BighelpPointerOutline = .standard,
        minimum: CGFloat? = nil,
        padding: CGFloat = 0
    ) -> some View {
        #if targetEnvironment(macCatalyst)
        buttonStyle(BighelpPointerButtonStyle(outline: outline, minimum: minimum, padding: padding) { button in
            button.buttonStyle(style)
        })
        #else
        buttonStyle(style)
        #endif
    }

    /// `bighelpPointerButtonStyle` for a `ButtonStyle` (a custom press style).
    func bighelpPointerButtonStyle<Style: ButtonStyle>(
        _ style: Style,
        outline: BighelpPointerOutline = .standard,
        minimum: CGFloat? = nil,
        padding: CGFloat = 0
    ) -> some View {
        #if targetEnvironment(macCatalyst)
        buttonStyle(BighelpPointerButtonStyle(outline: outline, minimum: minimum, padding: padding) { button in
            button.buttonStyle(style)
        })
        #else
        buttonStyle(style)
        #endif
    }

    /// Mac: only the soft highlight under the pointer, in a shape the view
    /// already draws (a glass circle or capsule). It doesn't change what takes clicks.
    func bighelpHover<S: Shape>(in shape: S) -> some View {
        modifier(BighelpHoverModifier(shape: shape))
    }

    /// Mac: a tooltip naming the control, with its keyboard shortcut if it has one
    /// (`shortcut: "⌘N"`). Icon-only controls need one: the Mac has no labels under icons.
    func bighelpHelp(_ text: String, shortcut: String? = nil) -> some View {
        #if targetEnvironment(macCatalyst)
        help(shortcut.map { "\(text) (\($0))" } ?? text)
        #else
        self
        #endif
    }

    /// An icon-only control's name: VoiceOver reads it everywhere, and the Mac
    /// shows it as a tooltip. Use instead of `.accessibilityLabel` on icon buttons.
    func bighelpIconLabel(_ label: String, shortcut: String? = nil) -> some View {
        accessibilityLabel(label).bighelpHelp(label, shortcut: shortcut)
    }

    /// Mac: Return presses this button. Put it on a sheet's or dialog's main
    /// action (Save, Add, Send, Done); `.confirmationAction` placement alone
    /// doesn't do it on the Mac.
    func bighelpDefaultAction() -> some View {
        #if targetEnvironment(macCatalyst)
        keyboardShortcut(.defaultAction)
        #else
        self
        #endif
    }

    /// Mac: Esc presses this button. The Mac already closes a plain sheet on
    /// Esc; use this on a Cancel that does more than close (asks about unsaved
    /// changes, stops work) and on full-screen covers, which Esc doesn't close.
    func bighelpCancelAction() -> some View {
        #if targetEnvironment(macCatalyst)
        keyboardShortcut(.cancelAction)
        #else
        self
        #endif
    }

    /// Mac: a system-drawn button (bordered, prominent, or the default style in a
    /// header) at a bigger control size. The Mac draws those at a fixed height per
    /// size, so a frame on the label can't grow them; `.small` ones are 20 points.
    func bighelpMacControlSize(_ size: ControlSize) -> some View {
        #if targetEnvironment(macCatalyst)
        controlSize(size)
        #else
        self
        #endif
    }

    /// Mac: an icon-only toolbar button's label. The toolbar draws a glass
    /// capsule around the item but takes clicks only on the glyph; this sizes
    /// the label to the capsule so its whole face takes the click.
    func bighelpToolbarIcon() -> some View {
        #if targetEnvironment(macCatalyst)
        frame(minWidth: BighelpPointer.minimumIconTarget, minHeight: BighelpPointer.minimumIconTarget)
            .contentShape(.rect)
        #else
        self
        #endif
    }

    /// Mac: a text field takes clicks across its row's height, not just its
    /// line of text, and uses bighelp's text size (the Mac's own body text is
    /// small and fixed). A click beside the text puts the caret at its end, as
    /// clicking a Mac field's bezel does. Put it on the `TextField` itself.
    func bighelpMacField() -> some View {
        #if targetEnvironment(macCatalyst)
        font(.bighelp(.body))
            .frame(minHeight: BighelpPointer.minimumIconTarget)
            .modifier(MacFieldClickTarget())
        #else
        self
        #endif
    }

    /// Mac: a click anywhere on this container (a search capsule, a field with
    /// its icon) puts the caret at the end of the one text field inside it.
    func bighelpMacFieldArea() -> some View {
        #if targetEnvironment(macCatalyst)
        modifier(MacFieldClickTarget())
        #else
        self
        #endif
    }
}

#if targetEnvironment(macCatalyst)
/// The field's line of text is a UIKit text field that takes clicks only on
/// itself; the frame around it is SwiftUI's. A click there finds that text
/// field (the one under this frame) and puts the caret at its end.
private struct MacFieldClickTarget: ViewModifier {
    @State private var finder = MacTextFieldFinder()

    func body(content: Content) -> some View {
        content
            .background(MacTextFieldProbe(finder: finder).allowsHitTesting(false).accessibilityHidden(true))
            .contentShape(.rect)
            .onTapGesture { finder.focus() }
    }
}

@MainActor
private final class MacTextFieldFinder {
    weak var probe: UIView?

    func focus() {
        guard let probe, let window = probe.window else { return }
        let area = probe.convert(probe.bounds, to: window)
        var host: UIView? = probe.superview
        while let view = host, !String(describing: type(of: view)).contains("HostingView") { host = view.superview }
        var best: (view: UIView, overlap: CGFloat)?
        func visit(_ view: UIView) {
            if view is UITextField || view is UITextView {
                let overlap = view.convert(view.bounds, to: window).intersection(area)
                if !overlap.isNull, overlap.width * overlap.height > (best?.overlap ?? 0) {
                    best = (view, overlap.width * overlap.height)
                }
                return
            }
            view.subviews.forEach(visit)
        }
        visit(host ?? window)
        guard let field = best?.view, field.becomeFirstResponder() else { return }
        if let field = field as? UITextField {
            field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
        } else if let field = field as? UITextView {
            field.selectedRange = NSRange(location: (field.text as NSString).length, length: 0)
        }
    }
}

private struct MacTextFieldProbe: UIViewRepresentable {
    let finder: MacTextFieldFinder

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        finder.probe = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        finder.probe = view
    }
}
#endif

#if targetEnvironment(macCatalyst)
/// A button style with the pointer helpers on the label. A button's click area
/// is what its label draws, so the shape has to sit inside the label; this
/// rebuilds the button around it and leaves the drawing to `base`.
private struct BighelpPointerButtonStyle<Styled: View>: PrimitiveButtonStyle {
    let outline: BighelpPointerOutline
    let minimum: CGFloat?
    let padding: CGFloat
    let base: (Button<AnyView>) -> Styled

    init(outline: BighelpPointerOutline, minimum: CGFloat?, padding: CGFloat,
         base: @escaping (Button<AnyView>) -> Styled) {
        self.outline = outline
        self.minimum = minimum
        self.padding = padding
        self.base = base
    }

    func makeBody(configuration: Configuration) -> some View {
        base(Button(role: configuration.role, action: configuration.trigger) {
            AnyView(configuration.label.bighelpPointer(outline, minimum: minimum, padding: padding))
        })
    }
}
#endif

/// The pointer's highlight: the theme's ink at a whisper, so it reads on cream,
/// white, graphite and black alike.
private struct BighelpHoverModifier<S: Shape>: ViewModifier {
    let shape: S

    #if targetEnvironment(macCatalyst)
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @BighelpThemeReader private var theme
    #endif

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content
            .overlay {
                // Over the content, so it shows on cards that paint their own background.
                shape.fill(theme.primaryText.opacity(theme.isDarkPalette ? 0.10 : 0.06))
                    .opacity(isHovered && isEnabled ? 1 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: BighelpTokens.pressDuration), value: isHovered)
        #else
        content
        #endif
    }
}

private struct BighelpPointerModifier: ViewModifier {
    let outline: BighelpPointerOutline
    let minimum: CGFloat?
    let padding: CGFloat
    let highlights: Bool

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        let shape = BighelpPointerShape(
            outline: outline, minimum: minimum ?? BighelpPointer.minimumTarget, padding: padding
        )
        if highlights {
            content.contentShape(.interaction, shape).bighelpHover(in: shape)
        } else {
            content.contentShape(.interaction, shape)
        }
        #else
        content
        #endif
    }
}
