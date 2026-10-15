//! Lines to stdout and stderr that never panic.
//!
//! `println!` and `eprintln!` panic when a write fails. A write to a pipe
//! whose reader is gone fails with `EPIPE` (Rust ignores `SIGPIPE`, so the
//! write returns the error instead of ending the process), and a reader that
//! goes away is ordinary: an MCP client that quits, a hook runner that gives
//! up, `| head`. `mci-agent` then died with "failed printing to stderr:
//! Broken pipe" and left a crash record behind.
//!
//! Everything this crate prints goes through [`outln!`](crate::outln),
//! [`out!`](crate::out) and [`errln!`](crate::errln) instead, and
//! `apps/agent/clippy.toml` refuses the std macros so it stays that way. A
//! line nobody can read any more is dropped and the work goes on; a caller
//! that must know whether output arrived (the MCP stdio loop) writes through
//! a handle and handles the error itself.

use std::fmt;
use std::io::Write;

/// Print to stdout like `println!`. A closed or failing stdout drops the
/// line instead of panicking.
#[macro_export]
macro_rules! outln {
    () => {
        $crate::stdio::stdout_text(::std::format_args!(""), true)
    };
    ($($arg:tt)*) => {
        $crate::stdio::stdout_text(::std::format_args!($($arg)*), true)
    };
}

/// Print to stdout like `print!`. A closed or failing stdout drops the text
/// instead of panicking.
#[macro_export]
macro_rules! out {
    ($($arg:tt)*) => {
        $crate::stdio::stdout_text(::std::format_args!($($arg)*), false)
    };
}

/// Print to stderr like `eprintln!`. A closed or failing stderr drops the
/// line instead of panicking.
#[macro_export]
macro_rules! errln {
    () => {
        $crate::stdio::stderr_text(::std::format_args!(""), true)
    };
    ($($arg:tt)*) => {
        $crate::stdio::stderr_text(::std::format_args!($($arg)*), true)
    };
}

/// What [`outln!`](crate::outln) and [`out!`](crate::out) call.
#[doc(hidden)]
pub fn stdout_text(args: fmt::Arguments<'_>, newline: bool) {
    let _ = write_text(&mut std::io::stdout().lock(), args, newline);
}

/// What [`errln!`](crate::errln) calls.
#[doc(hidden)]
pub fn stderr_text(args: fmt::Arguments<'_>, newline: bool) {
    let _ = write_text(&mut std::io::stderr().lock(), args, newline);
}

/// Write `args`, then a line break when `newline`, and flush. The first
/// failure stops the write and is returned for the caller to drop.
///
/// # Errors
/// Whatever the writer returns.
pub fn write_text(
    writer: &mut impl Write,
    args: fmt::Arguments<'_>,
    newline: bool,
) -> std::io::Result<()> {
    writer.write_fmt(args)?;
    if newline {
        writer.write_all(b"\n")?;
    }
    writer.flush()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A reader that went away: every write and flush fails with `EPIPE`.
    struct ClosedPipe;

    impl Write for ClosedPipe {
        fn write(&mut self, _: &[u8]) -> std::io::Result<usize> {
            Err(std::io::ErrorKind::BrokenPipe.into())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Err(std::io::ErrorKind::BrokenPipe.into())
        }
    }

    #[test]
    fn a_closed_pipe_returns_the_error_instead_of_panicking() {
        let error = write_text(&mut ClosedPipe, format_args!("ready on {}", "stdio"), true)
            .expect_err("a closed pipe fails the write");
        assert_eq!(error.kind(), std::io::ErrorKind::BrokenPipe);
    }

    #[test]
    fn a_line_is_the_text_and_one_line_break() {
        let mut buffer = Vec::new();
        write_text(&mut buffer, format_args!("a {} c", "b"), true).unwrap();
        write_text(&mut buffer, format_args!("no break"), false).unwrap();
        assert_eq!(buffer, b"a b c\nno break");
    }

    #[test]
    fn the_macros_print_without_panicking() {
        crate::outln!();
        crate::outln!("stdio test line {}", 1);
        crate::out!("stdio test text\n");
        crate::errln!();
        crate::errln!("stdio test line {}", 2);
    }
}
