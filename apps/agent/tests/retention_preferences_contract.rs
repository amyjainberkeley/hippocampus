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
        ("forever", RetentionConfig::Forever),
        ("thirty-days", RetentionConfig::Days(30)),
        ("seven-days", RetentionConfig::Days(7)),
        ("custom", RetentionConfig::Days(90)),
        ("replacement", RetentionConfig::Days(90)),
    ];
    for (name, expected) in cases {
        let path = root.join(name).join("retention.json");
        assert_eq!(load_retention_config(&path), expected, "case {name}");
    }
}
