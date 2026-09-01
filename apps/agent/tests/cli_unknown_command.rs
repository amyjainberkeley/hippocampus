//! A mistyped or not-yet-built subcommand used to print the usage text and
//! exit 0. That is the worst possible response: a human skims the help and
//! assumes it ran, and a wrapper script sees success and carries on.

use std::path::PathBuf;
use std::process::Command;

fn agent_bin() -> PathBuf {
    let mut path = std::env::current_exe().expect("current_exe");
    path.pop();
    if path.ends_with("deps") {
        path.pop();
    }
    path.push("mci-agent");
    path
}

#[test]
fn unknown_subcommand_fails_loudly() {
    let output = Command::new(agent_bin())
        .arg("totally-bogus-command")
        .output()
        .expect("spawn mci-agent");

    assert!(
        !output.status.success(),
        "an unknown subcommand must not exit 0"
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("totally-bogus-command"),
        "the error must name the command that was not understood, got: {stderr}"
    );
}

/// Flags are deliberately still tolerated: the Swift host passes its own,
/// and the two halves ship independently. Locking this in so the stricter
/// subcommand check is not later widened into an outage.
#[test]
fn unknown_flag_is_still_tolerated() {
    let output = Command::new(agent_bin())
        .arg("--some-future-flag")
        .arg("--version")
        .output()
        .expect("spawn mci-agent");

    assert!(
        output.status.success(),
        "an unknown flag must not break a host that ships out of step"
    );
}

#[test]
fn help_and_version_still_exit_zero() {
    for arg in ["--help", "--version"] {
        let output = Command::new(agent_bin())
            .arg(arg)
            .output()
            .expect("spawn mci-agent");
        assert!(output.status.success(), "{arg} must exit 0");
    }
}

/// An unknown flag's *value* is a bare token too. Rejecting it would
/// reintroduce exactly the ships-out-of-step outage the flag rule exists
/// to prevent, so the bare-token decision waits until the whole argv has
/// been read and fires only when nothing named a mode.
#[test]
fn an_unknown_flags_value_is_not_mistaken_for_a_command() {
    let output = Command::new(agent_bin())
        .arg("--some-future-flag")
        .arg("/some/path")
        .arg("--version")
        .output()
        .expect("spawn mci-agent");

    assert!(
        output.status.success(),
        "a future flag carrying a value must not break a host that ships out of step; stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

/// The loud path must still be loud when there is genuinely no mode.
#[test]
fn a_bare_token_with_no_mode_anywhere_still_fails() {
    let output = Command::new(agent_bin())
        .arg("--some-future-flag")
        .arg("totally-bogus-command")
        .output()
        .expect("spawn mci-agent");

    assert!(
        !output.status.success(),
        "no mode was named, so this must not exit 0"
    );
}
