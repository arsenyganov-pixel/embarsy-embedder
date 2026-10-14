import SwiftUI

/// What agents proposed to remember. Each proposal is a card: the fact, why the agent thinks
/// it matters, notes that already say something similar, and where it would go.
struct MemoryInboxPanel: View {
    @ObservedObject var memory: MemoryService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agents propose; you decide. Nothing here is memory until you accept it — rejected proposals go to archive/, so nothing is lost.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = memory.lastError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if memory.inbox.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nothing to review.")
                        .font(.system(size: 12.5, weight: .medium))
                    Text("When you ask an agent to remember something, its proposal appears here.")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 6)
            }
            ForEach(memory.inbox) { item in
                InboxCard(item: item, memory: memory)
            }
        }
    }
}

private struct InboxCard: View {
    let item: InboxItem
    @ObservedObject var memory: MemoryService

    enum Kind: String, CaseIterable, Identifiable {
        case knowledge, experience, person, coreRule, aboutMe
        var id: String { rawValue }
        var label: String {
            switch self {
            case .knowledge: return L("Knowledge")
            case .experience: return L("Experience")
            case .person: return L("Person")
            case .coreRule: return L("Core rule")
            case .aboutMe: return L("About you")
            }
        }
        var typeName: String {
            switch self {
            case .knowledge: return "knowledge"
            case .experience: return "experience"
            case .person: return "person"
            case .coreRule, .aboutMe: return "core"
            }
        }
    }

    @State private var kind: Kind = .knowledge
    @State private var path = ""
    @State private var similar: [SimilarNote] = []
    @State private var showAll = false
    @State private var hint: DecisionHint?
    @State private var prepared = false

    private var destination: InboxDestination {
        switch kind {
        case .coreRule: return .coreRule
        case .aboutMe: return .aboutMe
        default: return .note(path: path.trimmed)
        }
    }

    private var pathIsValid: Bool {
        guard kind != .coreRule, kind != .aboutMe else { return true }
        guard let vault = memory.vault else { return false }
        return MemoryInbox(layout: vault).isValidNotePath(path)
    }

