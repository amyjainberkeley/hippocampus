import Foundation

public enum DetectedLanguage: String, Equatable, Sendable {
    case swift, rust, python, shell, unknown
}

public enum SyntaxTokenType: Equatable, Sendable {
    case keyword, string, comment, number, plain
}

public struct SyntaxToken: Equatable, Sendable {
    public let text: String
    public let type: SyntaxTokenType

    public init(text: String, type: SyntaxTokenType) {
        self.text = text
        self.type = type
    }
}

public enum SyntaxHighlighter {
    private static let swiftKeywords: Set<String> = [
        "func", "let", "var", "import", "struct", "class", "enum", "protocol",
        "return", "if", "else", "guard", "switch", "case", "for", "while",
        "self", "Self", "nil", "true", "false", "public", "private", "static",
        "async", "await", "throws", "try", "catch", "defer", "where",
    ]

    private static let rustKeywords: Set<String> = [
        "fn", "let", "mut", "pub", "use", "struct", "impl", "mod", "trait",
        "return", "if", "else", "match", "for", "while", "loop", "self",
        "Self", "true", "false", "async", "await", "crate", "super", "where",
        "unsafe", "dyn", "type", "const", "static", "ref", "move",
    ]

    private static let pythonKeywords: Set<String> = [
        "def", "class", "import", "from", "return", "if", "elif", "else",
        "for", "while", "try", "except", "finally", "with", "as", "pass",
        "True", "False", "None", "and", "or", "not", "in", "is", "lambda",
        "yield", "raise", "break", "continue",
    ]

    private static let shellKeywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "while", "do", "done",
        "case", "esac", "export", "echo", "cd", "exit", "return", "local",
        "set", "unset", "source", "function",
    ]

    public static func looksLikeCode(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let hasIndented = lines.contains { $0.hasPrefix("  ") || $0.hasPrefix("\t") }
        return hasIndented && detectLanguage(text) != .unknown
    }

    public static func detectLanguage(_ text: String) -> DetectedLanguage {
        if text.contains("func ") && (text.contains("let ") || text.contains("var ") || text.contains("import ")) {
            return .swift
        }
        if text.contains("fn ") && (text.contains("let ") || text.contains("pub ") || text.contains("use ")) {
            return .rust
        }
        if text.contains("def ") || (text.contains("import ") && text.contains(":") && !text.contains("func ")) {
            return .python
        }
        if text.hasPrefix("#!") || text.contains("export ") || text.contains("echo ") {
            return .shell
        }
        return .unknown
    }

    public static func tokenize(_ text: String) -> [SyntaxToken] {
        let lang = detectLanguage(text)
        guard lang != .unknown else {
            return [SyntaxToken(text: text, type: .plain)]
        }
        let kw = keywordsFor(lang)
        let commentPrefix = (lang == .python || lang == .shell) ? "#" : "//"
        return tokenizeLines(text, keywords: kw, commentPrefix: commentPrefix)
    }

    private static func keywordsFor(_ lang: DetectedLanguage) -> Set<String> {
        switch lang {
        case .swift: return swiftKeywords
        case .rust: return rustKeywords
        case .python: return pythonKeywords
        case .shell: return shellKeywords
        case .unknown: return []
        }
    }

    private static func tokenizeLines(
        _ text: String, keywords: Set<String>, commentPrefix: String
    ) -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, line) in lines.enumerated() {
            if i > 0 { tokens.append(SyntaxToken(text: "\n", type: .plain)) }
            let s = String(line)
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(commentPrefix) {
                tokens.append(SyntaxToken(text: s, type: .comment))
                continue
            }
            tokenizeLine(s, keywords: keywords, into: &tokens)
        }
        return tokens
    }

    private static func tokenizeLine(
        _ line: String, keywords: Set<String>, into tokens: inout [SyntaxToken]
    ) {
        var buf = ""
        var inString = false
        var stringChar: Character = "\""
        var i = line.startIndex

        while i < line.endIndex {
            let c = line[i]
            if inString {
                buf.append(c)
                if c == stringChar {
                    tokens.append(SyntaxToken(text: buf, type: .string))
                    buf = ""
                    inString = false
                }
            } else if c == "\"" || c == "'" {
                if !buf.isEmpty { flushWord(buf, keywords: keywords, into: &tokens); buf = "" }
                inString = true
                stringChar = c
                buf.append(c)
            } else if c.isLetter || c == "_" || (!buf.isEmpty && c.isNumber) {
                buf.append(c)
            } else {
                if !buf.isEmpty { flushWord(buf, keywords: keywords, into: &tokens); buf = "" }
                if c.isNumber {
                    var num = String(c)
                    var j = line.index(after: i)
                    while j < line.endIndex && (line[j].isNumber || line[j] == "." || line[j] == "_") {
                        num.append(line[j])
                        j = line.index(after: j)
                    }
                    tokens.append(SyntaxToken(text: num, type: .number))
                    i = j
                    continue
                }
                tokens.append(SyntaxToken(text: String(c), type: .plain))
            }
            i = line.index(after: i)
        }
        if !buf.isEmpty {
            tokens.append(SyntaxToken(text: buf, type: inString ? .string : .plain))
            if !inString { flushWord(buf, keywords: keywords, into: &tokens); tokens.removeLast() }
        }
    }

    private static func flushWord(
        _ word: String, keywords: Set<String>, into tokens: inout [SyntaxToken]
    ) {
        if keywords.contains(word) {
            tokens.append(SyntaxToken(text: word, type: .keyword))
        } else {
            tokens.append(SyntaxToken(text: word, type: .plain))
        }
    }
}
