use std::path::PathBuf;

use mci_agent::retention_worker::load_retention_config;
use mci_brain::retention_purger::RetentionConfig;

#[test]
#[ignore = "run by scripts/test-retention-policy-contract.sh after the Swift picker fixture"]
fn picker_outputs_are_worker_compatible() {
    let root = PathBuf::from(
        std::env::var("MCI_RETENTION_PICKER_FIXTURE_DIR")
            .expect("MCI_RETENTION_PICKER_FIXTURE_DIR is required"),
    );
    let cases = [
        ("forever/retention.json", RetentionConfig::Forever),
        ("thirty-days/retention.json", RetentionConfig::Days(30)),
        ("seven-days/retention.json", RetentionConfig::Days(7)),
        ("custom-one/retention.json", RetentionConfig::Days(1)),
        ("custom/retention.json", RetentionConfig::Days(90)),
        ("custom-365/retention.json", RetentionConfig::Days(365)),
        ("replacement/retention.json", RetentionConfig::Days(90)),
        ("onboarding/retention.json", RetentionConfig::Days(7)),
        ("custom-zero/retention.json", RetentionConfig::Forever),
        ("custom-366/retention.json", RetentionConfig::Forever),
        ("custom-missing/retention.json", RetentionConfig::Forever),
        ("custom-overflow/retention.json", RetentionConfig::Forever),
    ];
    for (relative_path, expected) in cases {
        let path = root.join(relative_path);
        assert_eq!(
            load_retention_config(&path),
            expected,
            "case {relative_path}"
        );
    }
}
