use mci_agent::child_command_environment::{sanitized_command, REUSABLE_KEY_ENVIRONMENT_VARIABLES};

#[test]
fn spawned_process_receives_no_reusable_key_environment() {
    let mut command = sanitized_command("/usr/bin/env");
    command.env("MCI_CHILD_ENV_MARKER", "preserved");
    for variable in REUSABLE_KEY_ENVIRONMENT_VARIABLES {
        command.env(variable, "must-not-reach-child");
    }
    // Scrub again after hostile configuration to prove the reusable helper is
    // the final command-construction boundary production callers rely on.
    mci_agent::child_command_environment::scrub_reusable_keys(&mut command);

    let output = command.output().expect("spawn /usr/bin/env");
    assert!(output.status.success());
    let received = String::from_utf8(output.stdout).expect("environment is UTF-8");
    assert!(received.contains("MCI_CHILD_ENV_MARKER=preserved"));
    for variable in REUSABLE_KEY_ENVIRONMENT_VARIABLES {
        assert!(
            !received
                .lines()
                .any(|line| line.starts_with(&format!("{variable}="))),
            "child received forbidden variable {variable}"
        );
    }
}

#[test]
fn brief_worker_uses_the_centralized_command_boundary() {
    let source = include_str!("../src/brief_worker.rs");
    assert!(source.contains("sanitized_command(\"date\")"));
    assert!(!source.contains("std::process::Command::new(\"date\")"));
}
