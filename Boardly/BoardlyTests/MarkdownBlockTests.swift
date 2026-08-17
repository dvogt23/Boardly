//
//  MarkdownBlockTests.swift
//  BoardlyTests
//
//  Line-based Markdown block parser behind MarkdownText (comment bodies).
//

import Testing
@testable import Boardly

/// Compact description of a parse result, so expectations read as the shape of the
/// rendered output rather than as nested enum pattern matches.
private func shape(_ source: String) -> [String] {
    MarkdownBlock.parse(source).map { block in
        switch block {
        case let .paragraph(text): return "p(\(text))"
        case let .heading(level, text): return "h\(level)(\(text))"
        case let .list(items, ordered):
            let rendered = items.map { item in
                switch item.checked {
                case nil: item.text
                case true: "[x] \(item.text)"
                case false: "[ ] \(item.text)"
                }
            }
            return "\(ordered ? "ol" : "ul")(\(rendered.joined(separator: "|")))"
        case let .quote(text): return "quote(\(text))"
        case let .code(text): return "code(\(text))"
        case .rule: return "rule"
        }
    }
}

@Suite("MarkdownBlock.parse")
struct MarkdownBlockTests {
    @Test("plain text is one paragraph")
    func singleParagraph() {
        #expect(shape("Just a comment.") == ["p(Just a comment.)"])
    }

    @Test("consecutive lines join into one paragraph, a blank line starts the next")
    func paragraphs() {
        #expect(shape("one\ntwo\n\nthree") == ["p(one\ntwo)", "p(three)"])
    }

    @Test("ATX headings carry their level")
    func headings() {
        #expect(shape("# Title\n## Sub\n#### Deep") == ["h1(Title)", "h2(Sub)", "h4(Deep)"])
    }

    @Test("a hash without a space is not a heading")
    func hashtagIsNotAHeading() {
        #expect(shape("#1 priority") == ["p(#1 priority)"])
    }

    @Test("bullet markers all start an unordered list")
    func bulletList() {
        #expect(shape("- a\n* b\n+ c") == ["ul(a|b|c)"])
    }

    @Test("numbered items form an ordered list")
    func numberedList() {
        #expect(shape("1. first\n2. second") == ["ol(first|second)"])
    }

    @Test("switching marker style starts a new list")
    func mixedLists() {
        #expect(shape("- a\n1. b") == ["ul(a)", "ol(b)"])
    }

    @Test("task items keep their checkbox state")
    func taskItems() {
        #expect(shape("- [ ] todo\n- [x] done\n- plain") == ["ul([ ] todo|[x] done|plain)"])
    }

    @Test("quote lines merge into one block")
    func quotes() {
        #expect(shape("> first\n> second") == ["quote(first\nsecond)"])
    }

    @Test("fenced code keeps its lines verbatim, including blanks and markers")
    func fencedCode() {
        let source = """
        ```swift
        let a = 1

        // - not a bullet
        ```
        """
        #expect(shape(source) == ["code(let a = 1\n\n// - not a bullet)"])
    }

    @Test("an unclosed fence still renders as code")
    func unclosedFence() {
        #expect(shape("```\nlet a = 1") == ["code(let a = 1)"])
    }

    @Test("three or more dashes or stars are a thematic break")
    func thematicBreak() {
        #expect(shape("a\n---\nb") == ["p(a)", "rule", "p(b)"])
    }

    @Test("a dash followed by text is a bullet, not a break")
    func dashIsNotABreak() {
        #expect(shape("- item") == ["ul(item)"])
    }

    @Test("empty input renders nothing")
    func empty() {
        #expect(shape("").isEmpty)
        #expect(shape("\n\n").isEmpty)
    }

    @Test("inline syntax is left for the inline parser")
    func inlineSyntaxUntouched() {
        #expect(shape("**bold** and `code` and [link](https://example.com)")
            == ["p(**bold** and `code` and [link](https://example.com))"])
    }
}
