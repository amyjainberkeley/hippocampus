// SPDX-License-Identifier: TBD-private
//
// FootprintSampler — per-flush helper CPU% + RSS sampler.
//
// PROTECTED-SET per AGENT_PROTOCOL §5 (helper-side observability).
//
// Pairs the wire-0x09 `cpu_pct_micro` + `rss_bytes` HelperHealth fields
// with concrete samplers. The Mach-backed production impl
// (`MachFootprintSampler`) reads:
//   - RSS via `task_info(MACH_TASK_BASIC_INFO)` — the Mach kernel API
//     that gives the helper's instantaneous resident set size in bytes.
//   - CPU time via `getrusage(RUSAGE_SELF)` — user + system tick total.
//     CPU % is computed as (rusage_delta_us / wall_delta_us) on each
//     sample, microfraction-scaled (1_000_000 = 100% of one core).
//
// The protocol indirection lets headless tests substitute a deterministic
// `StubFootprintSampler` without standing up real Mach calls.
//
// Pair with the MetricKit subscriber (also Phase 6 PR 6) for finer-
// than-daily-aggregate footprint observability against the G2-ratified
// ≤10-15% CPU / ≤2 GB RAM SLOs (AGENT_PROTOCOL §4 / S4 acceptance
// gate). MetricKit aggregates daily; this sampler runs per HelperHealth
// flush (default 30s cadence).

import Darwin
import Foundation

/// One footprint reading: instantaneous CPU + RSS at sample time.
/// Both fields are content-free numeric counters.
public struct FootprintReading: Sendable, Equatable {
    /// Instantaneous CPU % × 1_000_000 (microfraction). 1_000_000 =
    /// 100% of one core. 0 = sampler had no prior baseline to compute
    /// a delta against (first call in a process) OR the underlying
    /// syscall failed.
    public let cpuPctMicro: UInt32
    /// Instantaneous resident set size in bytes. 0 = sampler failed.
    public let rssBytes: UInt64
    public init(cpuPctMicro: UInt32, rssBytes: UInt64) {
        self.cpuPctMicro = cpuPctMicro
        self.rssBytes = rssBytes
    }
}

/// FootprintSampler — protocol for the CPU% + RSS source feeding
/// `HelperHealthCounters.snapshot()`. Sendable so the counters actor
/// can hold a sampler reference across task boundaries.
public protocol FootprintSampler: Sendable {
    /// Take one sample. `now` is the wall-clock at the calling
    /// HelperHealth flush; the sampler uses it to compute CPU time
    /// elapsed since its last sample.
    func sample(now: Date) -> FootprintReading
}

/// Production sampler — Mach `task_info` for RSS + `getrusage` for
/// CPU. Actor-isolated state (previous rusage + previous wall time)
/// so concurrent `sample()` calls (e.g. test storms) are serialized.
public final class MachFootprintSampler: FootprintSampler, @unchecked Sendable {
    // @unchecked Sendable because the mutable previous-sample state
    // is guarded by an OSAllocatedUnfairLock-equivalent (NSLock).
    // Swift 6 strict concurrency requires this attribution; a stricter
    // actor isolation would force every `snapshot()` caller through
    // an `await sampler.sample()` boundary, which is more ceremony
    // than the always-synchronous Mach calls warrant.
    private let lock = NSLock()
    private var prev: (timeMicros: UInt64, wallMillis: UInt64)?

    public init() {}

    public func sample(now: Date) -> FootprintReading {
        let rss = currentRSSBytes()
        let cpuTimeMicros = currentRUsageCPUMicros()

        let nowMillis = UInt64(max(0, now.timeIntervalSince1970 * 1000))

        let cpuPctMicro: UInt32
        lock.lock()
        defer { lock.unlock() }
        if let last = prev {
            let cpuDeltaMicros = cpuTimeMicros &- last.timeMicros
            let wallDeltaMillis = nowMillis &- last.wallMillis
            if wallDeltaMillis == 0 {
                cpuPctMicro = 0
            } else {
                // microfraction = cpuTime_us / wallTime_us
                // = cpuTime_us / (wallTime_ms * 1000)
                // × 1_000_000 (microfraction unit)
                // The two scaling factors cancel: result =
                //   cpuDeltaMicros * 1000 / wallDeltaMillis
                let cpuMicro = cpuDeltaMicros &* 1000 / wallDeltaMillis
                cpuPctMicro = UInt32(min(cpuMicro, UInt64(UInt32.max)))
            }
        } else {
            // First sample — no baseline. Convention: 0 (matches the
            // wire decoder default on a legacy-version frame).
            cpuPctMicro = 0
        }
        prev = (timeMicros: cpuTimeMicros, wallMillis: nowMillis)

        return FootprintReading(cpuPctMicro: cpuPctMicro, rssBytes: rss)
    }

    /// Mach `task_info(MACH_TASK_BASIC_INFO)` resident_size field, in
    /// bytes. 0 on syscall failure (extremely rare; would indicate a
    /// Mach kernel error).
    private func currentRSSBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    reboundPtr,
                    &count
                )
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return info.resident_size
    }

    /// `getrusage(RUSAGE_SELF)` user + system CPU time, in microseconds.
    /// 0 on syscall failure.
    private func currentRUsageCPUMicros() -> UInt64 {
        var ru = rusage()
        guard getrusage(RUSAGE_SELF, &ru) == 0 else { return 0 }
        let userMicros =
            UInt64(ru.ru_utime.tv_sec) &* 1_000_000 &+ UInt64(ru.ru_utime.tv_usec)
        let sysMicros =
            UInt64(ru.ru_stime.tv_sec) &* 1_000_000 &+ UInt64(ru.ru_stime.tv_usec)
        return userMicros &+ sysMicros
    }
}

/// Test-only deterministic sampler — returns whatever the test
/// installs. Use in `HelperHealthCounters.installFootprintSampler(...)`
/// to drive deterministic CPU + RSS values into `snapshot()` for
/// fixture tests.
public final class StubFootprintSampler: FootprintSampler, @unchecked Sendable {
    private let lock = NSLock()
    private var reading: FootprintReading

    public init(_ initial: FootprintReading = FootprintReading(cpuPctMicro: 0, rssBytes: 0)) {
        self.reading = initial
    }

    public func setReading(_ newReading: FootprintReading) {
        lock.lock()
        defer { lock.unlock() }
        reading = newReading
    }

    public func sample(now _: Date) -> FootprintReading {
        lock.lock()
        defer { lock.unlock() }
        return reading
    }
}
