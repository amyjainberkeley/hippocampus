// SPDX-License-Identifier: Apache-2.0
//
// SecretMatrixTests — the launch secret-matrix harness, Swift side.
//
// This is the "outside judge" for the claim "Hippocampus never stores
// secrets": it renders a SYNTHETIC screen for each sensitive case and runs
// it through the REAL shipping policy code (`SuppressionCascade`,
// `SensitiveCaptureDenylist`, `BrowserPixelCapturePolicy`) — the same types
// the signed helper runs in production — then records PASS/FAIL per row.
//
// A "synthetic screen" is the cascade's own input shape: an app bundle id, a
// window title, a URL, OCR lines with positions, plus the three OS signals
// the cascade reads through protocols (secure-event-input bit, focused-AX
// secure subrole, OS-blacked region). The cascade is OS-API-free by design
// (see `SuppressionCascade.swift`), so every decision below is the production
// decision — only the three OS signals are injected, because they cannot be
// produced headlessly. NO screenshot is taken and NO real memory is read:
// every string here is invented.
//
// Production posture is reproduced exactly: `.ordinaryApplications` admission
// (what `Sources/MCICaptureHelper/main.swift` passes) + the full browser
// bundle set + the real `SensitiveCaptureDenylist` rules.
//
// When `SECRET_MATRIX_OUT` is set, `testSecretMatrix` also writes a TSV row
// per case so `scripts/launch/secret-matrix/run.sh` can assemble
// `eval/secret-matrix-2026-10-17.md`. The assertions make this a real
// pass/fail gate regardless of whether the TSV is written.

import CoreGraphics
import XCTest

@testable import MCICaptureHelperKit

// MARK: - Mock OS-signal probes (the only injected inputs)

private struct FixedSecureInput: SecureEventInputProbe {
    let on: Bool
    func isSecureEventInputEnabled() -> Bool { on }
}

private struct FixedAX: AXSecureSubroleProbe {
    let value: Bool?
    func focusedHasSecureSubrole() -> Bool? { value }
}

private struct FixedBlacked: BlackedRegionProbe {
    let present: Bool
    func hasBlackedRegion() -> Bool { present }
}

/// One row of the matrix.
private struct Row {
    let id: String
    let scenario: String
    let expected: String
    let observed: String
    let verdict: String   // PASS | FAIL | NEEDS-A-PERSON | LIMITATION
    let rule: String
    let proof: String
}

final class SecretMatrixTests: XCTestCase {
    // Production-faithful cascade: real denylist rules, real browser set,
    // ordinary-applications admission; only the three OS signals are injected.
    private func cascade(
        secureInput: Bool = false,
        ax: Bool? = false,
        blacked: Bool = false,
        privateWindows: PrivateBrowserWindows = PrivateBrowserWindows()
    ) -> SuppressionCascade {
        SuppressionCascade(
            secureEventInput: FixedSecureInput(on: secureInput),
            axSecureSubrole: FixedAX(value: ax),
            denylist: SensitiveCaptureDenylist(entries: []),
            blackedRegion: FixedBlacked(present: blacked),
            browserAppBundles: BrowserPixelCapturePolicy.browserBundleIds,
            admissionPolicy: .ordinaryApplications,
            privateWindows: privateWindows
        )
    }

    private static func label(_ d: SuppressionDecision) -> String {
        switch d {
        case .allow: return "allow"
        case .suppress(let r): return "suppress(\(r.dbString))"
        }
    }

    // A browser top-bar line at the given height in a unit window.
    private static func topBarLine(_ text: String, y: CGFloat = 0.925) -> OCRLine {
        OCRLine(text: text, boundingBox: CGRect(x: 0.30, y: y, width: 0.40, height: 0.015), confidence: 1)
    }

    private static let unitWindow = CGRect(x: 0, y: 0, width: 1, height: 1)
    private static let pixelSize = CGSize(width: 2400, height: 1600)

    /// Canonical SYNTHETIC secret strings (all invented).
    private enum Fixture {
        static let awsKeyLine = "export AWS_SECRET_ACCESS_KEY=AKIAIOSFODNN7EXAMPLE"
        static let githubPat = "ghp_EXAMPLE00000000000000000000000000000"
        static let apiKeyAssign = "api_key = sk_" + "test_4eC39HqLyjWDarjtT1zdp7dc"
        static let jwt =
            "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9." +
            "eyJzdWIiOiIxMjM0NTY3ODkwIn0." +
            "dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        static let tokenAssign = "const token = \"ghp_000000000000000000000000000000000000\""
        static let otpChat = "Your verification code is 123456. It expires in 10 minutes."
        static let creditCard = "4111 1111 1111 1111  exp 04/29  cvv 123"
    }

