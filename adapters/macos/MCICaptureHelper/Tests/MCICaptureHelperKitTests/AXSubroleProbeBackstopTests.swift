// SPDX-License-Identifier: TBD-private
//
// AXSubroleProbeBackstopTests — synthetic-input coverage of the
// STEP-2-FINDING-001 §4 backstop layer added to
// `AXSubroleProbe.classify(...)`.
//
// Scope honesty: this file does NOT touch ApplicationServices /
// AXUIElementCreateSystemWide / AXUIElementCopyAttributeValue. The
// backstop's live AX plumbing
// (`descendantSecureSubroleSignal`, `valueAttributeHiddenSignal`,
// `identifierRegexSignal`) is exercised on a real Mac via
// `mci-capture-helper --capture --probe-debug`. These tests pin the
// pure backstop combiner — `classify(...)`'s mapping of
// (prior-AX-result, descendantSecure, valueAttributeHidden,
// identifierRegexMatch) → cascade-input — so the §4 contract cannot
// silently regress.
//
// **Contract pinned here** (from the STEP-2-FINDING-001 brief):
//   - any signal `.positive` ⇒ `true`.
//   - all three `.negative` (prior false) ⇒ `false` (prior preserved).
//   - any `.errored` with no `.positive` ⇒ `nil` (do NOT widen to
//     false on a partially-blind signal — fail-safe).
//   - backstops only fire on the prior-false path; prior `true`
//     stays `true`, prior `nil` stays `nil`.

import ApplicationServices
import XCTest

@testable import MCICaptureHelperKit

final class AXSubroleProbeBackstopTests: XCTestCase {

    // Helpers — most calls share the prior-false focus shape.
    private func priorFalseClassify(
        descendantSecure: AXBackstopOutcome = .negative,
        valueAttributeHidden: AXBackstopOutcome = .negative,
        identifierRegexMatch: AXBackstopOutcome = .negative
    ) -> Bool? {
        AXSubroleProbe.classify(
            focusResult: .success,
            focusedRefMatched: true,
            subroleResult: .success,
            subroleValue: "AXApplicationDialog",  // a real-Mac §4 case
            descendantSecure: descendantSecure,
            valueAttributeHidden: valueAttributeHidden,
            identifierRegexMatch: identifierRegexMatch
        )
    }

    // ───────── individual-signal positive (any one ⇒ true) ─────────

    /// Signal 1 (descendant traversal) positive in isolation ⇒ true.
    /// Real-world case: `kAXFocusedUIElement` returned an `AXGroup`
    /// dialog whose subrole was `AXApplicationDialog`; the descendant
    /// walk found an `AXSecureTextField` two levels in.
    func testDescendantSecurePositiveAloneClassifiesTrue() {
        XCTAssertEqual(
            priorFalseClassify(descendantSecure: .positive),
            true)
    }

    /// Signal 2 (value-attribute-hidden) positive in isolation ⇒ true.
    /// Real-world case: focused `AXTextField` whose
    /// `kAXValueAttribute` is settable but reads back as `•••••`.
    func testValueHiddenPositiveAloneClassifiesTrue() {
        XCTAssertEqual(
            priorFalseClassify(valueAttributeHidden: .positive),
            true)
    }

    /// Signal 3 (identifier regex) positive in isolation ⇒ true.
    /// Real-world case: focused container whose descendant
    /// identifier is "PasswordField".
    func testIdentifierRegexPositiveAloneClassifiesTrue() {
        XCTAssertEqual(
            priorFalseClassify(identifierRegexMatch: .positive),
            true)
    }

    // ───────── all-negative ⇒ preserve prior false ─────────

    /// All three signals negative on prior-false ⇒ false. The
    /// backstop only widens; it never re-classifies a positively
    /// non-secure focus.
    func testAllNegativeOnPriorFalseStaysFalse() {
        XCTAssertEqual(
            priorFalseClassify(
                descendantSecure: .negative,
                valueAttributeHidden: .negative,
                identifierRegexMatch: .negative),
            false)
    }

    // ───────── individual-signal errored (no positive) ⇒ nil ─────────

    /// Signal 1 errored, others negative ⇒ nil. AX traversal failure
    /// must NOT silently widen to `false` (which would mean the cascade
    /// could fall through to `.allow`).
    func testDescendantErroredOthersNegativeClassifiesNil() {
        XCTAssertNil(
            priorFalseClassify(
                descendantSecure: .errored,
                valueAttributeHidden: .negative,
                identifierRegexMatch: .negative))
    }

