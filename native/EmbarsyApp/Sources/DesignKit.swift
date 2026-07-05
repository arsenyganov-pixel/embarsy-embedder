import AppKit
import SwiftUI

// Shared design-system building blocks used across the redesigned screens.

/// GitHub releases page for "Check for updates". Placeholder until the real URL
/// is provided — swap the string when the repo is public.
enum AppLinks {
    static let telegram = URL(string: "https://t.me/rcgunoff")!
    static let githubReleases = URL(string: "https://github.com/arsenyganov-pixel/embarsy-embedder/releases")!
    static let bugReport = URL(string: "https://docs.google.com/forms/d/e/1FAIpQLSe8PIfJZaJq-ZSpAAkw4gmtUkEIPZYmdkNl4cNyWd_v6ZjeVQ/viewform?usp=publish-editor")!
}

// MARK: - Branded screen header (logotype-style title + teal period)

/// Screen title rendered like the Embarsy logotype: heavy lead word, medium rest,
/// and a teal period — so every screen echoes the Status brand lockup.
func brandedTitle(_ title: String, size: CGFloat = 19) -> Text {
    let parts = title.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    let lead = parts.first ?? title
    let rest = parts.count > 1 ? " " + parts[1] : ""
    return Text(lead).font(.system(size: size, weight: .heavy))
        + Text(rest).font(.system(size: size, weight: .medium))
        + Text(".").font(.system(size: size, weight: .heavy)).foregroundColor(Theme.accent)
}

struct BrandedHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                brandedTitle(title)
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}

extension BrandedHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() })
    }
}

// MARK: - SectionCard (surface panel with title + optional right label)

struct EmbarsySection<Content: View>: View {
    var title: String? = nil
    var right: String? = nil
    var spacing: CGFloat = 10
    /// When true the card fills the height it is offered (so its surface matches a taller
    /// sibling in the same row, e.g. a Grid row of equal-height cards). Content stays top-aligned.
    var fillHeight: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if title != nil || right != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title {
                        Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                    }
                    Spacer(minLength: 8)
                    if let right {
                        Text(right).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                }
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusXl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusXl, style: .continuous).stroke(Theme.separator))
    }
}

// MARK: - HelpNote (small secondary caption)

struct HelpNote: View {
    let text: String
    var tone: Tone = .normal
    enum Tone { case normal, warn }
    init(_ text: String, tone: Tone = .normal) { self.text = text; self.tone = tone }
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(tone == .warn ? AnyShapeStyle(Color(nsColor: .systemOrange)) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Auto-refresh interval menu (Grafana-style pill + dropdown)

enum RefreshInterval: String, CaseIterable, Identifiable {
    case s2, s5, s10, s30, m1, m5, m15
    var id: String { rawValue }
    var short: String {
        switch self {
        case .s2: return "2s"; case .s5: return "5s"; case .s10: return "10s"; case .s30: return "30s"
        case .m1: return "1m"; case .m5: return "5m"; case .m15: return "15m"
        }
    }
    var label: String {
        switch self {
        case .s2: return "2 seconds"; case .s5: return "5 seconds"; case .s10: return "10 seconds"; case .s30: return "30 seconds"
        case .m1: return "1 minute"; case .m5: return "5 minutes"; case .m15: return "15 minutes"
        }
    }
    var seconds: Double {
        switch self {
        case .s2: return 2; case .s5: return 5; case .s10: return 10; case .s30: return 30
        case .m1: return 60; case .m5: return 300; case .m15: return 900
        }
    }
    /// Options for the Content refresh menu (10s and up).
    static var contentOptions: [RefreshInterval] { [.s10, .s30, .m1, .m5, .m15] }
}

// MARK: - Custom dropdown building blocks
//
// Native macOS menus can't be sized to their trigger or clamped to the app window, so the
// range picker and the refresh-interval picker are drawn as custom popovers instead. A page
// hosts the open dropdown in an overlay (drawn above its ScrollView) and positions it from the
// trigger pill's captured bounds.

/// Shared anchor preference so a page can capture its trigger pill(s) bounds and position the
/// dropdown under them. Two slots so a page (Monitoring) can host two pickers at once.
struct MenuAnchors {
    var range: Anchor<CGRect>? = nil
    var refresh: Anchor<CGRect>? = nil
}
struct MenuAnchorsKey: PreferenceKey {
    static let defaultValue = MenuAnchors()
    static func reduce(value: inout MenuAnchors, nextValue: () -> MenuAnchors) {
        let next = nextValue()
        if let r = next.range { value.range = r }
        if let r = next.refresh { value.refresh = r }
    }
}

/// Dark rounded popover card holding dropdown rows. `width == nil` uses the intrinsic width.
struct DropdownCard<Content: View>: View {
    var width: CGFloat? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 1) { content() }
            .padding(.vertical, 4)
            .frame(width: width, alignment: .leading)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.separator))
            .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
    }
}

