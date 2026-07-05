import SwiftUI

/// Decorative "binary grain" background — a fine lattice of monospaced 0/1 glyphs
/// (a nod to embedding vectors) at low teal opacity, with ~2% of the cells randomly
/// flipping every 0.65s and a brighten-then-fade pulse. Ported from the design-system
/// mock (`ui_kits/embarsy-app/index.html` `embGrain`). Purely decorative and
/// non-interactive; animation pauses when inactive or Reduce Motion is on.
struct BinaryGrainView: View {
    /// Digits keep flipping only while this is true (mock: grain runs only when running).
    var active: Bool = true
    var tint: Color = Color(red: 0.624, green: 0.878, blue: 0.839) // #9FE0D6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var cells: [Cell] = []
    @State private var gridKey = 0

    private let timer = Timer.publish(every: 0.65, on: .main, in: .common).autoconnect()
    private let colStep: CGFloat = 14
    private let rowStep: CGFloat = 15
    private let fade: Double = 0.65

    private struct Cell {
        var point: CGPoint
        var one: Bool
        var base: Double
        var ping: Double   // reference-time of last flip; far past = at rest
    }

    private var animating: Bool { active && !reduceMotion }

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !animating)) { timeline in
                Canvas { ctx, _ in
                    guard !cells.isEmpty else { return }
                    let now = timeline.date.timeIntervalSinceReferenceDate
                    let font = Font.system(size: 8, design: .monospaced)
                    let zero = ctx.resolve(Text("0").font(font).foregroundColor(tint))
                    let one = ctx.resolve(Text("1").font(font).foregroundColor(tint))
                    for cell in cells {
                        var c = ctx
                        c.opacity = opacity(for: cell, now: now)
                        c.draw(cell.one ? one : zero, at: cell.point, anchor: .topLeading)
                    }
                }
            }
            .onAppear { rebuild(proxy.size) }
            .onChange(of: proxy.size) { rebuild($0) }
            .onReceive(timer) { _ in if animating { flip() } }
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

    private func flip() {
        guard !cells.isEmpty else { return }
        let now = Date().timeIntervalSinceReferenceDate
        let k = max(2, Int(Double(cells.count) * 0.02))
        for _ in 0..<k {
            let i = Int.random(in: 0..<cells.count)
            cells[i].one.toggle()
            cells[i].ping = now
        }
    }
}
