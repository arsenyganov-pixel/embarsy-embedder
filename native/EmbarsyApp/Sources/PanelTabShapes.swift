import SwiftUI

// Shapes for a tab strip that opens into the panel beneath it, shared by Connections and
// Memory so both read as the same control.

/// The selected tab: rounded top corners, square bottom. Open (no bottom edge) when stroked,
/// so its outline flows into the panel instead of drawing a line between them.
struct TabShape: Shape {
    var radius: CGFloat
    var closed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: radius)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        if closed { path.closeSubpath() }
        return path
    }
}

/// The tab panel. Its top-left corner is square while the first tab is selected, so that tab
/// sits flush on the panel's edge instead of floating above a rounded corner.
struct PanelShape: Shape {
    var radius: CGFloat
    var squareTopLeft: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if squareTopLeft {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + radius))
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                        tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: radius)
        }
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: radius)
        path.closeSubpath()
        return path
    }
}
