//! Storage-security review S4: the one-time key change, on synthetic stores
//! in throwaway folders, with a fake Keychain. Nothing here touches the real
//! Keychain, the real memory or the real data folder.
//!
//! Every test ends by proving the invariant that matters: every moment and
//! every screenshot that opened before still opens, with exactly one key, and
//! the key every reader finds is that key.
#![cfg(target_os = "macos")]

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use mci_agent::key_change::{
    self, Checkpoints, Envelope, KeyChangeContext, KeyChangeError, KeyChangeOutcome,
    KeychainDeleter, NoCheckpoints, SealedScreenshotEnvelope, SpaceProbe, Step, ADOPTED_MARKER,
    BACKUP_FILE, JOURNAL_FILE, KEY_CHANGE_DIR, MAX_ATTEMPTS, UNDONE_FILE,
};
use mci_agent::key_resolver::{
    resolve_current_database_key, KeyResolutionError, KeychainKeyReference, KeychainReader,
    KeychainWriter, SqlCipherDatabaseKeyValidator, DEFAULT_KEYCHAIN_ACCOUNT,
    DEFAULT_KEYCHAIN_SERVICE, ROTATED_KEYCHAIN_ACCOUNT,
};
use mci_brain::{BrainStore, Event, EventId, SqlCipherBrainStore};
use mci_core::crypto::DbKey;

const SERVICE: &str = DEFAULT_KEYCHAIN_SERVICE;
const V1: &str = DEFAULT_KEYCHAIN_ACCOUNT;
const V2: &str = ROTATED_KEYCHAIN_ACCOUNT;

// ---------------------------------------------------------------------------
// A fake Keychain: in memory, or in a JSON file another process shares.
// ---------------------------------------------------------------------------

#[derive(Default)]
struct FakeKeychain {
    items: Mutex<BTreeMap<String, String>>,
    file: Option<PathBuf>,
    locked: AtomicBool,
    refuse_add: AtomicBool,
    refuse_delete: Mutex<BTreeSet<String>>,
}

impl FakeKeychain {
    fn in_file(path: &Path) -> Self {
        Self {
            file: Some(path.to_path_buf()),
            ..Self::default()
        }
    }

    fn load(&self) -> BTreeMap<String, String> {
        match &self.file {
            Some(path) => std::fs::read(path)
                .ok()
                .and_then(|bytes| serde_json::from_slice(&bytes).ok())
                .unwrap_or_default(),
            None => self.items.lock().unwrap().clone(),
        }
    }

    fn save(&self, items: &BTreeMap<String, String>) {
        match &self.file {
            Some(path) => {
                let temporary = path.with_extension("tmp");
                std::fs::write(&temporary, serde_json::to_vec(items).unwrap()).unwrap();
                std::fs::rename(&temporary, path).unwrap();
            }
            None => *self.items.lock().unwrap() = items.clone(),
        }
    }

    fn get(&self, account: &str) -> Option<String> {
        self.load().get(account).cloned()
    }

    fn put(&self, account: &str, value: &str) {
        let mut items = self.load();
        items.insert(account.to_owned(), value.to_owned());
        self.save(&items);
    }

    fn locked_error(account: &str) -> KeyResolutionError {
        KeyResolutionError::InteractionNotAllowed {
            service: SERVICE.to_owned(),
            account: account.to_owned(),
        }
    }
}

impl KeychainReader for FakeKeychain {
    fn read_generic_password(
        &self,
        service: &str,
        account: &str,
    ) -> Result<String, KeyResolutionError> {
        if self.locked.load(Ordering::SeqCst) {
            return Err(Self::locked_error(account));
        }
        assert_eq!(service, SERVICE);
        self.get(account)
            .ok_or_else(|| KeyResolutionError::MissingKey {
                service: service.to_owned(),
                account: account.to_owned(),
            })
    }
}

impl KeychainWriter for FakeKeychain {
    fn add_generic_password(
        &self,
        service: &str,
        account: &str,
        secret: &str,
        trusted_application_paths: &[PathBuf],
    ) -> Result<(), KeyResolutionError> {
        assert_eq!(service, SERVICE);
        assert!(
            !trusted_application_paths.is_empty(),
            "every item is added with its ACL"
        );
        if self.locked.load(Ordering::SeqCst) {
            return Err(Self::locked_error(account));
        }
        if self.refuse_add.load(Ordering::SeqCst) {
            return Err(KeyResolutionError::WriteFailure { status: -61 });
        }
        if self.get(account).is_some() {
            return Err(KeyResolutionError::KeyAlreadyExists);
        }
        self.put(account, secret);
        Ok(())
    }
}

