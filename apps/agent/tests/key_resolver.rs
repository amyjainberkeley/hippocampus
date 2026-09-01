//! Privacy gate tests for SQLCipher key custody.

use std::cell::RefCell;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

use mci_agent::key_resolver::{
    initialize_database_key_with, is_valid_database_key, mcp_registration_env,
    resolve_database_key_with_reader, KeyInitializationOutcome, KeyResolutionError,
    KeychainAclContract, KeychainKeyReference, KeychainReader, KeychainWriter,
    DEFAULT_KEYCHAIN_ACCOUNT, DEFAULT_KEYCHAIN_SERVICE,
};

struct FakeKeychainReader {
    values: HashMap<(String, String), String>,
}

struct FakeKeychainWriter {
    writes: RefCell<Vec<String>>,
    error: Option<KeyResolutionError>,
}

impl FakeKeychainWriter {
    fn succeeding() -> Self {
        Self {
            writes: RefCell::new(Vec::new()),
            error: None,
        }
    }
}

impl KeychainWriter for FakeKeychainWriter {
    fn add_generic_password(
        &self,
        _service: &str,
        _account: &str,
        secret: &str,
        trusted_application_paths: &[PathBuf],
    ) -> Result<(), KeyResolutionError> {
        if let Some(error) = &self.error {
            return Err(error.clone());
        }
        assert_eq!(
            trusted_application_paths,
            trusted_application_paths_fixture()
        );
        self.writes.borrow_mut().push(secret.to_owned());
        Ok(())
    }
}

fn trusted_application_paths_fixture() -> Vec<PathBuf> {
    ["Hippocampus", "MCICaptureHelper", "mci-agent", "recall-ui"]
        .iter()
        .map(|name| Path::new("/Applications/Hippocampus.app/Contents/MacOS").join(name))
        .collect()
}

impl FakeKeychainReader {
    fn with_default_key(hex: &str) -> Self {
        let mut values = HashMap::new();
        values.insert(
            (
                DEFAULT_KEYCHAIN_SERVICE.to_owned(),
                DEFAULT_KEYCHAIN_ACCOUNT.to_owned(),
            ),
            hex.to_owned(),
        );
        Self { values }
    }
}

impl KeychainReader for FakeKeychainReader {
    fn read_generic_password(
        &self,
        service: &str,
        account: &str,
    ) -> Result<String, KeyResolutionError> {
        self.values
            .get(&(service.to_owned(), account.to_owned()))
            .cloned()
            .ok_or(KeyResolutionError::MissingKey {
                service: service.to_owned(),
                account: account.to_owned(),
            })
    }
}

#[test]
fn key_resolution_accepts_an_injected_keychain_reader() {
    let expected = "ab".repeat(32);
    let reader = FakeKeychainReader::with_default_key(&expected);

    let actual = resolve_database_key_with_reader(&reader, &KeychainKeyReference::default())
        .expect("resolve injected key");

    assert_eq!(actual, expected);
}

#[test]
fn key_resolution_rejects_malformed_keychain_material_without_echoing_it() {
    let reader = FakeKeychainReader::with_default_key("not-a-key");

    let err = resolve_database_key_with_reader(&reader, &KeychainKeyReference::default())
        .expect_err("malformed key should fail");
    let rendered = err.to_string();

    assert!(rendered.contains("64 hex"));
    assert!(!rendered.contains("not-a-key"));
}

#[test]
fn key_validation_rejects_unicode_hex_digits() {
    assert!(!is_valid_database_key(&"Ａ".repeat(64)));
}

#[test]
fn mcp_configuration_uses_keychain_reference_not_reusable_key_material() {
    let env = mcp_registration_env("/Users/amy/Library/Application Support/MCI/mci.sqlite");

    assert_eq!(
        env.get("MCI_DB_KEYCHAIN_SERVICE").map(String::as_str),
        Some(DEFAULT_KEYCHAIN_SERVICE)
    );
    assert_eq!(
        env.get("MCI_DB_KEYCHAIN_ACCOUNT").map(String::as_str),
        Some(DEFAULT_KEYCHAIN_ACCOUNT)
    );
    assert!(env.contains_key("MCI_DB_PATH"));
    assert!(
        !env.contains_key("MCI_DB_KEY_HEX"),
        "MCP client config must not serialize the reusable database key"
    );
}

#[test]
fn initialization_creates_a_key_only_after_proven_not_found() {
    struct MissingReader;
    impl KeychainReader for MissingReader {
        fn read_generic_password(
            &self,
            service: &str,
            account: &str,
        ) -> Result<String, KeyResolutionError> {
            Err(KeyResolutionError::MissingKey {
                service: service.to_owned(),
                account: account.to_owned(),
            })
        }
    }

    let writer = FakeKeychainWriter::succeeding();
    let generated = "cd".repeat(32);
    let outcome = initialize_database_key_with(
        &MissingReader,
        &writer,
        &KeychainKeyReference::default(),
        &trusted_application_paths_fixture(),
        || Ok(generated.clone()),
    )
    .expect("missing item should be created");

    assert_eq!(outcome, KeyInitializationOutcome::Created);
    assert_eq!(writer.writes.borrow().as_slice(), &[generated]);
}

