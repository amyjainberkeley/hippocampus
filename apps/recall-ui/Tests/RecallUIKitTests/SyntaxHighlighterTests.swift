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

    // MARK: JavaScript and TypeScript (the demo week's billing.ts)

    /// TypeScript, the demo week's own code: not read as Python, so an
    /// English word inside a `//` comment is never colored as a keyword and
    /// the comment line is a comment (the verifier's probe).
    func testTypeScriptIsNotReadAsPython() {
        let code = """
        import Stripe from "stripe";
        import { plans, type PlanId } from "./plans";

        // Moves a studio to yearly billing and credits the unused part of the month.
        export async function switchToYearly(studioId: string, plan: PlanId) {
          const subscription = await findSubscription(studioId);
        }
        """
        XCTAssertNotEqual(SyntaxHighlighter.detectLanguage(code), .python)
        XCTAssertEqual(SyntaxHighlighter.detectLanguage(code), .javascript)
        let tokens = SyntaxHighlighter.codeTokens(code)
        XCTAssertTrue(tokens.filter { $0.type == .keyword && $0.text == "and" }.isEmpty,
                      "\"and\" inside a // comment was colored as a keyword")
        XCTAssertTrue(tokens.contains { $0.type == .comment && $0.text.contains("Moves a studio") },
                      "the // comment line is not a comment token")
        for word in ["import", "from", "export", "async", "function", "const", "await"] {
            XCTAssertTrue(tokens.contains(SyntaxToken(text: word, type: .keyword)), word)
        }
        XCTAssertEqual(tokens.map(\.text).joined(), code, "every character, in order")
    }

    func testJavaScriptIsToldByWhatOnlyItWrites() {
        for code in [
            "const total = plans.reduce((sum, plan) => sum + plan.price, 0);",
            "export default function Pricing() {\n  return <Plans />;\n}",
            "function yearly(price) {\n  return price * 10;\n}",
            "interface Plan {\n  id: string;\n  price: number;\n}",
            "type PlanId = \"solo\" | \"team\";",
            "plans.forEach((plan) => {\n  console.log(plan.id);\n});",
            "const stripe = require(\"stripe\")(key);",
        ] {
            XCTAssertEqual(SyntaxHighlighter.detectLanguage(code), .javascript, code)
        }
    }

    /// Python, a shell script and Rust keep their own words: a comment or a
    /// sentence that says "function", a shell's `export NAME=`, Python's
    /// `from x import y` and Rust's `const` are not JavaScript.
    func testOtherLanguagesAreNotTakenForJavaScript() {
        let python = "import os\n# call the function below\ndef main():\n    return os.getcwd()"
        XCTAssertEqual(SyntaxHighlighter.detectLanguage(python), .python)
        XCTAssertEqual(SyntaxHighlighter.detectLanguage("from billing import plans\nif plans.yearly:\n    print(plans)"),
                       .python)
        let docstring = "def yearly(price):\n    \"\"\"\n    function to call (later) for yearly plans\n    \"\"\"\n    return price"
        XCTAssertEqual(SyntaxHighlighter.detectLanguage(docstring), .python)
        XCTAssertEqual(SyntaxHighlighter.detectLanguage("export PATH=\"/usr/local/bin:$PATH\"\necho \"hello\""), .shell)
        XCTAssertEqual(SyntaxHighlighter.detectLanguage("#!/bin/bash\nfunction greet() {\n  echo hi\n}"), .shell)
        XCTAssertEqual(SyntaxHighlighter.detectLanguage("pub const MAX: usize = 3;\npub fn cap() -> usize { MAX }"), .rust)
        XCTAssertEqual(SyntaxHighlighter.detectLanguage("hello world"), .unknown)
    }

    /// A `/* … */` comment's lines are comments in C-like code, and in a
    /// block whose language isn't known.
    func testABlockCommentsLinesAreComments() {
        let code = "/*\n * Credits the unused part of the month.\n */\nconst credit = 0;"
        for line in code.split(separator: "\n").prefix(3).map(String.init) {
            XCTAssertEqual(SyntaxHighlighter.codeTokens(line, language: .javascript).first?.type, .comment, line)
            XCTAssertEqual(SyntaxHighlighter.codeTokens(line, language: .unknown).first?.type, .comment, line)
        }
        let tokens = SyntaxHighlighter.tokenize(code)
        XCTAssertTrue(tokens.contains { $0.type == .comment && $0.text.contains("Credits the unused") })
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

    func testAToolsSentenceBetweenCodeLinesIsNotColored() {
        let code = "fn main() {\n  let x = 1;\n}\nUpdated src/tax.rs with 2 additions and 1 removal"
        let tokens = SyntaxHighlighter.tokenize(code)
        XCTAssertTrue(tokens.contains(SyntaxToken(text: "Updated src/tax.rs with 2 additions and 1 removal",
                                                  type: .plain)))
        XCTAssertFalse(tokens.contains(SyntaxToken(text: "2", type: .number)))
        XCTAssertTrue(tokens.contains(SyntaxToken(text: "1", type: .number)), "code keeps its colors")
    }

    func testACodingAssistantsMarkersReadAsPlainBullets() {
        XCTAssertEqual(
            SyntaxHighlighter.plainBullets("\u{23FA} Update(src/tax.rs)\n  \u{23BF} Updated src/tax.rs"),
            "\u{2022} Update(src/tax.rs)\n    Updated src/tax.rs")
        XCTAssertEqual(SyntaxHighlighter.plainBullets("no markers"), "no markers")
    }

    func testUnknownLanguageReturnsSinglePlainToken() {
        let text = "just plain text"
        let tokens = SyntaxHighlighter.tokenize(text)
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens.first?.type, .plain)
        XCTAssertEqual(tokens.first?.text, text)
    }

    // MARK: Code blocks in the reading view (SPEC 4.6)

    func testCodeTokensColorNumbersAndALinesTrailingCommentInAnyLanguage() {
        let line = "round_half_even(2.5)   // 2.0"
        let tokens = SyntaxHighlighter.codeTokens(line)
        XCTAssertEqual(tokens.map(\.text).joined(), line, "every character, in order")
        XCTAssertTrue(tokens.contains(SyntaxToken(text: "2.5", type: .number)))
        XCTAssertEqual(tokens.last, SyntaxToken(text: "// 2.0", type: .comment))
    }

    func testAnAddressOrAStringIsNeverTakenForAComment() {
        for line in [#"let url = "https://devnotes.example/rounding";"#, "curl https://devnotes.example/a//b",
                     #"print("// not a comment")"#] {
            let tokens = SyntaxHighlighter.codeTokens(line)
            XCTAssertEqual(tokens.map(\.text).joined(), line)
            XCTAssertFalse(tokens.contains { $0.type == .comment }, line)
        }
    }

    func testABlocksLanguageColorsEveryLinesKeywords() {
        let block = "pub fn total() -> Money {\n    let tax = 1;\n    return tax\n}"
        let language = SyntaxHighlighter.detectLanguage(block)
        XCTAssertEqual(language, .rust)
        let second = SyntaxHighlighter.codeTokens("    let tax = 1;", language: language)
        XCTAssertTrue(second.contains(SyntaxToken(text: "let", type: .keyword)))
        XCTAssertFalse(SyntaxHighlighter.codeTokens("    let tax = 1;").contains { $0.type == .keyword },
                       "on its own, one line does not say its language")
        let python = SyntaxHighlighter.codeTokens("x = 1  # one", language: .python)
        XCTAssertEqual(python.last, SyntaxToken(text: "# one", type: .comment))
    }

    func testCodeTokensKeepEveryCharacterOfEveryLine() {
        let block = "use std::time::Duration;\n\n/// Delete events older than the configured window.\n" +
            "pub fn sweep(store: &Store) -> Result<u64, SweepError> {\n    \"quoted // text\"; // done\n}"
        XCTAssertEqual(SyntaxHighlighter.codeTokens(block).map(\.text).joined(), block)
    }

    /// The byte search language detection and the reading's links use
    /// answers as `contains` does for every needle they ask about.
    func testAByteSearchFindsWhatContainsFinds() {
        let texts = ["", "f", "func", "func main() {", "caf\u{E9} func x()", "\u{1F469}\u{200D}\u{1F4BB} let x = 1",
                     "see https://devnotes.example/rounding", "fn\u{301} total", "\u{65E5}\u{672C} echo hi", "a:b"]
        let needles = ["func ", "let ", "fn ", "echo ", "://", ":", "x"]
        for text in texts {
            for needle in needles {
                XCTAssertEqual(text.containsBytes(needle), text.contains(needle), "\(text) / \(needle)")
            }
            XCTAssertTrue(text.containsBytes(""), "an empty needle is in every text")
        }
        XCTAssertFalse("fn".containsBytes("fn "), "a needle longer than the text")
    }
}

