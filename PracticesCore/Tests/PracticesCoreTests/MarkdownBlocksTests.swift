import Testing
@testable import PracticesCore

@Suite struct MarkdownBlocksTests {
    @Test func blocks() {
        let md = """
        # Title

        Intro line
        continues here.

        ## Section

        - one `code`
          wrapped
        - two
          - nested
        1. first

        ```yaml
          frontend:
            labels: x
        ```

        | a | b |
        |---|---|
        #hashtag is text
        """
        #expect(MarkdownBlock.parse(md) == [
            .heading(level: 1, text: "Title"),
            .paragraph("Intro line continues here."),
            .heading(level: 2, text: "Section"),
            .item(indent: 0, marker: "•", text: "one `code` wrapped"),
            .item(indent: 0, marker: "•", text: "two"),
            .item(indent: 1, marker: "•", text: "nested"),
            .item(indent: 0, marker: "1.", text: "first"),
            .code(language: "yaml", text: "  frontend:\n    labels: x"),
            .table("| a | b |\n|---|---|"),
            .paragraph("#hashtag is text"),
        ])
    }

    @Test func htmlCommentsAreLeftOut() {
        #expect(MarkdownBlock.parse("<!-- обследование spheretele -->\n- a <!-- x -->\n<!--\nmany\n-->\nb") == [
            .item(indent: 0, marker: "•", text: "a"), .paragraph("b"),
        ])
    }

    @Test func unclosedFenceKeepsItsLines() {
        #expect(MarkdownBlock.parse("```\nx") == [.code(language: nil, text: "x")])
    }
}
