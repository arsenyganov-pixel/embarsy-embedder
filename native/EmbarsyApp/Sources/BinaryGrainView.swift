import SwiftUI

/// Decorative "binary grain" background — a fine lattice of monospaced 0/1 glyphs
/// (a nod to embedding vectors) at low teal opacity, with ~2% of the cells flipping
/// every 0.65s and a brighten-then-fade pulse. Ported from the design-system
/// mock (`ui_kits/embarsy-app/index.html` `embGrain`). Purely decorative and
/// non-interactive; animation pauses when inactive, when Reduce Motion is on, and
/// when the window can't be seen (closed / minimized / fully covered).
///
/// Flips PERSIST (the lattice keeps evolving, like the mock) but there is no
/// dedicated Timer: the epoch change rides the TimelineView tick, so a paused
/// timeline costs zero wakeups.
struct BinaryGrainView: View {
    /// Digits keep flipping only while this is true (mock: grain runs only when running).
    var active: Bool = true
    var tint: Color = Color(red: 0.624, green: 0.878, blue: 0.839) // #9FE0D6
    /// The main-window mount pauses when that window can't be seen; the menu-bar popover
    /// passes `false` — it only exists while open and its window is not level-.normal, so
    /// gating it on the MAIN window would freeze the grain exactly when the user looks at it.
    var pausesWhenMainWindowHidden: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var windowVisibility = WindowVisibility.shared

    @State private var cells: [Cell] = []
    @State private var gridKey = 0

    private let colStep: CGFloat = 14
    private let rowStep: CGFloat = 15
    private static let flipInterval: Double = 0.65
    private let fade: Double = 0.65

    private struct Cell {
        var point: CGPoint
        var one: Bool
        var base: Double
        var ping: Double   // reference-time of last flip; far past = at rest
    }

    private var animating: Bool {
        active && !reduceMotion && (!pausesWhenMainWindowHidden || windowVisibility.isMainWindowVisible)
    }

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !animating)) { timeline in
                let now = timeline.date.timeIntervalSinceReferenceDate
                Canvas { ctx, _ in
                    guard !cells.isEmpty else { return }
                    let font = Font.system(size: 8, design: .monospaced)
                    let zero = ctx.resolve(Text("0").font(font).foregroundColor(tint))
                    let one = ctx.resolve(Text("1").font(font).foregroundColor(tint))
                    for cell in cells {
                        var c = ctx
                        c.opacity = opacity(for: cell, now: now)
                        c.draw(cell.one ? one : zero, at: cell.point, anchor: .topLeading)
                    }
                }
                // Persistent flips without a Timer: fire once per 0.65s epoch, but only
                // while the timeline actually ticks (visible + active), so hidden windows
                // cost nothing.
                .onChange(of: Int(now / Self.flipInterval)) { _ in
                    flip(at: now)
                }
            }
            .onAppear { rebuild(proxy.size) }
            .onChange(of: proxy.size) { rebuild($0) }
        }
        .allowsHitTesting(false)
    }

    private func opacity(for cell: Cell, now: Double) -> Double {
        let elapsed = now - cell.ping
        guard elapsed >= 0, elapsed < fade else { return cell.base }
        let bright = min(0.30, cell.base * 2.8)
        return bright + (cell.base - bright) * (elapsed / fade)
    }

    private func rebuild(_ size: CGSize) {
        let cols = size.width > 0 ? Int((size.width + 13) / colStep) : 0
        let rows = size.height > 0 ? Int((size.height + 14) / rowStep) : 0
        let key = cols * 1000 + rows
        guard key != gridKey else { return }
        gridKey = key

        var fresh: [Cell] = []
        fresh.reserveCapacity(cols * rows)
        for r in 0..<max(rows, 0) {
            for col in 0..<max(cols, 0) {
                fresh.append(Cell(
                    point: CGPoint(x: 1 + CGFloat(col) * colStep, y: 2 + CGFloat(r) * rowStep),
                    one: Bool.random(),
                    base: 0.06 + Double.random(in: 0...0.09),
                    ping: -1000
                ))
            }
        }
        cells = fresh
    }

    /// The mock's behavior: each interval, ~2% of cells toggle their digit FOR GOOD and
    /// pulse — that persistent churn is what makes the lattice read as alive.
    private func flip(at now: Double) {
        guard !cells.isEmpty else { return }
        let k = max(2, Int(Double(cells.count) * 0.02))
        for _ in 0..<k {
            let i = Int.random(in: 0..<cells.count)
            cells[i].one.toggle()
            cells[i].ping = now
        }
    }
}
