#!/usr/bin/env python3
# SPDX-License-Identifier: TBD-private
#
# wire_decode.py — READ-ONLY decoder for the MCI helper IPC wire stream.
#
# This tool touches NO protected-set code (AGENT_PROTOCOL §5). It only
# parses a `--output` file produced by `mci-capture-helper`. It is the
# observation harness for Track B · Step 1 (live SCStream runtime
# verification of the merged `// UNVERIFIED` shapes) AND Step 2 §7
# OS-integration corpus.
#
# Wire format mirrors `adapters/macos/.../IPC/Wire.swift` /
# `core/src/ipc/wire.rs` (binary, little-endian):
#
#   magic(1=0x4D) + version(1=0x04) + msg_type(2) + seq(8) + len(4) + payload(len)
#
# msg_type discriminants (MUST match Wire.swift `MessageType`):
#   0x0001 captureStart   0x0002 captureStop
#   0x0010 stateTransitionEvent   0x0011 privacyTombstone
#   0x0020 surfaceReleased        0x0030 helperHealth
#   0x0040 ocrEvent               (wire 0x04 / ADR-0016 P3.6)
#
# RedactionReason byte (PrivacyTombstone payload tail; MUST match
# RedactionReason.swift): 1 denylist-source · 2 os-blacked-region ·
# 3 secure-event-input · 4 ax-secure-subrole · 5 denylist-postcapture ·
# 6 ocr-time-secret (wire 0x04 / ADR-0016 P3.6) · 7 failsafe-unknown
#
# STEP-1 MECHANICAL VERDICT (printed at the end):
#   PASS shape  ⇔  ALL of:
#     - zero 0x0010 StateTransitionEvent frames (no pixels/event ever)
#     - every PrivacyTombstone reason == 7 (failsafe-unknown)
#     - PrivacyTombstone seq is contiguous from its first value with NO
#       gaps. A gap = a seq was allocated with no wire frame written =
#       an `.allow` decision happened (fail-safe predicts zero). Loud.
#   A truncated final frame (Ctrl-C mid-write) is tolerated, reported,
#   and NOT counted as corruption.
#
# This is NOT the ADR-0013 §7 corpus and NOT the G2 footprint proof.
#
# `--verbose` / `-v` adds a per-frame table dump for temporal
# correlation against a paper log (e.g. "sudo prompt opened at T+30s
# → which tombstone seqs cluster around T+30s?"). Off by default;
# steady-state output is unchanged.

import argparse
import struct
import sys
from collections import Counter

MAGIC = 0x4D
# wire bumped 0x08->0x09 (Phase 6 PR 6 — PR #226 §5.1 + CTO §4 Phase 6
# PR 6 + S13 acceptance gate). HelperHealth gained four trailing
# content-free fields: failsafe_by_app (cap 8 LRU), cpu_pct_micro
# (u32), rss_bytes (u64), tracker_alive_at_us (u64 — V2-P1 PR 13
# reserved slot per the §6.2 = A + §8 coordination contract). Decoder
# dual-accepts {0x09, 0x08, 0x07, 0x06} per the Rust-side
# ACCEPTED_FRAME_VERSIONS — see core/src/ipc/wire.rs FRAME_VERSION
# doc for the full bump sequence. 0x06 is retained for the Safari
# extension async-update window (cycle 8.27 lesson).
VERSION = 0x09
ACCEPTED_VERSIONS = (VERSION, 0x08, 0x07, 0x06)
HEADER = 1 + 1 + 2 + 8 + 4  # 16 bytes
# HelperHealth v0x07 payload = 8 × u64 LE = 64 bytes:
#   uptime_ms · frames_delivered · frames_suppressed ·
#   frames_redacted_by_failsafe · cascade_forced_count ·
#   frames_dropped_backpressure · frames_dropped_late_ack ·
#   frames_encode_failed
# v0x08 appends `frames_focus_race_dropped`, totalling 9 × u64 LE = 72
# bytes.
# v0x09 appends failsafe_by_app (u8 entry_count + N × (u8 bundle_id_len
# + bundle_id bytes + u64 counter)) + cpu_pct_micro (u32 LE) + rss_bytes
# (u64 LE) + tracker_alive_at_us (u64 LE). Minimum at v0x09 with empty
# failsafe_by_app: 9 × u64 (72) + u8(1) + u32(4) + u64(8) + u64(8) = 93
# bytes; cap-8 with max bundle ids would be 93 + 8 × (1 + 255 + 8) =
# 2205 bytes.
HELPER_HEALTH_PAYLOAD_V07 = 8 * 8
HELPER_HEALTH_PAYLOAD_V08 = 9 * 8
HELPER_HEALTH_PAYLOAD_V09_MIN_WITH_EMPTY_MAP = 9 * 8 + 1 + 4 + 8 + 8  # = 93
MAX_FAILSAFE_BY_APP_ENTRIES = 8  # cap per PR #226 §5.1 + Rust wire.rs
# OCREvent v0x04 fixed-header layout (ADR-0016 §1.6):
#   seq u64 · ts_us u64 · app_bundle_id [u8; 64] ·
#   window_title_len u16 · url_len u16 · ocr_text_len u32 ·
#   keyframe_hash [u8; 32]
# = 8 + 8 + 64 + 2 + 2 + 4 + 32 = 120 bytes; trailer is
#   window_title + url + ocr_text bytes.
OCR_EVENT_FIXED_HEADER = 8 + 8 + 64 + 2 + 2 + 4 + 32
MAX_OCR_TEXT_BYTES = 64 * 1024  # ADR-0016 §4.9