/// Small section label inside a dropdown card.
struct DropdownHeader: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One selectable dropdown row: a leading checkmark column (for pick lists) or a fixed accent
/// icon (for actions), with hover / press fill matching a native menu.
struct DropdownRow: View {
    let label: String
    var systemImage: String? = nil     // shown (accent) only when checkColumn == false
    var selected: Bool = false
    var checkColumn: Bool = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if checkColumn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent)
                        .opacity(selected ? 1 : 0).frame(width: 14)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent).frame(width: 14)
                }
                Text(label)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(.primary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).frame(height: 30).contentShape(Rectangle())
        }
        .buttonStyle(DropdownRowStyle())
    }
}

private struct DropdownRowStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background((hover || configuration.isPressed) ? Color.primary.opacity(0.08) : Color.clear)
            .onHover { hover = $0 }
    }
}

/// The refresh-interval dropdown body (Refresh Now + Auto-refresh list), reused by every page.
struct RefreshDropdownCard: View {
    @Binding var interval: RefreshInterval
    var options: [RefreshInterval] = RefreshInterval.allCases
    var width: CGFloat
    var onRefreshNow: (() -> Void)? = nil
    var onSelect: () -> Void

    var body: some View {
        DropdownCard(width: width) {
            if let onRefreshNow {
                DropdownRow(label: "Refresh Now", systemImage: "arrow.clockwise", checkColumn: false) {
                    onRefreshNow(); onSelect()
                }
                Divider().overlay(Theme.separator).padding(.horizontal, 10).padding(.vertical, 3)
            }
            DropdownHeader(text: "Auto-refresh")
            ForEach(options) { option in
                DropdownRow(label: option.label, selected: interval == option) {
                    interval = option; onSelect()
                }
            }
        }
    }
}

/// The refresh pill (spinning icon + short label + chevron) used as the dropdown trigger.
struct RefreshPillLabel: View {
    let short: String
    var busy: Bool = false
    var open: Bool = false
    var body: some View {
        HStack(spacing: 7) {
            SpinningRefreshIcon(busy: busy)
            Text(short).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
            Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.tertiary)
                .rotationEffect(.degrees(open ? 180 : 0))
        }
        .padding(.horizontal, 12).frame(height: 36)
        .background(Theme.fillQuaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.separator))
    }
}

/// Refresh-interval icon that spins continuously while `busy` (matches the design
/// system's `emb-spin 0.7s linear infinite`). TimelineView drives it every frame,
/// which is reliable where `.rotationEffect(360).repeatForever(value:)` often stalls.
private struct SpinningRefreshIcon: View {
    let busy: Bool
    @State private var angle: Double = 0

    var body: some View {
        // The layout footprint is a FIXED transparent box; the rotating glyph is an overlay,
        // and overlays never affect layout — so the spin can't resize/squeeze the pill or the
        // dropdown next to it (a `.frame` after `.rotationEffect` alone didn't prevent this).
        Color.clear
            .frame(width: 14, height: 14)
            .overlay(
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(angle))
            )
            // Each refresh (busy → true) drives one guaranteed full 360° turn, so the spin is
            // always visible even when the fetch itself finishes in a few ms. `withAnimation`
            // (not a `.repeatForever`/`TimelineView`) animates reliably inside the Menu label.
            .onChange(of: busy) { isBusy in
                if isBusy { withAnimation(.linear(duration: 0.7)) { angle += 360 } }
            }
    }
}

// MARK: - App Support chips (Telegram · Report a bug · Check for updates)

struct SupportChip: View {
    var body: some View {
        HStack(spacing: 10) {
            // Telegram
            Link(destination: AppLinks.telegram) {
                HStack(spacing: 8) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Color(red: 0.149, green: 0.647, blue: 0.894), in: Circle())
                    Text("@rcgunoff").font(.system(size: 12, design: .monospaced)).foregroundStyle(.primary)
                }
                .chipBackground()
            }
            .buttonStyle(.plain)
            .help("Telegram — @rcgunoff")

            // Report a bug / request a feature (accent-tinted)
            Link(destination: AppLinks.bugReport) {
                HStack(spacing: 8) {
                    Image(systemName: "ladybug").font(.system(size: 13)).foregroundStyle(Theme.accent)
                    Text("Report a bug / request a feature")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 13)
                .frame(height: 34)
                .background(Theme.accent.opacity(0.10), in: Capsule())
                .overlay(Capsule().stroke(Theme.accent.opacity(0.30)))
            }
            .buttonStyle(.plain)
            .help("Report a bug or request a feature")

