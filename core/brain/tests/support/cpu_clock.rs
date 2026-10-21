//! This thread's CPU clock, for the timing tests whose budgets are CPU
//! work. A Mac busy with other builds keeps a test waiting for a core, and
//! that wait is not the code's cost; the wall clock counts it, this clock
//! doesn't. `tier2_footprint.rs` checks the clock itself.

use std::time::Duration;

/// The CPU time this thread has used so far.
pub fn thread_cpu_time() -> Duration {
    let mut now = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: clock_gettime only writes the timespec it is given, which
    // lives on this stack frame for the whole call.
    let rc = unsafe { libc::clock_gettime(libc::CLOCK_THREAD_CPUTIME_ID, &raw mut now) };
    assert_eq!(rc, 0, "clock_gettime(CLOCK_THREAD_CPUTIME_ID) failed");
    Duration::new(
        u64::try_from(now.tv_sec).expect("CPU seconds are never negative"),
        u32::try_from(now.tv_nsec).expect("nanoseconds fit in u32"),
    )
}

/// The CPU time this thread has used since `start`, a reading of
/// `thread_cpu_time`.
pub fn cpu_since(start: Duration) -> Duration {
    thread_cpu_time()
        .checked_sub(start)
        .expect("the CPU clock never runs backwards")
}
