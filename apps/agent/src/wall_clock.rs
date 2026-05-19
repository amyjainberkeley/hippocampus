//! Wall-clock helper. RFC-3339 UTC timestamps for the
//! `HealthLogRecord::wall_ts` field.
//!
//! Hand-rolled formatter — no `chrono` / `time` crate dep, in line
//! with the CRS Security-Signal stance (iter-7 memo) on minimizing
//! the dep surface. The format is a strict subset of RFC-3339:
//! `YYYY-MM-DDTHH:MM:SS.sssZ` (UTC, millisecond precision, `Z`
//! suffix). Sufficient for the live-workday measurement protocol +
//! human-readable in the log.
//!
//! The clock is abstracted behind a [`WallClock`] trait so tests can
//! drive deterministic timestamps. Production uses [`SystemWallClock`]
//! which calls `SystemTime::now()`.

use std::time::{SystemTime, UNIX_EPOCH};

/// Wall-clock abstraction. Production = [`SystemWallClock`]; tests
/// inject a fixed-instant fake.
pub trait WallClock: Send + Sync {
    /// Render the current time as RFC-3339 UTC,
    /// `YYYY-MM-DDTHH:MM:SS.sssZ`.
    fn now_rfc3339(&self) -> String;
}

/// Production wall clock backed by `SystemTime::now()`.
#[derive(Debug, Default)]
pub struct SystemWallClock;

impl WallClock for SystemWallClock {
    fn now_rfc3339(&self) -> String {
        let now = SystemTime::now();
        let dur = now
            .duration_since(UNIX_EPOCH)
            .unwrap_or(std::time::Duration::ZERO);
        format_unix_ms(dur.as_millis())
    }
}

/// Format a `unix_ms` value (milliseconds since epoch) as
/// `YYYY-MM-DDTHH:MM:SS.sssZ`. UTC; ignores leap seconds.
///
/// Pure-arithmetic implementation; no allocations beyond the output
/// `String`. Handles years 1970..=9999.
#[must_use]
#[allow(
    clippy::cast_possible_truncation,
    clippy::cast_possible_wrap,
    clippy::cast_sign_loss
)]
pub fn format_unix_ms(unix_ms: u128) -> String {
    // Total seconds + sub-second ms.
    let total_secs: u128 = unix_ms / 1000;
    let ms: u128 = unix_ms % 1000;

    // Time of day.
    let secs_in_day: u128 = total_secs % 86_400;
    let hour = (secs_in_day / 3600) as u32;
    let minute = ((secs_in_day % 3600) / 60) as u32;
    let second = (secs_in_day % 60) as u32;

    // Date (days since 1970-01-01).
    let mut days: i64 = (total_secs / 86_400) as i64;

    // Calendar conversion using a well-known algorithm.
    // Reference: Howard Hinnant's "date" library / civil_from_days.
    // We use the algorithm directly (small, no deps).
    days += 719_468; // shift to 0000-03-01 epoch
    let era = if days >= 0 { days } else { days - 146_096 } / 146_097;
    let doe = (days - era * 146_097) as u64; // [0, 146097)
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if m <= 2 { y + 1 } else { y };

    format!("{year:04}-{m:02}-{d:02}T{hour:02}:{minute:02}:{second:02}.{ms:03}Z")
}

/// Test support helpers — gated on `cfg(test)` so production builds
/// don't pull them in.
#[cfg(test)]
pub mod test_support {
    use super::*;
    use std::sync::Mutex;

    /// Deterministic clock for tests — returns a fixed RFC-3339 string
    /// the test set up front. Optional advance via `advance_ms` is
    /// available if a test wants to verify ordering.
    pub struct FixedClock {
        inner: Mutex<u128>,
    }

    impl FixedClock {
        /// Construct a fixed clock anchored at `ms` (milliseconds
        /// since Unix epoch). Calls to `now_rfc3339()` render this
        /// value plus any subsequent `advance_ms` deltas.
        #[must_use]
        pub fn at_unix_ms(ms: u128) -> Self {
            Self {
                inner: Mutex::new(ms),
            }
        }

