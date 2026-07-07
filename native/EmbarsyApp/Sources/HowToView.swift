import AppKit
import SwiftUI

struct HowToView: View {
    @State private var editor: Editor?
    @State private var pickerOpen = false
    @EnvironmentObject private var store: EmbarsyStore

    private let editorMenuWidth: CGFloat = 240

    enum Editor: String, CaseIterable, Identifiable {
        case claude, codex, roo
        var id: String { rawValue }
        var label: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex:  return "Codex"
            case .roo:    return "Zoo / Roo Code"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                BrandedHeader(title: "How To", subtitle: "Enable smart code search in your editor")

                VStack(alignment: .leading, spacing: 14) {
                    editorPicker
                    EmbarsySection(spacing: 16) {
                        guideContent
                    }
                }

                EmbarsySection(title: "If something goes wrong") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Self.trouble, id: \.0) { title, detail in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "exclamationmark.circle")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color(nsColor: .systemOrange))
                                Text("**\(title)** \(detail)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                EmbarsySection(title: "App Support") {
                    SupportChip()
                }
            }
            .padding(Theme.padScreen)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Custom editor picker dropdown, styled like the monitoring / activity dropdowns.
        .overlayPreferenceValue(HowToMenuAnchor.self) { anchor in
            if pickerOpen, let anchor {
                GeometryReader { proxy in
                    let r = proxy[anchor]
                    ZStack(alignment: .topLeading) {
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture { pickerOpen = false }
                        editorDropdownCard
                            .offset(x: max(Theme.padScreen, min(r.minX, proxy.size.width - editorMenuWidth - Theme.padScreen)),
                                    y: r.maxY + 6)
                    }
                }
            }
        }
    }

    private var editorPicker: some View {
        Button { pickerOpen.toggle() } label: {
            HStack(spacing: 8) {
                Text(editor?.label ?? "Choose editor / client")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(editor == nil ? Theme.accent : .primary)
                Image(systemName: "chevron.down").font(.system(size: 14)).foregroundStyle(Theme.accent)
                    .rotationEffect(.degrees(pickerOpen ? 180 : 0))
            }
            .padding(.horizontal, editor == nil ? 12 : 2)
            .padding(.vertical, editor == nil ? 7 : 2)
            .background(
                editor == nil ? Theme.accent.opacity(0.10) : Color.clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay {
                if editor == nil {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.accent.opacity(0.30))
                }
            }
        }
        .buttonStyle(.plain).fixedSize()
        .anchorPreference(key: HowToMenuAnchor.self, value: .bounds) { $0 }
    }

    private var editorDropdownCard: some View {
        DropdownCard(width: editorMenuWidth) {
            ForEach(Editor.allCases) { option in
                DropdownRow(label: option.label, selected: editor == option) {
                    editor = option
                    pickerOpen = false
                }
            }
        }
    }

    @ViewBuilder
    private var guideContent: some View {
        switch editor {
        case .none:
            HStack(spacing: 10) {
                Image(systemName: "cursorarrow.rays").font(.system(size: 15)).foregroundStyle(.tertiary)
                Text("Pick an editor / client above to see its setup steps.")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
        case .claude:  guideClaude
        case .codex:   guideCodex
        case .roo:     guideRoo
        }
    }

    // MARK: Guides

    private var guideClaude: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepIntro("Claude Code doesn't search code on its own — Embarsy's bridge indexes your project into Qdrant and exposes it to Claude Code over MCP.")
            NumStep(1) {
                StepText("Install the bridge:")
                CodeBlock(code: Self.installBridge)
            }
            NumStep(2) {
                StepText("Index the project once (substitute your path and the keys from Embarsy \u{2192} **Status**):")
                CodeBlock(code: Self.indexProject)
            }
            NumStep(3) {
                StepText("Connect it to Claude Code — run this **in your project folder** (it writes `.mcp.json` with absolute paths):")
                CodeBlock(code: Self.claudeConnect)
            }
            NumStep(4) {
                StepText("Verify: ask Claude about the code — e.g. \u{201C}where is authorization handled\u{201D}. It finds the right files, and counters start moving in Embarsy \u{2192} **Monitoring**.")
            }
            noteBox("Both API keys come from Embarsy \u{2192} **Status** (the connection block). Copy the current values — they change after a Hard Reset.")
            updateNote
        }
    }

    private var guideCodex: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepIntro("Same bridge as Claude Code, registered with Codex. If you already indexed the project in the Claude Code section, skip step 2.")
            NumStep(1) {
                StepText("Install the bridge (skip if you already did it for Claude Code):")
                CodeBlock(code: Self.installBridge)
            }
            NumStep(2) {
                StepText("Index the project once (substitute your path and the keys from Embarsy \u{2192} **Status**):")
                CodeBlock(code: Self.indexProject)
            }
            NumStep(3) {
                StepText("Register it with Codex — writes `~/.codex/config.toml` with absolute paths (so the desktop app can always launch it):")
                CodeBlock(code: Self.codexConnect)
            }
            NumStep(4) {
                StepText("Restart Codex and type `/mcp` — `embarsy-qdrant` should appear in the list.")
            }
            NumStep(5) {
                StepText("Ask about the code — Codex finds the files, and counters move in Embarsy \u{2192} **Monitoring**.")
            }
            updateNote
        }
    }

    private var guideRoo: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepIntro("The simplest option: search is built in, no bridge needed.")
            NumStep(1) { StepText("Open the project in VSCode.") }
            NumStep(2) { StepText("In the bottom-right of the Zoo/Roo chat, click the **Codebase Indexing** icon.") }
            NumStep(3) {
                StepText("Fill in the fields with values from Embarsy:")
                VStack(spacing: 0) {
                    ForEach(Array(Self.rooFields.enumerated()), id: \.offset) { i, pair in
                        if i > 0 { Divider().overlay(Theme.separator) }
                        HStack(spacing: 12) {
                            Text(pair.0).font(.system(size: 12)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(pair.1).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.primary)
                                .multilineTextAlignment(.trailing)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(i.isMultiple(of: 2) ? Color.clear : Color.white.opacity(0.02))
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.separator))
                .clipShape(RoundedRectangle(cornerRadius: 9))
            }
            NumStep(4) { StepText("Click **Save**, then **Start Indexing** and wait for the green status.") }
            NumStep(5) { StepText("Done — ask about the code in plain words. You'll see counters in Embarsy \u{2192} **Monitoring**.") }
            Text("If you changed the model or dimension — click **Clear Index Data** in Roo and re-run indexing (Embarsy must be running). If that doesn't help — Embarsy \u{2192} **Status** \u{2192} **Clear Roo Index**.")
                .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stepIntro(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func noteBox(_ markdown: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            EmbarsyMarkView(color: Theme.accent).frame(width: 15, height: 15)
            Text(.init(markdown)).font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.accent.opacity(0.25)))
    }

    /// Shared "how to update the bridge" note for the Claude Code / Codex guides.
    private var updateNote: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 13)).foregroundStyle(.tertiary)
            Text(.init("**Updating the bridge:** run `npm install -g embarsy-qdrant-mcp@latest`, then restart your editor — the config stays, no need to re-run setup. Re-run the `embarsy-index` command to pick up improvements (it's incremental)."))
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.fillQuaternary, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.separator))
    }

    // MARK: Content

    static let installBridge = "npm install -g embarsy-qdrant-mcp"

    // The tool defaults to Embarsy's proxy (embeddings :8000/v1, Qdrant :8000/qdrant) and the
    // qwen3-embedding / 1024 model, so only the two API keys are needed.
    static let indexProject = """
    OPENAI_API_KEY=<API Key from Embarsy> \\
    QDRANT_API_KEY=<Qdrant API Key from Embarsy> \\
    embarsy-index ~/projects/my-project --collection my-project
    """
    static let claudeConnect = """
    OPENAI_API_KEY=<API Key from Embarsy> \\
    QDRANT_API_KEY=<Qdrant API Key from Embarsy> \\
    QDRANT_COLLECTION_NAME=my-project \\
    embarsy-mcp --setup-claude
    """
    static let codexConnect = """
    OPENAI_API_KEY=<API Key from Embarsy> \\
    QDRANT_API_KEY=<Qdrant API Key from Embarsy> \\
    QDRANT_COLLECTION_NAME=my-project \\
    embarsy-mcp --setup-codex
    """

    static let rooFields: [(String, String)] = [
        ("Embedder Provider", "OpenAI Compatible"),
        ("Base URL", "http://localhost:8000"),
        ("API Key", "API Key from Embarsy (if empty — leave empty)"),
        ("Model", "qwen3-embedding"),
        ("Embedding Dimension", "1024"),
        ("Qdrant URL", "http://localhost:8000/qdrant"),
        ("Qdrant API Key", "Qdrant API Key from Embarsy"),
        ("Search Score Threshold", "0.4"),
        ("Maximum Search Results", "50"),
    ]

    static let trouble: [(String, String)] = [
        ("Search finds nothing / dimension error.", "The dimension must be 1024. Recreate the collection (in Zoo/Roo — Clear Index Data) and run again."),
        ("401 error / no access.", "Copy fresh API Key and Qdrant API Key from Embarsy — they change after a Hard Reset."),
        ("Everything reads zero in Monitoring.", "The client must call http://localhost:8000/qdrant, not :6333 directly."),
        ("Nothing starts up.", "Make sure every status row in Embarsy is green (the Install and Start button)."),
    ]
}

