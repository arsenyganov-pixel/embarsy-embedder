import AppKit
import SwiftUI

struct MenuBarIconView: View {
    let status: ServiceStatus

    var body: some View {
        // Render the mark to an NSImage: a MenuBarExtra status-bar label can come up
        // blank with custom SwiftUI drawing (Canvas), but an Image/NSImage is reliable.
        Image(nsImage: MenuBarIconView.markImage(color: NSColor(Theme.markTint(status)), height: 20))
            .accessibilityLabel("Embarsy — \(status.title)")
            .help("Embarsy status, shown by the mark's colour: teal = all running, amber = starting up, red = a service failed, grey = stopped. Currently: \(status.title)")
    }

    /// Draws the "Vector Ears" mark cropped to its visible bounds and scaled to fill
    /// `height`, so the mark reads large in the menu bar (no wasted vertical padding).
    /// Points below are in the SVG's 96-unit space with translate(11,26) baked in.
    static func markImage(color: NSColor, height: CGFloat) -> NSImage {
        // Visible content box (incl. half stroke-width and the dots) in the 96-space.
        let x0: CGFloat = 13, y0: CGFloat = 27
        let contentW: CGFloat = 70, contentH: CGFloat = 42
        let pad: CGFloat = 1.5
        let s = (height - pad * 2) / contentH
        let width = contentW * s + pad * 2

        func tx(_ x: CGFloat) -> CGFloat { (x - x0) * s + pad }
        func ty(_ y: CGFloat) -> CGFloat { (y - y0) * s + pad }

        let image = NSImage(size: NSSize(width: ceil(width), height: ceil(height)), flipped: true) { _ in
            let stroke = NSBezierPath()
            stroke.move(to: NSPoint(x: tx(16), y: ty(65.5)))
            stroke.line(to: NSPoint(x: tx(32), y: ty(30.5)))
            stroke.line(to: NSPoint(x: tx(48), y: ty(57.5)))
            stroke.line(to: NSPoint(x: tx(64), y: ty(30.5)))
            stroke.line(to: NSPoint(x: tx(80), y: ty(65.5)))
            stroke.move(to: NSPoint(x: tx(80), y: ty(65.5)))
            stroke.line(to: NSPoint(x: tx(79), y: ty(51.5)))
            stroke.move(to: NSPoint(x: tx(80), y: ty(65.5)))
            stroke.line(to: NSPoint(x: tx(70), y: ty(55.5)))
            stroke.lineWidth = 6 * s
            stroke.lineCapStyle = .round
            stroke.lineJoinStyle = .round
            color.setStroke()
            stroke.stroke()

            color.setFill()
            let r = 3.4 * s
            NSBezierPath(ovalIn: NSRect(x: tx(37) - r, y: ty(64.5) - r, width: 2 * r, height: 2 * r)).fill()
            NSBezierPath(ovalIn: NSRect(x: tx(59) - r, y: ty(64.5) - r, width: 2 * r, height: 2 * r)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
