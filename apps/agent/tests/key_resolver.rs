//! Privacy gate tests for SQLCipher key custody.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::rc::Rc;

use mci_agent::key_resolver::{
    initialize_database_key_with, initialize_database_key_with_remover, is_valid_database_key,
    mcp_registration_env, resolve_database_key_with_reader, DatabaseKeyValidator,
    KeyInitializationOutcome, KeyResolutionError, KeychainAclContract, KeychainKeyReference,
    KeychainReader, KeychainWriter, LegacyKeyRemover, SqlCipherDatabaseKeyValidator,
    DEFAULT_KEYCHAIN_ACCOUNT, DEFAULT_KEYCHAIN_SERVICE,
};
use mci_brain::SqlCipherBrainStore;
use mci_core::crypto::DbKey;

struct FakeKeychainReader {
    values: HashMap<(String, String), String>,
}

struct FakeKeychainWriter {
    writes: RefCell<Vec<String>>,
    error: Option<KeyResolutionError>,
}

struct SharedKeychain {
    value: Rc<RefCell<Option<String>>>,
    read_error: Rc<RefCell<Option<KeyResolutionError>>>,
    add_error: RefCell<Option<KeyResolutionError>>,
    duplicate_value: RefCell<Option<String>>,
    writes: RefCell<Vec<String>>,
}

impl SharedKeychain {
    fn missing() -> Self {
        Self {
            value: Rc::new(RefCell::new(None)),
            read_error: Rc::new(RefCell::new(None)),
            add_error: RefCell::new(None),
            duplicate_value: RefCell::new(None),
            writes: RefCell::new(Vec::new()),
        }
    }
}

impl KeychainReader for SharedKeychain {
    fn read_generic_password(
        &self,
        service: &str,
        account: &str,
    ) -> Result<String, KeyResolutionError> {
        if let Some(error) = self.read_error.borrow().clone() {
            return Err(error);
        }
        self.value
            .borrow()
            .clone()
            .ok_or(KeyResolutionError::MissingKey {
                service: service.to_owned(),
                account: account.to_owned(),
            })
    }
}

impl KeychainWriter for SharedKeychain {
    fn add_generic_password(
        &self,
        _service: &str,
        _account: &str,
        secret: &str,
        trusted_application_paths: &[PathBuf],
    ) -> Result<(), KeyResolutionError> {
        assert_eq!(
            trusted_application_paths,
            trusted_application_paths_fixture()
        );
        self.writes.borrow_mut().push(secret.to_owned());
        if let Some(value) = self.duplicate_value.borrow_mut().take() {
            *self.value.borrow_mut() = Some(value);
            return Err(KeyResolutionError::KeyAlreadyExists);
        }
        if let Some(error) = self.add_error.borrow_mut().take() {
            return Err(error);
        }
        *self.value.borrow_mut() = Some(secret.to_owned());
        Ok(())
    }
}

struct RecordingValidator {
    accepted_key: String,
    calls: RefCell<Vec<String>>,
    fail_on_call: Option<usize>,
}

impl RecordingValidator {
    fn accepting(key: &str) -> Self {
        Self {
            accepted_key: key.to_owned(),
            calls: RefCell::new(Vec::new()),
            fail_on_call: None,
        }
    }
}

impl DatabaseKeyValidator for RecordingValidator {
    fn validate_existing_database(
        &self,
        _database_path: &Path,
        key: &str,
    ) -> Result<(), KeyResolutionError> {
        let call = self.calls.borrow().len() + 1;
        self.calls.borrow_mut().push(key.to_owned());
        if self.fail_on_call == Some(call) || key != self.accepted_key {
            return Err(KeyResolutionError::DatabaseValidationFailed);
        }
        Ok(())
    }
}

fn existing_database_fixture() -> (tempfile::TempDir, PathBuf, PathBuf) {
    let temp = tempfile::tempdir().expect("temp database fixture");
    let database = temp.path().join("mci.sqlite");
    let legacy = temp.path().join("dev.key");
    std::fs::write(&database, b"encrypted database fixture").expect("write database marker");
    (temp, database, legacy)
}

