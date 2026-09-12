//! Environment policy for every child process owned by an agent binary.

use std::ffi::OsStr;
use std::process::Command;

/// Reusable secret or legacy-authority variables that must never cross an
/// agent-owned process boundary.
pub const REUSABLE_KEY_ENVIRONMENT_VARIABLES: [&str; 4] = [
    "MCI_DB_KEY_HEX",
    "MCI_DB_KEY_FILE",
    "MCI_DEVELOPMENT_FILE_KEY",
    "HIPPOCAMPUS_ENABLE_V2P1",
];

/// Construct a child command with reusable key variables removed from its
/// inherited environment.
pub fn sanitized_command<S: AsRef<OsStr>>(program: S) -> Command {
    let mut command = Command::new(program);
    scrub_reusable_keys(&mut command);
    command
}

/// Remove reusable key variables after all other command configuration.
pub fn scrub_reusable_keys(command: &mut Command) {
    for variable in REUSABLE_KEY_ENVIRONMENT_VARIABLES {
        command.env_remove(variable);
    }
}