    /// Signal 2 errored, others negative ⇒ nil.
    func testValueHiddenErroredOthersNegativeClassifiesNil() {
        XCTAssertNil(
            priorFalseClassify(
                descendantSecure: .negative,
                valueAttributeHidden: .errored,
                identifierRegexMatch: .negative))
    }

    /// Signal 3 errored, others negative ⇒ nil.
    func testIdentifierRegexErroredOthersNegativeClassifiesNil() {
        XCTAssertNil(
            priorFalseClassify(
                descendantSecure: .negative,
                valueAttributeHidden: .negative,
                identifierRegexMatch: .errored))
    }

    /// All three errored ⇒ nil. AX is fundamentally answering "I do
    /// not know" — fail-safe to nil so cascade §7 catches.
    func testAllErroredClassifiesNil() {
        XCTAssertNil(
            priorFalseClassify(
                descendantSecure: .errored,
                valueAttributeHidden: .errored,
                identifierRegexMatch: .errored))
    }

    /// Mixed errored + negative without any positive ⇒ nil (any
    /// blindness ⇒ fail-safe). Explicitly pinned — easy mis-refactor.
    func testTwoErroredOneNegativeClassifiesNil() {
        XCTAssertNil(
            priorFalseClassify(
                descendantSecure: .errored,
                valueAttributeHidden: .errored,
                identifierRegexMatch: .negative))
    }

    // ───────── positive wins over any other combination ─────────

    /// Positive + errored ⇒ true (positive wins; errors are
    /// short-circuited).
    func testPositiveAndErroredClassifiesTrue() {
        XCTAssertEqual(
            priorFalseClassify(
                descendantSecure: .positive,
                valueAttributeHidden: .errored,
                identifierRegexMatch: .errored),
            true)
    }

    /// Positive + negative ⇒ true.
    func testPositiveAndNegativeClassifiesTrue() {
        XCTAssertEqual(
            priorFalseClassify(
                descendantSecure: .negative,
                valueAttributeHidden: .positive,
                identifierRegexMatch: .negative),
            true)
    }

    /// All-positive ⇒ true.
    func testAllPositiveClassifiesTrue() {
        XCTAssertEqual(
            priorFalseClassify(
                descendantSecure: .positive,
                valueAttributeHidden: .positive,
                identifierRegexMatch: .positive),
            true)
    }

    /// One errored, one negative, one positive ⇒ true.
    func testMixedWithOnePositiveClassifiesTrue() {
        XCTAssertEqual(
            priorFalseClassify(
                descendantSecure: .errored,
                valueAttributeHidden: .negative,
                identifierRegexMatch: .positive),
            true)
    }

    // ───────── prior-true / prior-nil unaffected by backstops ─────────

    /// Prior subrole was `kAXSecureTextFieldSubrole` ⇒ true. Backstops
    /// cannot demote a positive secure detection.
    func testPriorTrueWithAllNegativeBackstopsStaysTrue() {
        let r = AXSubroleProbe.classify(
            focusResult: .success,
            focusedRefMatched: true,
            subroleResult: .success,
            subroleValue: kAXSecureTextFieldSubrole as String,
            descendantSecure: .negative,
            valueAttributeHidden: .negative,
            identifierRegexMatch: .negative
        )
        XCTAssertEqual(r, true)
    }

    /// Prior secure + all-errored backstops ⇒ still true. Errors must
    /// not poison an already-correct positive answer.
    func testPriorTrueWithAllErroredBackstopsStaysTrue() {
        let r = AXSubroleProbe.classify(
            focusResult: .success,
            focusedRefMatched: true,
            subroleResult: .success,
            subroleValue: kAXSecureTextFieldSubrole as String,
            descendantSecure: .errored,
            valueAttributeHidden: .errored,
            identifierRegexMatch: .errored
        )
        XCTAssertEqual(r, true)
    }

    /// Prior `.apiDisabled` (cascade fail-safe nil) + positive
    /// backstops ⇒ still nil. Backstops cannot widen a fundamentally
    /// blind AX into a positive classification — AX disabled means
    /// every backstop also ran in a blind regime.
    func testPriorNilWithPositiveBackstopsStaysNil() {
        let r = AXSubroleProbe.classify(
            focusResult: .apiDisabled,
            focusedRefMatched: false,
            subroleResult: .success,
            subroleValue: nil,
            descendantSecure: .positive,
            valueAttributeHidden: .positive,
            identifierRegexMatch: .positive
        )
        XCTAssertNil(r)
    }