#[test]
fn production_validator_opens_existing_sqlcipher_schema_read_only() {
    let temp = tempfile::tempdir().expect("temp SQLCipher brain");
    let database = temp.path().join("mci.sqlite");
    let key_hex = "12".repeat(32);
    let key = DbKey::from_bytes([0x12; 32]);
    drop(SqlCipherBrainStore::new(&database, &key).expect("create migrated brain"));

    SqlCipherDatabaseKeyValidator
        .validate_existing_database(&database, &key_hex)
        .expect("real key should open and query schema");
    assert_eq!(
        SqlCipherDatabaseKeyValidator
            .validate_existing_database(&database, &"34".repeat(32))
            .expect_err("wrong key must fail"),
        KeyResolutionError::DatabaseValidationFailed
    );
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
fn clean_install_generates_only_when_no_database_exists_and_rereads_keychain() {
    let temp = tempfile::tempdir().expect("temp clean install");
    let database = temp.path().join("mci.sqlite");
    let legacy = temp.path().join("dev.key");
    let keychain = SharedKeychain::missing();
    let validator = RecordingValidator::accepting(&"ff".repeat(32));
    let generated = "cd".repeat(32);
    let generated_calls = Cell::new(0);

    let outcome = initialize_database_key_with(
        &keychain,
        &keychain,
        &validator,
        &KeychainKeyReference::default(),
        &trusted_application_paths_fixture(),
        &database,
        &legacy,
        || {
            generated_calls.set(generated_calls.get() + 1);
            Ok(generated.clone())
        },
    )
    .expect("clean install should create a key");

    assert_eq!(outcome, KeyInitializationOutcome::Created);
    assert_eq!(generated_calls.get(), 1);
    assert_eq!(keychain.writes.borrow().as_slice(), &[generated.clone()]);
    assert_eq!(keychain.value.borrow().as_ref(), Some(&generated));
    assert!(validator.calls.borrow().is_empty());
}

#[test]
fn valid_legacy_upgrade_validates_adds_rereads_revalidates_and_removes_plaintext() {
    let (_temp, database, legacy) = existing_database_fixture();
    let legacy_key = "ab".repeat(32);
    std::fs::write(&legacy, &legacy_key).expect("write legacy key");
    let keychain = SharedKeychain::missing();
    let validator = RecordingValidator::accepting(&legacy_key);

    let outcome = initialize_database_key_with(
        &keychain,
        &keychain,
        &validator,
        &KeychainKeyReference::default(),
        &trusted_application_paths_fixture(),
        &database,
        &legacy,
        || panic!("existing database must never generate"),
    )
    .expect("valid legacy database should migrate");

    assert_eq!(outcome, KeyInitializationOutcome::MigratedLegacyKey);
    assert_eq!(keychain.writes.borrow().as_slice(), &[legacy_key.clone()]);
    assert_eq!(
        validator.calls.borrow().as_slice(),
        &[legacy_key.clone(), legacy_key]
    );
    assert!(!legacy.exists(), "completed migration must remove dev.key");
}

#[test]
fn restart_after_add_revalidates_matching_legacy_and_removes_plaintext() {
    let (_temp, database, legacy) = existing_database_fixture();
    let legacy_key = "ab".repeat(32);
    std::fs::write(&legacy, &legacy_key).expect("write interrupted migration key");
    let keychain = FakeKeychainReader::with_default_key(&legacy_key);
    let writer = FakeKeychainWriter::succeeding();
    let validator = RecordingValidator::accepting(&legacy_key);

    let outcome = initialize_database_key_with(
        &keychain,
        &writer,
        &validator,
        &KeychainKeyReference::default(),
        &trusted_application_paths_fixture(),
        &database,
        &legacy,
        || panic!("existing Keychain item must never generate"),
    )
    .expect("restart should complete the interrupted migration");

    assert_eq!(
        outcome,
        KeyInitializationOutcome::CompletedInterruptedMigration
    );
    assert!(writer.writes.borrow().is_empty());
    assert_eq!(
        validator.calls.borrow().as_slice(),
        &[legacy_key.clone(), legacy_key]
    );
    assert!(!legacy.exists());
}

#[test]
fn restart_after_add_preserves_malformed_or_wrong_legacy_plaintext() {
    for legacy_key in ["A".repeat(63), "cd".repeat(32)] {
        let (_temp, database, legacy) = existing_database_fixture();
        std::fs::write(&legacy, &legacy_key).expect("write ambiguous legacy key");
        let keychain_key = "ab".repeat(32);
        let keychain = FakeKeychainReader::with_default_key(&keychain_key);
        let writer = FakeKeychainWriter::succeeding();
        let validator = RecordingValidator::accepting(&keychain_key);

        let error = initialize_database_key_with(
            &keychain,
            &writer,
            &validator,
            &KeychainKeyReference::default(),
            &trusted_application_paths_fixture(),
            &database,
            &legacy,
            || panic!("existing Keychain item must never generate"),
        )
        .expect_err("ambiguous restart must fail visibly");

        assert!(matches!(
            error,
            KeyResolutionError::InvalidLegacyKey
                | KeyResolutionError::DatabaseValidationFailed
                | KeyResolutionError::LegacyKeyMismatch
        ));
        assert!(legacy.exists());
        assert!(writer.writes.borrow().is_empty());
    }
}

#[test]
fn malformed_legacy_key_never_writes_or_generates() {
    let (_temp, database, legacy) = existing_database_fixture();
    std::fs::write(&legacy, "A".repeat(63)).expect("write malformed key");
    let keychain = SharedKeychain::missing();
    let validator = RecordingValidator::accepting(&"ab".repeat(32));

    let error = initialize_database_key_with(
        &keychain,
        &keychain,
        &validator,
        &KeychainKeyReference::default(),
        &trusted_application_paths_fixture(),
        &database,
        &legacy,
        || panic!("existing database must never generate"),
    )
    .expect_err("malformed legacy key must fail closed");

    assert_eq!(error, KeyResolutionError::InvalidLegacyKey);
    assert!(keychain.writes.borrow().is_empty());
    assert!(validator.calls.borrow().is_empty());
    assert!(legacy.exists());
}

#[test]
fn wrong_legacy_key_is_rejected_before_keychain_add() {
    let (_temp, database, legacy) = existing_database_fixture();
    let legacy_key = "ab".repeat(32);
    std::fs::write(&legacy, &legacy_key).expect("write legacy key");
    let keychain = SharedKeychain::missing();
    let validator = RecordingValidator::accepting(&"cd".repeat(32));

    let error = initialize_database_key_with(
        &keychain,
        &keychain,
        &validator,
        &KeychainKeyReference::default(),
        &trusted_application_paths_fixture(),
        &database,
        &legacy,
        || panic!("existing database must never generate"),
    )
    .expect_err("wrong legacy key must fail closed");

    assert_eq!(error, KeyResolutionError::DatabaseValidationFailed);
    assert!(keychain.writes.borrow().is_empty());
    assert_eq!(validator.calls.borrow().as_slice(), &[legacy_key]);
    assert!(legacy.exists());
}

#[test]
fn duplicate_race_rereads_winner_and_accepts_only_a_key_that_opens_existing_database() {
    let (_temp, database, legacy) = existing_database_fixture();
    let legacy_key = "ab".repeat(32);
    std::fs::write(&legacy, &legacy_key).expect("write legacy key");
    let keychain = SharedKeychain::missing();
    *keychain.duplicate_value.borrow_mut() = Some(legacy_key.clone());
    let validator = RecordingValidator::accepting(&legacy_key);

    let outcome = initialize_database_key_with(
        &keychain,
        &keychain,
        &validator,
        &KeychainKeyReference::default(),
        &trusted_application_paths_fixture(),
        &database,
        &legacy,
        || panic!("existing database must never generate"),
    )
    .expect("matching duplicate-race winner should be accepted");

    assert_eq!(outcome, KeyInitializationOutcome::ConcurrentItemValidated);
    assert_eq!(validator.calls.borrow().len(), 2);
    assert!(
        !legacy.exists(),
        "a validated same-key race must remove the legacy plaintext"
    );

    std::fs::write(&legacy, &legacy_key).expect("restore legacy key for conflicting race");

    let wrong_keychain = SharedKeychain::missing();
    *wrong_keychain.duplicate_value.borrow_mut() = Some("cd".repeat(32));
    let error = initialize_database_key_with(
        &wrong_keychain,
        &wrong_keychain,
        &validator,
        &KeychainKeyReference::default(),
        &trusted_application_paths_fixture(),
        &database,
        &legacy,
        || panic!("existing database must never generate"),
    )
    .expect_err("conflicting duplicate-race winner must fail closed");
    assert!(matches!(
        error,
        KeyResolutionError::PostAddValidationFailed { .. }
    ));
    assert!(legacy.exists());
}

#[test]
fn legacy_removal_failure_is_visible_and_does_not_report_completed_migration() {
    struct FailingRemover;
    impl LegacyKeyRemover for FailingRemover {
        fn remove(&self, _path: &Path) -> std::io::Result<()> {
            Err(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                "fixture denied",
            ))
        }
    }

    let (_temp, database, legacy) = existing_database_fixture();
    let legacy_key = "ab".repeat(32);
    std::fs::write(&legacy, &legacy_key).expect("write legacy key");
    let keychain = SharedKeychain::missing();
    let validator = RecordingValidator::accepting(&legacy_key);

    let error = initialize_database_key_with_remover(
        &keychain,
        &keychain,
        &validator,
        &FailingRemover,
        &KeychainKeyReference::default(),
        &trusted_application_paths_fixture(),
        &database,
        &legacy,
        || panic!("existing database must never generate"),
    )
    .expect_err("plaintext deletion failure must leave migration incomplete");

    assert!(matches!(
        error,
        KeyResolutionError::LegacyKeyRemovalFailed { .. }
    ));
    assert!(legacy.exists());
}

