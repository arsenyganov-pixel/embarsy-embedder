import AppKit
import SwiftUI

/// Modern "chip"-style hover tooltip — the app's own rounded card, not the default
/// yellow system tooltip. Rendered in a borderless floating panel so it is never
/// clipped by a ScrollView and can sit off the owning view's bounds; it also nudges
/// itself away from screen edges. Use `.chipHelp(_:)` in place of `.help(_:)`.
///
/// Why a panel and not a SwiftUI overlay: overlays get clipped by ScrollView bounds
/// and overflow window edges; a panel escapes both and mirrors how a real tooltip
/// behaves (appears near the cursor, on a short delay).
extension View {
    func chipHelp(_ text: String) -> some View {
        modifier(ChipHelpModifier(text: text))
    }
}

private struct ChipHelpModifier: ViewModifier {
    let text: String
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .accessibilityHint(text)   // keep VoiceOver parity with what the chip says
            .onHover { inside in
                hovering = inside
                if inside {
                    // Short delay like a real tooltip; only show if still hovered.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if hovering { ChipTooltipController.shared.show(text, at: NSEvent.mouseLocation) }
                    }
                } else {
                    ChipTooltipController.shared.hide(after: text)
                }
            }
    }
}

/// The chip card itself — themed to match the app's popovers/badges.
private struct ChipTooltipCard: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .lineSpacing(2)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 300, alignment: .leading)
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.separatorStrong))
            .shadow(color: .black.opacity(0.32), radius: 11, y: 5)
            .padding(14)   // transparent margin so the soft shadow isn't clipped by the panel
    }
}

@MainActor
final class ChipTooltipController {
    static let shared = ChipTooltipController()

    private var panel: NSPanel?
    private var hosting: NSHostingView<ChipTooltipCard>?
    /// The text currently shown — so a stale hide from another symbol can't close a
    /// tooltip that a newer hover already replaced.
    private var currentText: String?

    func show(_ text: String, at mouse: NSPoint) {
        let card = ChipTooltipCard(text: text)
        let panel = ensurePanel()
        hosting?.rootView = card
        hosting?.layoutSubtreeIfNeeded()
        let size = hosting?.fittingSize ?? NSSize(width: 240, height: 60)
        panel.setContentSize(size)

        // NSEvent.mouseLocation and NSPanel origin are both bottom-left screen coords.
        // Place the card up-and-right of the cursor, then clamp inside the screen.
        var origin = NSPoint(x: mouse.x + 6, y: mouse.y + 10)
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        }
        panel.setFrameOrigin(origin)
        currentText = text
        panel.orderFront(nil)
    }

    /// Hide only if the tooltip still belongs to `text` (guards against a lingering
    /// exit event closing a newer tooltip when the cursor slides between symbols).
    func hide(after text: String) {
        if currentText == text {
            currentText = nil
            panel?.orderOut(nil)
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .statusBar          // float above the app window
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false           // the SwiftUI card draws its own shadow
        p.ignoresMouseEvents = true   // never steals hover/click from the UI
        p.hidesOnDeactivate = false
        let host = NSHostingView(rootView: ChipTooltipCard(text: ""))
        host.sizingOptions = [.intrinsicContentSize]
        p.contentView = host
        panel = p
        hosting = host
        return p
    }
}