        /// Advance the clock by `delta` milliseconds.
        pub fn advance_ms(&self, delta: u128) {
            let mut g = self.inner.lock().expect("FixedClock mutex");
            *g += delta;
        }
    }

    impl WallClock for FixedClock {
        fn now_rfc3339(&self) -> String {
            let ms = *self.inner.lock().expect("FixedClock mutex");
            format_unix_ms(ms)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::FixedClock;
    use super::*;

    #[test]
    fn epoch_renders_as_1970() {
        assert_eq!(format_unix_ms(0), "1970-01-01T00:00:00.000Z");
    }

    #[test]
    fn one_second_after_epoch() {
        assert_eq!(format_unix_ms(1000), "1970-01-01T00:00:01.000Z");
    }

    #[test]
    fn millisecond_precision_preserved() {
        assert_eq!(format_unix_ms(1234), "1970-01-01T00:00:01.234Z");
    }

    #[test]
    fn known_recent_timestamp_renders_correctly() {
        // 2026-05-19T04:00:00.000Z computed from the calendar:
        //   days 1970-01-01..2026-01-01 = 56*365 + 14 leap = 20454
        //   days 2026-01-01..2026-05-19 = 31+28+31+30+18 = 138
        //   total days = 20592; +4h = 20592*86400 + 14400 = 1_779_163_200 s
        let ts = 1_779_163_200_000_u128;
        assert_eq!(format_unix_ms(ts), "2026-05-19T04:00:00.000Z");
    }

    #[test]
    fn handles_leap_year_february_29() {
        // 2024-02-29T12:34:56.789Z:
        //   days 1970-01-01..2024-01-01 = 54*365 + 13 leap = 19723
        //   days 2024-01-01..2024-02-29 = 31 + 28 = 59
        //   total days = 19782; +12h 34m 56s = 19782*86400 + 45296 = 1_709_210_096 s
        let ts = 1_709_210_096_789_u128;
        assert_eq!(format_unix_ms(ts), "2024-02-29T12:34:56.789Z");
    }

    #[test]
    fn end_of_day_rolls_over_correctly() {
        // 2026-05-19T23:59:59.999Z = 1 ms before 2026-05-20T00:00:00Z.
        // 2026-05-19T04:00:00Z is 1_779_163_200_000 ms (verified in the
        // test above). 23:59:59.999 - 04:00:00.000 = 71_999_999 ms.
        // 1_779_163_200_000 + 71_999_999 = 1_779_235_199_999.
        let ts = 1_779_235_199_999_u128;
        assert_eq!(format_unix_ms(ts), "2026-05-19T23:59:59.999Z");
    }

    #[test]
    fn end_of_month_rolls_over() {
        // 2026-12-31T23:59:59.000Z = 1_798_761_599_000 ms.
        let ts = 1_798_761_599_000_u128;
        assert_eq!(format_unix_ms(ts), "2026-12-31T23:59:59.000Z");
    }

    #[test]
    fn fixed_clock_returns_fixed_value() {
        let c = FixedClock::at_unix_ms(1_779_163_200_000);
        let s1 = c.now_rfc3339();
        let s2 = c.now_rfc3339();
        assert_eq!(s1, "2026-05-19T04:00:00.000Z");
        assert_eq!(s1, s2);
    }

    #[test]
    fn fixed_clock_advances() {
        let c = FixedClock::at_unix_ms(1_779_163_200_000);
        let s1 = c.now_rfc3339();
        c.advance_ms(1500);
        let s2 = c.now_rfc3339();
        assert_eq!(s1, "2026-05-19T04:00:00.000Z");
        assert_eq!(s2, "2026-05-19T04:00:01.500Z");
    }

    #[test]
    fn system_clock_renders_now_in_year_2026_or_later() {
        let c = SystemWallClock;
        let s = c.now_rfc3339();
        // Smoke check: the format is right + the year is plausible.
        assert!(s.ends_with('Z'));
        assert_eq!(s.len(), 24); // YYYY-MM-DDTHH:MM:SS.sssZ
        let year: u32 = s[..4].parse().expect("year is digits");
        assert!(year >= 2026, "got {year}");
    }
}
