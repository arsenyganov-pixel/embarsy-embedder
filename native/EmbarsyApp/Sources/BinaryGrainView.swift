import SwiftUI

/// Decorative "binary grain" background — a fine lattice of monospaced 0/1 glyphs
/// (a nod to embedding vectors) at low teal opacity, with ~2% of the cells flipping
/// every 0.65s and a brighten-then-fade pulse. Ported from the design-system
/// mock (`ui_kits/embarsy-app/index.html` `embGrain`). Purely decorative and
/// non-interactive; animation pauses when inactive, when Reduce Motion is on, and
/// when the window can't be seen (closed / minimized / fully covered).
///
/// Flips are a pure deterministic function of time — the old dedicated 0.65s
/// main-runloop Timer (an extra app-wide wakeup source) is gone entirely.
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

    private struct Cell {
        var point: CGPoint
        var one: Bool
        var base: Double
        var seed: UInt64   // per-cell hash input for deterministic time-based flips
    }

    private var animating: Bool {
        active && !reduceMotion && (!pausesWhenMainWindowHidden || windowVisibility.isMainWindowVisible)
    }

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !animating)) { timeline in
                Canvas { ctx, _ in
                    guard !cells.isEmpty else { return }
                    let now = timeline.date.timeIntervalSinceReferenceDate
                    let epoch = Int(now / Self.flipInterval)
                    let font = Font.system(size: 8, design: .monospaced)
                    let zero = ctx.resolve(Text("0").font(font).foregroundColor(tint))
                    let one = ctx.resolve(Text("1").font(font).foregroundColor(tint))
                    for cell in cells {
                        let flipped = Self.isChosen(seed: cell.seed, epoch: epoch)
                        var c = ctx
                        c.opacity = opacity(for: cell, now: now, epoch: epoch, flipped: flipped)
                        c.draw(cell.one != flipped ? one : zero, at: cell.point, anchor: .topLeading)
                    }
                }
            }
            .onAppear { rebuild(proxy.size) }
            .onChange(of: proxy.size) { rebuild($0) }
        }
        .allowsHitTesting(false)
    }

    /// ~2% of cells are "chosen" each 0.65s epoch via a cheap splitmix-style hash of
    /// (cell seed, epoch) — same visual cadence as the old random Timer flips.
    private static func isChosen(seed: UInt64, epoch: Int) -> Bool {
        var h = seed ^ (UInt64(bitPattern: Int64(epoch)) &* 0x9E37_79B9_7F4A_7C15)
        h ^= h >> 33
        h &*= 0xFF51_AFD7_ED55_8CCD
        h ^= h >> 33
        return h % 50 == 0   // ~2%
    }

    /// Chosen cells brighten at the start of their flip epoch and fade back over it.
    private func opacity(for cell: Cell, now: Double, epoch: Int, flipped: Bool) -> Double {
        guard flipped else { return cell.base }
        let elapsed = now - Double(epoch) * Self.flipInterval
        guard elapsed >= 0, elapsed < Self.flipInterval else { return cell.base }
        let bright = min(0.30, cell.base * 2.8)
        return bright + (cell.base - bright) * (elapsed / Self.flipInterval)
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
                    seed: UInt64(r) &* 0x1F1F_1F1F &+ UInt64(col) &* 0x0BAD_C0DE &+ 0x5EED
                ))
            }
        }
        cells = fresh
    }
}