impl KeychainDeleter for FakeKeychain {
    fn delete_generic_password(
        &self,
        service: &str,
        account: &str,
    ) -> Result<(), KeyResolutionError> {
        assert_eq!(service, SERVICE);
        if self.locked.load(Ordering::SeqCst) {
            return Err(Self::locked_error(account));
        }
        if self.refuse_delete.lock().unwrap().contains(account) {
            return Err(KeyResolutionError::AccessDenied {
                service: service.to_owned(),
                account: account.to_owned(),
            });
        }
        let mut items = self.load();
        items.remove(account);
        self.save(&items);
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Envelopes, space and checkpoints.
// ---------------------------------------------------------------------------

/// The production envelope, failing every seal after the first `limit`, as a
/// full disk or an I/O error would.
struct FailingEnvelope {
    limit: usize,
    seals: AtomicUsize,
}

impl Envelope for FailingEnvelope {
    fn open(&self, blob: &[u8], key: &[u8; 32]) -> Option<zeroize::Zeroizing<Vec<u8>>> {
        SealedScreenshotEnvelope.open(blob, key)
    }

    fn seal(
        &self,
        plaintext: &[u8],
        key: &[u8; 32],
        salt: &[u8; 16],
        nonce: &[u8; 12],
    ) -> Result<Vec<u8>, String> {
        if self.seals.fetch_add(1, Ordering::SeqCst) >= self.limit {
            return Err("No space left on device (os error 28)".to_owned());
        }
        SealedScreenshotEnvelope.seal(plaintext, key, salt, nonce)
    }
}

struct Space(u64);

impl SpaceProbe for Space {
    fn available_bytes(&self, _path: &Path) -> std::io::Result<u64> {
        Ok(self.0)
    }
}

const PLENTY: Space = Space(u64::MAX / 4);

/// Stops the change at the `nth` time it reaches `step`, as a crash there
/// would.
struct StopAt {
    step: Step,
    nth: usize,
    seen: AtomicUsize,
}

impl StopAt {
    fn new(step: Step, nth: usize) -> Self {
        Self {
            step,
            nth,
            seen: AtomicUsize::new(0),
        }
    }
}

impl Checkpoints for StopAt {
    fn reached(&self, step: Step) -> Result<(), KeyChangeError> {
        if step == self.step && self.seen.fetch_add(1, Ordering::SeqCst) + 1 == self.nth {
            return Err(KeyChangeError::Stopped(step));
        }
        Ok(())
    }
}

/// Runs `action` the first time the change reaches `step`.
struct OnStep<F: Fn()> {
    step: Step,
    action: F,
    done: AtomicBool,
}

impl<F: Fn()> Checkpoints for OnStep<F> {
    fn reached(&self, step: Step) -> Result<(), KeyChangeError> {
        if step == self.step && !self.done.swap(true, Ordering::SeqCst) {
            (self.action)();
        }
        Ok(())
    }
}

/// Sleeps at every step, so a kill from outside lands all over the change.
struct Dawdle(Duration);

impl Checkpoints for Dawdle {
    fn reached(&self, _step: Step) -> Result<(), KeyChangeError> {
        std::thread::sleep(self.0);
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Synthetic stores.
// ---------------------------------------------------------------------------

fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    bytes.iter().fold(String::new(), |mut out, byte| {
        let _ = write!(out, "{byte:02x}");
        out
    })
}

fn random_key() -> [u8; 32] {
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes).unwrap();
    bytes
}

// The shape the change's `generate` hook takes; this one never fails.
#[allow(clippy::unnecessary_wraps)]
fn generate() -> Result<String, KeyResolutionError> {
    Ok(hex(&random_key()))
}

/// What a store held before the change: each moment's text, and the
/// plaintext of each screenshot that opened.
struct Expected {
    texts: BTreeMap<u64, String>,
    pictures: BTreeMap<u64, Vec<u8>>,
    /// Moments whose screenshot was already missing or damaged.
    unreadable: BTreeMap<u64, String>,
}

struct Fixture {
    _root: tempfile::TempDir,
    support: PathBuf,
    db: PathBuf,
    old_key: [u8; 32],
    expected: Expected,
    trusted: Vec<PathBuf>,
}

impl Fixture {
    /// A memory of `moments` made-up moments, every third with a sealed
    /// screenshot, two sharing one, one whose file is missing and one whose
    /// file is damaged, under a key that sits in `dev.key.stale-20260901`
    /// too, as on a real install that ran a pre-0.1 build.
    fn new(moments: u64, picture_bytes: usize, keychain: &FakeKeychain) -> Self {
        let root = tempfile::tempdir().expect("tempdir");
        let support = root.path().join("MCI");
        std::fs::create_dir_all(support.join("blobs")).unwrap();
        let db = support.join("mci.sqlite");
        let old_key = random_key();
        keychain.put(V1, &hex(&old_key));
        std::fs::write(support.join("dev.key.stale-20260901"), hex(&old_key)).unwrap();

        let store = SqlCipherBrainStore::new(&db, &DbKey::from_bytes(old_key)).expect("store");
        let mut expected = Expected {
            texts: BTreeMap::new(),
            pictures: BTreeMap::new(),
            unreadable: BTreeMap::new(),
        };
        let mut shared: Option<(String, Vec<u8>)> = None;
        for index in 0..moments {
            let text = format!("Synthetic moment {index}: Quillfeather planning notes.");
            let mut blob = None;
            let mut picture = None;
            if index % 3 == 0 {
                if index == 6 {
                    // Shares the screenshot of moment 3's neighbour, 0.
                    let (digest, plaintext) = shared.clone().expect("first picture");
                    blob = Some(digest);
                    picture = Some(plaintext);
                } else {
                    let mut plaintext = vec![0xff, 0xd8, 0xff, 0xe0];
                    plaintext.extend((0..picture_bytes).map(|n| {
                        u8::try_from((n * 31 + usize::try_from(index).unwrap()) % 251).unwrap()
                    }));
                    let sealed = seal(&plaintext, &old_key);
                    let digest = key_change::sha256_hex(&sealed);
                    std::fs::write(support.join("blobs").join(format!("{digest}.bin")), &sealed)
                        .unwrap();
                    if shared.is_none() {
                        shared = Some((digest.clone(), plaintext.clone()));
                    }
                    blob = Some(digest);
                    picture = Some(plaintext);
                }
            }
            let id = store
                .put_event(&event(
                    1_800_000_000_000_000 + index * 1_000_000,
                    &text,
                    blob.clone(),
                ))
                .expect("put event");
            expected.texts.insert(id.0, text);
            if let Some(plaintext) = picture {
                expected.pictures.insert(id.0, plaintext);
            }
        }
        // One moment whose screenshot is gone, one whose screenshot is
        // damaged: both stay exactly as they are.
        let missing = "a".repeat(64);
        let id = store
            .put_event(&event(
                1_800_000_100_000_000,
                "Moment with a lost picture",
                Some(missing.clone()),
            ))
            .unwrap();
        expected
            .texts
            .insert(id.0, "Moment with a lost picture".to_owned());
        expected.unreadable.insert(id.0, missing);
        let damaged_bytes = vec![7u8; 300];
        let damaged = key_change::sha256_hex(&damaged_bytes);
        std::fs::write(
            support.join("blobs").join(format!("{damaged}.bin")),
            &damaged_bytes,
        )
        .unwrap();
        let id = store
            .put_event(&event(
                1_800_000_200_000_000,
                "Moment with a damaged picture",
                Some(damaged.clone()),
            ))
            .unwrap();
        expected
            .texts
            .insert(id.0, "Moment with a damaged picture".to_owned());
        expected.unreadable.insert(id.0, damaged);
        drop(store);

        let macos = root.path().join("Hippocampus.app/Contents/MacOS");
        std::fs::create_dir_all(&macos).unwrap();
        let trusted = ["Hippocampus", "MCICaptureHelper", "mci-agent", "recall-ui"]
            .iter()
            .map(|name| macos.join(name))
            .collect();
        Self {
            _root: root,
            support,
            db,
            old_key,
            expected,
            trusted,
        }
    }

    fn ctx<'a>(
        &'a self,
        keychain: &'a FakeKeychain,
        envelope: &'a dyn Envelope,
        space: &'a dyn SpaceProbe,
        checkpoints: &'a dyn Checkpoints,
    ) -> KeyChangeContext<'a> {
        KeyChangeContext {
            support_dir: &self.support,
            db_path: &self.db,
            service: SERVICE,
            reader: keychain,
            writer: keychain,
            deleter: keychain,
            trusted_application_paths: &self.trusted,
            envelope,
            space,
            generate: &generate,
            checkpoints,
        }
    }

    fn run(
        &self,
        keychain: &FakeKeychain,
        checkpoints: &dyn Checkpoints,
    ) -> Result<KeyChangeOutcome, KeyChangeError> {
        key_change::run_key_change(&self.ctx(
            keychain,
            &SealedScreenshotEnvelope,
            &PLENTY,
            checkpoints,
        ))
    }

    fn blob(&self, digest: &str) -> Option<Vec<u8>> {
        std::fs::read(self.support.join("blobs").join(format!("{digest}.bin"))).ok()
    }

    fn change_dir(&self) -> PathBuf {
        self.support.join(KEY_CHANGE_DIR)
    }

    /// The key every reader finds: the resolver the agent, `mcp-serve` and
    /// connected AI tools use.
    fn reader_key(&self, keychain: &FakeKeychain) -> [u8; 32] {
        let found = resolve_current_database_key(
            keychain,
            &SqlCipherDatabaseKeyValidator,
            &KeychainKeyReference::default(),
            Some(&self.db),
        )
        .expect("a reader finds a key");
        key_change::decode_key(&found).expect("hex")
    }