    private var targetExists: Bool {
        guard case .note(let p) = destination, let vault = memory.vault else { return false }
        return FileManager.default.fileExists(atPath: vault.root.appendingPathComponent(p).path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Text(item.title)
                .font(.system(size: 13.5, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            // A one-line fact is its own title; don't print it twice.
            if item.text.trimmed != item.title.trimmed {
                Text(item.text.trimmed)
                    .font(.system(size: 12.5))
                    .lineLimit(showAll ? nil : 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if item.text.count > 400 {
                Button(showAll ? L("Show less") : L("Show all")) { showAll.toggle() }
                    .buttonStyle(.link)
                    .font(.system(size: 11.5))
            }
            if !item.reason.trimmed.isEmpty {
                Text("Why: \(item.reason.trimmed)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !similar.isEmpty { similarList }
            Divider().overlay(Theme.separator)
            destinationRow
        }
        .padding(14)
        .background(Theme.fillQuaternary, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).stroke(Theme.separator))
        .task(id: item.id) {
            guard !prepared else { return }
            prepared = true
            apply(memory.suggestedDestination(for: item))
            similar = await memory.similarNotes(to: item)
            hint = await memory.decisionHint(for: item)
            // Earlier decisions only fill in where the agent had no idea itself: a path or a
            // note it named is its own, better-informed suggestion.
            if case .folder(let folder)? = hint?.kind, item.proposedPath.isEmpty, item.mergeWith.isEmpty,
               MemoryInbox.noteSections.contains(String(folder.split(separator: "/").first ?? "")) {
                apply(.note(path: "\(folder)/\(MemoryInbox.slug(item.title)).md"))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(verbatim: item.agentDisplayLabel)
                .font(.system(size: 11.5, weight: .medium))
            if !item.created.isEmpty {
                Text(item.created.replacingOccurrences(of: "T", with: " "))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            if !item.confidence.isEmpty { ConfidenceGlyph(confidence: item.confidence) }
            Spacer(minLength: 8)
            if item.isClaudeAutoMemory {
                Text("Claude Code's own memory")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var similarList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Already in memory")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
            ForEach(similar) { note in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(note.heading.isEmpty ? note.title : "\(note.title) › \(note.heading)")
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Text(note.path)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Button("Add to this note") { apply(.note(path: note.path)) }
                        .controlSize(.small)
                }
            }
        }
    }

    private var destinationRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // A user's pick moves the path to that kind's default; a suggestion sets both
                // itself (apply), so its more specific path isn't overwritten.
                Picker("", selection: Binding(
                    get: { kind },
                    set: { newKind in
                        kind = newKind
                        if case .note(let p) = memory.defaultDestination(type: newKind.typeName, title: item.title),
                           newKind != .coreRule, newKind != .aboutMe {
                            path = p
                        }
                    }
                )) {
                    ForEach(Kind.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                if kind != .coreRule && kind != .aboutMe {
                    TextField("knowledge/topic.md", text: $path)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
                Spacer(minLength: 0)
                Button("Reject") { Task { await memory.reject(item) } }
                    .disabled(memory.isWorking)
                Button("Accept") { Task { await memory.accept(item, to: destination) } }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(!pathIsValid || memory.isWorking)
            }
            Text(destinationHint)
                .font(.system(size: 11))
                .foregroundStyle(pathIsValid ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.orange))
                .fixedSize(horizontal: false, vertical: true)
            if let hint {
                Text(decisionText(hint))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Why a destination was suggested, from what the user did before. Grey: advice, not a fault.
    private func decisionText(_ hint: DecisionHint) -> String {
        let examples = hint.examples.filter { !$0.isEmpty }.map { "«\($0)»" }.joined(separator: ", ")
        switch hint.kind {
        case .folder(let folder):
            return examples.isEmpty
                ? L("You put \(hint.count) similar facts in \(folder)/ before.")
                : L("You put \(hint.count) similar facts in \(folder)/ before — like \(examples).")
        case .rejected:
            return examples.isEmpty
                ? L("You rejected \(hint.count) similar proposals before.")
                : L("You rejected \(hint.count) similar proposals before — like \(examples).")
        }
    }

    private var destinationHint: String {
        switch kind {
        case .coreRule: return L("Becomes one more line in your rules — every agent reads it in every session.")
        case .aboutMe: return L("Goes into \"Anything else about you\" in the core — every agent reads it in every session.")
        default:
            if !pathIsValid { return L("Use a .md path inside knowledge/, experience/ or people/.") }
            return targetExists ? L("Adds a dated section to this note; what's there stays.") : L("Creates this note.")
        }
    }

    private func apply(_ destination: InboxDestination) {
        switch destination {
        case .coreRule: kind = .coreRule
        case .aboutMe: kind = .aboutMe
        case .note(let p):
            path = p
            switch p.split(separator: "/").first {
            case "experience": kind = .experience
            case "people": kind = .person
            default: kind = .knowledge
            }
        }
    }
}

/// How the agent knows the fact. Three shapes so it reads without colour; the hover gives
/// all three.
private struct ConfidenceGlyph: View {
    let confidence: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 11))
            Text(label)
                .font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
        .chipHelp("How the agent knows this. Speech bubble — you said it. Seal — the agent checked it. Question mark — the agent's own conclusion; worth a second look before accepting.")
    }

    private var symbol: String {
        switch confidence {
        case "stated": return "quote.bubble"
        case "observed": return "checkmark.seal"
        default: return "questionmark.circle"
        }
    }

    private var label: String {
        switch confidence {
        case "stated": return L("you said it")
        case "observed": return L("verified")
        default: return L("inferred")
        }
    }
}
