//! Storage-security review S12: no product path may fall back to a shared
//! folder such as `/tmp` when `HOME` is unset. Another local account can create
//! folders there first, then read or replace what Hippocampus writes. Every
//! path resolves the home through `mci_core::home` (HOME, else `getpwuid_r`)
//! and fails closed.

use std::path::{Path, PathBuf};

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(2)
        .expect("apps/agent sits two levels below the repository root")
        .to_path_buf()
}

fn rust_sources(dir: &Path, out: &mut Vec<PathBuf>) {
    for entry in std::fs::read_dir(dir).expect("read source folder") {
        let path = entry.expect("source entry").path();
        if path.is_dir() {
            rust_sources(&path, out);
        } else if path.extension().is_some_and(|ext| ext == "rs") {
            out.push(path);
        }
    }
}

#[test]
fn no_home_lookup_falls_back_to_tmp() {
    let root = repo_root();
    let mut files = Vec::new();
    for dir in [
        "apps/agent/src",
        "apps/hippocampus-native-host/src",
        "core/src",
        "core/mcp-client/src",
        "core/brain/src",
    ] {
        rust_sources(&root.join(dir), &mut files);
    }
    assert!(files.len() > 50, "scanned too few files: {}", files.len());

    let forbidden = [
        r#"PathBuf::from("/tmp")"#,
        r#"PathBuf::from("/tmp/mci")"#,
        r#"|| "/tmp""#,
    ];
    let mut offenders = Vec::new();
    for file in &files {
        let text = std::fs::read_to_string(file).expect("read source");
        for (index, line) in text.lines().enumerate() {
            if forbidden.iter().any(|pattern| line.contains(pattern)) {
                offenders.push(format!(
                    "{}:{}: {}",
                    file.strip_prefix(&root).unwrap_or(file).display(),
                    index + 1,
                    line.trim()
                ));
            }
        }
    }
    assert!(
        offenders.is_empty(),
        "home lookups must fail closed, never fall back to /tmp:\n{}",
        offenders.join("\n")
    );
}

#[test]
fn the_shared_resolver_prefers_home_and_never_names_tmp() {
    let home = mci_core::home::user_home_or_unwritable();
    assert!(home.is_absolute());
    assert!(!home.starts_with("/tmp") && !home.starts_with("/private/tmp"));
    if let Some(set) = std::env::var_os("HOME").filter(|value| !value.is_empty()) {
        assert_eq!(home, PathBuf::from(set), "HOME, when set, wins");
    }
}