    /// Every moment reads with `key`, and every screenshot that opened
    /// before opens with `key` (or, mid-change, `other`), to the same bytes.
    fn assert_whole(&self, key: &[u8; 32], other: Option<&[u8; 32]>) {
        let store = SqlCipherBrainStore::open_readonly(&self.db, &DbKey::from_bytes(*key))
            .expect("the memory opens with the key readers find");
        assert_eq!(
            store.stats().unwrap().event_count,
            self.expected.texts.len() as u64
        );
        for (id, text) in &self.expected.texts {
            let event = store.get_event(EventId(*id)).unwrap().expect("moment kept");
            assert_eq!(&event.text, text, "moment {id} reads back");
            if let Some(plaintext) = self.expected.pictures.get(id) {
                let digest = event.keyframe_blob.clone().expect("screenshot named");
                let sealed = self.blob(&digest).expect("screenshot file present");
                assert_eq!(
                    key_change::sha256_hex(&sealed),
                    digest,
                    "named by its own digest"
                );
                let opened = SealedScreenshotEnvelope
                    .open(&sealed, key)
                    .or_else(|| {
                        other.and_then(|other| SealedScreenshotEnvelope.open(&sealed, other))
                    })
                    .unwrap_or_else(|| panic!("screenshot of moment {id} opens"));
                assert_eq!(opened.as_slice(), plaintext.as_slice());
            }
            if let Some(digest) = self.expected.unreadable.get(id) {
                assert_eq!(
                    event.keyframe_blob.as_deref(),
                    Some(digest.as_str()),
                    "left alone"
                );
            }
        }
    }

    /// The state a finished change leaves: one new key under the usual
    /// account, nothing else, and nothing under the old key.
    fn assert_finished(&self, keychain: &FakeKeychain) -> [u8; 32] {
        let new_hex = keychain
            .get(V1)
            .expect("the key is under its usual account");
        let new_key = key_change::decode_key(&new_hex).unwrap();
        assert_ne!(new_key, self.old_key, "the key changed");
        assert!(
            keychain.get(V2).is_none(),
            "nothing is left under the new account"
        );
        assert_eq!(self.reader_key(keychain), new_key);
        assert!(
            !key_change::opens(&self.db, &hex(&self.old_key)),
            "the old key opens nothing"
        );
        self.assert_whole(&new_key, None);
        // No screenshot under the old key is left.
        for entry in std::fs::read_dir(self.support.join("blobs")).unwrap() {
            let path = entry.unwrap().path();
            let bytes = std::fs::read(&path).unwrap();
            assert!(
                SealedScreenshotEnvelope
                    .open(&bytes, &self.old_key)
                    .is_none(),
                "{} still opens with the old key",
                path.display()
            );
        }
        assert!(
            key_change::key_files(&self.support).unwrap().is_empty(),
            "key files shredded"
        );
        assert!(!self.support.join(ADOPTED_MARKER).exists());
        assert!(!self.change_dir().join(JOURNAL_FILE).exists());
        assert!(!self.change_dir().join(BACKUP_FILE).exists());
        let wal = std::fs::metadata(self.db.with_extension("sqlite-wal")).map_or(0, |m| m.len());
        assert_eq!(wal, 0, "no log frames are left");
        new_key
    }

    /// The state an undone change leaves: everything as it was.
    fn assert_as_before(&self, keychain: &FakeKeychain) {
        assert_eq!(keychain.get(V1), Some(hex(&self.old_key)));
        assert!(keychain.get(V2).is_none());
        assert_eq!(self.reader_key(keychain), self.old_key);
        self.assert_whole(&self.old_key, None);
        assert!(!self.change_dir().join(JOURNAL_FILE).exists());
        assert!(!self.change_dir().join(BACKUP_FILE).exists());
        // Only the screenshots the memory names, under the old key.
        let store =
            SqlCipherBrainStore::open_readonly(&self.db, &DbKey::from_bytes(self.old_key)).unwrap();
        let named: BTreeSet<String> = store
            .referenced_keyframe_digests()
            .unwrap()
            .into_iter()
            .collect();
        for entry in std::fs::read_dir(self.support.join("blobs")).unwrap() {
            let name = entry.unwrap().file_name().into_string().unwrap();
            let digest = name.strip_suffix(".bin").unwrap_or(&name);
            assert!(
                named.contains(digest),
                "a re-sealed copy {name} was left behind"
            );
        }
    }
}

fn seal(plaintext: &[u8], key: &[u8; 32]) -> Vec<u8> {
    let mut salt = [0u8; 16];
    let mut nonce = [0u8; 12];
    getrandom::fill(&mut salt).unwrap();
    getrandom::fill(&mut nonce).unwrap();
    SealedScreenshotEnvelope
        .seal(plaintext, key, &salt, &nonce)
        .expect("seal")
}

fn event(ts_us: u64, text: &str, keyframe_blob: Option<String>) -> Event {
    Event {
        id: EventId(0),
        ts_us,
        app_bundle_id: Some("com.example.Notes".into()),
        window_title: Some("Synthetic notes".into()),
        url: None,
        text: text.into(),
        summary: None,
        entities: None,
        episode_id: None,
        cascade_reason: 0,
        keyframe_blob,
        tab_id: None,
        embedding: None,
    }
}

fn changed(outcome: KeyChangeOutcome) -> key_change::KeyChangeReport {
    match outcome {
        KeyChangeOutcome::Changed(report) => report,
        other => panic!("expected a finished change, got {other:?}"),
    }
}

// ---------------------------------------------------------------------------
// The change itself.
// ---------------------------------------------------------------------------

#[test]
fn nothing_happens_without_a_key_file_or_a_marker() {
    let keychain = FakeKeychain::default();
    let fixture = Fixture::new(9, 64, &keychain);
    for file in key_change::key_files(&fixture.support).unwrap() {
        std::fs::remove_file(file).unwrap();
    }
    assert_eq!(
        fixture.run(&keychain, &NoCheckpoints).unwrap(),
        KeyChangeOutcome::NotNeeded
    );
    assert_eq!(keychain.get(V1), Some(hex(&fixture.old_key)));
    assert!(!fixture.change_dir().exists());
    fixture.assert_whole(&fixture.old_key, None);
}

#[test]
fn a_stale_key_file_moves_the_memory_to_a_new_key() {
    let keychain = FakeKeychain::default();
    let fixture = Fixture::new(30, 2_000, &keychain);
    let report = changed(fixture.run(&keychain, &NoCheckpoints).unwrap());
    assert!(report.finished, "{report:?}");
    assert!(report.old_key_deleted);
    assert_eq!(report.cleanup_pending, None);
    assert_eq!(report.moments, fixture.expected.texts.len() as u64);
    // Moments 0..30 step 3, one shared: nine distinct screenshots.
    assert_eq!(report.screenshots_resealed, 9);
    assert_eq!(report.screenshots_unreadable, 2);
    assert_eq!(report.key_files_deleted, 1);
    fixture.assert_finished(&keychain);
    // Done once: the next launch has nothing to do.
    assert_eq!(
        fixture.run(&keychain, &NoCheckpoints).unwrap(),
        KeyChangeOutcome::NotNeeded
    );
}

