import SwiftUI

/// Embarsy design tokens — macOS **Dark** appearance.
/// The app runs in forced dark mode. Status / metric colors use the native macOS
/// system palette (which already matches our dark tokens 1:1); the ONLY proprietary
/// hue is brand teal. Do not hardcode hex for status/metric colors — use these.
enum Theme {

    // MARK: Brand
    static let accent      = Color(red: 0.078, green: 0.722, blue: 0.651) // #14B8A6 brand teal (accent / "on")
    static let accentHover = Color(red: 0.129, green: 0.788, blue: 0.718) // #21C9B7
    static let offGray     = Color(red: 0.431, green: 0.463, blue: 0.506) // #6E7681 muted mark ("off")
    static let onAccent    = Color(red: 0.031, green: 0.125, blue: 0.114) // #08201D ink on the teal fill

    // MARK: Status → native system colors (match dark tokens)
    static func status(_ s: ServiceStatus) -> Color {
        switch s {
        case .running:            return Color(nsColor: .systemGreen)  // #30D158
        case .starting:           return Color(nsColor: .systemOrange) // #FF9F0A
        case .failed:             return Color(nsColor: .systemRed)    // #FF453A
        case .stopped, .unknown:  return Color(nsColor: .systemGray)   // #98989D
        }
    }

    // MARK: Metric / chart series
    static let mReads    = Color(nsColor: .systemCyan)   // #64D2FF  Qdrant reads
    static let mWrites   = Color(nsColor: .systemOrange) // #FF9F0A  Qdrant writes
    static let mVectors  = Color(nsColor: .systemGreen)  // #30D158  embedding vectors
    static let mErrors   = Color(nsColor: .systemRed)    // #FF453A  embedding errors
    static let mLatency  = Color(nsColor: .systemPurple) // #BF5AF2  latency
    static let mRequests = Color(nsColor: .systemBlue)   // #0A84FF  embedding requests
    static let mTemp     = Color(nsColor: .systemOrange) // #FF9F0A  CPU temperature

    // MARK: Surfaces / neutrals (dark)
    static let surface         = Color(red: 0.173, green: 0.173, blue: 0.180) // #2C2C2E  card / panel
    static let surfaceRaised   = Color(red: 0.227, green: 0.227, blue: 0.235) // #3A3A3C  active segment / popover row
    static let fillQuaternary  = Color.white.opacity(0.05)                    // .quaternary card fill
    static let separator       = Color.white.opacity(0.12)                    // hairline
    static let separatorStrong = Color.white.opacity(0.20)

    // MARK: Corner radii
    static let radiusSm: CGFloat = 6   // buttons / small controls
    static let radiusMd: CGFloat = 10  // inner cells, service group, activity box
    static let radiusLg: CGFloat = 12  // metric cards, connection panel
    static let radiusXl: CGFloat = 14  // section containers, tables

    // MARK: Spacing
    static let padScreen: CGFloat  = 24
    static let padCard: CGFloat    = 14
    static let gapRow: CGFloat     = 8
    static let gapSection: CGFloat = 18
}

extension View {
    /// Standard Embarsy "fill" card: quaternary fill + hairline stroke.
    func embarsyCard(radius: CGFloat = Theme.radiusLg) -> some View {
        self.padding(Theme.padCard)
            .background(Theme.fillQuaternary)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Theme.separator))
    }
}
