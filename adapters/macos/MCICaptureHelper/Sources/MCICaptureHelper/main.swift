// SPDX-License-Identifier: TBD-private
//
// MCI macOS capture helper — executable entry point.
//
// Per ADR-0007 the helper is launched by the Rust core as a child process
// over a pre-opened `AF_UNIX` socketpair. Phase-1 cycle 2+ wires the
// SCStream lifecycle, VideoToolbox encoder, and the IPC reader/writer.
// This cycle (Phase-1 cycle 1) lands the helper-library structure +
// suppression cascade + dHash dual-threshold + wire-format mirror, all
// testable headlessly.
//
// Running this binary today prints a one-line banner and exits — it is a
// PLACEHOLDER deliberately, so that `swift build` produces a notarizable
// Mach-O the next cycle can fill in. The cascade library is consumable
// from XCTest today.

import Foundation
import MCICaptureHelperKit

let helperVersion = "0.0.1-phase1-cycle1"

let banner = """
mci-capture-helper \(helperVersion)
  ADR-0007 macOS Swift helper (Phase-1 skeleton).
  ADR-0013 sensitive-surface suppression cascade: LINKED, awaiting
  SCStream lifecycle wiring (Phase-1 cycle 2+).
"""

print(banner)
exit(0)