MSG = {
    0x0001: "captureStart",
    0x0002: "captureStop",
    0x0010: "stateTransitionEvent",
    0x0011: "privacyTombstone",
    0x0020: "surfaceReleased",
    0x0030: "helperHealth",
    0x0040: "ocrEvent",
    0x0050: "pageContentEvent",
}
REASON = {
    1: "denylist-source",
    2: "os-blacked-region",
    3: "secure-event-input",
    4: "ax-secure-subrole",
    5: "denylist-postcapture",
    6: "ocr-time-secret",
    7: "failsafe-unknown",
    8: "focus-race-dropped",
}


def parse_ocr_event_payload(p):
    """Decode an OCREvent payload (ADR-0016 P3.6 §1.6).

    Layout (little-endian):
      seq u64 · ts_us u64 · app_bundle_id [u8; 64] ·
      window_title_len u16 · url_len u16 · ocr_text_len u32 ·
      keyframe_hash [u8; 32] · window_title bytes · url bytes ·
      ocr_text bytes.

    Returns a dict or ``None`` on short / malformed payload.
    """
    if len(p) < OCR_EVENT_FIXED_HEADER:
        return None
    seq, ts_us = struct.unpack_from("<QQ", p, 0)
    bundle_bytes = p[16:16 + 64]
    bundle = bundle_bytes.rstrip(b"\x00").decode("utf-8", errors="replace")
    wt_len, url_len = struct.unpack_from("<HH", p, 16 + 64)
    text_len = struct.unpack_from("<I", p, 16 + 64 + 4)[0]
    keyframe_hash = p[OCR_EVENT_FIXED_HEADER - 32: OCR_EVENT_FIXED_HEADER]
    off = OCR_EVENT_FIXED_HEADER
    if off + wt_len + url_len + text_len > len(p):
        return None
    if text_len > MAX_OCR_TEXT_BYTES:
        return None  # over-cap = trust-boundary violation per ADR-0016 §4.9
    wt = p[off:off + wt_len].decode("utf-8", errors="replace")
    off += wt_len
    url = p[off:off + url_len].decode("utf-8", errors="replace")
    off += url_len
    text = p[off:off + text_len].decode("utf-8", errors="replace")
    return {
        "seq": seq,
        "ts_us": ts_us,
        "app_bundle_id": bundle,
        "window_title": wt,
        "url": url,
        "ocr_text_len": text_len,
        "ocr_text": text,
        "keyframe_hash_hex": keyframe_hash.hex(),
    }