// MARK: - How To building blocks

/// Captures the editor-picker button's bounds so its custom dropdown can be positioned under it.
private struct HowToMenuAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

private struct StepText: View {
    let markdown: String
    init(_ markdown: String) { self.markdown = markdown }
    var body: some View {
        Text(.init(markdown))
            .font(.system(size: 12.5))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NumStep<Content: View>: View {
    let n: Int
    @ViewBuilder var content: () -> Content
    init(_ n: Int, @ViewBuilder content: @escaping () -> Content) { self.n = n; self.content = content }
    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Text("\(n)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 21, height: 21)
                .background(Theme.fillQuaternary, in: Circle())
                .overlay(Circle().stroke(Theme.separator))
            VStack(alignment: .leading, spacing: 8) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CodeBlock: View {
    let code: String
    @State private var copied = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Color(red: 0.839, green: 0.847, blue: 0.855))
                .textSelection(.enabled)
                .padding(.vertical, 12)
                .padding(.leading, 14)
                .padding(.trailing, 88)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.067, green: 0.071, blue: 0.078))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.separator))
        .overlay(alignment: .topTrailing) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10))
                    Text(copied ? "Copied" : "Copy").font(.system(size: 10.5, weight: .semibold))
                }
                .foregroundStyle(copied ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                .frame(width: 74, height: 24)
                .background(copied ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.06)),
                           in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.separator))
            }
            .buttonStyle(.plain)
            .padding(7)
        }
    }
}
