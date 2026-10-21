// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The capture helper's secret checks, for pages a browser extension stages
/// (storage-security review S10): its fourteen regex shapes (labelled
/// secrets, vendor API keys, private keys, tokens after `Bearer`), a card
/// number that stands on its own and passes the Luhn checksum, and a
/// one-time code beside its keyword. A copy of
/// `SuppressionCascade.containsSecretOrPII` (the helper is another package);
/// the shared corpus `core/brain/fixtures/ocr-secret-corpus.json`, which the
/// helper, the Rust reader and this copy all pass, keeps the three the same.
package enum PageSecretCheck {
    /// Whether `text` holds any of the helper's shapes.
    package static func containsSecret(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        for pattern in patterns where pattern.firstMatch(in: text, range: range) != nil {
            return true
        }
        return containsCreditCard(text) || containsOneTimeCode(text)
    }

    /// The helper's regex shapes, as it compiles them
    /// (`SuppressionCascade.ocrSecretPatterns`, Rust `ocr_secrets::PATTERNS`).
    private static let patterns: [NSRegularExpression] = [
        #"(?i)(password|passwd|secret|api[_-]?key|token|bearer|access[_-]?token)\s*[:=]\s*\S+"#,
        #"\bgh[poursAS]_[A-Za-z0-9_]{20,}\b"#,
        #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#,
        #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#,
        #"\bsk-ant-[A-Za-z0-9_-]{20,}"#,
        #"\bsk-(?:proj|svcacct|admin)-[A-Za-z0-9_-]{20,}"#,
        #"\bsk-[A-Za-z0-9]{32,}"#,
        #"\bxox[abeprs]-[0-9]+-[A-Za-z0-9-]{8,}"#,
        #"\bgithub_pat_[A-Za-z0-9_]{22,}"#,
        #"\bglpat-[A-Za-z0-9_-]{20,}"#,
        #"\bAIza[0-9A-Za-z_-]{35}"#,
        #"\b[rs]k_(?:live|test)_[0-9A-Za-z]{20,}"#,
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
        #"(?i)\bbearer\s+[A-Za-z0-9._~+/-]{20,}"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// Words that make a nearby 4–8 digit run a one-time code; the helper's
    /// and the Rust reader's list.
    private static let oneTimeCodeKeywords: [[UInt8]] = [
        "one-time", "one time", "verification code", "security code", "passcode", "otp", "2fa",
        "two-factor", "authentication code", "login code", "confirmation code", "confirm code",
        "your code is",
    ].map { Array($0.utf8) }

    /// How near, in UTF-8 bytes, the run must sit to its keyword.
    private static let oneTimeCodeWindow = 40

    /// A maximal run of 13–19 digits (single spaces or hyphens between
    /// them) that stands on its own (`standsAlone`) and passes the Luhn
    /// checksum.
    static func containsCreditCard(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var i = 0
        while i < bytes.count {
            guard isDigit(bytes[i]) else {
                i += 1
                continue
            }
            let start = i
            var digits = 0
            while true {
                while i < bytes.count, isDigit(bytes[i]) {
                    digits += 1
                    i += 1
                }
                if i + 1 < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x2D, isDigit(bytes[i + 1]) {
                    i += 1
                } else {
                    break
                }
            }
            if (13...19).contains(digits), standsAlone(bytes, start, i), luhnValid(bytes[start..<i]) { return true }
        }
        return false
    }

    /// Whether the digit run `bytes[start..<end]` stands on its own rather
    /// than inside a name: no ASCII letter or `_` right before or after it,
    /// and no `-`, `.` or `/` joining it to a letter or digit on that side
    /// (an id or a timestamp, not a card). The helper's `standsAlone`.
    static func standsAlone(_ bytes: [UInt8], _ start: Int, _ end: Int) -> Bool {
        func glued(_ near: UInt8?, _ beyond: UInt8?) -> Bool {
            guard let near else { return false }
            if isASCIILetter(near) || near == 0x5F { return true }
            guard near == 0x2D || near == 0x2E || near == 0x2F, let beyond else { return false }
            return isASCIILetter(beyond) || isDigit(beyond)
        }
        let before: UInt8? = start > 0 ? bytes[start - 1] : nil
        let beforeThat: UInt8? = start > 1 ? bytes[start - 2] : nil
        let after: UInt8? = end < bytes.count ? bytes[end] : nil
        let afterThat: UInt8? = end + 1 < bytes.count ? bytes[end + 1] : nil
        return !glued(before, beforeThat) && !glued(after, afterThat)
    }

    static func luhnValid(_ run: ArraySlice<UInt8>) -> Bool {
        var sum = 0
        var position = 0
        for byte in run.reversed() where isDigit(byte) {
            var digit = Int(byte - 0x30)
            if position % 2 == 1 {
                digit *= 2
                if digit > 9 { digit -= 9 }
            }
            sum += digit
            position += 1
        }
        return sum % 10 == 0
    }

    /// A maximal run of 4–8 digits within the window of a keyword, on a
    /// word boundary, case-insensitively.
    static func containsOneTimeCode(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var runs: [(Int, Int)] = []
        var i = 0
        while i < bytes.count {
            if isDigit(bytes[i]) {
                let start = i
                while i < bytes.count, isDigit(bytes[i]) { i += 1 }
                if (4...8).contains(i - start) { runs.append((start, i)) }
            } else {
                i += 1
            }
        }
        if runs.isEmpty { return false }
        let lower = bytes.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }
        for keyword in oneTimeCodeKeywords where keyword.count <= lower.count {
            var start = 0
            while start <= lower.count - keyword.count {
                defer { start += 1 }
                guard lower[start..<start + keyword.count].elementsEqual(keyword) else { continue }
                let end = start + keyword.count
                guard start == 0 || !isWordByte(lower[start - 1]),
                      end == lower.count || !isWordByte(lower[end]) else { continue }
                for (runStart, runEnd) in runs {
                    let gap = runStart >= end ? runStart - end : (start >= runEnd ? start - runEnd : 0)
                    if gap <= oneTimeCodeWindow { return true }
                }
            }
        }
        return false
    }

    private static func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    private static func isWordByte(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }
}
