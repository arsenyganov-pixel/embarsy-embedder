import SwiftUI

/// Crisp, resolution-independent Embarsy "Vector Ears" mark.
///
/// Mirrors `Embarsy-icons/Toolbar/EmbarsyIndex_Template.svg` (viewBox 96×96 with a
/// `translate(11,26)` group). Drawing it natively keeps the mark sharp at any Retina
/// scale — no more blurry 36px PNGs — and lets us tint it by status. Recolor via `color`.
struct EmbarsyMarkView: View {
    var color: Color
    /// Stroke width expressed in the 96-unit design space (SVG uses 6).
    var strokeWidth: CGFloat = 6
    /// When true, the stroke draws itself on a loop (design-system `emb-draw`):
    /// a 2.4s cycle — draw over the first 55% (eased), then hold. Dots stay static.
    var animated: Bool = false

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let style = StrokeStyle(lineWidth: strokeWidth * s / 96.0, lineCap: .round, lineJoin: .round)
            ZStack {
                if animated {
                    TimelineView(.animation) { timeline in
                        MarkOutline()
                            .trim(from: 0, to: Self.drawProgress(timeline.date.timeIntervalSinceReferenceDate))
                            .stroke(color, style: style)
                    }
                } else {
                    MarkOutline().stroke(color, style: style)
                }
                MarkDots().fill(color)
            }
            .frame(width: s, height: s)
        }
    }

    /// Draw fraction for the 2.4s loop: 0→1 (smoothstep-eased) over the first 55%, then held at 1.
    private static func drawProgress(_ t: TimeInterval) -> CGFloat {
        let phase = t.truncatingRemainder(dividingBy: 2.4) / 2.4
        let raw = min(1.0, phase / 0.55)
        return CGFloat(raw * raw * (3 - 2 * raw))   // ease-in-out (smoothstep)
    }
}

/// The "Vector Ears" M + arrowhead barbs — one continuous stroke path (so `.trim`
/// draws it in path order). Points are already offset by the SVG's translate(11,26).
private struct MarkOutline: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 96.0
        var p = Path()
        p.addLines([
            CGPoint(x: 16, y: 65.5), CGPoint(x: 32, y: 30.5), CGPoint(x: 48, y: 57.5),
            CGPoint(x: 64, y: 30.5), CGPoint(x: 80, y: 65.5),
        ])
        p.move(to: CGPoint(x: 80, y: 65.5)); p.addLine(to: CGPoint(x: 79, y: 51.5))
        p.move(to: CGPoint(x: 80, y: 65.5)); p.addLine(to: CGPoint(x: 70, y: 55.5))
        return p.applying(CGAffineTransform(scaleX: scale, y: scale))
    }
}

/// The two static "eyes" (filled r=3.4 circles).
private struct MarkDots: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 96.0
        var p = Path()
        p.addEllipse(in: CGRect(x: 37 - 3.4, y: 64.5 - 3.4, width: 6.8, height: 6.8))
        p.addEllipse(in: CGRect(x: 59 - 3.4, y: 64.5 - 3.4, width: 6.8, height: 6.8))
        return p.applying(CGAffineTransform(scaleX: scale, y: scale))
    }
}

extension Theme {
    /// Brand-mark tint by aggregate status (status header + menu-bar icon).
    /// Teal when running, muted gray when off, status hue while transitioning.
    static func markTint(_ status: ServiceStatus) -> Color {
        switch status {
        case .running:            return accent
        case .starting:           return Theme.status(.starting)
        case .failed:             return Theme.status(.failed)
        case .stopped, .unknown:  return offGray
        }
    }
}