#[test]
fn the_adoption_marker_alone_triggers_the_change() {
    let keychain = FakeKeychain::default();
    let fixture = Fixture::new(9, 64, &keychain);
    for file in key_change::key_files(&fixture.support).unwrap() {
        std::fs::remove_file(file).unwrap();
    }
    key_change::mark_key_adopted_from_file(&fixture.support).unwrap();
    changed(fixture.run(&keychain, &NoCheckpoints).unwrap());
    fixture.assert_finished(&keychain);
}

/// Every step at which the change can stop, with how often it is reached
/// for the default fixture.
const STOPS: &[(Step, usize)] = &[
    (Step::JournalWritten, 1),
    (Step::BackupWritten, 1),
    (Step::BackedUp, 1),
    (Step::KeyAddedUnrecorded, 1),
    (Step::KeyAdded, 1),
    (Step::RekeyRan, 1),
    (Step::Rekeyed, 1),
    (Step::ScreenshotWritten, 1),
    (Step::ScreenshotWritten, 5),
    (Step::ScreenshotWritten, 9),
    (Step::BatchMoved, 1),
    (Step::Resealed, 1),
    (Step::Verified, 1),
    (Step::Committed, 1),
    (Step::OldScreenshotsDeleted, 1),
    (Step::BackupDeleted, 1),
    (Step::KeyFilesDeleted, 1),
    (Step::OldKeyDeleted, 1),
    (Step::KeyRestored, 1),
    (Step::RotatedKeyDeleted, 1),
];

#[test]
fn a_crash_at_every_step_resumes_and_finishes() {
    for &(step, nth) in STOPS {
        let keychain = FakeKeychain::default();
        let fixture = Fixture::new(30, 500, &keychain);
        let stop = StopAt::new(step, nth);
        match fixture.run(&keychain, &stop) {
            Err(KeyChangeError::Stopped(at)) => assert_eq!(at, step),
            other => panic!("{step:?}#{nth}: expected a stop, got {other:?}"),
        }
        // While it is stopped, the memory is whole under the key readers
        // find, and every screenshot opens with it or with the old key.
        let found = fixture.reader_key(&keychain);
        fixture.assert_whole(&found, Some(&fixture.old_key));

        let outcome = fixture
            .run(&keychain, &NoCheckpoints)
            .unwrap_or_else(|error| panic!("{step:?}#{nth}: {error}"));
        let report = changed(outcome);
        assert!(report.finished, "{step:?}#{nth}: {report:?}");
        assert!(report.resumed, "{step:?}#{nth}: a stopped change resumes");
        fixture.assert_finished(&keychain);
    }
}

#[test]
fn a_crash_at_every_step_then_a_failure_puts_everything_back() {
    // Steps before the commit: a failure on resume undoes the change.
    for &(step, nth) in STOPS.iter().filter(|(step, _)| {
        !matches!(
            step,
            Step::Verified
                | Step::Committed
                | Step::OldScreenshotsDeleted
                | Step::BackupDeleted
                | Step::KeyFilesDeleted
                | Step::OldKeyDeleted
                | Step::KeyRestored
                | Step::RotatedKeyDeleted
        )
    }) {
        let keychain = FakeKeychain::default();
        let fixture = Fixture::new(30, 500, &keychain);
        assert!(matches!(
            fixture.run(&keychain, &StopAt::new(step, nth)),
            Err(KeyChangeError::Stopped(_))
        ));
        // The resume fails sealing its first screenshot, as a full disk would.
        let envelope = FailingEnvelope {
            limit: 0,
            seals: AtomicUsize::new(0),
        };
        let outcome =
            key_change::run_key_change(&fixture.ctx(&keychain, &envelope, &PLENTY, &NoCheckpoints))
                .unwrap_or_else(|error| panic!("{step:?}#{nth}: {error}"));
        if let KeyChangeOutcome::RolledBack(_) = outcome {
            fixture.assert_as_before(&keychain);
            assert!(
                fixture.change_dir().join(UNDONE_FILE).exists(),
                "the undo is recorded"
            );
            assert!(
                !key_change::key_files(&fixture.support).unwrap().is_empty(),
                "the trigger stays"
            );
        } else {
            // Stopped after every screenshot was already re-sealed: nothing
            // left to seal, so the change finished.
            assert!(
                matches!(
                    step,
                    Step::Resealed | Step::BatchMoved | Step::ScreenshotWritten
                ),
                "{step:?}#{nth}: {outcome:?}"
            );
            fixture.assert_finished(&keychain);
        }
    }
}