            UpdateButton()
        }
    }
}

struct UpdateButton: View {
    var releasesURL: URL = AppLinks.githubReleases
    var body: some View {
        Link(destination: releasesURL) {
            HStack(spacing: 8) {
                GitHubMark().frame(width: 15, height: 15)
                Text("Check for updates").font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
            }
            .chipBackground()
        }
        .buttonStyle(.plain)
        .help("Check for updates on GitHub")
    }
}

/// Minimal GitHub "Octocat" mark drawn from the Simple Icons path (SF Symbols
/// has no brand glyph), tinted with the primary label color.
struct GitHubMark: View {
    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
    }
}

// MARK: - Flow layout (wrapping chips)

struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4
    /// When set, each subview is measured AND placed with this max width, so single-line
    /// truncating children shrink to fit instead of overflowing the container. Layout
    /// measures with `.unspecified` by default, so a plain `.frame(maxWidth:)` on a child
    /// never binds — this proposal is what actually caps the width.
    var maxItemWidth: CGFloat? = nil

    private func measure(_ v: LayoutSubview, containerWidth: CGFloat) -> CGSize {
        guard let cap = maxItemWidth else { return v.sizeThatFits(.unspecified) }
        let width = containerWidth.isFinite ? min(cap, containerWidth) : cap
        return v.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxRowW: CGFloat = 0
        for v in subviews {
            let s = measure(v, containerWidth: maxW)
            if x + s.width > maxW, x > 0 {
                maxRowW = max(maxRowW, x - spacing); x = 0; y += rowH + lineSpacing; rowH = 0
            }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        maxRowW = max(maxRowW, x - spacing)
        let width = maxW.isFinite ? maxW : maxRowW
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = measure(v, containerWidth: bounds.width)
            if x + s.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowH + lineSpacing; rowH = 0
            }
            v.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

// MARK: - Slide-to-delete (calm slide-to-confirm control)

/// Drag the grip right → left; a red wash grows from the right, the knob reddens
/// past 60% and the grip morphs into a trash can. Release past `threshold` fires
/// `onDelete`; release short springs back.
struct SlideToDelete: View {
    var label: String = "delete"
    var threshold: CGFloat = 0.85
    var onDelete: () -> Void

    @State private var progress: CGFloat = 0
    private let handleW: CGFloat = 34
    private let trackH: CGFloat = 28
    private let knobOverhang: CGFloat = 3   // knob extends this far above & below the track edge

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let travel = max(1, w - handleW - 2)
            let hot = progress > 0.6
            let red = Color(nsColor: .systemRed)
            ZStack(alignment: .leading) {
                // ── track (clipped): red wash + label + rounded border ──
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(red.opacity(0.20))
                        .frame(width: progress * w)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Text("\u{2039}\u{2039}\u{2039} \(label)")
                        .font(.system(size: 10)).tracking(0.5)
                        .foregroundStyle(.tertiary)
                        .opacity(Double(1 - progress))
                        .frame(maxWidth: .infinity)
                }
                .frame(width: w, height: trackH)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.separator))
                .contentShape(Rectangle())
                .onTapGesture {}   // absorb taps so the parent row doesn't toggle

                // ── knob: drawn on top and a little taller than the track, so it slightly
                //    overhangs the top and bottom edges (centered by the ZStack). ──
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hot ? red : Theme.surfaceRaised)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(hot ? red : Theme.separator))
                    .overlay(
                        Image(systemName: progress > 0.45 ? "trash" : "line.3.horizontal")
                            .font(.system(size: 12))
                            .foregroundStyle(hot ? AnyShapeStyle(Color.white) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                    )
                    .frame(width: handleW, height: trackH + knobOverhang * 2)
                    .shadow(color: .black.opacity(0.28), radius: 2.5, y: 1)
                    .offset(x: 1 + (1 - progress) * travel)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { g in
                                progress = min(1, max(0, -g.translation.width / travel))
                            }
                            .onEnded { _ in
                                // Always spring back — the row may survive (e.g. Qdrant
                                // down), so never leave the knob pinned in the armed state.
                                let fire = progress >= threshold
                                withAnimation(.easeOut(duration: 0.18)) { progress = 0 }
                                if fire { onDelete() }
                            }
                    )
            }
            .frame(width: w, height: trackH)
        }
        .frame(height: trackH)
    }
}

private extension View {
    func chipBackground() -> some View {
        self.padding(.horizontal, 13)
            .frame(height: 34)
            .background(Theme.fillQuaternary, in: Capsule())
            .overlay(Capsule().stroke(Theme.separator))
    }
}
