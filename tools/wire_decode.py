#!/usr/bin/env python3
# SPDX-License-Identifier: TBD-private
#
# wire_decode.py — READ-ONLY decoder for the MCI helper IPC wire stream.
#
# This tool touches NO protected-set code (AGENT_PROTOCOL §5). It only
# parses a `--output` file produced by `mci-capture-helper`. It is the
# observation harness for Track B · Step 1 (live SCStream runtime
# verification of the merged `// UNVERIFIED` shapes).
#
# Wire format mirrors `adapters/macos/.../IPC/Wire.swift` /
# `core/src/ipc/wire.rs` (binary, little-endian):
#
#   magic(1=0x4D) + version(1=0x01) + msg_type(2) + seq(8) + len(4) + payload(len)
#
# msg_type discriminants (MUST match Wire.swift `MessageType`):
#   0x0001 captureStart   0x0002 captureStop
#   0x0010 stateTransitionEvent   0x0011 privacyTombstone
#   0x0020 surfaceReleased        0x0030 helperHealth
#
# RedactionReason byte (PrivacyTombstone payload tail; MUST match
# RedactionReason.swift): 1 denylist-source · 2 os-blacked-region ·
# 3 secure-event-input · 4 ax-secure-subrole · 5 denylist-postcapture ·
# 7 failsafe-unknown
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

import sys
import struct
from collections import Counter

MAGIC = 0x4D
VERSION = 0x01
HEADER = 1 + 1 + 2 + 8 + 4  # 16 bytes

MSG = {
    0x0001: "captureStart",
    0x0002: "captureStop",
    0x0010: "stateTransitionEvent",
    0x0011: "privacyTombstone",
    0x0020: "surfaceReleased",
    0x0030: "helperHealth",
}
REASON = {
    1: "denylist-source",
    2: "os-blacked-region",
    3: "secure-event-input",
    4: "ax-secure-subrole",
    5: "denylist-postcapture",
    7: "failsafe-unknown",
}


def main(path):
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
        if magic != MAGIC or ver != VERSION:
            corrupt.append(
                f"@{off}: bad header magic=0x{magic:02X} ver=0x{ver:02X} "
                f"(expected 0x4D/0x01) — stopping decode here"
            )
            break
        if n - off - HEADER < plen:
            # final frame truncated by Ctrl-C mid-write — tolerated.
            truncated_tail = n - off
            break
        payload = buf[off + HEADER: off + HEADER + plen]
        frames.append((mtype, seq, payload))
        off += HEADER + plen

    by_type = Counter(MSG.get(m, f"unknown(0x{m:04X})") for m, _, _ in frames)
    tombstones = [(s, p) for (m, s, p) in frames if m == 0x0011]
    state_events = [(s, p) for (m, s, p) in frames if m == 0x0010]

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
    if len(sys.argv) != 2:
        sys.stderr.write("usage: wire_decode.py <helper --output file>\n")
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