#[test]
fn post_add_validation_failure_is_visible_and_preserves_legacy_key() {
    let (_temp, database, legacy) = existing_database_fixture();
    let legacy_key = "ab".repeat(32);
    std::fs::write(&legacy, &legacy_key).expect("write legacy key");
    let keychain = SharedKeychain::missing();
    let validator = RecordingValidator {
        accepted_key: legacy_key.clone(),
        calls: RefCell::new(Vec::new()),
        fail_on_call: Some(2),
    };

    let error = initialize_database_key_with(
        &keychain,
        &keychain,
        &validator,
        &KeychainKeyReference::default(),
        &trusted_application_paths_fixture(),
        &database,
        &legacy,
        || panic!("existing database must never generate"),
    )
    .expect_err("post-add database validation must be mandatory");

    assert!(matches!(
        error,
        KeyResolutionError::PostAddValidationFailed { .. }
    ));
    assert_eq!(keychain.writes.borrow().len(), 1);
    assert!(legacy.exists());
}

#[test]
fn interrupted_reread_after_add_fails_closed_and_preserves_legacy_key() {
    struct InterruptedKeychain {
        reads: Cell<usize>,
        writes: Cell<usize>,
    }
    impl KeychainReader for InterruptedKeychain {
        fn read_generic_password(
            &self,
            service: &str,
            account: &str,
        ) -> Result<String, KeyResolutionError> {
            self.reads.set(self.reads.get() + 1);
            Err(KeyResolutionError::MissingKey {
                service: service.to_owned(),
                account: account.to_owned(),
            })
        }
    }
    impl KeychainWriter for InterruptedKeychain {
        fn add_generic_password(
            &self,
            _service: &str,
            _account: &str,
            _secret: &str,
            _trusted_application_paths: &[PathBuf],
        ) -> Result<(), KeyResolutionError> {
            self.writes.set(self.writes.get() + 1);
            Ok(())
        }
    }

    let (_temp, database, legacy) = existing_database_fixture();
    let legacy_key = "ab".repeat(32);
    std::fs::write(&legacy, &legacy_key).expect("write legacy key");
    let keychain = InterruptedKeychain {
        reads: Cell::new(0),
        writes: Cell::new(0),
    };
    let validator = RecordingValidator::accepting(&legacy_key);

    let error = initialize_database_key_with(
        &keychain,
        &keychain,
        &validator,
        &KeychainKeyReference::default(),
        &trusted_application_paths_fixture(),
        &database,
        &legacy,
        || panic!("existing database must never generate"),
    )
    .expect_err("missing post-add reread must fail closed");

    assert!(matches!(
        error,
        KeyResolutionError::PostAddReadFailed { .. }
    ));
    assert_eq!(keychain.reads.get(), 2);
    assert_eq!(keychain.writes.get(), 1);
    assert!(legacy.exists());
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

    let (_temp, database, legacy) = existing_database_fixture();
    let legacy_key = "ef".repeat(32);
    std::fs::write(&legacy, &legacy_key).expect("write legacy key");
    let writer = FakeKeychainWriter::succeeding();
    let err = initialize_database_key_with(
        &DeniedReader,
        &writer,
        &RecordingValidator::accepting(&legacy_key),
        &KeychainKeyReference::default(),
        &trusted_application_paths_fixture(),
        &database,
        &legacy,
        || Ok("ef".repeat(32)),
    )
    .expect_err("denied reads must fail closed");

    assert!(matches!(err, KeyResolutionError::AccessDenied { .. }));
    assert!(writer.writes.borrow().is_empty());
    assert!(
        legacy.exists(),
        "denied access must preserve migration input"
    );
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

    let (_temp, database, legacy) = existing_database_fixture();
    let legacy_key = "01".repeat(32);
    std::fs::write(&legacy, &legacy_key).expect("write legacy key");
    let writer = FakeKeychainWriter::succeeding();
    let err = initialize_database_key_with(
        &LockedReader,
        &writer,
        &RecordingValidator::accepting(&legacy_key),
        &KeychainKeyReference::default(),
        &trusted_application_paths_fixture(),
        &database,
        &legacy,
        || Ok("01".repeat(32)),
    )
    .expect_err("locked Keychain must fail closed");

    assert!(matches!(
        err,
        KeyResolutionError::InteractionNotAllowed { .. }
    ));
    assert!(writer.writes.borrow().is_empty());
    assert!(
        legacy.exists(),
        "locked access must preserve migration input"
    );
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