    func testSecretMatrix() {
        var rows: [Row] = []

        // -- Case 1: password field, secure-input bit (Carbon). Cascade §3. --
        do {
            let d = cascade(secureInput: true, ax: false)
                .decide(context: WorkflowContext(appBundleId: "com.apple.TextEdit",
                                                 windowTitle: "Untitled"))
            XCTAssertEqual(d, .suppress(reason: .secureEventInput), "password field (secure input)")
            rows.append(Row(
                id: "1", scenario: "Password field active (secure input on) — any app",
                expected: "suppress(secure-event-input)", observed: Self.label(d),
                verdict: d == .suppress(reason: .secureEventInput) ? "PASS" : "FAIL",
                rule: "Cascade §3 — IsSecureEventInputEnabled()",
                proof: "SecretMatrixTests.testSecretMatrix; CascadeSecureEventInputTests; "
                    + "CarbonSecureEventInputProbeTests"))
        }

        // -- Case 2: password field via focused-AX secure subrole. Cascade §4. --
        do {
            let d = cascade(secureInput: false, ax: true)
                .decide(context: WorkflowContext(appBundleId: "com.apple.TextEdit",
                                                 windowTitle: "Sign in"))
            XCTAssertEqual(d, .suppress(reason: .axSecureSubrole), "password field (AX secure subrole)")
            rows.append(Row(
                id: "2", scenario: "Focused element is a secure text field (AXSecureTextField)",
                expected: "suppress(ax-secure-subrole)", observed: Self.label(d),
                verdict: d == .suppress(reason: .axSecureSubrole) ? "PASS" : "FAIL",
                rule: "Cascade §4 — kAXSecureTextFieldSubrole",
                proof: "SecretMatrixTests.testSecretMatrix; CascadeAXSubroleTests; AXSubroleProbeTests"))
        }

        // -- Case 3: visible password in a password-manager window. Cascade §1. --
        // A representative slice of NeverReadPasswordManagersTests.verified,
        // spanning the apps the launch copy names plus families it does not.
        do {
            let managers: [(String, String)] = [
                ("com.1password.1password", "1Password 8"),
                ("com.agilebits.onepassword7", "1Password 7"),
                ("2BUA8C4S2C.com.1password.browser-helper", "1Password browser helper"),
                ("com.apple.Passwords", "Apple Passwords"),
                ("com.apple.keychainaccess", "Keychain Access"),
                ("com.bitwarden.desktop", "Bitwarden"),
                ("com.dashlane.dashlanephonefinal", "Dashlane"),
                ("com.lastpass.lastpassmacdesktop", "LastPass"),
                ("org.keepassxc.keepassxc", "KeePassXC"),
                ("com.keepersecurity.passwordmanager", "Keeper"),
                ("com.nordsec.nordpass", "NordPass"),
                ("me.proton.pass.electron", "Proton Pass"),
                ("in.sinew.Enpass-Desktop", "Enpass"),
                ("com.markmcguill.strongbox", "Strongbox"),
                ("com.yubico.yubioath", "Yubico Authenticator"),
            ]
            var allDenied = true
            var failing = ""
            for (bundle, name) in managers {
                let never = SensitiveCaptureDenylist.isNeverReadApp(bundle)
                let d = cascade().decide(context: WorkflowContext(appBundleId: bundle,
                                                                  windowTitle: "\(name) — Vault"))
                let ok = never && d == .suppress(reason: .denylistSource)
                XCTAssertTrue(ok, "password manager never read: \(name) (\(bundle))")
                if !ok { allDenied = false; failing += "\(bundle) " }
            }
            rows.append(Row(
                id: "3", scenario: "Visible password inside a password-manager / authenticator window "
                    + "(15 bundles checked; e.g. 1Password, Apple Passwords, Bitwarden, Dashlane, "
                    + "KeePassXC, Keeper, NordPass, Proton Pass, Enpass, Yubico Authenticator)",
                expected: "suppress(denylist-source) for every bundle",
                observed: allDenied ? "all 15 suppressed(denylist-source)" : "NOT suppressed: \(failing)",
                verdict: allDenied ? "PASS" : "FAIL",
                rule: "Cascade §1 — SensitiveCaptureDenylist.appBundles + passwordManagerFamilies "
                    + "(whole-app skip; the window is never read, so a password shown in it is never captured)",
                proof: "SecretMatrixTests.testSecretMatrix; NeverReadPasswordManagersTests "
                    + "(.verified = 76 identifiers across 66 bundle-id families, each with a cited source)"))
        }

        // -- Case 4: private browser window — Firefox title marker. Cascade §1. --
        do {
            let d = cascade().decide(context: WorkflowContext(
                appBundleId: "org.mozilla.firefox",
                windowTitle: "Release notes — Private Browsing"))
            XCTAssertEqual(d, .suppress(reason: .denylistSource), "firefox private window title")
            rows.append(Row(
                id: "4", scenario: "Private browser window — Firefox (title ends \"— Private Browsing\")",
                expected: "suppress(denylist-source)", observed: Self.label(d),
                verdict: d == .suppress(reason: .denylistSource) ? "PASS" : "FAIL",
                rule: "Cascade §1 — window title marker (BrowserPixelCapturePolicy.titleIsPrivate)",
                proof: "SecretMatrixTests.testSecretMatrix; BrowserPrivateWindowTests."
                    + "testEachPrivateTitleMarkerSkipsTheWindow"))
        }

        // -- Case 5: private browser window — Chrome/Edge new-tab title. Cascade §1. --
        do {
            let chrome = cascade().decide(context: WorkflowContext(
                appBundleId: "com.google.Chrome", windowTitle: "New Incognito Tab"))
            let edge = cascade().decide(context: WorkflowContext(
                appBundleId: "com.microsoft.edgemac", windowTitle: "New InPrivate tab"))
            let ok = chrome == .suppress(reason: .denylistSource)
                && edge == .suppress(reason: .denylistSource)
            XCTAssertTrue(ok, "chrome/edge private new-tab title")
            rows.append(Row(
                id: "5", scenario: "Private browser window — Chrome \"New Incognito Tab\" / Edge \"New InPrivate tab\"",
                expected: "suppress(denylist-source)",
                observed: "chrome=\(Self.label(chrome)); edge=\(Self.label(edge))",
                verdict: ok ? "PASS" : "FAIL",
                rule: "Cascade §1 — window title marker",
                proof: "SecretMatrixTests.testSecretMatrix; BrowserPrivateWindowTests."
                    + "testEachPrivateTitleMarkerSkipsTheWindow"))
        }

        // -- Case 6: private browser window — Incognito/Private badge read in the top bar. --
        do {
            let incognito = BrowserPixelCapturePolicy.topBarFinding(
                [Self.topBarLine("Incognito")], window: Self.unitWindow,
                pixelSize: Self.pixelSize, pixelsPerPoint: 2, denylist: SensitiveCaptureDenylist(entries: []))
            let privateBadge = BrowserPixelCapturePolicy.topBarFinding(
                [Self.topBarLine("Private")], window: Self.unitWindow,
                pixelSize: Self.pixelSize, pixelsPerPoint: 2, denylist: SensitiveCaptureDenylist(entries: []))
            let ok = incognito == .privateWindow && privateBadge == .privateWindow
            XCTAssertTrue(ok, "top-bar incognito / private badge")
            rows.append(Row(
                id: "6", scenario: "Private browser window — \"Incognito\"/\"InPrivate\"/\"Private\" badge in the top bar "
                    + "(for a window with no private title, e.g. a navigated Chrome/Brave/Safari window)",
                expected: "topBarFinding == privateWindow", observed: "incognito=\(incognito.map(String.init(describing:)) ?? "nil"); private=\(privateBadge.map(String.init(describing:)) ?? "nil")",
                verdict: ok ? "PASS" : "FAIL",
                rule: "Cascade §1 — top-bar read (BrowserPixelCapturePolicy.topBarFinding), top 120 pt only",
                proof: "SecretMatrixTests.testSecretMatrix; BrowserPrivateWindowTests."
                    + "testIncognitoInTheTopBarSkipsTheFrameButIncognitoOnThePageDoesNot, "
                    + "testTheTopBarIsTheTop120PointsOfTheWindowOnly"))
        }

        // -- Case 7: bank / sign-in page by URL. Cascade §1. --
        do {
            var allDenied = true
            var detail: [String] = []
            for url in ["https://accounts.google.com/signin", "https://secure.chase.com/web/auth",
                        "https://www.bankofamerica.com/", "https://login.microsoftonline.com/"] {
                let d = cascade().decide(context: WorkflowContext(appBundleId: "com.apple.Safari", url: url))
                let ok = d == .suppress(reason: .denylistSource)
                if !ok { allDenied = false }
                detail.append("\(url) -> \(Self.label(d))")
            }
            XCTAssertTrue(allDenied, "bank/sign-in URL")
            rows.append(Row(
                id: "7", scenario: "Bank / sign-in page open in a browser (by URL): accounts.google.com, "
                    + "secure.chase.com, bankofamerica.com, login.microsoftonline.com",
                expected: "suppress(denylist-source)",
                observed: allDenied ? "all suppressed(denylist-source)" : detail.joined(separator: "; "),
                verdict: allDenied ? "PASS" : "FAIL",
                rule: "Cascade §1 — SensitiveCaptureDenylist.sensitiveDomains (host + subdomain match)",
                proof: "SecretMatrixTests.testSecretMatrix; CascadeDenylistTests.testURLDenylistMatchSuppresses; "
                    + "NeverReadPasswordManagersTests.testPasswordManagersWebVaultsAreNeverRead"))
        }

        // -- Case 8: bank / sign-in address read in the top bar or page title. --
        do {
            let topBar = BrowserPixelCapturePolicy.topBarFinding(
                [Self.topBarLine("secure.chase.com/web/auth")], window: Self.unitWindow,
                pixelSize: Self.pixelSize, pixelsPerPoint: 2, denylist: SensitiveCaptureDenylist(entries: []))
            let titleAsAddress = cascade().decide(context: WorkflowContext(
                appBundleId: "com.apple.Safari", windowTitle: "accounts.google.com"))
            let ok = topBar == .deniedSite && titleAsAddress == .suppress(reason: .denylistSource)
            XCTAssertTrue(ok, "bank/sign-in address in top bar / title")
            rows.append(Row(
                id: "8", scenario: "Bank / sign-in page with the address in the top bar, or a page titled with the address",
                expected: "topBarFinding == deniedSite; title route suppress(denylist-source)",
                observed: "topBar=\(topBar.map(String.init(describing:)) ?? "nil"); title=\(Self.label(titleAsAddress))",
                verdict: ok ? "PASS" : "FAIL",
                rule: "Cascade §1 — BrowserPixelCapturePolicy.namesDeniedSite (address bar / title)",
                proof: "SecretMatrixTests.testSecretMatrix; BrowserPrivateWindowTests."
                    + "testASignInOrBankAddressInTheTopBarSkipsThePage, testAPageTitledWithASignInOrBankAddressIsSkipped"))
        }

        // -- Case 9: API key / token in a TERMINAL (pixel-allow, then §6 OCR drop). --
        do {
            let ctx = WorkflowContext(appBundleId: "com.apple.Terminal", windowTitle: "zsh")
            let pixel = cascade(ax: false).decide(context: ctx)       // frame is allowed at pixel time
            let aws = cascade().decideOcr(text: Fixture.awsKeyLine, context: ctx)
            let pat = cascade().decideOcr(text: Fixture.githubPat, context: ctx)
            let ok = pixel == .allow
                && aws == .suppress(reason: .ocrTimeSecret)
                && pat == .suppress(reason: .ocrTimeSecret)
            XCTAssertEqual(pixel, .allow, "terminal pixel-time allow")
            XCTAssertEqual(aws, .suppress(reason: .ocrTimeSecret), "terminal AWS key OCR drop")
            XCTAssertEqual(pat, .suppress(reason: .ocrTimeSecret), "terminal GitHub PAT OCR drop")
            rows.append(Row(
                id: "9", scenario: "API key / token printed in a terminal (AWS access key id; GitHub PAT). "
                    + "The frame clears the pixel-time cascade, then the OCR text is dropped.",
                expected: "pixel allow; decideOcr suppress(ocr-time-secret)",
                observed: "pixel=\(Self.label(pixel)); aws=\(Self.label(aws)); pat=\(Self.label(pat))",
                verdict: ok ? "PASS" : "FAIL",
                rule: "Cascade §6 — OCR-time secret regex (SuppressionCascade.decideOcr, patterns 2 & 3)",
                proof: "SecretMatrixTests.testSecretMatrix; core/brain reading.rs cross-engine parity; "
                    + "ocr_secrets::tests"))
        }

        // -- Case 10: API key / token in a text EDITOR (§6 OCR drop). --
        do {
            let ctx = WorkflowContext(appBundleId: "com.microsoft.VSCode", windowTitle: "config.ts")
            let token = cascade().decideOcr(text: Fixture.tokenAssign, context: ctx)
            let apiKey = cascade().decideOcr(text: Fixture.apiKeyAssign, context: ctx)
            let jwt = cascade().decideOcr(text: Fixture.jwt, context: ctx)
            let ok = token == .suppress(reason: .ocrTimeSecret)
                && apiKey == .suppress(reason: .ocrTimeSecret)
                && jwt == .suppress(reason: .ocrTimeSecret)
            XCTAssertEqual(token, .suppress(reason: .ocrTimeSecret), "editor token OCR drop")
            XCTAssertEqual(apiKey, .suppress(reason: .ocrTimeSecret), "editor api_key OCR drop")
            XCTAssertEqual(jwt, .suppress(reason: .ocrTimeSecret), "editor JWT OCR drop")
            rows.append(Row(
                id: "10", scenario: "API key / token / JWT in a text editor (token = \"…\"; api_key = …; a JWT)",
                expected: "decideOcr suppress(ocr-time-secret)",
                observed: "token=\(Self.label(token)); api_key=\(Self.label(apiKey)); jwt=\(Self.label(jwt))",
                verdict: ok ? "PASS" : "FAIL",
                rule: "Cascade §6 — OCR-time secret regex (patterns 1, 2 & 4). Re-checked on the raw join, "
                    + "the reading-order text, and the exact stored text (OCRPostAllowEmitter.handleOCRResult).",
                proof: "SecretMatrixTests.testSecretMatrix; ocr_secrets::tests; "
                    + "BrowserPrivateWindowTests.testPasswordFieldsPasswordManagersAndSignInSitesStayNeverRead"))
        }

        // -- Case 11: one-time code in a chat, SEEN ON SCREEN (OCR path). §6. --
        // Now REDACTED: a 4–8 digit run within ~40 bytes of an OTP keyword is
        // dropped by §6 (SuppressionCascade.containsOTP). Precision-first: a bare
        // number with no keyword is still kept, so ordinary numbers survive.
        do {
            let ctx = WorkflowContext(appBundleId: "com.hnc.Discord", windowTitle: "direct message")
            let d = cascade().decideOcr(text: Fixture.otpChat, context: ctx)
            let bare = cascade().decideOcr(text: "123456", context: ctx)
            let ok = d == .suppress(reason: .ocrTimeSecret) && bare == .allow
            XCTAssertEqual(d, .suppress(reason: .ocrTimeSecret), "on-screen OTP via OCR is redacted by §6")
            XCTAssertEqual(bare, .allow, "a bare number with no keyword is kept (precision-first)")
            rows.append(Row(
                id: "11", scenario: "One-time code shown on screen in a chat app and captured by OCR "
                    + "(e.g. \"Your verification code is 123456\")",
                expected: "decideOcr suppress(ocr-time-secret); a bare number is allowed",
                observed: "otp=\(Self.label(d)); bare=\(Self.label(bare))",
                verdict: ok ? "PASS" : "FAIL",
                rule: "Cascade §6 — OCR-time OTP rule (SuppressionCascade.containsOTP): a 4–8 digit run "
                    + "within ~40 bytes of an OTP keyword (one-time, verification/security/login/"
                    + "authentication/confirmation code, passcode, OTP, 2FA, …). Keyword required, so a "
                    + "bare number is kept. Cross-engine with the Rust reader.",
                proof: "SecretMatrixTests.testSecretMatrix, testOnScreenOtpOnOcrPathIsRedacted; "
                    + "ocr_secrets::tests::an_otp_needs_both_a_keyword_and_a_nearby_run; shared corpus"))
        }

        // -- Case 12: credit-card number in a text editor (OCR path). §6. --
        // Now REDACTED: a 13–19 digit run (single space/hyphen groups) that passes
        // the Luhn checksum is dropped by §6 (SuppressionCascade.containsCreditCard).
        // Precision-first: a non-Luhn look-alike is kept.
        do {
            let ctx = WorkflowContext(appBundleId: "com.apple.TextEdit", windowTitle: "notes.txt")
            let d = cascade().decideOcr(text: Fixture.creditCard, context: ctx)
            let nonLuhn = cascade().decideOcr(text: "1234 1234 1234 1234", context: ctx)
            let ok = d == .suppress(reason: .ocrTimeSecret) && nonLuhn == .allow
            XCTAssertEqual(d, .suppress(reason: .ocrTimeSecret), "credit-card number via OCR is redacted by §6")
            XCTAssertEqual(nonLuhn, .allow, "a 16-digit non-Luhn number is kept (precision-first)")
            rows.append(Row(
                id: "12", scenario: "Credit-card number typed in a plain text editor and captured by OCR "
                    + "(\"4111 1111 1111 1111 …\")",
                expected: "decideOcr suppress(ocr-time-secret); a non-Luhn look-alike is allowed",
                observed: "card=\(Self.label(d)); nonLuhn=\(Self.label(nonLuhn))",
                verdict: ok ? "PASS" : "FAIL",
                rule: "Cascade §6 — OCR-time card rule (SuppressionCascade.containsCreditCard): a maximal "
                    + "13–19 digit run (single space/hyphen groups) that passes the Luhn checksum. Luhn drops "
                    + "almost all ordinary numbers, so phone numbers / order ids / dates are kept. "
                    + "Cross-engine with the Rust reader.",
                proof: "SecretMatrixTests.testSecretMatrix, testCreditCardOnOcrPathIsRedacted; "
                    + "ocr_secrets::tests::real_test_cards_pass_luhn_and_look_alikes_do_not; shared corpus"))
        }

        writeMatrix(rows)
    }

