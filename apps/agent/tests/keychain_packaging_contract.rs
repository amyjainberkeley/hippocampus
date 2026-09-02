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
        .find(
            "if [[ \"$SIGNING_MODE\" == \"developer-id\" ]]; then\n    echo \"Codesigning with Developer ID",
        )
        .expect("developer-id signing branch");
    let ad_hoc_start = script[developer_start..]
        .find("\nelse\n    echo \"Codesigning (development-only ad-hoc)...\"")
        .map(|offset| developer_start + offset)
        .expect("ad-hoc signing branch");
    let branch_end = script[ad_hoc_start..]
        .find("\nfi\n\nEXPECTED_SIGNED_TEAM_ID=")
        .map(|offset| ad_hoc_start + offset)
        .expect("signing branch end");
    let developer_branch = &script[developer_start..ad_hoc_start];
    let ad_hoc_branch = &script[ad_hoc_start..branch_end];

    for executable in TRUSTED_EXECUTABLE_NAMES {
        assert!(
            developer_branch.contains(&format!("$MACOS/{executable}")),
            "Developer ID branch must sign ACL consumer {executable}"
        );
        assert!(ad_hoc_branch.contains(&format!("$MACOS/{executable}")));
    }
    assert_eq!(
        developer_branch
            .matches("--entitlements \"$ENTITLEMENTS\"")
            .count(),
        2,
        "only the host executable and app bundle need the host App Group entitlement"
    );
    assert!(developer_branch.contains("--entitlements \"$APPEX_ENTITLEMENTS\""));
    assert_eq!(
        ad_hoc_branch
            .matches("--entitlements \"$ENTITLEMENTS\"")
            .count(),
        2
    );
    assert!(ad_hoc_branch.contains("--entitlements \"$APPEX_ENTITLEMENTS\""));
    assert!(!ad_hoc_branch.contains("codesign --force --deep --sign - \"$APP\""));
    assert!(script.contains("hippocampus_render_app_group_entitlements"));
    assert!(script.contains("--development-ad-hoc"));
    assert!(script.contains("Ad-hoc signing is development-only and requires --debug"));
    assert!(script.contains("Release assembly requires a stable Developer ID Application identity"));
}

#[test]
fn installer_requires_stable_identity_for_release_artifacts() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let installer = std::fs::read_to_string(root.join("scripts/build-installer.sh"))
        .expect("read build-installer.sh");
    let docs =
        std::fs::read_to_string(root.join("scripts/README.md")).expect("read scripts README");

    assert!(installer.contains("--development-ad-hoc"));
    assert!(installer.contains("Ad-hoc signing is development-only and requires --debug"));
    assert!(
        installer.contains("Release installer requires a stable Developer ID Application identity")
    );
    assert!(!installer.contains("falling back to ad-hoc"));

    let normalized_docs = docs
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase();
    assert!(normalized_docs.contains("developer id signed"));
    assert!(normalized_docs.contains("required for release"));
    assert!(normalized_docs.contains("development-only ad-hoc"));
    assert!(normalized_docs.contains("never a release artifact"));
    assert!(docs.contains("--debug --development-ad-hoc"));
    assert!(!docs.contains("Ad-hoc (default when no cert present)"));
}

#[test]
fn recall_links_only_the_staged_archive_for_the_requested_profile() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let package = std::fs::read_to_string(root.join("apps/recall-ui/Package.swift"))
        .expect("read Recall Package.swift");
    let wrapper = std::fs::read_to_string(root.join("scripts/swift-package.sh"))
        .expect("read SwiftPM wrapper");
    let stage = std::fs::read_to_string(root.join("scripts/stage-recall-ffi.sh"))
        .expect("read Recall FFI staging script");

    assert!(!package.contains("../../target/debug"));
    assert!(!package.contains("../../target/release"));
    assert!(package.contains(".build/mci-brain-ffi/debug"));
    assert!(package.contains(".build/mci-brain-ffi/release"));
    assert!(package.contains(".when(configuration: .debug)"));
    assert!(package.contains(".when(configuration: .release)"));
    assert!(wrapper.contains("stage-recall-ffi.sh"));
    assert!(stage.contains("cargo build --locked -p mci-brain-ffi"));
    assert!(stage.contains("libmci_brain_ffi.a"));
}

#[test]
fn packaged_consumers_have_a_two_version_stable_identity_check() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let verifier = std::fs::read_to_string(root.join("scripts/verify-keychain-acl-upgrade.sh"))
        .expect("read two-version ACL verifier");

    for executable in TRUSTED_EXECUTABLE_NAMES {
        assert!(verifier.contains(executable));
    }
    assert!(verifier.contains("codesign -d -r-"));
    assert!(verifier.contains("Signature=adhoc"));
}

#[test]
fn shipped_consumers_and_children_use_reference_only_custody() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let brain = std::fs::read_to_string(root.join("apps/agent/src/bin/mci_brain.rs"))
        .expect("read mci-brain");
    let status = std::fs::read_to_string(
        root.join("apps/hippocampus/Sources/Hippocampus/StatusMenuView.swift"),
    )
    .expect("read status menu");
    let onboarding = std::fs::read_to_string(
        root.join("apps/onboarding/Sources/Onboarding/LocalKeyGenerator.swift"),
    )
    .expect("read onboarding key preparer");

    assert!(brain.contains("resolve_database_key()"));
    assert!(brain.contains("MCI_DEVELOPMENT_FILE_KEY"));
    assert!(status.contains("sanitizedChildEnvironment()"));
    assert!(!status.contains("dev.key"));
    assert!(onboarding.contains("ensure-key"));
    assert!(!onboarding.contains("SecRandomCopyBytes"));
    assert!(!onboarding.contains("dev.key"));
}

#[test]
fn raw_key_demo_tools_require_the_explicit_development_gate() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    for path in [
        "apps/agent/src/bin/mci_seed_brain.rs",
        "apps/agent/src/bin/mci_seed_brief.rs",
        "scripts/demo.sh",
        "scripts/try-it.sh",
    ] {
        let source = std::fs::read_to_string(root.join(path)).expect("read development tool");
        assert!(source.contains("MCI_DEVELOPMENT_FILE_KEY"), "{path}");
    }
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