#[test]
fn a_full_disk_part_way_through_undoes_the_change() {
    let keychain = FakeKeychain::default();
    let fixture = Fixture::new(30, 500, &keychain);
    let envelope = FailingEnvelope {
        limit: 4,
        seals: AtomicUsize::new(0),
    };
    let outcome =
        key_change::run_key_change(&fixture.ctx(&keychain, &envelope, &PLENTY, &NoCheckpoints))
            .unwrap();
    assert!(
        matches!(outcome, KeyChangeOutcome::RolledBack(ref reason) if reason.contains("No space left")),
        "{outcome:?}"
    );
    fixture.assert_as_before(&keychain);
    // It waits a day before the next try, and changes nothing meanwhile.
    let again = fixture.run(&keychain, &NoCheckpoints).unwrap();
    assert!(
        matches!(again, KeyChangeOutcome::Deferred(ref reason) if reason.contains("less than a day")),
        "{again:?}"
    );
    fixture.assert_as_before(&keychain);
    // A day later it runs, and finishes.
    let record = fixture.change_dir().join(UNDONE_FILE);
    std::fs::write(&record, br#"{"count":1,"last_unix_ms":0}"#).unwrap();
    changed(fixture.run(&keychain, &NoCheckpoints).unwrap());
    fixture.assert_finished(&keychain);
}

#[test]
fn not_enough_free_space_postpones_it_untouched() {
    let keychain = FakeKeychain::default();
    let fixture = Fixture::new(9, 4_000, &keychain);
    let outcome = key_change::run_key_change(&fixture.ctx(
        &keychain,
        &SealedScreenshotEnvelope,
        &Space(1024),
        &NoCheckpoints,
    ))
    .unwrap();
    assert!(
        matches!(outcome, KeyChangeOutcome::Deferred(ref reason) if reason.contains("free space")),
        "{outcome:?}"
    );
    fixture.assert_as_before(&keychain);
    assert!(!fixture.change_dir().exists(), "nothing was written");
}

#[test]
fn a_locked_keychain_postpones_it_untouched() {
    let keychain = FakeKeychain::default();
    let fixture = Fixture::new(9, 64, &keychain);
    keychain.locked.store(true, Ordering::SeqCst);
    assert!(matches!(
        fixture.run(&keychain, &NoCheckpoints),
        Err(KeyChangeError::Keychain(_))
    ));
    keychain.locked.store(false, Ordering::SeqCst);
    fixture.assert_as_before(&keychain);
    assert!(!fixture.change_dir().exists());
}

#[test]
fn a_keychain_that_locks_part_way_through_resumes_once_unlocked() {
    let keychain = FakeKeychain::default();
    let fixture = Fixture::new(30, 500, &keychain);
    let lock = OnStep {
        step: Step::Rekeyed,
        action: || keychain.locked.store(true, Ordering::SeqCst),
        done: AtomicBool::new(false),
    };
    // Locked after the re-encryption: neither the change nor its undo can
    // read a key, so the journal stays and nothing is lost.
    assert!(fixture.run(&keychain, &lock).is_err());
    assert!(fixture.change_dir().join(JOURNAL_FILE).exists());
    keychain.locked.store(false, Ordering::SeqCst);
    let found = fixture.reader_key(&keychain);
    fixture.assert_whole(&found, Some(&fixture.old_key));
    changed(fixture.run(&keychain, &NoCheckpoints).unwrap());
    fixture.assert_finished(&keychain);
}

#[test]
fn a_keychain_that_will_not_store_the_new_key_changes_nothing() {
    let keychain = FakeKeychain::default();
    let fixture = Fixture::new(9, 64, &keychain);
    keychain.refuse_add.store(true, Ordering::SeqCst);
    let outcome = fixture.run(&keychain, &NoCheckpoints).unwrap();
    assert!(
        matches!(outcome, KeyChangeOutcome::RolledBack(_)),
        "{outcome:?}"
    );
    keychain.refuse_add.store(false, Ordering::SeqCst);
    fixture.assert_as_before(&keychain);
}

#[test]
fn a_keychain_that_will_not_delete_the_old_key_finishes_later() {
    let keychain = FakeKeychain::default();
    let fixture = Fixture::new(30, 500, &keychain);
    keychain.refuse_delete.lock().unwrap().insert(V1.to_owned());
    let report = changed(fixture.run(&keychain, &NoCheckpoints).unwrap());
    assert!(!report.finished);
    assert!(!report.old_key_deleted);
    assert!(report.cleanup_pending.is_some());
    // Committed: readers find the new key, and every moment and screenshot
    // opens with it, though the old item is still there.
    let new_key = key_change::decode_key(&keychain.get(V2).unwrap()).unwrap();
    assert_eq!(fixture.reader_key(&keychain), new_key);
    fixture.assert_whole(&new_key, None);
    assert!(
        key_change::key_files(&fixture.support).unwrap().is_empty(),
        "files go at once"
    );
    // The next launch, with a Keychain that allows it, finishes.
    keychain.refuse_delete.lock().unwrap().clear();
    let report = changed(fixture.run(&keychain, &NoCheckpoints).unwrap());
    assert!(report.finished, "{report:?}");
    assert_eq!(fixture.assert_finished(&keychain), new_key);
}

#[test]
fn a_screenshot_that_does_not_verify_undoes_the_change() {
    let keychain = FakeKeychain::default();
    let fixture = Fixture::new(30, 500, &keychain);
    let blobs = fixture.support.join("blobs");
    let old_names: BTreeSet<_> = std::fs::read_dir(&blobs)
        .unwrap()
        .map(|e| e.unwrap().file_name())
        .collect();
    let tamper = OnStep {
        step: Step::Resealed,
        action: || {
            // Damage one re-sealed copy before verification reads it.
            for entry in std::fs::read_dir(&blobs).unwrap() {
                let entry = entry.unwrap();
                if !old_names.contains(&entry.file_name()) {
                    let mut bytes = std::fs::read(entry.path()).unwrap();
                    let last = bytes.len() - 1;
                    bytes[last] ^= 0x55;
                    std::fs::write(entry.path(), bytes).unwrap();
                    break;
                }
            }
        },
        done: AtomicBool::new(false),
    };
    let outcome = fixture.run(&keychain, &tamper).unwrap();
    assert!(
        matches!(outcome, KeyChangeOutcome::RolledBack(ref reason) if reason.contains("screenshot")),
        "{outcome:?}"
    );
    fixture.assert_as_before(&keychain);
}

#[test]
fn a_change_that_never_finishes_is_undone_after_its_tries() {
    let keychain = FakeKeychain::default();
    let fixture = Fixture::new(30, 500, &keychain);
    assert!(fixture
        .run(&keychain, &StopAt::new(Step::ScreenshotWritten, 4))
        .is_err());
    // As if it had already been tried that often: each resume counts.
    let path = fixture.change_dir().join(JOURNAL_FILE);
    let mut journal: key_change::Journal =
        serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(journal.attempts, 1);
    journal.attempts = MAX_ATTEMPTS;
    std::fs::write(&path, serde_json::to_vec(&journal).unwrap()).unwrap();
    let outcome = fixture.run(&keychain, &NoCheckpoints).unwrap();
    assert!(
        matches!(outcome, KeyChangeOutcome::RolledBack(_)),
        "{outcome:?}"
    );
    fixture.assert_as_before(&keychain);
}

#[test]
fn a_damaged_journal_is_rebuilt_and_the_change_finishes() {
    for step in [
        Step::BackedUp,
        Step::Rekeyed,
        Step::BatchMoved,
        Step::Verified,
    ] {
        let keychain = FakeKeychain::default();
        let fixture = Fixture::new(30, 500, &keychain);
        assert!(fixture.run(&keychain, &StopAt::new(step, 1)).is_err());
        std::fs::write(
            fixture.change_dir().join(JOURNAL_FILE),
            b"{\"version\":1,\"pha",
        )
        .unwrap();
        let outcome = fixture.run(&keychain, &NoCheckpoints).unwrap();
        match outcome {
            KeyChangeOutcome::Changed(report) => {
                assert!(report.finished, "{step:?}: {report:?}");
                fixture.assert_finished(&keychain);
            }
            other => panic!("{step:?}: {other:?}"),
        }
    }
}

#[test]
fn three_undone_changes_stop_the_tries() {
    let keychain = FakeKeychain::default();
    let fixture = Fixture::new(9, 64, &keychain);
    std::fs::create_dir_all(fixture.change_dir()).unwrap();
    std::fs::write(
        fixture.change_dir().join(UNDONE_FILE),
        br#"{"count":3,"last_unix_ms":0}"#,
    )
    .unwrap();
    let outcome = fixture.run(&keychain, &NoCheckpoints).unwrap();
    assert!(
        matches!(outcome, KeyChangeOutcome::Deferred(ref reason) if reason.contains("not tried again")),
        "{outcome:?}"
    );
    fixture.assert_as_before(&keychain);
}

#[test]
fn with_no_memory_yet_only_the_key_is_replaced() {
    let keychain = FakeKeychain::default();
    let root = tempfile::tempdir().unwrap();
    let support = root.path().join("MCI");
    std::fs::create_dir_all(&support).unwrap();
    let old = hex(&random_key());
    keychain.put(V1, &old);
    std::fs::write(support.join("dev.key"), &old).unwrap();
    let trusted = vec![root.path().join("mci-agent")];
    let db = support.join("mci.sqlite");
    let ctx = KeyChangeContext {
        support_dir: &support,
        db_path: &db,
        service: SERVICE,
        reader: &keychain,
        writer: &keychain,
        deleter: &keychain,
        trusted_application_paths: &trusted,
        envelope: &SealedScreenshotEnvelope,
        space: &PLENTY,
        generate: &generate,
        checkpoints: &NoCheckpoints,
    };
    let report = changed(key_change::run_key_change(&ctx).unwrap());
    assert!(report.finished);
    let new = keychain.get(V1).unwrap();
    assert_ne!(new, old);
    assert!(keychain.get(V2).is_none());
    assert!(!support.join("dev.key").exists());
}

#[test]
fn a_key_file_that_is_a_link_is_unlinked_and_its_target_kept() {
    let keychain = FakeKeychain::default();
    let fixture = Fixture::new(9, 64, &keychain);
    let outside = fixture.support.parent().unwrap().join("elsewhere.txt");
    std::fs::write(&outside, b"not ours").unwrap();
    std::os::unix::fs::symlink(&outside, fixture.support.join("dev.key.link")).unwrap();
    changed(fixture.run(&keychain, &NoCheckpoints).unwrap());
    fixture.assert_finished(&keychain);
    assert_eq!(std::fs::read(&outside).unwrap(), b"not ours");
}

// ---------------------------------------------------------------------------
// Settling the Keychain, and what readers find.
// ---------------------------------------------------------------------------

#[test]
fn readers_find_the_key_that_opens_the_memory() {
    let keychain = FakeKeychain::default();
    let fixture = Fixture::new(3, 64, &keychain);
    // Only the usual item.
    assert_eq!(fixture.reader_key(&keychain), fixture.old_key);
    // A newer item that does not open the memory yet (before the rekey).
    let newer = random_key();
    keychain.put(V2, &hex(&newer));
    assert_eq!(fixture.reader_key(&keychain), fixture.old_key);
    // Once the memory is under the newer key, it wins.
    let store = SqlCipherBrainStore::new(&fixture.db, &DbKey::from_bytes(fixture.old_key)).unwrap();
    store.rekey_in_place(&DbKey::from_bytes(newer)).unwrap();
    drop(store);
    assert_eq!(fixture.reader_key(&keychain), newer);
    // The usual item gone: the newer one alone.
    keychain.delete_generic_password(SERVICE, V1).unwrap();
    assert_eq!(fixture.reader_key(&keychain), newer);
    // Any other reference is read exactly.
    let other = KeychainKeyReference {
        service: SERVICE.to_owned(),
        account: "some-other-account".to_owned(),
    };
    keychain.put("some-other-account", &hex(&[9u8; 32]));
    let found = resolve_current_database_key(
        &keychain,
        &SqlCipherDatabaseKeyValidator,
        &other,
        Some(&fixture.db),
    )
    .unwrap();
    assert_eq!(found, hex(&[9u8; 32]));
}

#[test]
fn rekey_is_atomic_and_the_old_key_stops_opening() {
    let keychain = FakeKeychain::default();
    let fixture = Fixture::new(60, 64, &keychain);
    let newer = random_key();
    let store = SqlCipherBrainStore::new(&fixture.db, &DbKey::from_bytes(fixture.old_key)).unwrap();
    store.rekey_in_place(&DbKey::from_bytes(newer)).unwrap();
    drop(store);
    assert!(key_change::opens(&fixture.db, &hex(&newer)));
    assert!(!key_change::opens(&fixture.db, &hex(&fixture.old_key)));
    let reopened =
        SqlCipherBrainStore::open_readonly(&fixture.db, &DbKey::from_bytes(newer)).unwrap();
    reopened.quick_check().unwrap();
    assert_eq!(
        reopened.stats().unwrap().event_count,
        fixture.expected.texts.len() as u64
    );
}

fn settle(fixture: &Fixture, keychain: &FakeKeychain) -> Result<KeyChangeOutcome, KeyChangeError> {
    key_change::settle_key_change(&fixture.ctx(
        keychain,
        &SealedScreenshotEnvelope,
        &PLENTY,
        &NoCheckpoints,
    ))
}

#[test]
fn settling_removes_a_stray_key_that_opens_nothing() {
    let keychain = FakeKeychain::default();
    let fixture = Fixture::new(3, 64, &keychain);
    keychain.put(V2, &hex(&random_key()));
    let outcome = settle(&fixture, &keychain).unwrap();
    assert!(
        matches!(outcome, KeyChangeOutcome::Settled(_)),
        "{outcome:?}"
    );
    assert!(keychain.get(V2).is_none());
    assert_eq!(keychain.get(V1), Some(hex(&fixture.old_key)));
}

#[test]
fn settling_moves_a_key_left_under_the_new_account_back() {
    let keychain = FakeKeychain::default();
    let fixture = Fixture::new(3, 64, &keychain);
    keychain.delete_generic_password(SERVICE, V1).unwrap();
    keychain.put(V2, &hex(&fixture.old_key));
    let outcome = settle(&fixture, &keychain).unwrap();
    assert!(
        matches!(outcome, KeyChangeOutcome::Settled(_)),
        "{outcome:?}"
    );
    assert_eq!(keychain.get(V1), Some(hex(&fixture.old_key)));
    assert!(keychain.get(V2).is_none());
}

#[test]
fn settling_refuses_when_no_key_opens_the_memory() {
    let keychain = FakeKeychain::default();
    let fixture = Fixture::new(3, 64, &keychain);
    keychain.delete_generic_password(SERVICE, V1).unwrap();
    keychain.put(V1, &hex(&random_key()));
    keychain.put(V2, &hex(&random_key()));
    assert!(
        settle(&fixture, &keychain).is_err(),
        "the programs must not start"
    );
}

#[test]
fn a_stray_key_that_can_not_be_deleted_stops_the_start() {
    let keychain = FakeKeychain::default();
    let fixture = Fixture::new(3, 64, &keychain);
    keychain.put(V2, &hex(&random_key()));
    keychain.refuse_delete.lock().unwrap().insert(V2.to_owned());
    // Readers would pick it first, and screenshots would be sealed under a
    // key that opens nothing: ensure-key must fail instead.
    assert!(settle(&fixture, &keychain).is_err());
}

// ---------------------------------------------------------------------------
// Real crashes: the change in another process, killed at random moments.
// ---------------------------------------------------------------------------

const CHILD_ROOT: &str = "MCI_TEST_KEY_CHANGE_CHILD_ROOT";

/// The child side of `a_kill_at_any_moment_resumes_and_finishes`: runs the
/// change on the fixture the parent prepared, slowly, until it is killed.
#[test]
#[ignore = "run by a_kill_at_any_moment_resumes_and_finishes"]
fn child_runs_the_key_change_until_killed() {
    let Ok(root) = std::env::var(CHILD_ROOT) else {
        return;
    };
    let root = PathBuf::from(root);
    let keychain = FakeKeychain::in_file(&root.join("keychain.json"));
    let support = root.join("MCI");
    let db = support.join("mci.sqlite");
    let trusted = vec![root.join("mci-agent")];
    let pause = Dawdle(Duration::from_millis(3));
    let ctx = KeyChangeContext {
        support_dir: &support,
        db_path: &db,
        service: SERVICE,
        reader: &keychain,
        writer: &keychain,
        deleter: &keychain,
        trusted_application_paths: &trusted,
        envelope: &SealedScreenshotEnvelope,
        space: &PLENTY,
        generate: &generate,
        checkpoints: &pause,
    };
    std::fs::write(root.join("started"), b"").unwrap();
    let _ = key_change::run_key_change(&ctx);
    std::fs::write(root.join("finished"), b"").unwrap();
}

#[test]
fn a_kill_at_any_moment_resumes_and_finishes() {
    let mut killed_mid_change = 0;
    for round in 0..20_u64 {
        let keychain_seed = FakeKeychain::default();
        let fixture = Fixture::new(60, 4_000, &keychain_seed);
        let root = fixture.support.parent().unwrap().to_path_buf();
        let keychain = FakeKeychain::in_file(&root.join("keychain.json"));
        keychain.put(V1, &hex(&fixture.old_key));

        let mut child = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "child_runs_the_key_change_until_killed",
                "--ignored",
                "--nocapture",
            ])
            .env(CHILD_ROOT, &root)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn the change");
        let deadline = Instant::now() + Duration::from_secs(30);
        while !root.join("started").exists() {
            assert!(Instant::now() < deadline, "the child never started");
            std::thread::sleep(Duration::from_millis(2));
        }
        // Kill it 0–380 ms in: before, during and after every phase.
        std::thread::sleep(Duration::from_millis(round * 20));
        let _ = child.kill();
        let _ = child.wait();
        if !root.join("finished").exists() && fixture.change_dir().join(JOURNAL_FILE).exists() {
            killed_mid_change += 1;
        }

        // Whatever it was doing, the memory is whole under the key readers
        // find, and every screenshot opens with one of the two keys.
        let found = fixture.reader_key(&keychain);
        fixture.assert_whole(&found, Some(&fixture.old_key));

        // The next launch finishes it.
        let outcome = key_change::run_key_change(&fixture.ctx(
            &keychain,
            &SealedScreenshotEnvelope,
            &PLENTY,
            &NoCheckpoints,
        ))
        .unwrap_or_else(|error| panic!("round {round}: {error}"));
        match outcome {
            KeyChangeOutcome::Changed(report) => {
                assert!(report.finished, "round {round}: {report:?}");
            }
            KeyChangeOutcome::NotNeeded => {}
            other => panic!("round {round}: {other:?}"),
        }
        fixture.assert_finished(&keychain);
    }
    mci_agent::errln!("{killed_mid_change} of 20 kills landed mid-change");
    assert!(
        killed_mid_change >= 6,
        "only {killed_mid_change} kills landed mid-change"
    );
}