    // MARK: - OCR-path OTP and card regression gates (were the two GAP skips).
    //
    // G1 (OTP) and G2 (credit card) are now closed on the OCR path. These were
    // `XCTSkip`ped assertions of the behavior we wanted; they are now live
    // regression gates. Each also checks the precision side so a future change
    // that over-redacts ordinary numbers is caught too.

    /// G1 closed: an OTP shown on screen in an ordinary app is dropped on the
    /// OCR path, while a bare number with no keyword is kept.
    func testOnScreenOtpOnOcrPathIsRedacted() {
        let ctx = WorkflowContext(appBundleId: "com.hnc.Discord")
        XCTAssertEqual(cascade().decideOcr(text: "Your verification code is 123456", context: ctx),
                       .suppress(reason: .ocrTimeSecret),
                       "on-screen OTP dropped on the OCR path")
        XCTAssertEqual(cascade().decideOcr(text: "one-time passcode: 55012", context: ctx),
                       .suppress(reason: .ocrTimeSecret))
        XCTAssertEqual(cascade().decideOcr(text: "Order #40281773", context: ctx), .allow,
                       "a bare order number with no OTP keyword is kept")
        XCTAssertEqual(cascade().decideOcr(text: "123456", context: ctx), .allow,
                       "a bare code with no keyword is kept")
    }

