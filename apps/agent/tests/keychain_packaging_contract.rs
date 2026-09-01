//! Content-free contract checks for the macOS file-Keychain ACL model.

use std::path::Path;

use mci_agent::key_resolver::{KEYCHAIN_STORAGE_MODEL, TRUSTED_EXECUTABLE_NAMES};

#[test]
fn manifest_and_rust_resolver_use_one_file_keychain_acl_contract() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let manifest_path = root
        .join("apps/hippocampus/Sources/HippocampusKit/Resources/keychain-sharing-contract.json");
    let manifest: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(&manifest_path).expect("read Keychain sharing manifest"),
    )
    .expect("parse Keychain sharing manifest");

    assert_eq!(manifest["storage_model"], KEYCHAIN_STORAGE_MODEL);
    assert_eq!(manifest["service"], "ai.hippocampus.brain");
    assert_eq!(manifest["account"], "database-key-v1");
    assert_eq!(
        manifest["trusted_executables"],
        serde_json::json!(TRUSTED_EXECUTABLE_NAMES)
    );
    assert_eq!(manifest["use_data_protection_keychain"], false);
    assert_eq!(manifest["synchronizable"], false);
}

#[test]
fn packaging_places_and_signs_every_acl_consumer_before_sealing_the_app() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let script = std::fs::read_to_string(root.join("apps/hippocampus/Resources/build-app.sh"))
        .expect("read build-app.sh");

    assert!(script
        .contains("cp \"$KEYCHAIN_CONTRACT_SRC\" \"$RESOURCES/keychain-sharing-contract.json\""));
    for executable in TRUSTED_EXECUTABLE_NAMES {
        assert!(
            script.contains(&format!("$MACOS/{executable}")),
            "build script must package/sign ACL consumer {executable}"
        );
    }

    let developer_start = script
        .rfind("if [[ \"$SIGNING_MODE\" == \"developer-id\" ]]")
        .expect("developer-id signing branch");
    let ad_hoc_start = script[developer_start..]
        .find("\nelse\n    echo \"Codesigning (ad-hoc)...\"")
        .map(|offset| developer_start + offset)
        .expect("ad-hoc signing branch");
    let branch_end = script[ad_hoc_start..]
        .find("\nfi\n\n# Verify rpath")
        .map(|offset| ad_hoc_start + offset)
        .expect("signing branch end");
    let developer_branch = &script[developer_start..ad_hoc_start];
    let ad_hoc_branch = &script[ad_hoc_start..branch_end];

    for executable in TRUSTED_EXECUTABLE_NAMES {
        assert!(
            developer_branch.contains(&format!("$MACOS/{executable}")),
            "Developer ID branch must sign ACL consumer {executable}"
        );
        assert!(
            ad_hoc_branch.contains(&format!("$MACOS/{executable}")),
            "ad-hoc branch must sign ACL consumer {executable}"
        );
    }
    assert!(
        developer_branch
            .matches("--entitlements \"$ENTITLEMENTS\"")
            .count()
            >= 4
    );
    assert!(ad_hoc_branch.contains("codesign --force --deep --sign - \"$APP\""));
}

#[test]
fn packaging_and_resolvers_pin_the_file_keychain_domain() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let entitlements =
        std::fs::read_to_string(root.join("apps/hippocampus/Resources/Hippocampus.entitlements"))
            .expect("read signing entitlements");
    assert!(!entitlements.contains("keychain-access-groups"));

    for path in [
        "apps/hippocampus/Sources/HippocampusKit/KeyStore.swift",
        "adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Security/KeychainDatabaseKeyResolver.swift",
        "apps/recall-ui/Sources/RecallUIKit/KeychainDatabaseKeyResolver.swift",
    ] {
        let source = std::fs::read_to_string(root.join(path)).expect("read Swift resolver");
        assert!(source.contains("kSecUseDataProtectionKeychain"), "{path}");
        assert!(source.contains("useDataProtectionKeychain: false"), "{path}");
        assert!(source.contains("kSecAttrSynchronizable"), "{path}");
        assert!(source.contains("synchronizable: false"), "{path}");
        assert!(source.contains("file-keychain-acl-v1"), "{path}");
    }

    let adapter = std::fs::read_to_string(root.join("adapters/macos/mci-keychain/src/lib.rs"))
        .expect("read Rust Keychain adapter");
    assert!(adapter.contains("kSecUseDataProtectionKeychain"));
    assert!(adapter.contains("kSecAttrSynchronizable"));
    assert!(adapter.contains("kSecMatchLimitOne"));
    assert!(adapter.matches("CFBoolean::false_value()").count() >= 2);
}

#[test]
fn agent_keeps_all_unsafe_keychain_ffi_in_the_native_adapter() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let agent = std::fs::read_to_string(root.join("apps/agent/src/bin/mci_agent.rs"))
        .expect("read mci-agent binary");
    let resolver = std::fs::read_to_string(root.join("apps/agent/src/key_resolver.rs"))
        .expect("read Rust key resolver");
    let adapter = std::fs::read_to_string(root.join("adapters/macos/mci-keychain/src/lib.rs"))
        .expect("read Rust Keychain adapter");

    assert!(agent.contains("#![forbid(unsafe_code)]"));
    assert!(!agent.contains("extern \"C\""));
    assert!(!agent.contains("SecItemAdd"));
    assert!(!resolver.contains("extern \"C\""));
    assert!(!resolver.contains("SecItemCopyMatching"));
    assert!(adapter.contains("extern \"C\""));
    assert!(adapter.contains("SecItemAdd"));
    assert!(adapter.contains("SecItemCopyMatching"));
}