    /// Prior `.apiDisabled` + all-negative backstops ⇒ still nil.
    func testPriorNilWithAllNegativeBackstopsStaysNil() {
        let r = AXSubroleProbe.classify(
            focusResult: .apiDisabled,
            focusedRefMatched: false,
            subroleResult: .success,
            subroleValue: nil,
            descendantSecure: .negative,
            valueAttributeHidden: .negative,
            identifierRegexMatch: .negative
        )
        XCTAssertNil(r)
    }

    // ───────── focus .noValue (no element to traverse) ─────────

    /// `focusResult == .noValue` ⇒ prior false. No focused element to
    /// traverse, so backstops will all be `.negative`; combiner
    /// returns false unchanged. (Live wiring suppresses backstop calls
    /// in this case for the same reason.)
    func testFocusNoValueAllNegativeStaysFalse() {
        let r = AXSubroleProbe.classify(
            focusResult: .noValue,
            focusedRefMatched: false,
            subroleResult: .success,
            subroleValue: nil,
            descendantSecure: .negative,
            valueAttributeHidden: .negative,
            identifierRegexMatch: .negative
        )
        XCTAssertEqual(r, false)
    }

    /// `focusResult == .noValue` + a hypothetical signal positive ⇒
    /// true (the combiner trusts the positive signal regardless of
    /// the focus-empty prior). Pinned for refactor-safety — the live
    /// wiring will not produce this combination, but the pure
    /// classifier must remain coherent if a future signal source
    /// (e.g. NSWorkspace-derived) is added.
    func testFocusNoValueButPositiveSignalWidensToTrue() {
        let r = AXSubroleProbe.classify(
            focusResult: .noValue,
            focusedRefMatched: false,
            subroleResult: .success,
            subroleValue: nil,
            descendantSecure: .positive,
            valueAttributeHidden: .negative,
            identifierRegexMatch: .negative
        )
        XCTAssertEqual(r, true)
    }

    // ───────── prior false from .noValue subrole (focus succeeded) ─────────

    /// Focus succeeded, subrole read returned `.noValue` (legit — many
    /// AX elements lack a subrole), prior = false. Signal 3 positive
    /// (e.g. identifier "PasswordField") ⇒ true. This is the
    /// real-world shape for a focused `AXTextField` whose own subrole
    /// is absent but whose identifier reveals intent.
    func testFocusSuccessSubroleNoValueRegexPositiveClassifiesTrue() {
        let r = AXSubroleProbe.classify(
            focusResult: .success,
            focusedRefMatched: true,
            subroleResult: .noValue,
            subroleValue: nil,
            descendantSecure: .negative,
            valueAttributeHidden: .negative,
            identifierRegexMatch: .positive
        )
        XCTAssertEqual(r, true)
    }
}

// MARK: - Pure regex / tokenizer matrix (Signal 3)

/// Pins `passwordIdentifierMatches(...)` against the explicit
/// positive/negative matrix from the STEP-2-FINDING-001 brief.
///
/// Live signal 3 reads `kAXIdentifierAttribute` / `kAXTitleAttribute`
/// / `kAXPlaceholderValueAttribute` and runs each string through this
/// matcher. The matcher itself is pure / side-effect-free; this file
/// pins it without touching AX.
final class AXSubroleProbePasswordRegexTests: XCTestCase {
    // ───────── positive matrix ─────────

    /// "password" — exact, lowercase. Pinned positive.
    func testPasswordExactLowercaseMatches() {
        XCTAssertTrue(AXSubroleProbe.passwordIdentifierMatches("password"))
    }

    /// "Passcode" — exact, mixed case. Case-insensitive match required.
    func testPasscodeMixedCaseMatches() {
        XCTAssertTrue(AXSubroleProbe.passwordIdentifierMatches("Passcode"))
    }

    /// "secret-pin" — two positive tokens separated by a hyphen.
    func testSecretPinMatches() {
        XCTAssertTrue(AXSubroleProbe.passwordIdentifierMatches("secret-pin"))
    }

    /// "MyPasswordField" — CamelCase boundary detection is required
    /// because a bare `\bpassword\b` does not match (no word boundary
    /// between `y` and `P`).
    func testMyPasswordFieldCamelCaseMatches() {
        XCTAssertTrue(AXSubroleProbe.passwordIdentifierMatches("MyPasswordField"))
    }

    /// "PASSCODE" — all caps. Token survives lowercasing.
    func testAllCapsPasscodeMatches() {
        XCTAssertTrue(AXSubroleProbe.passwordIdentifierMatches("PASSCODE"))
    }