    /// G2 closed: a Luhn-valid credit-card number is dropped on the OCR path,
    /// while a non-Luhn look-alike and a phone number are kept.
    func testCreditCardOnOcrPathIsRedacted() {
        let ctx = WorkflowContext(appBundleId: "com.apple.TextEdit")
        for card in ["4111 1111 1111 1111", "5500 0000 0000 0004", "3400 0000 0000 009",
                     "4111-1111-1111-1111"] {
            XCTAssertEqual(cascade().decideOcr(text: card, context: ctx),
                           .suppress(reason: .ocrTimeSecret), "card dropped: \(card)")
        }
        XCTAssertEqual(cascade().decideOcr(text: "1234 1234 1234 1234", context: ctx), .allow,
                       "a 16-digit non-Luhn number is kept")
        XCTAssertEqual(cascade().decideOcr(text: "Call 415-555-0132", context: ctx), .allow,
                       "a phone number is kept")
    }

    // MARK: - TSV emission for the shell harness

    private func writeMatrix(_ rows: [Row]) {
        guard let out = ProcessInfo.processInfo.environment["SECRET_MATRIX_OUT"], !out.isEmpty else { return }
        var lines = ["id\tscenario\texpected\tobserved\tverdict\trule\tproof"]
        for r in rows {
            func clean(_ s: String) -> String {
                s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
            }
            lines.append([r.id, r.scenario, r.expected, r.observed, r.verdict, r.rule, r.proof]
                .map(clean).joined(separator: "\t"))
        }
        let text = lines.joined(separator: "\n") + "\n"
        do {
            try text.write(toFile: out, atomically: true, encoding: .utf8)
        } catch {
            XCTFail("could not write SECRET_MATRIX_OUT=\(out): \(error)")
        }
    }
}
