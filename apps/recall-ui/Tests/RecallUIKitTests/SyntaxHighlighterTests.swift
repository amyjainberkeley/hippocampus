import XCTest
@testable import RecallUIKit

final class SyntaxHighlighterTests: XCTestCase {
    func testDetectsSwift() {
        let code = """
        import Foundation
        func main() {
            let x = 42
        }
        """
        XCTAssertEqual(SyntaxHighlighter.detectLanguage(code), .swift)
    }

    func testDetectsRust() {
        let code = """
        use std::io;
        fn main() {
            let x = 42;
        }
        """
        XCTAssertEqual(SyntaxHighlighter.detectLanguage(code), .rust)
    }

    func testDetectsPython() {
        let code = """
        import os
        def main():
            x = 42
        """
        XCTAssertEqual(SyntaxHighlighter.detectLanguage(code), .python)
    }

    func testDetectsShell() {
        let code = """
        #!/bin/bash
        export PATH="/usr/local/bin:$PATH"
        echo "hello"
        """
        XCTAssertEqual(SyntaxHighlighter.detectLanguage(code), .shell)
    }

    func testUnknownLanguage() {
        XCTAssertEqual(SyntaxHighlighter.detectLanguage("hello world"), .unknown)
    }

    func testLooksLikeCodeRequiresIndentation() {
        let noIndent = "func main() {\nlet x = 42\n}"
        XCTAssertFalse(SyntaxHighlighter.looksLikeCode(noIndent))
    }

    func testLooksLikeCodeWithIndentation() {
        let code = "func main() {\n  let x = 42\n}"
        XCTAssertTrue(SyntaxHighlighter.looksLikeCode(code))
    }

    func testTokenizeSwiftKeywords() {
        let code = "  let x = 42"
        let tokens = SyntaxHighlighter.tokenize("func main() {\n\(code)\n}")
        let keywords = tokens.filter { $0.type == .keyword }
        let kwTexts = keywords.map(\.text)
        XCTAssertTrue(kwTexts.contains("func"))
        XCTAssertTrue(kwTexts.contains("let"))
    }

    func testTokenizeRustKeywords() {
        let code = "use std::io;\nfn main() {\n  let x = 42;\n}"
        let tokens = SyntaxHighlighter.tokenize(code)
        let keywords = tokens.filter { $0.type == .keyword }
        let kwTexts = keywords.map(\.text)
        XCTAssertTrue(kwTexts.contains("fn"))
        XCTAssertTrue(kwTexts.contains("let"))
        XCTAssertTrue(kwTexts.contains("use"))
    }

    func testTokenizePythonKeywords() {
        let code = "import os\ndef main():\n  return 42"
        let tokens = SyntaxHighlighter.tokenize(code)
        let keywords = tokens.filter { $0.type == .keyword }
        let kwTexts = keywords.map(\.text)
        XCTAssertTrue(kwTexts.contains("import"))
        XCTAssertTrue(kwTexts.contains("def"))
        XCTAssertTrue(kwTexts.contains("return"))
    }

    func testTokenizeStringLiterals() {
        let code = "func main() {\n  let s = \"hello\"\n}"
        let tokens = SyntaxHighlighter.tokenize(code)
        let strings = tokens.filter { $0.type == .string }
        XCTAssertFalse(strings.isEmpty)
        XCTAssertTrue(strings.contains { $0.text.contains("hello") })
    }

    func testTokenizeComments() {
        let code = "fn main() {\n  // this is a comment\n  let x = 1;\n}"
        let tokens = SyntaxHighlighter.tokenize(code)
        let comments = tokens.filter { $0.type == .comment }
        XCTAssertFalse(comments.isEmpty)
        XCTAssertTrue(comments.contains { $0.text.contains("comment") })
    }

    func testUnknownLanguageReturnsSinglePlainToken() {
        let text = "just plain text"
        let tokens = SyntaxHighlighter.tokenize(text)
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens.first?.type, .plain)
        XCTAssertEqual(tokens.first?.text, text)
    }
}