def parse_tombstone_payload(p):
    """Decode a PrivacyTombstone payload.

    Layout: tsUs(u64) + appBundleLen(u16) + appBundle(utf8 bytes) + reason(u8).
    Returns (ts_us, app_bundle, reason) or (None, None, None) on short payload.
    """
    if len(p) < 8 + 2 + 1:
        return (None, None, None)
    ts_us = struct.unpack_from("<Q", p, 0)[0]
    bundle_len = struct.unpack_from("<H", p, 8)[0]
    bundle_start = 10
    bundle_end = bundle_start + bundle_len
    if bundle_end + 1 > len(p):
        return (ts_us, None, None)
    try:
        app_bundle = p[bundle_start:bundle_end].decode("utf-8", errors="replace")
    except Exception:
        app_bundle = "<utf8-decode-error>"
    reason = p[-1]
    return (ts_us, app_bundle, reason)


def main(path, verbose):
    with open(path, "rb") as f:
        buf = f.read()

    n = len(buf)
    off = 0
    frames = []          # (msg_type, seq, payload)
    truncated_tail = 0
    corrupt = []         # human-readable problems

    while off < n:
        if n - off < HEADER:
            truncated_tail = n - off
            break
        magic, ver, mtype, seq, plen = struct.unpack_from("<BBHQI", buf, off)
        if magic != MAGIC or ver not in ACCEPTED_VERSIONS:
            corrupt.append(
                f"@{off}: bad header magic=0x{magic:02X} ver=0x{ver:02X} "
                f"(expected 0x4D and version in {[hex(v) for v in ACCEPTED_VERSIONS]}) — stopping decode here"
            )
            break
        if n - off - HEADER < plen:
            # final frame truncated by Ctrl-C mid-write — tolerated.
            truncated_tail = n - off
            break
        payload = buf[off + HEADER: off + HEADER + plen]
        frames.append((mtype, ver, seq, payload))
        off += HEADER + plen

    by_type = Counter(MSG.get(m, f"unknown(0x{m:04X})") for m, _, _, _ in frames)
    tombstones = [(s, p) for (m, _v, s, p) in frames if m == 0x0011]
    state_events = [(s, p) for (m, _v, s, p) in frames if m == 0x0010]
    health_frames = [(v, s, p) for (m, v, s, p) in frames if m == 0x0030]
    ocr_events = [(s, p) for (m, _v, s, p) in frames if m == 0x0040]

    # HelperHealth: 0x07 payload = 8 u64s, 0x08 payload = 9 u64s
    # (frames_focus_race_dropped appended — ADR-0031 V2-P1),
    # 0x09 payload = 9 u64s + failsafe_by_app map + cpu_pct_micro (u32)
    # + rss_bytes (u64) + tracker_alive_at_us (u64) — Phase 6 PR 6.
    # Parse what we can; a malformed payload-length-mismatch is
    # reported, not silently papered over.
    health_parsed = []  # list of dicts in chronological seq order
    health_malformed = []
    for v, s, p in health_frames:
        failsafe_by_app = []  # default for non-0x09 frames
        cpu_pct_micro = 0
        rss_bytes = 0
        tracker_alive_at_us = 0
        if v == 0x07 and len(p) == HELPER_HEALTH_PAYLOAD_V07:
            (
                uptime_ms,
                frames_delivered,
                frames_suppressed,
                frames_redacted_by_failsafe,
                cascade_forced_count,
                frames_dropped_backpressure,
                frames_dropped_late_ack,
                frames_encode_failed,
            ) = struct.unpack_from("<QQQQQQQQ", p, 0)
            frames_focus_race_dropped = 0
        elif v == 0x08 and len(p) == HELPER_HEALTH_PAYLOAD_V08:
            (
                uptime_ms,
                frames_delivered,
                frames_suppressed,
                frames_redacted_by_failsafe,
                cascade_forced_count,
                frames_dropped_backpressure,
                frames_dropped_late_ack,
                frames_encode_failed,
                frames_focus_race_dropped,
            ) = struct.unpack_from("<QQQQQQQQQ", p, 0)
        elif v == 0x09 and len(p) >= HELPER_HEALTH_PAYLOAD_V09_MIN_WITH_EMPTY_MAP:
            # 9 u64s leading, then the variable-length failsafe_by_app
            # map, then fixed-length cpu/rss/tracker trailing.
            (
                uptime_ms,
                frames_delivered,
                frames_suppressed,
                frames_redacted_by_failsafe,
                cascade_forced_count,
                frames_dropped_backpressure,
                frames_dropped_late_ack,
                frames_encode_failed,
                frames_focus_race_dropped,
            ) = struct.unpack_from("<QQQQQQQQQ", p, 0)
            off = 9 * 8
            entry_count = p[off]
            if entry_count > MAX_FAILSAFE_BY_APP_ENTRIES:
                # Trust-boundary check — over-cap entry_count is the
                # same fail-closed posture as the Rust decoder.
                health_malformed.append((s, len(p), v))
                continue
            off += 1
            cap_failed = False
            for _ in range(entry_count):
                if off + 1 > len(p):
                    cap_failed = True
                    break
                id_len = p[off]
                off += 1
                if off + id_len + 8 > len(p):
                    cap_failed = True
                    break
                bundle = p[off:off + id_len].decode("utf-8", errors="replace")
                off += id_len
                (counter,) = struct.unpack_from("<Q", p, off)
                off += 8
                failsafe_by_app.append((bundle, counter))
            if cap_failed or off + 4 + 8 + 8 != len(p):
                health_malformed.append((s, len(p), v))
                continue
            (cpu_pct_micro,) = struct.unpack_from("<I", p, off)
            off += 4
            (rss_bytes,) = struct.unpack_from("<Q", p, off)
            off += 8
            (tracker_alive_at_us,) = struct.unpack_from("<Q", p, off)
        else:
            health_malformed.append((s, len(p), v))
            continue
        health_parsed.append({
            "seq": s,
            "uptime_ms": uptime_ms,
            "frames_delivered": frames_delivered,
            "frames_suppressed": frames_suppressed,
            "frames_redacted_by_failsafe": frames_redacted_by_failsafe,
            "cascade_forced_count": cascade_forced_count,
            "frames_dropped_backpressure": frames_dropped_backpressure,
            "frames_dropped_late_ack": frames_dropped_late_ack,
            "frames_encode_failed": frames_encode_failed,
            "frames_focus_race_dropped": frames_focus_race_dropped,
            "failsafe_by_app": failsafe_by_app,
            "cpu_pct_micro": cpu_pct_micro,
            "rss_bytes": rss_bytes,
            "tracker_alive_at_us": tracker_alive_at_us,
        })

    reason_hist = Counter()
    bad_reason_seqs = []
    for s, p in tombstones:
        # payload = tsUs(u64) + appBundle(u16 len + utf8) + reason(u8)
        r = None
        if len(p) >= 1:
            r = p[-1]
        reason_hist[REASON.get(r, f"UNKNOWN({r})")] += 1
        if r != 7:
            bad_reason_seqs.append((s, r))

    # seq contiguity of the tombstone stream (the pipeline's own
    # FrameSequence). A missing seq value = a seq allocated with no
    # frame emitted = an `.allow` happened. Fail-safe predicts NONE.
    tomb_seqs = sorted(s for s, _ in tombstones)
    seq_gaps = []
    if tomb_seqs:
        lo, hi = tomb_seqs[0], tomb_seqs[-1]
        present = set(tomb_seqs)
        seq_gaps = [x for x in range(lo, hi + 1) if x not in present]
        dups = [x for x, c in Counter(tomb_seqs).items() if c > 1]
    else:
        lo = hi = None
        dups = []

    print(f"file              : {path} ({n} bytes)")
    print(f"frames decoded    : {len(frames)}")
    for k in sorted(by_type):
        print(f"  {k:<22}: {by_type[k]}")
    if truncated_tail:
        print(f"truncated tail    : {truncated_tail} bytes (Ctrl-C mid-write — tolerated, not corruption)")
    for c in corrupt:
        print(f"CORRUPT           : {c}")

    print("--- PrivacyTombstone ---")
    print(f"  count           : {len(tombstones)}")
    if tomb_seqs:
        print(f"  seq range       : {lo}..{hi}  (expected contiguous, step 1, no gaps)")
        print(f"  seq gaps        : {len(seq_gaps)}" + (f"  -> {seq_gaps[:50]}{' …' if len(seq_gaps) > 50 else ''}" if seq_gaps else "  (none)"))
        print(f"  seq duplicates  : {len(dups)}" + (f"  -> {dups[:20]}" if dups else "  (none)"))
    print(f"  reason histogram: {dict(reason_hist)}")
    print("--- StateTransitionEvent (0x0010) ---")
    print(f"  count           : {len(state_events)}  (MUST be 0 — any > 0 = pixels/event reached IPC)")

    # ---- OCREvent (wire 0x04) ----
    ocr_parsed = []
    ocr_malformed = []
    ocr_text_bytes_total = 0
    for s, p in ocr_events:
        parsed = parse_ocr_event_payload(p)
        if parsed is None:
            ocr_malformed.append((s, len(p)))
            continue
        ocr_parsed.append((s, parsed))
        ocr_text_bytes_total += parsed["ocr_text_len"]
    print("--- OCREvent (0x0040) — ADR-0016 P3.6 user-content channel ---")
    print(f"  count           : {len(ocr_events)}")
    if ocr_malformed:
        print(f"  MALFORMED       : {len(ocr_malformed)} frame(s) — short / over-cap")
        for s, ln in ocr_malformed[:10]:
            print(f"    seq={s} len={ln}")
    if ocr_parsed:
        print(f"  total ocr_text  : {ocr_text_bytes_total} bytes across {len(ocr_parsed)} event(s)")
        sample = ocr_parsed[0][1]
        print(f"  first event     : seq={ocr_parsed[0][0]}  app={sample['app_bundle_id']!r}")
        print(f"                    title={sample['window_title']!r}  url={sample['url']!r}")
        print(f"                    ocr_text_len={sample['ocr_text_len']}")

    # ---- HelperHealth (wire 0x09 — failsafe_by_app + cpu/rss/tracker added) ----
    print("--- HelperHealth (0x0030) ---")
    print(f"  count           : {len(health_frames)}")
    if health_malformed:
        print(
            f"  MALFORMED       : {len(health_malformed)} frame(s) — payload len mismatch "
            f"(expected {HELPER_HEALTH_PAYLOAD_V07} bytes @ v0x07, "
            f"{HELPER_HEALTH_PAYLOAD_V08} @ v0x08, or ≥{HELPER_HEALTH_PAYLOAD_V09_MIN_WITH_EMPTY_MAP} @ v0x09)"
        )
        for s, ln, vv in health_malformed[:10]:
            print(f"    seq={s} ver=0x{vv:02X} len={ln}")
    if health_parsed:
        # Per-message: print the last one's snapshot — usually the most
        # interesting at end-of-run.
        last = health_parsed[-1]
        print(f"  last snapshot   : seq={last['seq']}  uptime_ms={last['uptime_ms']}")
        print(f"                    frames_delivered={last['frames_delivered']}")
        print(f"                    frames_suppressed={last['frames_suppressed']}")
        print(f"                    frames_redacted_by_failsafe={last['frames_redacted_by_failsafe']}")
        print(f"                    cascade_forced_count={last['cascade_forced_count']}")
        print(f"                    frames_dropped_backpressure={last['frames_dropped_backpressure']}")
        print(f"                    frames_dropped_late_ack={last['frames_dropped_late_ack']}")
        print(f"                    frames_encode_failed={last['frames_encode_failed']}")
        print(f"                    frames_focus_race_dropped={last['frames_focus_race_dropped']}")
        # PR #226 §5.1 (1) surface — `failsafe-by-app: bundle=N, ...`
        # mci-agent --health-summary mirrors this same shape from the
        # JSONL log; the wire_decode.py output here is the per-frame
        # view (vs aggregate).
        if last["failsafe_by_app"]:
            pairs = ", ".join(f"{b}={c}" for b, c in last["failsafe_by_app"])
            print(f"                    failsafe-by-app: {pairs}")
        else:
            print(f"                    failsafe-by-app: none")
        # Wire-0x09 footprint sample pair.
        cpu_pct = last["cpu_pct_micro"] / 10_000.0
        rss_mib = last["rss_bytes"] / (1024.0 * 1024.0)
        print(f"                    cpu={cpu_pct:.3f}%  rss={rss_mib:.1f}MiB")
        print(f"                    tracker_alive_at_us={last['tracker_alive_at_us']}")
        # End-of-stream running totals: each counter is monotonic, so
        # the final HelperHealth carries the run totals. We print them
        # explicitly alongside the per-message snapshot for the
        # Telemetry-Gap analyst's static-secure-surface signal.
        print(
            f"  running totals  : frames_redacted_by_failsafe={last['frames_redacted_by_failsafe']}  "
            f"cascade_forced_count={last['cascade_forced_count']}  "
            f"frames_encode_failed={last['frames_encode_failed']}  "
            f"frames_focus_race_dropped={last['frames_focus_race_dropped']}"
        )

    if verbose:
        # Per-frame dump for temporal correlation against a paper log
        # (e.g. "sudo prompt opened at T+30s → which tombstone seqs
        # cluster around T+30s?"). Tombstones get ts_us + reason +
        # appBundle parsed out; other message types print the raw
        # msg_type + seq + payload size.
        print("--- per-frame (verbose) ---")
        print(f"  {'idx':>5}  {'msg_type':<22}  {'seq':>10}  {'ts_us':>17}  {'reason':<22}  app_bundle")
        for i, (m, _v, seq, p) in enumerate(frames):
            mname = MSG.get(m, f"unknown(0x{m:04X})")
            if m == 0x0011:
                ts_us, app, r = parse_tombstone_payload(p)
                rname = REASON.get(r, f"UNKNOWN({r})") if r is not None else "<no-payload>"
                ts_str = f"{ts_us}" if ts_us is not None else "-"
                app_str = app if app is not None else ""
                print(f"  {i:>5}  {mname:<22}  {seq:>10}  {ts_str:>17}  {rname:<22}  {app_str}")
            else:
                print(f"  {i:>5}  {mname:<22}  {seq:>10}  {'-':>17}  {'-':<22}  <payload={len(p)}B>")

    # ---- mechanical verdict ----
    fails = []
    if state_events:
        fails.append(f"{len(state_events)} StateTransitionEvent frame(s) emitted (expected 0)")
    if bad_reason_seqs:
        fails.append(f"{len(bad_reason_seqs)} tombstone(s) with reason != 7: {bad_reason_seqs[:20]}")
    if seq_gaps:
        fails.append(f"{len(seq_gaps)} tombstone seq gap(s) — evidence of an `.allow` decision: {seq_gaps[:20]}")
    if dups:
        fails.append(f"{len(dups)} duplicate tombstone seq(s): {dups[:20]}")
    if not tombstones and not state_events:
        fails.append("no tombstones AND no state events — callback likely never fired "
                      "(check Screen-Recording grant / stderr / early-abort criteria)")

    print("=== STEP-1 SHAPE VERDICT ===")
    if fails:
        print("  RESULT: NEEDS-REVIEW (not a clean pass)")
        for x in fails:
            print(f"   - {x}")
        return 1
    print("  RESULT: PASS — merged shapes behaved as predicted:")
    print("   - zero StateTransitionEvent (no pixels/event crossed IPC)")
    print("   - every tombstone reason == 7 (failsafe-unknown — fail-closed on real pixels)")
    print("   - tombstone seq contiguous, no gaps (zero `.allow` — PR-1/PR-2 path correct)")
    print("  NOTE: proves PR-1 (live SCStream+callback+extract) + PR-2 (retain→lease, no")
    print("        stall over the run). Does NOT prove PR-3 encode, §7 corpus, or G2 footprint.")
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="READ-ONLY decoder for the MCI helper IPC wire stream.",
        epilog="Outputs an aggregate report by default. Use --verbose for "
               "per-frame rows useful for temporal correlation against a paper log "
               "during Step-2 §7 corpus runs.",
    )
    parser.add_argument(
        "path",
        help="path to a helper --output file (binary wire stream)",
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="dump per-frame rows (idx, msg_type, seq, ts_us, reason, appBundle)",
    )
    args = parser.parse_args()
    sys.exit(main(args.path, args.verbose))
