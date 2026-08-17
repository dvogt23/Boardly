import SwiftUI

/// Renders a Markdown string that is always **server data** — a comment, a description
/// — never localizable copy. That is why the source goes through
/// `AttributedString(markdown:)` rather than `Text(LocalizedStringKey)`: the latter
/// would look the text up in the String Catalog and treat user content as a key.
///
/// Block support is deliberately small — paragraphs, ATX headings, bullet / numbered
/// lists (including task items), block quotes, fenced code and thematic breaks, which
/// is what PLANKA's own editor emits. Inline spans (emphasis, code, links,
/// strikethrough) come from Foundation's inline parser.
struct MarkdownText: View {
    let markdown: String
    var font: Font = .boardlyBody

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Links inside the parsed runs pick this up.
        .tint(Color.accentColor)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case let .paragraph(text):
            Text(inline(text))
                .font(font)
                .foregroundStyle(Color.boardlyInk)
                .fixedSize(horizontal: false, vertical: true)

        case let .heading(level, text):
            Text(inline(text))
                .font(.sans(headingSize(level), .bold))
                .foregroundStyle(Color.boardlyInk)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

        case let .list(items, ordered):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        marker(for: item, at: index, ordered: ordered)
                        Text(inline(item.text))
                            .font(font)
                            .foregroundStyle(Color.boardlyInk)
                            .strikethrough(item.checked == true)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }

        case let .quote(text):
            HStack(alignment: .top, spacing: 10) {
                Capsule()
                    .fill(Color.boardlySeparator)
                    .frame(width: 3)
                Text(inline(text))
                    .font(font)
                    .foregroundStyle(Color.boardlyTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)

        case let .code(text):
            // Code must not wrap mid-token, so it scrolls sideways on its own instead
            // of stretching the comment bubble.
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: text)
                    .font(.mono(13))
                    .foregroundStyle(Color.boardlyInk)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(Color.boardlySurfaceSecondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

        case .rule:
            Divider()
        }
    }

    @ViewBuilder
    private func marker(for item: MarkdownBlock.Item, at index: Int, ordered: Bool) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: 14))
                .foregroundStyle(checked ? Color.accentColor : Color.boardlyTextTertiary)
        } else if ordered {
            Text(verbatim: "\(index + 1).")
                .font(.mono(13, .medium))
                .foregroundStyle(Color.boardlyTextSecondary)
        } else {
            Text(verbatim: "•")
                .font(font)
                .foregroundStyle(Color.boardlyTextSecondary)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 20
        case 2: 18
        default: 16
        }
    }

    /// Inline-only parse: emphasis, code spans, links and strikethrough, with newlines
    /// inside a paragraph preserved. Unparseable input falls back to the raw text, so a
    /// stray `*` in a comment can never blank it out.
    private func inline(_ source: String) -> AttributedString {
        guard var attributed = try? AttributedString(
            markdown: source,
            options: AttributedString.MarkdownParsingOptions(
                allowsExtendedAttributes: true,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible))
        else {
            return AttributedString(source)
        }
        // Foundation marks code spans but leaves the styling to us.
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = .mono(13)
        }
        return attributed
    }
}

/// One rendered block of Markdown. Parsing is line-based: enough for the constructs
/// PLANKA emits, without pulling in a Markdown dependency.
enum MarkdownBlock {
    struct Item {
        let text: String
        /// `nil` for a plain item, otherwise the state of its `- [ ]` / `- [x]` box.
        let checked: Bool?
    }

    case paragraph(String)
    case heading(level: Int, text: String)
    case list(items: [Item], ordered: Bool)
    case quote(String)
    case code(String)
    case rule

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var listItems: [Item] = []
        var listOrdered = false
        var quote: [String] = []
        var code: [String]?

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }
        func flushList() {
            if !listItems.isEmpty {
                blocks.append(.list(items: listItems, ordered: listOrdered))
                listItems = []
            }
        }
        func flushQuote() {
            if !quote.isEmpty {
                blocks.append(.quote(quote.joined(separator: "\n")))
                quote = []
            }
        }
        func flushAll() {
            flushParagraph()
            flushList()
            flushQuote()
        }

        for rawLine in source.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Inside a fence, every line is literal until the closing fence.
            if code != nil {
                if line.hasPrefix("```") {
                    blocks.append(.code(code!.joined(separator: "\n")))
                    code = nil
                } else {
                    code?.append(rawLine)
                }
                continue
            }

            if line.hasPrefix("```") {
                flushAll()
                code = []
            } else if line.isEmpty {
                flushAll()
            } else if line.allSatisfy({ $0 == "-" }) && line.count >= 3
                || line.allSatisfy({ $0 == "*" }) && line.count >= 3
            {
                flushAll()
                blocks.append(.rule)
            } else if let heading = headingLevel(line) {
                flushAll()
                blocks.append(.heading(
                    level: heading,
                    text: String(line.dropFirst(heading)).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix(">") {
                flushParagraph()
                flushList()
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else if let item = bulletItem(line) {
                flushParagraph()
                flushQuote()
                if listOrdered, !listItems.isEmpty { flushList() }
                listOrdered = false
                listItems.append(item)
            } else if let item = numberedItem(line) {
                flushParagraph()
                flushQuote()
                if !listOrdered, !listItems.isEmpty { flushList() }
                listOrdered = true
                listItems.append(item)
            } else {
                flushList()
                flushQuote()
                paragraph.append(line)
            }
        }

        if let code { blocks.append(.code(code.joined(separator: "\n"))) } // unclosed fence
        flushAll()
        return blocks
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1 ... 6).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") else { return nil }
        return hashes
    }

    private static func bulletItem(_ line: String) -> Item? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return item(from: String(line.dropFirst(marker.count)))
        }
        return nil
    }

    private static func numberedItem(_ line: String) -> Item? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return item(from: String(rest.dropFirst(2)))
    }

    /// Splits a task-list checkbox off the front of an item, if there is one.
    private static func item(from body: String) -> Item {
        for (prefix, checked) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)]
            where body.hasPrefix(prefix)
        {
            return Item(text: String(body.dropFirst(prefix.count)), checked: checked)
        }
        return Item(text: body, checked: nil)
    }
}
