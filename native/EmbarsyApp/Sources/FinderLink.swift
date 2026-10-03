import AppKit
import SwiftUI

/// A folder rendered as navigation rather than decoration: clicking reveals it in Finder.
///
/// Wherever the app shows a place on disk, that place is reachable. The affordance is the
/// app's standard one — a capsule that lights up under the pointer, the pointing-hand
/// cursor, and a tooltip that states what the click will do, so the link never has to be
/// discovered by trial.
struct FinderLink: View {
    let label: String
    let folder: URL
    var font: Font = .system(size: 12, weight: .semibold)

    @State private var hovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(hovering ? Theme.accent : Color.secondary)
                Text(label)
                    .font(font)
                    .foregroundStyle(hovering ? Theme.accent : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // Padding is constant so the row never shifts as the highlight appears.
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(hovering ? Theme.accent.opacity(0.12) : Color.clear, in: Capsule())
            .overlay(Capsule().stroke(hovering ? Theme.accent.opacity(0.35) : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            guard inside != hovering else { return }
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDisappear {
            // A row can scroll away while the pointer is still over it; without this the
            // pushed cursor would outlive the view and stick as a hand over the whole app.
            if hovering { NSCursor.pop(); hovering = false }
        }
        .chipHelp("Reveal \(folder.path) in Finder")
    }
}