// ---------------------------------------------------------------------------
// A huge store, timed. Run on purpose:
//   MCI_KEY_CHANGE_HUGE=1 cargo test -p mci-agent --test key_change -- --ignored huge --nocapture
// ---------------------------------------------------------------------------

#[test]
#[ignore = "builds a large synthetic memory; run on purpose"]
fn a_huge_store_changes_key_in_reasonable_time() {
    if std::env::var("MCI_KEY_CHANGE_HUGE").as_deref() != Ok("1") {
        return;
    }
    let moments: u64 = std::env::var("MCI_KEY_CHANGE_HUGE_MOMENTS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(60_000);
    let picture: usize = std::env::var("MCI_KEY_CHANGE_HUGE_PICTURE")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(120_000);
    let keychain = FakeKeychain::default();
    let built = Instant::now();
    let fixture = Fixture::new(moments, picture, &keychain);
    let db_bytes = std::fs::metadata(&fixture.db).unwrap().len();
    let blob_bytes: u64 = std::fs::read_dir(fixture.support.join("blobs"))
        .unwrap()
        .map(|e| e.unwrap().metadata().unwrap().len())
        .sum();
    mci_agent::errln!(
        "huge store: {moments} moments, {} screenshots, database {} MB, screenshots {} MB, built in {:.1} s",
        fixture.expected.pictures.len(),
        db_bytes / 1_000_000,
        blob_bytes / 1_000_000,
        built.elapsed().as_secs_f64()
    );
    let timer = Instant::now();
    let report = changed(fixture.run(&keychain, &NoCheckpoints).unwrap());
    mci_agent::errln!(
        "huge store: key changed in {:.1} s ({} screenshots re-sealed)",
        timer.elapsed().as_secs_f64(),
        report.screenshots_resealed
    );
    assert!(report.finished);
    let verify = Instant::now();
    fixture.assert_finished(&keychain);
    mci_agent::errln!(
        "huge store: verified in {:.1} s",
        verify.elapsed().as_secs_f64()
    );
}

// ---------------------------------------------------------------------------
// A real full disk. Run on purpose, with a small volume mounted at
// MCI_KEY_CHANGE_SMALL_VOLUME (scripts/test-key-change-full-disk.sh).
// ---------------------------------------------------------------------------

#[test]
#[ignore = "needs a small mounted volume; run on purpose"]
fn a_really_full_disk_undoes_or_postpones_and_loses_nothing() {
    let Ok(volume) = std::env::var("MCI_KEY_CHANGE_SMALL_VOLUME") else {
        return;
    };
    let volume = PathBuf::from(volume);
    let keychain = FakeKeychain::default();
    let fixture = Fixture::new(400, 30_000, &keychain);
    // Move the memory onto the small volume.
    let support = volume.join("MCI");
    let _ = std::fs::remove_dir_all(&support);
    let status = Command::new("/bin/cp")
        .arg("-R")
        .arg(&fixture.support)
        .arg(&support)
        .status()
        .unwrap();
    assert!(status.success());
    let db = support.join("mci.sqlite");
    // Fill the volume until less than the change needs is free.
    let filler = volume.join("filler.bin");
    let free = key_change::VolumeSpace.available_bytes(&volume).unwrap();
    let db_bytes = std::fs::metadata(&db).unwrap().len();
    let target = free.saturating_sub(db_bytes / 2);
    let file = std::fs::File::create(&filler).unwrap();
    file.set_len(target).unwrap();
    {
        // Really allocate it: write it.
        use std::io::Write as _;
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .open(&filler)
            .unwrap();
        let chunk = vec![0x5a_u8; 1 << 20];
        let mut written = 0;
        while written < target {
            if file.write_all(&chunk).is_err() {
                break;
            }
            written += chunk.len() as u64;
        }
    }
    let trusted = fixture.trusted.clone();
    // The real space probe: postponed, untouched.
    let ctx = KeyChangeContext {
        support_dir: &support,
        db_path: &db,
        service: SERVICE,
        reader: &keychain,
        writer: &keychain,
        deleter: &keychain,
        trusted_application_paths: &trusted,
        envelope: &SealedScreenshotEnvelope,
        space: &key_change::VolumeSpace,
        generate: &generate,
        checkpoints: &NoCheckpoints,
    };
    let outcome = key_change::run_key_change(&ctx).unwrap();
    mci_agent::errln!("full disk, real probe: {outcome:?}");
    assert!(
        matches!(outcome, KeyChangeOutcome::Deferred(_)),
        "{outcome:?}"
    );
    // A probe that lies: the change runs into the real full disk, and is
    // undone, or postponed, with nothing lost.
    let ctx = KeyChangeContext {
        space: &PLENTY,
        ..ctx
    };
    let outcome = key_change::run_key_change(&ctx);
    mci_agent::errln!("full disk, lying probe: {outcome:?}");
    let found = resolve_current_database_key(
        &keychain,
        &SqlCipherDatabaseKeyValidator,
        &KeychainKeyReference::default(),
        Some(&db),
    )
    .unwrap();
    let found = key_change::decode_key(&found).unwrap();
    let store = SqlCipherBrainStore::open_readonly(&db, &DbKey::from_bytes(found)).unwrap();
    assert_eq!(
        store.stats().unwrap().event_count,
        fixture.expected.texts.len() as u64
    );
    for (id, text) in &fixture.expected.texts {
        let event = store.get_event(EventId(*id)).unwrap().unwrap();
        assert_eq!(&event.text, text);
        if let Some(plaintext) = fixture.expected.pictures.get(id) {
            let digest = event.keyframe_blob.unwrap();
            let sealed =
                std::fs::read(support.join("blobs").join(format!("{digest}.bin"))).unwrap();
            let opened = SealedScreenshotEnvelope
                .open(&sealed, &found)
                .expect("opens");
            assert_eq!(opened.as_slice(), plaintext.as_slice());
        }
    }
    drop(store);
    std::fs::remove_file(&filler).unwrap();
    let _ = std::fs::remove_dir_all(&support);
}

// ---------------------------------------------------------------------------
// `ensure-key`, which the app runs before it starts anything, wires it in.
// ---------------------------------------------------------------------------

#[test]
fn ensure_key_settles_first_validates_then_changes_under_the_writer_lease() {
    let source = include_str!("../src/bin/mci_agent.rs");
    let start = source
        .find("fn run_ensure_key_with_lease")
        .expect("ensure-key body");
    let body = &source[start..];
    let body = &body[..body.find("\n}\n").expect("end of body")];
    let settle = body
        .find("settle_key_change(")
        .expect("settles an unfinished change");
    let validate = body
        .find("initialize_database_key_with_remover(")
        .expect("validates the usual item");
    let change = body.find("run_due_key_change(").expect("runs a due change");
    assert!(source.contains("mci_agent::key_change::run_key_change(ctx)"));
    assert!(
        settle < validate && validate < change,
        "an unfinished change is settled before the usual item is read, and a due one runs after"
    );
    assert!(
        body.contains("ShreddingLegacyKeyRemover"),
        "a legacy key file is marked for the change, then shredded"
    );
    assert!(
        body.contains("take_writer_lease("),
        "the change runs under the writer lease"
    );
    assert!(source.contains("match acquire_lock(&lock_path_for_brain(db_path))"));
    assert!(
        source.contains("run_ensure_key_with_lease(db_path, Some(&lease))"),
        "init passes the lease it holds"
    );
}

// ---------------------------------------------------------------------------
// Delete Everything as a crypto-shred (storage-security review S3).
// ---------------------------------------------------------------------------

fn erase(
    fixture: &Fixture,
    keychain: &FakeKeychain,
) -> Result<mci_agent::erase::EraseReport, mci_agent::erase::EraseError> {
    mci_agent::erase::erase_memory(&mci_agent::erase::EraseContext {
        support_dir: &fixture.support,
        db_path: &fixture.db,
        service: SERVICE,
        deleter: keychain,
    })
}

#[test]
fn erasing_deletes_the_memory_and_its_key_so_no_earlier_copy_opens() {
    let keychain = FakeKeychain::default();
    let fixture = Fixture::new(30, 500, &keychain);
    // A copy someone took, or a backup: the database and its screenshots.
    let copy = fixture.support.parent().unwrap().join("backup-copy");
    let status = Command::new("/bin/cp")
        .arg("-R")
        .arg(&fixture.support)
        .arg(&copy)
        .status()
        .unwrap();
    assert!(status.success());
    // A key change left half done, with its backup under the old key.
    assert!(fixture
        .run(&keychain, &StopAt::new(Step::BackedUp, 1))
        .is_err());
    assert!(fixture.change_dir().join(BACKUP_FILE).exists());

    let report = erase(&fixture, &keychain).expect("erase");
    assert!(report.database_files_deleted >= 1);
    assert_eq!(
        report.screenshots_deleted, 10,
        "nine sealed screenshots and the damaged one"
    );
    assert_eq!(report.key_files_deleted, 1);
    assert!(!fixture.db.exists());
    assert!(std::fs::read_dir(fixture.support.join("blobs"))
        .unwrap()
        .next()
        .is_none());
    assert!(
        !fixture.change_dir().exists(),
        "the key change's backup is gone"
    );
    assert!(key_change::key_files(&fixture.support).unwrap().is_empty());
    assert!(!mci_agent::erase::erase_pending(&fixture.support));
    // The key is gone from the Keychain, under both accounts.
    assert!(keychain.get(V1).is_none());
    assert!(keychain.get(V2).is_none());
    // So the copy opens with nothing the Mac still holds; it opened with
    // the old key only.
    assert!(key_change::opens(
        &copy.join("mci.sqlite"),
        &hex(&fixture.old_key)
    ));
    for value in keychain.load().values() {
        assert!(!key_change::opens(&copy.join("mci.sqlite"), value));
    }
}

#[test]
fn an_erase_the_keychain_refuses_keeps_its_marker_until_the_key_is_gone() {
    let keychain = FakeKeychain::default();
    let fixture = Fixture::new(9, 64, &keychain);
    keychain.refuse_delete.lock().unwrap().insert(V1.to_owned());
    assert!(matches!(
        erase(&fixture, &keychain),
        Err(mci_agent::erase::EraseError::Keychain(_))
    ));
    // The files are gone, and the marker stays, so `ensure-key` finishes
    // the erase before any key is used for a new memory.
    assert!(!fixture.db.exists());
    assert!(mci_agent::erase::erase_pending(&fixture.support));
    assert_eq!(keychain.get(V1), Some(hex(&fixture.old_key)));
    keychain.refuse_delete.lock().unwrap().clear();
    erase(&fixture, &keychain).expect("finishes");
    assert!(keychain.get(V1).is_none());
    assert!(!mci_agent::erase::erase_pending(&fixture.support));
}

#[test]
fn ensure_key_finishes_an_unfinished_erase_before_anything_else() {
    let source = include_str!("../src/bin/mci_agent.rs");
    let start = source
        .find("fn run_ensure_key_with_lease")
        .expect("ensure-key body");
    let body = &source[start..];
    let body = &body[..body.find("\n}\n").expect("end of body")];
    let erase = body
        .find("erase::erase_pending(")
        .expect("checks for an unfinished erase");
    let settle = body.find("settle_key_change(").expect("settles");
    let validate = body
        .find("initialize_database_key_with_remover(")
        .expect("validates");
    assert!(
        erase < settle && erase < validate,
        "the old key is never validated or reused first"
    );
    let command = source
        .find("fn run_erase_memory_cmd")
        .expect("erase-memory command");
    let command = &source[command..];
    let command = &command[..command.find("\n}\n").expect("end")];
    assert!(
        command.contains("acquire_command_writer_lease(WriterCommand::Erase"),
        "runs under the writer lease"
    );
    assert!(
        command.contains("DevelopmentKeychainDeleter"),
        "a development build never deletes a real Keychain item"
    );
}
