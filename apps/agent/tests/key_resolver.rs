//! Privacy gate tests for SQLCipher key custody.

use std::collections::HashMap;

use mci_agent::key_resolver::{
    mcp_registration_env, resolve_database_key_with_reader, KeyResolutionError,
    KeychainKeyReference, KeychainReader, DEFAULT_KEYCHAIN_ACCOUNT, DEFAULT_KEYCHAIN_SERVICE,
};

struct FakeKeychainReader {
    values: HashMap<(String, String), String>,
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
