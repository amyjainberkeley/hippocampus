#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
#
# render.py — turn the secret-matrix harness results into eval/secret-matrix-*.md.
#
# Input: the Swift matrix TSV (written by SecretMatrixTests.testSecretMatrix)
# plus PASS/FAIL flags for the Rust-backed rows. Output: one Markdown file.
#
# Deterministic: given the same TSV and the same flags it writes byte-identical
# output (no timestamps), so a re-run leaves the tree clean. Run it with
# `python3 -I` from run.sh. It reads only the paths it is given.

import argparse
import sys

DATE = "2026-10-17"


def read_tsv(path):
    rows = []
    with open(path, encoding="utf-8") as fh:
        header = fh.readline().rstrip("\n").split("\t")
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            cells = line.split("\t")
            rows.append(dict(zip(header, cells)))
    return rows


def md_escape(text):
    return text.replace("|", "\\|")


VERDICT_MARK = {
    "PASS": "PASS",
    "FAIL": "**FAIL**",
    "NEEDS-A-PERSON": "needs a person",
    "LIMITATION": "documented limitation",
}


def verdict_cell(v):
    return VERDICT_MARK.get(v, v)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tsv", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--rust-redaction", default="UNKNOWN")  # PASS/FAIL
    ap.add_argument("--rust-reading", default="UNKNOWN")
    ap.add_argument("--swift-matrix", default="UNKNOWN")
    ap.add_argument("--swift-cited", default="UNKNOWN")
    args = ap.parse_args()

    swift_rows = read_tsv(args.tsv)

    # Rust-backed rows (verdict comes from the cargo runs this harness drove).
    rust_ingest_v = "PASS" if args.rust_redaction == "PASS" else "FAIL"
    rust_domains_v = "PASS" if args.rust_redaction == "PASS" else "FAIL"
    rust_parity_v = "PASS" if args.rust_reading == "PASS" else "FAIL"

    rust_rows = [
        {
            "id": "O2",
            "scenario": "One-time code / bank alert in a message, via the Messages or Mail "
            "**deep-hook ingest** (opt-in; the path that reads the Messages/Mail store directly, "
            "not OCR). E.g. \"Your Apple ID code is 123456\".",
            "expected": "OTP -> [REDACTED:SMS_OTP]; bank alert -> [REDACTED:BANK_NOTIFICATION]; "
            "no source bytes survive; event still ingested",
            "observed": "redacted + ingested" if rust_ingest_v == "PASS" else "test failure",
            "verdict": rust_ingest_v,
            "rule": "ADR-0030 §3(a) sms_otp + §3(b) sensitive_domains, gated to com.apple.MobileSMS / "
            "com.apple.mail (redaction::bundle_is_in_scope); wired in apps/agent/src/messages_ingest.rs "
            "BEFORE storage.",
            "proof": "messages_plugin::tests::sms_otp_shape_is_redacted_but_ingested, "
            "bank_notification_shape_is_redacted_but_ingested, sensitive_url_in_body_drops; "
            "sms_otp::tests (A01–R05, 30+ shapes); redaction_corpus bin",
        },
        {
            "id": "S1",
            "scenario": "Bank / sign-in / password-vault domain recognised in a message body or URL "
            "(backstops the Swift domain list with the Rust table).",
            "expected": "matches_sensitive_domain == true for US banks, fintech, auth providers, "
            "OAuth callbacks, magic-links",
            "observed": "all matched" if rust_domains_v == "PASS" else "test failure",
            "verdict": rust_domains_v,
            "rule": "ADR-0030 §3(b) — sensitive_domains table (include_str! compile-time TOML)",
            "proof": "sensitive_domains::tests::matches_us_bank_exact, matches_us_bank_subdomain, "
            "matches_auth_provider, matches_oauth_callback_pattern, matches_magic_link_pattern",
        },
        {
            "id": "X1",
            "scenario": "Cross-engine parity: the Swift helper (ICU/NSRegularExpression) and the Rust "
            "reader (regex crate) agree on the four §6 secret shapes, so cleaning the text for recall "
            "can never reveal a secret the helper let through.",
            "expected": "same verdict on the shared corpus; the four pattern strings appear verbatim "
            "in SuppressionCascade.swift",
            "observed": "parity holds" if rust_parity_v == "PASS" else "test failure",
            "verdict": rust_parity_v,
            "rule": "Shared corpus core/brain/fixtures/ocr-secret-corpus.json + verbatim-string guard",
            "proof": "reading.rs::the_guard_answers_the_shared_corpus_like_the_capture_helper, "
            "the_guard_uses_the_capture_helpers_four_pattern_strings_verbatim",
        },
    ]

    def status_line(flag):
        return "PASS" if flag == "PASS" else ("**FAIL**" if flag == "FAIL" else flag)

    out = []
    w = out.append

    w(f"# Secret matrix — what Hippocampus skips or refuses before it stores ({DATE})")
    w("")
    w("This is the outside judge for one launch claim: **Hippocampus does not store the "
      "sensitive things on this list.** It is not a self-assessment — every PASS below is a "
      "synthetic screen run through the exact policy code the signed helper runs, with an "
      "assertion that fails the build if the drop regresses. It is deliberately honest about "
      "what it does **not** catch.")
    w("")
    w("No absolute claim is made here. This matrix shows, case by case, *which rule fires* and "
      "*which test proves it*, and names every case that a person must confirm on a real Mac or "
      "that is a documented limitation.")
    w("")
    w("## How to reproduce")
    w("")
    w("```sh")
    w("env -i HOME=\"$HOME\" USER=\"$USER\" TMPDIR=\"$TMPDIR\" LANG=en_US.UTF-8 \\")
    w("  PATH=\"$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin\" \\")
    w("  nice -n 15 scripts/launch/secret-matrix/run.sh")
    w("```")
    w("")
    w("The run below was green except where a row says otherwise:")
    w("")
    w(f"- Rust redaction unit tests (sms_otp, messages_plugin, sensitive_domains, ocr_secrets, mod): "
      f"{status_line(args.rust_redaction)}")
    w(f"- Rust cross-engine parity (core/brain/tests/reading.rs): {status_line(args.rust_reading)}")
    w(f"- Swift matrix (SecretMatrixTests): {status_line(args.swift_matrix)}")
    w(f"- Swift corroborating suites (NeverReadPasswordManagers / Denylist / BrowserPrivateWindow / "
      f"SuppressionCascade / ConcreteProbes): {status_line(args.swift_cited)}")
    w("")
    w("## What a \"synthetic screen\" is, and what this does not do")
    w("")
    w("The suppression cascade is OS-API-free by design (`SuppressionCascade.swift`): it takes an "
      "app bundle id, a window title, a URL, OCR lines with positions, and three OS signals "
      "(the Carbon secure-input bit, the focused element's AX subrole, an OS-blacked region), and "
      "returns allow or suppress. A synthetic screen is exactly that input, all strings invented. "
      "The harness injects only the three OS signals (they cannot be produced headlessly); every "
      "rule under test — the denylist, the browser checks, the secret regex — is the real shipping "
      "code, not a copy.")
    w("")
    w("Production posture is reproduced exactly: `admissionPolicy: .ordinaryApplications` (what "
      "`Sources/MCICaptureHelper/main.swift` passes — Hippocampus reads ordinary apps and relies "
      "on the cascade, it is not an allowlist-only capture), the full browser bundle set, and the "
      "real `SensitiveCaptureDenylist` rules. **No screenshot is taken and no real memory is read.**")
    w("")
    w("What this does not do: it does not render real pixels through PP-OCR, and it does not run the "
      "live Carbon/AX/ScreenCaptureKit APIs. Those are covered by the probe tests "
      "(`CarbonSecureEventInputProbeTests`, `AXSubroleProbeTests`) and by the on-device checks in "
      "the \"needs a person\" section.")
    w("")
    w("## The cascade, in order (first match wins)")
    w("")
    w("Reference for the \"rule\" column. From `SuppressionCascade.decide` + the OCR-time pass in "
      "`OCRPostAllowEmitter.handleOCRResult`:")
    w("")
    w("1. **§1 denylist-source** — app bundle / URL / window title is on the never-read list.")
    w("2. **§2 os-blacked-region** — the OS already renders the window black to capture.")
    w("3. **§3 secure-event-input** — `IsSecureEventInputEnabled()` is true (a password field, sudo, "
      "a vault unlock, anywhere in the login session).")
    w("4. **§4 ax-secure-subrole** — the focused element is an `AXSecureTextField`.")
    w("5. **§5 denylist-postcapture** — a denylist edit the live filter has not caught up to.")
    w("6. **§6 ocr-time-secret** — the OCR'd text matches one of four secret shapes; checked on the "
      "raw read, the reading-order text, and the exact stored text.")
    w("7. **§7 failsafe-unknown** — anything the cascade cannot positively classify as non-secure is "
      "dropped (AX must *affirmatively* say non-secure to allow; `nil` is a drop).")
    w("")
    w("## The matrix")
    w("")
    w("| # | Case (synthetic screen) | Verdict | Rule that fires | Proving test(s) |")
    w("| - | ----------------------- | ------- | --------------- | --------------- |")
    for r in swift_rows:
        w("| {id} | {sc} | {v} | {rule} | {proof} |".format(
            id=md_escape(r["id"]), sc=md_escape(r["scenario"]), v=verdict_cell(r["verdict"]),
            rule=md_escape(r["rule"]), proof=md_escape(r["proof"])))
    for r in rust_rows:
        w("| {id} | {sc} | {v} | {rule} | {proof} |".format(
            id=md_escape(r["id"]), sc=md_escape(r["scenario"]), v=verdict_cell(r["verdict"]),
            rule=md_escape(r["rule"]), proof=md_escape(r["proof"])))
    w("")
    w("### Decisions observed this run (falsifiability record)")
    w("")
    w("| # | Expected | Observed |")
    w("| - | -------- | -------- |")
    for r in swift_rows:
        w("| {id} | {e} | {o} |".format(
            id=md_escape(r["id"]), e=md_escape(r["expected"]), o=md_escape(r["observed"])))
    for r in rust_rows:
        w("| {id} | {e} | {o} |".format(
            id=md_escape(r["id"]), e=md_escape(r["expected"]), o=md_escape(r["observed"])))
    w("")
    w("## Needs a person (confirm on a real Mac)")
    w("")
    w("These cannot be settled headlessly. Each is a short, exact procedure. Use only throwaway "
      "test accounts and fake data.")
    w("")
    w("### N1 — A private Safari or Arc window that shows no readable marker")
    w("")
    w("The cascade catches a private window three ways: a private word in the title, a readable "
      "\"Incognito\"/\"InPrivate\"/\"Private\" badge in the top bar, or the browser's own answer "
      "(Automation, only for Chrome/Brave/Edge and only if you already allowed it). Safari and Arc "
      "are **not** in the Automation list, and Safari puts no private marker in the window title. So "
      "a private Safari/Arc window is skipped only if its top bar shows a word the reader recognises. "
      "Whether it does is a pixels question for a real Mac.")
    w("")
    w("Steps:")
    w("1. Install the signed build. Grant Screen Recording. Let it capture for a minute on an "
      "ordinary page so you know capture works.")
    w("2. Open a Safari **private** window (Shift-Cmd-N) and go to a harmless page (e.g. "
      "example.com). Do the same in Arc (an incognito/private window).")
    w("3. In the menu bar, confirm whether the dot shows reading or skipped for that window.")
    w("4. Wait ~60s, then in the window (Ask) search for a unique word you can see on that page.")
    w("5. **Pass** = the page is not found (window was skipped). **Gap** = it is found. If it is a "
      "gap, that private window was read; file it per SECURITY.md and add its marker to the top-bar "
      "reader. Note: the four secret shapes (§6) still apply to whatever was on it.")
    w("")
    w("### N2 — A one-time code shown on screen in an ordinary chat app (OCR path)")
    w("")
    w("Row 11 proves the OCR gate does **not** catch a bare numeric code; the Messages/Mail "
      "deep-hook ingest (row O2) does. Confirm the on-screen behaviour and decide if it is acceptable "
      "for launch.")
    w("")
    w("1. In a chat app that is **not** Apple Messages (e.g. a web Gmail, Slack, Discord), display a "
      "fake message \"Your verification code is 123456\".")
    w("2. Wait ~60s. In Ask, search \"123456\".")
    w("3. Expected (documented): it **can** be found — an on-screen OTP is not one of the four secret "
      "shapes (PRIVACY.md:72, SECURITY.md:29). Decide whether to broaden §6 or accept the "
      "documented limitation.")
    w("")
    w("### N3 — A credit-card number typed into an ordinary app (OCR path)")
    w("")
    w("Row 12 proves there is no card-number detector on the OCR path.")
    w("")
    w("1. In TextEdit, type a **fake** card-shaped number: `4111 1111 1111 1111`.")
    w("2. Wait ~60s. In Ask, search `4111`.")
    w("3. Expected (documented gap): it **can** be found. Decide whether a Luhn/PAN redactor is a "
      "launch blocker; today only a soft prompt instruction to the local model discourages recording "
      "it (not a hard filter).")
    w("")
    w("## Concerns / gaps (nothing hidden)")
    w("")
    w("- **G1 — On-screen OTP (OCR path) is not redacted.** Real, documented (PRIVACY.md:72, "
      "SECURITY.md:29). A bare numeric code is not one of the four §6 shapes. Covered on the "
      "Messages/Mail ingest path only. Tracked by the ignored test "
      "`SecretMatrixTests.testGAP_onScreenOtpOnOcrPathIsNotRedacted` (skipped with a note; remove "
      "the skip when coverage lands).")
    w("- **G2 — Credit-card numbers are not redacted on any storage path.** Real, documented "
      "(PRIVACY.md:96). No Luhn/PAN detector exists; only `apps/mind/.../Prompts.swift:27` asks the "
      "local model not to record card numbers, which is not a hard filter. Tracked by the ignored "
      "test `SecretMatrixTests.testGAP_creditCardOnOcrPathIsNotRedacted`.")
    w("- **G3 — Launch copy understates the app denylist.** PRIVACY.md:67 and SECURITY.md:27 say "
      "\"six password managers\" are skipped and \"others are read like any other app,\" but the code "
      "(`CaptureAdmissionPolicy.swift`) never-reads 66 password-manager/authenticator bundle-id "
      "families (Keeper, NordPass, Proton Pass, Enpass, KeePassXC, Yubico Authenticator, …), covering "
      "the 76 identifiers verified by `NeverReadPasswordManagersTests`. The code is **more** "
      "protective than the copy — the safe direction — but the two should be reconciled before launch. "
      "A person should decide the wording (this harness does not edit launch copy).")
    w("- **G4 — A stale rationale string in the allowlist.** `known-safe-apps.toml`'s "
      "`com.apple.MobileSMS` entry claims \"§3(a) … gate the rendered text on every cascade-twice "
      "pass,\" but the Swift OCR pass runs only the four §6 patterns, not the SMS-OTP bank (that runs "
      "in the Rust ingest path). Under `.ordinaryApplications` the allowlist is dormant, so this is a "
      "documentation accuracy issue, not a behaviour gap. Flag for a person.")
    w("- **G5 — §6 is a backstop, not a guarantee.** By design (SecretBench, Basak et al. "
      "arXiv:2307.00714 — best detectors 52–88% recall) the four shapes lean to precision. A secret "
      "in a shape they do not match (a bare high-entropy token with no keyword, a non-US OTP format, "
      "a card number) can be stored. This is stated in PRIVACY.md:96 and is why the denylist / "
      "secure-input / private-window rules (which are not pattern-recall-limited) carry the load.")
    w("")
    w("## What this proves, and what it does not")
    w("")
    w("Proves (headless, repeatable, asserted): password fields (two ways), 66 password-manager and "
      "authenticator bundle-id families (76 verified identifiers), private browser windows that show a "
      "marker, bank/sign-in sites by URL and by address, and API keys/tokens/JWTs in a terminal or "
      "editor are each dropped by a named rule, and the Swift and Rust secret checks agree. The "
      "Messages/Mail ingest path redacts OTPs and bank alerts.")
    w("")
    w("Does not prove (needs a person / out of scope here): the live Carbon/AX/ScreenCaptureKit "
      "pipeline on a real Mac (N1–N3), on-screen OTPs and card numbers (documented gaps G1–G2), and "
      "any secret in a shape §6 does not match (G5). None of these is hidden; each is a row or a "
      "concern above.")
    w("")

    text = "\n".join(out) + "\n"
    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write(text)
    # Gate: fail if any provable (PASS/FAIL) row is FAIL.
    provable_fail = any(r["verdict"] == "FAIL" for r in swift_rows) \
        or any(r["verdict"] == "FAIL" for r in rust_rows)
    if provable_fail:
        print("render.py: a provable row FAILED — see the matrix", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
