import Foundation

/// Markdown → HTML for reading notes inside Embarsy. Covers what the memory base's notes use:
/// headings, paragraphs, lists (nested by indent), blockquotes, fenced code, tables, rules,
/// and inline code, links, bold and italic. Raw HTML in a note is shown as text, never run.
enum MarkdownRenderer {
    /// The note without its frontmatter, and the frontmatter's flat fields.
    static func split(_ text: String) -> (fields: [(String, String)], body: String) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return ([], text) }
        var fields: [(String, String)] = []
        for line in lines[1..<end] where !line.hasPrefix(" ") && !line.hasPrefix("\t") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), let data = value.data(using: .utf8), let decoded = try? JSONDecoder().decode(String.self, from: data) {
                value = decoded
            }
            if !value.isEmpty { fields.append((key, value)) }
        }
        return (fields, lines[(end + 1)...].joined(separator: "\n"))
    }

    static func html(_ markdown: String) -> String {
        var out: [String] = []
        let lines = markdown.components(separatedBy: "\n")
        var i = 0
        var paragraph: [String] = []
        var listStack: [(tag: String, indent: Int)] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out.append("<p>" + inline(paragraph.joined(separator: " ")) + "</p>")
            paragraph.removeAll()
        }
        func closeLists(to depth: Int = 0) {
            while listStack.count > depth { out.append("</li></\(listStack.removeLast().tag)>") }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code: everything to the closing fence, verbatim.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph(); closeLists()
                let fence = String(trimmed.prefix(3))
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i]); i += 1
                }
                out.append("<pre><code>" + escape(code.joined(separator: "\n")) + "</code></pre>")
                i += 1
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                // A blank line inside a list doesn't end it unless the next line isn't a list item.
                if !listStack.isEmpty, i + 1 < lines.count, listItem(lines[i + 1]) == nil,
                   !(lines[i + 1].hasPrefix("  ") || lines[i + 1].hasPrefix("\t")) { closeLists() }
                i += 1
                continue
            }
            if let level = headingLevel(trimmed) {
                flushParagraph(); closeLists()
                let text = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                out.append("<h\(level)>" + inline(text) + "</h\(level)>")
                i += 1
                continue
            }
            if trimmed.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil {
                flushParagraph(); closeLists()
                out.append("<hr>")
                i += 1
                continue
            }
            // Table: a header row, then a |---|---| row.
            if trimmed.hasPrefix("|"), i + 1 < lines.count,
               lines[i + 1].trimmingCharacters(in: .whitespaces).range(of: #"^\|?\s*:?-{2,}"#, options: .regularExpression) != nil {
                flushParagraph(); closeLists()
                var rows: [[String]] = [cells(trimmed)]
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[i].trimmingCharacters(in: .whitespaces))); i += 1
                }
                var table = "<table><thead><tr>" + rows[0].map { "<th>" + inline($0) + "</th>" }.joined() + "</tr></thead><tbody>"
                for row in rows.dropFirst() { table += "<tr>" + row.map { "<td>" + inline($0) + "</td>" }.joined() + "</tr>" }
                out.append(table + "</tbody></table>")
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph(); closeLists()
                var quote: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                out.append("<blockquote>" + html(quote.joined(separator: "\n")) + "</blockquote>")
                continue
            }
            if let item = listItem(line) {
                flushParagraph()
                let tag = item.ordered ? "ol" : "ul"
                if let top = listStack.last, item.indent > top.indent {
                    out.append("<\(tag)><li>")
                    listStack.append((tag, item.indent))
                } else {
                    while let top = listStack.last, item.indent < top.indent { out.append("</li></\(listStack.removeLast().tag)>") }
                    if let top = listStack.last, top.tag == tag {
                        out.append("</li><li>")
                    } else {
                        if !listStack.isEmpty { out.append("</li></\(listStack.removeLast().tag)>") }
                        out.append("<\(tag)><li>")
                        listStack.append((tag, item.indent))
                    }
                }
                out.append(inline(item.text))
                i += 1
                continue
            }
            if !listStack.isEmpty, line.hasPrefix("  ") || line.hasPrefix("\t") {
                // A list item's continuation line.
                out.append(" " + inline(trimmed))
                i += 1
                continue
            }
            closeLists()
            paragraph.append(trimmed)
            i += 1
        }
        flushParagraph(); closeLists()
        return out.joined(separator: "\n")
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func listItem(_ line: String) -> (ordered: Bool, indent: Int, text: String)? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.drop(while: { $0 == " " || $0 == "\t" })
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            return (false, indent, String(rest.dropFirst(2)))
        }
        if let range = rest.range(of: #"^\d+[.)]\s"#, options: .regularExpression) {
            return (true, indent, String(rest[range.upperBound...]))
        }
        return nil
    }

    private static func cells(_ row: String) -> [String] {
        var r = row
        if r.hasPrefix("|") { r.removeFirst() }
        if r.hasSuffix("|") { r.removeLast() }
        return r.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Inline markup. Code spans are cut out first so nothing inside them is touched.
    static func inline(_ text: String) -> String {
        var codes: [String] = []
        var s = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "`") {
            s += rest[..<open]
            let after = rest.index(after: open)
            guard let close = rest[after...].firstIndex(of: "`") else { s += rest[open...]; rest = ""; break }
            codes.append(escape(String(rest[after..<close])))
            s += "\u{1}\(codes.count - 1)\u{2}"
            rest = rest[rest.index(after: close)...]
        }
        s += rest
        s = escape(s)
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\(([^)\s]+)\)"#, with: "<a href=\"$2\">$1</a>", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "<strong>$1</strong>", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<![\w*])\*([^*\s][^*]*)\*(?![\w*])"#, with: "<em>$1</em>", options: .regularExpression)
        for (n, code) in codes.enumerated() { s = s.replacingOccurrences(of: "\u{1}\(n)\u{2}", with: "<code>\(code)</code>") }
        return s
    }

    /// A full page in the app's dark theme.
    static func page(body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><style>
        :root { color-scheme: dark; }
        body { font: 13px -apple-system, system-ui, sans-serif; line-height: 1.55; color: #e6e6e6; background: transparent; margin: 0 4px 24px; }
        h1 { font-size: 20px; margin: 4px 0 12px; } h2 { font-size: 16px; margin: 22px 0 8px; } h3 { font-size: 14px; margin: 18px 0 6px; }
        h4, h5, h6 { font-size: 13px; margin: 14px 0 4px; }
        p { margin: 0 0 10px; } ul, ol { margin: 0 0 10px; padding-left: 22px; } li { margin: 2px 0; }
        a { color: #14B8A6; text-decoration: none; } a:hover { text-decoration: underline; }
        code { font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; background: rgba(255,255,255,0.07); padding: 1px 4px; border-radius: 4px; }
        pre { background: rgba(255,255,255,0.05); border: 1px solid rgba(255,255,255,0.10); border-radius: 8px; padding: 10px 12px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        blockquote { margin: 0 0 10px; padding: 2px 12px; border-left: 3px solid rgba(255,255,255,0.18); color: #b8b8b8; }
        table { border-collapse: collapse; margin: 0 0 12px; font-size: 12px; } th, td { border: 1px solid rgba(255,255,255,0.12); padding: 4px 8px; text-align: left; vertical-align: top; }
        th { background: rgba(255,255,255,0.05); } hr { border: none; border-top: 1px solid rgba(255,255,255,0.12); margin: 16px 0; }
        </style></head><body>\(body)</body></html>
        """
    }
}