#[test]
fn initialization_never_writes_after_access_denied() {
    struct DeniedReader;
    impl KeychainReader for DeniedReader {
        fn read_generic_password(
            &self,
            service: &str,
            account: &str,
        ) -> Result<String, KeyResolutionError> {
            Err(KeyResolutionError::AccessDenied {
                service: service.to_owned(),
                account: account.to_owned(),
            })
        }
    }

    let writer = FakeKeychainWriter::succeeding();
    let err = initialize_database_key_with(
        &DeniedReader,
        &writer,
        &KeychainKeyReference::default(),
        &trusted_application_paths_fixture(),
        || Ok("ef".repeat(32)),
    )
    .expect_err("denied reads must fail closed");

    assert!(matches!(err, KeyResolutionError::AccessDenied { .. }));
    assert!(writer.writes.borrow().is_empty());
}

#[test]
fn initialization_never_writes_when_keychain_is_locked() {
    struct LockedReader;
    impl KeychainReader for LockedReader {
        fn read_generic_password(
            &self,
            service: &str,
            account: &str,
        ) -> Result<String, KeyResolutionError> {
            Err(KeyResolutionError::InteractionNotAllowed {
                service: service.to_owned(),
                account: account.to_owned(),
            })
        }
    }

    let writer = FakeKeychainWriter::succeeding();
    let err = initialize_database_key_with(
        &LockedReader,
        &writer,
        &KeychainKeyReference::default(),
        &trusted_application_paths_fixture(),
        || Ok("01".repeat(32)),
    )
    .expect_err("locked Keychain must fail closed");

    assert!(matches!(
        err,
        KeyResolutionError::InteractionNotAllowed { .. }
    ));
    assert!(writer.writes.borrow().is_empty());
}

#[test]
fn acl_contract_resolves_exact_bundled_executables_without_keychain_access() {
    let temp = tempfile::tempdir().expect("temp app bundle");
    let contents = temp.path().join("Hippocampus.app/Contents");
    let macos = contents.join("MacOS");
    let resources = contents.join("Resources");
    std::fs::create_dir_all(&macos).expect("create MacOS directory");
    std::fs::create_dir_all(&resources).expect("create Resources directory");
    for name in ["Hippocampus", "MCICaptureHelper", "mci-agent", "recall-ui"] {
        std::fs::write(macos.join(name), []).expect("create bundled executable fixture");
    }
    std::fs::write(
        resources.join("keychain-sharing-contract.json"),
        r#"{
          "storage_model": "file-keychain-acl-v1",
          "service": "ai.hippocampus.brain",
          "account": "database-key-v1",
          "trusted_executables": ["Hippocampus", "MCICaptureHelper", "mci-agent", "recall-ui"],
          "use_data_protection_keychain": false,
          "synchronizable": false
        }"#,
    )
    .expect("write sharing contract fixture");

    let contract = KeychainAclContract::from_agent_executable(&macos.join("mci-agent"))
        .expect("valid bundled ACL contract");

    assert_eq!(
        contract.trusted_application_paths,
        ["Hippocampus", "MCICaptureHelper", "mci-agent", "recall-ui"]
            .iter()
            .map(|name| macos.join(name))
            .collect::<Vec<_>>()
    );
}

#[test]
fn acl_contract_fails_closed_when_a_trusted_executable_is_missing() {
    let temp = tempfile::tempdir().expect("temp app bundle");
    let contents = temp.path().join("Hippocampus.app/Contents");
    let macos = contents.join("MacOS");
    let resources = contents.join("Resources");
    std::fs::create_dir_all(&macos).expect("create MacOS directory");
    std::fs::create_dir_all(&resources).expect("create Resources directory");
    for name in ["Hippocampus", "MCICaptureHelper", "mci-agent"] {
        std::fs::write(macos.join(name), []).expect("create bundled executable fixture");
    }
    std::fs::write(
        resources.join("keychain-sharing-contract.json"),
        r#"{
          "storage_model": "file-keychain-acl-v1",
          "service": "ai.hippocampus.brain",
          "account": "database-key-v1",
          "trusted_executables": ["Hippocampus", "MCICaptureHelper", "mci-agent", "recall-ui"],
          "use_data_protection_keychain": false,
          "synchronizable": false
        }"#,
    )
    .expect("write sharing contract fixture");

    let error = KeychainAclContract::from_agent_executable(&macos.join("mci-agent"))
        .expect_err("missing ACL consumer must fail closed");

    assert!(matches!(error, KeyResolutionError::AclUnavailable { .. }));
}