    /// "passphraseEntry" — CamelCase passphrase + non-negative tail.
    func testPassphraseEntryMatches() {
        XCTAssertTrue(AXSubroleProbe.passwordIdentifierMatches("passphraseEntry"))
    }

    /// "Unlock Screen" — title with space + positive token.
    func testUnlockScreenTitleMatches() {
        XCTAssertTrue(AXSubroleProbe.passwordIdentifierMatches("Unlock Screen"))
    }

    /// "secureInput" — positive token + neutral tail.
    func testSecureInputMatches() {
        XCTAssertTrue(AXSubroleProbe.passwordIdentifierMatches("secureInput"))
    }

    // ───────── negative-context matrix ─────────

    /// "password-recovery-link" — positive token present, but
    /// recovery/link tokens in the negative-context set ⇒ negative.
    func testPasswordRecoveryLinkDoesNotMatch() {
        XCTAssertFalse(AXSubroleProbe.passwordIdentifierMatches("password-recovery-link"))
    }

    /// "passphrase-info" — passphrase + info ⇒ negative.
    func testPassphraseInfoDoesNotMatch() {
        XCTAssertFalse(AXSubroleProbe.passwordIdentifierMatches("passphrase-info"))
    }

    /// "Forgot password?" — forgot + question mark ⇒ negative.
    /// Real example from system unlock dialog.
    func testForgotPasswordButtonDoesNotMatch() {
        XCTAssertFalse(AXSubroleProbe.passwordIdentifierMatches("Forgot password?"))
    }

    /// "Reset Password" — reset is a negative-context token.
    func testResetPasswordDoesNotMatch() {
        XCTAssertFalse(AXSubroleProbe.passwordIdentifierMatches("Reset Password"))
    }

    /// "Password Hint" — hint is negative-context.
    func testPasswordHintDoesNotMatch() {
        XCTAssertFalse(AXSubroleProbe.passwordIdentifierMatches("Password Hint"))
    }

    // ───────── generic identifiers ─────────

    /// "submitButton" — no positive token ⇒ negative.
    func testSubmitButtonDoesNotMatch() {
        XCTAssertFalse(AXSubroleProbe.passwordIdentifierMatches("submitButton"))
    }

    /// "lastName" — no positive token ⇒ negative.
    func testLastNameDoesNotMatch() {
        XCTAssertFalse(AXSubroleProbe.passwordIdentifierMatches("lastName"))
    }

    /// "" — empty string ⇒ negative.
    func testEmptyStringDoesNotMatch() {
        XCTAssertFalse(AXSubroleProbe.passwordIdentifierMatches(""))
    }

    /// "email" — neutral identifier ⇒ negative.
    func testEmailDoesNotMatch() {
        XCTAssertFalse(AXSubroleProbe.passwordIdentifierMatches("email"))
    }

    // ───────── tokenizer pinning ─────────

    /// CamelCase: "MyPasswordField" → ["My", "Password", "Field"].
    func testTokenizeCamelCase() {
        XCTAssertEqual(
            AXSubroleProbe.tokenize("MyPasswordField"),
            ["My", "Password", "Field"])
    }

    /// Hyphen: "password-recovery-link" → ["password","recovery","link"].
    func testTokenizeHyphen() {
        XCTAssertEqual(
            AXSubroleProbe.tokenize("password-recovery-link"),
            ["password", "recovery", "link"])
    }

    /// All-caps stays one token: "PASSCODE" → ["PASSCODE"].
    /// (No lowercase→uppercase transition inside.)
    func testTokenizeAllCapsStaysOneToken() {
        XCTAssertEqual(AXSubroleProbe.tokenize("PASSCODE"), ["PASSCODE"])
    }

    /// Mixed separators: "secret-pin" → ["secret", "pin"].
    func testTokenizeMixedSeparators() {
        XCTAssertEqual(AXSubroleProbe.tokenize("secret-pin"), ["secret", "pin"])
    }

    /// Whitespace + punctuation: "Unlock Screen?" → ["Unlock","Screen"].
    func testTokenizeWhitespaceAndPunctuation() {
        XCTAssertEqual(
            AXSubroleProbe.tokenize("Unlock Screen?"),
            ["Unlock", "Screen"])
    }

    /// Empty string ⇒ empty token list.
    func testTokenizeEmptyString() {
        XCTAssertEqual(AXSubroleProbe.tokenize(""), [])
    }
}
