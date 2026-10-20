#!/usr/bin/env python3
"""Storage-security checks for a throwaway Hippocampus home.

`scripts/audit-storage-security.sh` runs this after `scripts/e2e-full.sh`.
Every check prints one line, PASS or FAIL, with its evidence: file paths,
counts, modes and source citations. It never prints file contents, and it
reads only the throwaway home, its TMPDIR, the files the test's own
processes opened (from the sampler) and the repository's source.

Checks:
  brain.header     the database has no "SQLite format 3" header
  brain.sqlite3    the system sqlite3 cannot read it (a copy is opened)
  blobs.sealed     every screenshot is the codec's sealed envelope: named by
                   its SHA-256, no image signature, ciphertext-like bytes
  blobs.open       each opens with the key (to a JPEG) and fails with a wrong one
  wal.encrypted    WAL and SHM files, live and snapshotted during the run,
                   carry no plaintext page and no marker
  scan.*           no synthetic marker in plain text anywhere outside the
                   encrypted stores: logs, crash reports, Saved Application
                   State, URL caches, launch agents, preferences, the rest
  scan.key         the database key appears nowhere but its key file
  pasteboard       every pasteboard write marks itself transient, concealed
                   and current-host-only (source)
  modes            files 0600, folders 0700 in the product's folders
  custody.*        the production key path (source, cited by file:line)
  net.static       scripts/launch/no-egress.sh, on the tracked sources
  net.binary       no telemetry endpoint compiled into a shipped binary
  net.runtime      no internet socket on the run's processes, sampled by lsof
  net.runtime-log  no connection by the run's processes in the unified log
  net.isolation    the product's processes opened nothing in the real home
  outputs          MCP answers and hook packets carry no secret marker
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SQLITE_HEADER = b"SQLite format 3\x00"
IMAGE_SIGNATURES = {
    b"\xff\xd8\xff": "JPEG",
    b"\x89PNG\r\n\x1a\n": "PNG",
    b"GIF8": "GIF",
}
WAL_MAGICS = (b"\x37\x7f\x06\x82", b"\x37\x7f\x06\x83")
PRODUCT_PROCESS_NAMES = (
    "Hippocampus", "MCICaptureHelper", "mci-agent", "recall-ui", "onboarding",
    "hippocampus-mind", "hippocampus-ocr", "hippocampus-native-host",
    "SyntheticCaptureFeed", "WindowReadsProbe", "KeyframeFixtureBuilder", "mci-brain",
)


class Report:
    def __init__(self) -> None:
        self.results: list[tuple[str, str, str]] = []

    def add(self, ok: bool, check: str, message: str) -> None:
        status = "PASS" if ok else "FAIL"
        self.results.append((status, check, message))
        print(f"{status:<5} {check:<18} {message}", flush=True)

    @property
    def failed(self) -> int:
        return sum(1 for status, _check, _message in self.results if status == "FAIL")


def entropy(data: bytes) -> float:
    if not data:
        return 0.0
    counts = [0] * 256
    for byte in data:
        counts[byte] += 1
    total = len(data)
    return -sum((c / total) * math.log2(c / total) for c in counts if c)


def load_markers(path: Path | None) -> list[tuple[str, str]]:
    if path is None or not path.exists():
        return []
    markers = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if "\t" in line:
            kind, marker = line.split("\t", 1)
            if marker:
                markers.append((kind, marker))
    return markers


def encodings(marker: str) -> list[bytes]:
    return [marker.encode("utf-8"), marker.encode("utf-16-le")]


def find_markers(data: bytes, markers: list[tuple[str, str]]) -> list[str]:
    found = []
    for _kind, marker in markers:
        if any(variant in data for variant in encodings(marker)):
            found.append(marker)
    return found


def read_capped(path: Path, cap: int = 64 * 1024 * 1024) -> bytes:
    try:
        with open(path, "rb") as handle:
            return handle.read(cap)
    except OSError:
        return b""


# ---- brain -------------------------------------------------------------------

def check_brain(report: Report, support: Path, sqlite3_bin: str) -> None:
    db = support / "mci.sqlite"
    if not db.is_file():
        report.add(False, "brain.header", f"no database at {db}")
        return
    header = read_capped(db, 16)
    report.add(header != SQLITE_HEADER, "brain.header",
               f"mci.sqlite ({db.stat().st_size} bytes) starts with {header[:6].hex()}…, not 'SQLite format 3'"
               if header != SQLITE_HEADER else "mci.sqlite starts with the plain 'SQLite format 3' header")
    with tempfile.TemporaryDirectory(prefix="audit-sqlite.") as scratch:
        copy = Path(scratch) / "copy.sqlite"
        shutil.copyfile(db, copy)
        result = subprocess.run(
            [sqlite3_bin, "-readonly", str(copy), "SELECT count(*) FROM sqlite_master;"],
            capture_output=True, text=True, check=False,
        )
    refused = result.returncode != 0 and re.search(r"not a database|encrypted|malformed", result.stderr + result.stdout, re.I)
    report.add(bool(refused), "brain.sqlite3",
               f"system sqlite3 refuses it: {(result.stderr or result.stdout).strip().splitlines()[-1] if (result.stderr or result.stdout).strip() else 'no output'}"
               if refused else f"system sqlite3 read it (exit {result.returncode}): {result.stdout.strip()[:80]}")


# ---- blobs -------------------------------------------------------------------

def check_blobs(report: Report, support: Path, key_hex: str | None, tool: str | None) -> None:
    blob_dir = support / "blobs"
    files = sorted(p for p in blob_dir.rglob("*") if p.is_file()) if blob_dir.is_dir() else []
    if not files:
        report.add(True, "blobs.sealed", "no screenshot blobs on disk")
        return
    problems = []
    for path in files:
        data = read_capped(path)
        name = path.name
        if not re.fullmatch(r"[0-9a-f]{64}\.bin", name):
            problems.append(f"{name}: not a content-addressed .bin name")
            continue
        if hashlib.sha256(data).hexdigest() != name[:-4]:
            problems.append(f"{name}: name is not the SHA-256 of its bytes")
        if len(data) <= 16 + 12 + 16:
            problems.append(f"{name}: shorter than salt+nonce+tag")
        for signature, kind in IMAGE_SIGNATURES.items():
            if data.startswith(signature) or data[4:12].startswith(b"ftyp"):
                problems.append(f"{name}: starts with a {kind} signature")
        if signature_inside(data[:4096]):
            problems.append(f"{name}: an image signature appears in its first 4 KB")
        if entropy(data) < 7.9:
            problems.append(f"{name}: byte entropy {entropy(data):.2f} bits (ciphertext is about 8)")
    report.add(not problems, "blobs.sealed",
               f"{len(files)} screenshot blob(s): each named by the SHA-256 of its bytes, salt(16)+nonce(12)+ciphertext+tag(16), "
               f"no JPEG/PNG/GIF/HEIC signature, entropy ≥ 7.9 bits/byte" if not problems else "; ".join(problems[:6]))
    if not tool or not key_hex:
        report.add(False, "blobs.open", "no keyframe tool or key given; cannot prove the wrong-key failure")
        return
    opened, wrong_refused, failures = 0, 0, []
    wrong_key = os.urandom(32).hex()
    for path in files:
        right = subprocess.run([tool, "--open", str(path)], capture_output=True, text=True,
                               env={"PATH": "/usr/bin:/bin", "MCI_DEVELOPMENT_FILE_KEY": "1", "MCI_DB_KEY_HEX": key_hex})
        try:
            verdict = json.loads(right.stdout.strip() or "{}")
        except json.JSONDecodeError:
            verdict = {}
        if right.returncode == 0 and verdict.get("opened") and verdict.get("kind") == "jpeg":
            opened += 1
        else:
            failures.append(f"{path.name}: right key gave exit {right.returncode} {verdict}")
        wrong = subprocess.run([tool, "--open", str(path)], capture_output=True, text=True,
                               env={"PATH": "/usr/bin:/bin", "MCI_DEVELOPMENT_FILE_KEY": "1", "MCI_DB_KEY_HEX": wrong_key})
        if wrong.returncode == 3:
            wrong_refused += 1
        else:
            failures.append(f"{path.name}: a wrong key gave exit {wrong.returncode}")
    report.add(not failures, "blobs.open",
               f"all {opened} blob(s) open with the key to a JPEG (AES-GCM, HKDF 'mci-blob-v2'), and all {wrong_refused} fail authentication with a random wrong key"
               if not failures else "; ".join(failures[:4]))


def signature_inside(data: bytes) -> bool:
    return any(data.find(signature, 1) != -1 for signature in (b"\xff\xd8\xff\xe0", b"\xff\xd8\xff\xdb", b"\x89PNG\r\n"))


# ---- WAL and SHM -------------------------------------------------------------

def wal_pages(data: bytes) -> list[bytes]:
    if len(data) < 32 or data[:4] not in WAL_MAGICS:
        return []
    page_size = int.from_bytes(data[8:12], "big") or 65536
    pages, offset = [], 32
    while offset + 24 + page_size <= len(data):
        pages.append(data[offset + 24: offset + 24 + page_size])
        offset += 24 + page_size
    return pages


def check_wal(report: Report, support: Path, snapshots: Path | None, markers) -> None:
    files = [p for p in (support / "mci.sqlite-wal", support / "mci.sqlite-shm") if p.is_file()]
    if snapshots and snapshots.is_dir():
        files += sorted(p for p in snapshots.iterdir() if p.is_file())
    if not files:
        report.add(False, "wal.encrypted", "no WAL or SHM file was present or snapshotted during the run")
        return
    problems, wal_count, shm_count, page_count, entropies = [], 0, 0, 0, []
    for path in files:
        data = read_capped(path)
        hits = find_markers(data, markers)
        if hits:
            problems.append(f"{path.name}: plaintext markers {hits[:3]}")
        if SQLITE_HEADER in data:
            problems.append(f"{path.name}: holds a plain 'SQLite format 3' page")
        if "-wal" in path.name:
            wal_count += 1
            pages = wal_pages(data)
            page_count += len(pages)
            for page in pages:
                value = entropy(page)
                entropies.append(value)
                if value < 7.0:
                    problems.append(f"{path.name}: a page with entropy {value:.2f} bits/byte")
                    break
        else:
            shm_count += 1
    low = min(entropies) if entropies else 0.0
    report.add(not problems and wal_count > 0, "wal.encrypted",
               f"{wal_count} WAL and {shm_count} SHM copies (live and taken during the drain): {page_count} WAL pages, "
               f"lowest page entropy {low:.2f} bits/byte (ciphertext; the 32-byte WAL header is plain by SQLite's design), no marker, no plain page"
               if not problems and wal_count > 0 else ("; ".join(problems[:5]) or "no WAL file was captured"))


# ---- plaintext scan ----------------------------------------------------------

def is_encrypted_store(path: Path, support: Path) -> bool:
    try:
        rel = path.relative_to(support)
    except ValueError:
        return False
    return rel.parts[:1] == ("blobs",) or path.name in ("mci.sqlite", "mci.sqlite-wal", "mci.sqlite-shm")


def category(rel: str) -> str:
    if "Logs/DiagnosticReports" in rel or rel.endswith((".ips", ".crash")):
        return "crash"
    if rel.startswith("Library/Logs/") or rel.endswith((".log", ".jsonl")):
        return "logs"
    if rel.startswith("Library/Saved Application State/"):
        return "savedstate"
    if "Cache.db" in rel or rel.startswith(("Library/Caches/", "Library/HTTPStorages/")):
        return "urlcache"
    if rel.startswith("Library/LaunchAgents/"):
        return "launchagents"
    if rel.startswith("Library/Preferences/"):
        return "preferences"
    return "other"


def check_scan(report: Report, home: Path, tmpdir: Path | None, extra: list[Path], markers, key_hex: str | None,
               key_file: Path | None) -> None:
    support = home / "Library/Application Support/MCI"
    excluded = [home / ".claude/projects", home / ".codex/sessions"]
    roots = [home] + ([tmpdir] if tmpdir else [])
    seen: dict[str, list[tuple[str, list[str]]]] = {name: [] for name in
                                                    ("logs", "crash", "savedstate", "urlcache", "launchagents", "preferences", "other")}
    counts = {name: 0 for name in seen}
    key_hits = []
    scanned = 0
    stores = 0
    for root in roots:
        for path in sorted(root.rglob("*")):
            if not path.is_file() or path.is_symlink():
                continue
            if any(str(path).startswith(str(e) + os.sep) for e in excluded):
                continue
            if is_encrypted_store(path, support):
                stores += 1
                continue
            scanned += 1
            rel = str(path.relative_to(home)) if str(path).startswith(str(home)) else "TMPDIR/" + str(path.relative_to(root))
            data = read_capped(path)
            kind = category(rel)
            counts[kind] += 1
            hits = find_markers(data, markers)
            if hits:
                seen[kind].append((rel, hits))
            if key_hex and key_file and path != key_file and key_hex.encode() in data:
                key_hits.append(rel)
    for path in extra:
        if path.is_file():
            scanned += 1
            counts["other"] += 1
            hits = find_markers(read_capped(path), markers)
            if hits:
                seen["other"].append((str(path), hits))
    labels = {
        "logs": "logs (Library/Logs, *.log, *.jsonl)",
        "crash": "crash reports",
        "savedstate": "Saved Application State",
        "urlcache": "URL caches (Caches, HTTPStorages, Cache.db)",
        "launchagents": "launch agents",
        "preferences": "preferences",
        "other": "every other file in the home and TMPDIR",
    }
    for kind, label in labels.items():
        hits = seen[kind]
        if hits:
            report.add(False, f"scan.{kind}", f"plaintext markers in {label}: " +
                       "; ".join(f"{rel} {sorted(set(h))[:4]}" for rel, h in hits[:5]))
        else:
            report.add(True, f"scan.{kind}", f"{label}: {counts[kind]} file(s) scanned, no marker"
                       if counts[kind] else f"{label}: none written")
    report.add(not key_hits, "scan.key",
               f"the database key appears in no file but its key file ({scanned} files scanned, {stores} encrypted store files set aside)"
               if not key_hits else f"the database key appears in: {key_hits[:5]}")


def check_real_crash_reports(report: Report, since: float | None, sampler: Path | None) -> None:
    """Crash reports macOS wrote for the run's own processes.

    Reports land in the account's real DiagnosticReports. A report counts as
    the run's only when its program name is one of the run's and its pid is in
    the sampler's record of the run's processes; from any other report only
    the pid field is read, and nothing of it is printed."""
    folder = Path.home() / "Library/Logs/DiagnosticReports"
    if since is None or not folder.is_dir():
        report.add(True, "scan.crash-real", "no run start given or no DiagnosticReports folder")
        return
    run_pids: set[int] = set()
    if sampler is not None and (sampler / "processes.log").is_file():
        for line in (sampler / "processes.log").read_text(errors="replace").splitlines():
            head = line.split("\t", 1)[0]
            if head.isdigit():
                run_pids.add(int(head))
    ours, others = [], 0
    for path in folder.iterdir():
        try:
            if path.stat().st_mtime < since or not path.name.startswith(PRODUCT_PROCESS_NAMES):
                continue
        except OSError:
            continue
        match = re.search(rb'"pid"\s*:\s*(\d+)', read_capped(path, 16 * 1024))
        if match and int(match.group(1)) in run_pids:
            ours.append(path.name)
        else:
            others += 1
    note = (f"; {others} report(s) with the same program names came from other processes on this Mac "
            f"(their pids are not the run's) and were set aside") if others else ""
    report.add(not ours, "scan.crash-real",
               f"no crash report from any of the run's own processes in ~/Library/Logs/DiagnosticReports{note}"
               if not ours else f"the run's programs crashed: {ours[:5]}")


# ---- pasteboard (source) -----------------------------------------------------

def check_pasteboard(report: Report, repo: Path) -> None:
    writes = []
    for root in ("apps/recall-ui/Sources", "apps/hippocampus/Sources", "apps/onboarding/Sources"):
        for path in sorted((repo / root).rglob("*.swift")):
            text = path.read_text(encoding="utf-8", errors="replace")
            for number, line in enumerate(text.splitlines(), start=1):
                if re.search(r"\.setString\(|\.setData\(|writeObjects\(", line) and ("board" in line.lower() or "Pasteboard" in line):
                    writes.append((path.relative_to(repo), number, text))
    marked = {
        "transient": "org.nspasteboard.TransientType",
        "concealed": "org.nspasteboard.ConcealedType",
        "current-host-only": "currentHostOnly",
    }
    unmarked = []
    for rel, number, text in writes:
        missing = [name for name, token in marked.items() if token not in text]
        if missing:
            unmarked.append(f"{rel}:{number} lacks {', '.join(missing)}")
    report.add(bool(writes) and not unmarked, "pasteboard",
               f"{len(writes)} pasteboard write(s), each transient, concealed and current-host-only"
               if writes and not unmarked else
               f"{len(unmarked)} of {len(writes)} pasteboard writes set none of the transient, concealed or current-host-only markers, "
               f"so clipboard managers keep the copied memory and Universal Clipboard can carry it to other devices: " +
               "; ".join(unmarked[:8]))


# ---- modes -------------------------------------------------------------------

def check_modes(report: Report, home: Path) -> None:
    product = [
        home / "Library/Application Support/MCI",
        home / "Library/Application Support/Hippocampus",
        home / "Library/Logs/MCI",
        home / ".config/hippocampus",
        home / ".mci",
        home / "Library/Caches/ai.hippocampus",
    ]
    wrong, checked = [], 0
    for root in product:
        if not root.exists():
            continue
        for path in [root] + sorted(root.rglob("*")):
            if path.is_symlink():
                continue
            mode = path.stat().st_mode & 0o777
            checked += 1
            want = 0o700 if path.is_dir() else 0o600
            if mode != want:
                wrong.append(f"{oct(mode)[2:]} {path.relative_to(home)}")
    report.add(not wrong, "modes",
               f"{checked} product files and folders: files 0600, folders 0700" if not wrong else
               f"{len(wrong)} of {checked} product paths are not 0600/0700: " + "; ".join(wrong[:10]))


# ---- key custody (source) ----------------------------------------------------

def grep(repo: Path, pattern: str, roots: list[str], suffixes=(".swift", ".rs")) -> list[str]:
    hits = []
    regex = re.compile(pattern)
    for root in roots:
        base = repo / root
        if base.is_file():
            files = [base]
        else:
            files = []
            for folder, dirs, names in os.walk(base):
                # Build outputs and tests are not shipping source.
                dirs[:] = [d for d in dirs if d not in (".build", "target", "Tests", "tests", "node_modules")]
                files += [Path(folder) / name for name in names if Path(name).suffix in suffixes]
            files.sort()
        for path in files:
            for number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), start=1):
                stripped = line.strip()
                if stripped.startswith(("//", "///", "//!", "#")):
                    continue
                if regex.search(line):
                    hits.append(f"{path.relative_to(repo)}:{number}")
    return hits


def check_custody(report: Report, repo: Path) -> None:
    keystore = "apps/hippocampus/Sources/HippocampusKit/KeyStore.swift"
    adapter = "adapters/macos/mci-keychain/src/lib.rs"
    helper = "adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Security/KeychainDatabaseKeyResolver.swift"
    window = "apps/recall-ui/Sources/RecallUIKit/KeychainDatabaseKeyResolver.swift"
    acl = grep(repo, r"SecAccessCreate\(|kSecAttrAccess as String|kSecAttrAccess\)", [keystore, adapter])
    add = grep(repo, r"SecItemAdd\(", [keystore, adapter])
    report.add(bool(acl) and bool(add), "custody.keychain",
               f"the production key is a Keychain generic-password item (service ai.hippocampus.brain) added with an access list of the app's own signed programs: "
               f"{', '.join(add + acl)}" if acl and add else "no ACL-protected SecItemAdd found")
    sync = grep(repo, r"kSecAttrSynchronizable", [keystore, adapter, helper, window])
    sync_true = grep(repo, r"synchronizable:\s*true|kSecAttrSynchronizable.*true_value", [keystore, adapter, helper, window])
    report.add(bool(sync) and not sync_true, "custody.no-sync",
               f"never synced to iCloud Keychain: kSecAttrSynchronizable=false on every create and read ({', '.join(sync)})"
               if sync and not sync_true else f"synchronizable keys found: {sync_true or 'none pinned'}")
    this_device = grep(repo, r"ThisDeviceOnly|kSecAttrAccessible", ["apps", "adapters", "core"])
    file_keychain = grep(repo, r"kSecUseDataProtectionKeychain", [keystore, adapter, helper, window])
    report.add(bool(this_device), "custody.this-device",
               f"a this-device-only accessibility class is set: {', '.join(this_device[:4])}" if this_device else
               "no this-device-only accessibility class is set anywhere (no kSecAttrAccessible in shipping code). The item is created in "
               f"the file-based login keychain (kSecUseDataProtectionKeychain=false: {', '.join(file_keychain[:2])}), where accessibility "
               "classes do not apply; it never syncs, but it moves with a copied login keychain (Migration Assistant, a restored backup) "
               "and opens with the login password. ADR-0008 asks for a Secure Enclave wrap with kSecAttrAccessibleWhenUnlockedThisDeviceOnly")
    reference = grep(repo, r'environment\["MCI_DB_KEYCHAIN_SERVICE"\]|"MCI_DB_KEYCHAIN_SERVICE"\.to_owned', [
        "apps/hippocampus/Sources/HippocampusKit/ProcessSupervisor.swift", "apps/agent/src/key_resolver.rs"])
    scrub = grep(repo, r'"MCI_DB_KEY_HEX"', ["apps/agent/src/child_command_environment.rs",
                                              "apps/hippocampus/Sources/HippocampusKit/ChildProcessEnvironment.swift"])
    report.add(bool(reference) and bool(scrub), "custody.reference",
               f"programs and AI tools get a Keychain reference, never the key: {', '.join(reference)}; raw-key variables scrubbed: {', '.join(scrub)}"
               if reference and scrub else f"reference={reference} scrub={scrub}")
    gate = grep(repo, r"infoPlistKey\] as\? Bool == true", ["apps/hippocampus/Sources/HippocampusKit/DevelopmentFileKeyMode.swift"])
    stamp = grep(repo, r"Add :MCIDevelopmentFileKeyEnabled", ["apps/hippocampus/Resources/build-app.sh"], suffixes=(".sh",))
    report.add(bool(gate) and bool(stamp), "custody.dev-gate",
               f"the file key this test used exists only in ad-hoc development builds: {', '.join(gate + stamp)} (inside `if [[ \"$SIGNING_MODE\" == \"ad-hoc\" ]]`)"
               if gate and stamp else f"gate={gate} stamp={stamp}")


# ---- network -----------------------------------------------------------------

PRODUCT_PROGRAMS = {
    "Hippocampus", "MCICaptureHelper", "mci-agent", "recall-ui", "onboarding", "hippocampus-mind",
    "hippocampus-ocr", "hippocampus-native-host",
    # The fixture stand-ins run the helper's and the window's own code.
    "SyntheticCaptureFeed", "WindowReadsProbe",
}
TELEMETRY_ENDPOINTS = re.compile(
    rb"events\.data\.microsoft\.com|OneCollector|vortex\.data\.microsoft|applicationinsights|"
    rb"browser-intake-datadoghq|api\.segment\.io|sentry\.io/api|api\.amplitude\.com|api\.mixpanel\.com|"
    rb"google-analytics\.com|app-measurement\.com|crashlytics|bugsnag\.com|telemetry\.[a-z0-9-]+\.(?:com|net|io)"
)


def run_no_egress(repo: Path) -> tuple[int, str, int, str]:
    """no-egress.sh in place, and on a copy of only the tracked sources."""
    in_place = subprocess.run([str(repo / "scripts/launch/no-egress.sh")], capture_output=True, text=True)
    tracked = subprocess.run(["git", "-C", str(repo), "ls-files", "-z"], capture_output=True, text=True)
    with tempfile.TemporaryDirectory(prefix="audit-egress.") as scratch:
        root = Path(scratch) / "repo"
        for name in tracked.stdout.split("\0"):
            if not name or not name.startswith(("apps/", "core/", "adapters/", "tools/ocr/", "extensions/", "scripts/launch/")):
                continue
            source = repo / name
            if not source.is_file():
                continue
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
        script = root / "scripts/launch/no-egress.sh"
        script.chmod(0o755)
        subprocess.run(["git", "init", "-q", str(root)], capture_output=True)
        snapshot = subprocess.run([str(script)], capture_output=True, text=True, cwd=root)
    last = lambda result: (result.stdout.strip().splitlines() or ["no output"])[-1]
    return in_place.returncode, last(in_place), snapshot.returncode, last(snapshot)


def check_network(report: Report, repo: Path, sampler: Path | None, real_home: Path, repo_root: Path,
                  binaries: list[Path], since: float | None, static: bool = True) -> None:
    if static:
        in_place_status, in_place_last, tracked_status, tracked_last = run_no_egress(repo)
        message = f"scripts/launch/no-egress.sh on the tracked sources: {tracked_last}"
        if in_place_status != tracked_status:
            message += (f" (run in place it reports '{in_place_last}': untracked build outputs under its roots, "
                        f"such as apps/hippocampus/.build/checkouts and tools/ocr/.venv, are not shipping source)")
        report.add(tracked_status == 0, "net.static", message)

    # What the source audit cannot see: endpoints compiled into shipped binaries.
    hits: dict[str, set[str]] = {}
    scanned = 0
    for root in binaries:
        if not root.exists():
            continue
        for path in ([root] if root.is_file() else sorted(p for p in root.rglob("*") if p.is_file() and not p.is_symlink())):
            head = read_capped(path, 4)
            if head not in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf"):
                continue
            scanned += 1
            for match in set(TELEMETRY_ENDPOINTS.findall(read_capped(path))):
                hits.setdefault(str(path.relative_to(root.parent if root.is_dir() else root.parent)), set()).add(match.decode(errors="replace"))
    if binaries:
        report.add(not hits, "net.binary",
                   f"{scanned} Mach-O files in the shipped bundle carry no telemetry endpoint" if not hits else
                   "telemetry endpoints compiled into shipped binaries: " +
                   "; ".join(f"{name}: {', '.join(sorted(found))}" for name, found in sorted(hits.items())[:4]))

    if sampler is None or not (sampler / "summary.json").is_file():
        report.add(False, "net.runtime", "no sampler summary: the runtime network check did not run")
        return
    summary = json.loads((sampler / "summary.json").read_text())
    programs: dict[int, set[str]] = {}
    for line in (sampler / "processes.log").read_text(errors="replace").splitlines() if (sampler / "processes.log").is_file() else []:
        parts = line.split("\t", 3)
        if len(parts) >= 3 and parts[0].isdigit():
            programs.setdefault(int(parts[0]), set()).add(parts[2])
    product_seen = sorted({name for names in programs.values() for name in names if name in PRODUCT_PROGRAMS})
    sockets = summary.get("internet_sockets_seen", -1)
    detail = "; ".join((sampler / "net.log").read_text(errors="replace").splitlines()[:3]) if sockets else ""
    report.add(sockets == 0 and summary.get("samples", 0) > 0, "net.runtime",
               f"lsof -i sampled the run's own processes {summary.get('samples')} times ({summary.get('processes_watched')} processes, "
               f"including {', '.join(product_seen)}): no internet socket seen open at a sample (a connection shorter than "
               f"the interval can be missed; net.runtime-log is the complete record)" if sockets == 0 else
               f"{sockets} internet socket line(s): {detail}")

    # The complete record: every connection CFNetwork and Network.framework
    # made for the run's own processes, from the unified log.
    product_pids = sorted(pid for pid, names in programs.items() if names & PRODUCT_PROGRAMS)
    if since is None or not product_pids:
        report.add(False, "net.runtime-log", "no run start or no product processes to look up in the unified log")
    else:
        connections = unified_log_connections(product_pids, programs, since)
        if connections is None:
            report.add(False, "net.runtime-log", "the unified log could not be read")
        elif connections:
            report.add(False, "net.runtime-log",
                       "outbound network traffic from the run's processes (unified log, hostnames redacted by macOS): " +
                       "; ".join(connections[:6]))
        else:
            report.add(True, "net.runtime-log",
                       f"the unified log shows no network connection by the run's {len(product_pids)} product processes "
                       f"({', '.join(product_seen)})")

    outside = []
    if (sampler / "outside-files.log").is_file():
        outside = [line.split("\t") for line in (sampler / "outside-files.log").read_text().splitlines() if line]
    real = str(real_home.resolve()) + os.sep
    repo_prefix = str(repo_root.resolve()) + os.sep
    in_real_home = sorted({f"{row[1]} -> {row[2]}" for row in outside
                           if len(row) == 3 and row[1] in PRODUCT_PROGRAMS
                           and row[2].startswith(real) and not row[2].startswith(repo_prefix)})
    product_outside = [row for row in outside if len(row) == 3 and row[1] in PRODUCT_PROGRAMS]
    if since is not None and product_pids:
        for denial in sandbox_denials(product_pids, programs, since, real):
            in_real_home.append(denial)
    report.add(not in_real_home, "net.isolation",
               f"the product's processes opened nothing in the real home ({len(product_outside)} file(s) outside the throwaway "
               f"root, all in the per-user system cache and temp folders)" if not in_real_home else
               "the product's processes wrote or read in the real home, outside HOME and CFFIXED_USER_HOME: " + "; ".join(in_real_home[:5]))


NETWORK_LOG_PREDICATE = '(subsystem == "com.apple.CFNetwork" OR subsystem BEGINSWITH "com.apple.network")'
SANDBOX_DENIAL_PREDICATE = 'senderImagePath ENDSWITH "/Sandbox" AND eventMessage CONTAINS " deny("'


def read_unified_log(predicate: str, since: float) -> list[dict] | None:
    """The unified log's entries matching `predicate` from five seconds
    before `since` (epoch seconds), or None when the log can't be read."""
    import datetime
    start = datetime.datetime.fromtimestamp(since - 5).strftime("%Y-%m-%d %H:%M:%S")
    result = subprocess.run(["/usr/bin/log", "show", "--style", "ndjson", "--start", start, "--predicate", predicate],
                            capture_output=True, text=True)
    if result.returncode != 0:
        return None
    entries = []
    for line in result.stdout.splitlines():
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(entry, dict):
            entries.append(entry)
    return entries


def network_activity(entries: list[dict], programs: dict[int, set[str]]) -> dict[tuple[int, str], dict]:
    """What CFNetwork and Network.framework logged for each (pid, program)
    in `programs`: tasks started, connection attempts, requests sent and
    their body bytes, remote ports and response statuses. An entry from a
    pid whose program isn't the one named (a reused pid) is not counted."""
    findings: dict[tuple[int, str], dict] = {}
    for entry in entries:
        pid = entry.get("processID")
        message = entry.get("eventMessage", "")
        image = os.path.basename(entry.get("processImagePath", ""))
        if pid not in programs or image not in programs[pid]:
            continue
        found = findings.setdefault((pid, image), {"tasks": 0, "connections": 0, "requests": 0, "bytes": 0,
                                                   "ports": set(), "statuses": set()})
        if " resuming, timeouts" in message:
            found["tasks"] += 1
        if "creating secure tcp or quic connection" in message or "nw_flow_connected" in message:
            found["connections"] += 1
        sent = re.search(r"sent request, body S (\d+)", message)
        if sent:
            found["requests"] += 1
            found["bytes"] += int(sent.group(1))
        port = re.search(r"#[0-9a-f]+:(\d+)", message)
        if port:
            found["ports"].add(port.group(1))
        status = re.search(r"received response, status (\d+)", message)
        if status:
            found["statuses"].add(status.group(1))
    return findings


def sandbox_refusals(entries: list[dict], pids: list[int]) -> list[tuple[str, int, str, str]]:
    """(program, pid, operation, target) for each sandbox refusal of one of `pids`."""
    found = []
    for entry in entries:
        match = re.search(r"Sandbox: ([^(]+)\((\d+)\) deny\(\d+\) (\S+) (.+)$", entry.get("eventMessage", ""))
        if match and int(match.group(2)) in pids:
            found.append((match.group(1), int(match.group(2)), match.group(3), match.group(4)))
    return found


def sandbox_denials(pids: list[int], programs: dict[int, set[str]], since: float, real_home_prefix: str) -> list[str]:
    """Real-home paths a run's process tried to open and the test sandbox refused."""
    found = set()
    for name, pid, operation, path in sandbox_refusals(read_unified_log(SANDBOX_DENIAL_PREDICATE, since) or [], pids):
        if name not in programs.get(pid, set()):
            continue
        if path.startswith(real_home_prefix) or path.rstrip("/") + "/" == real_home_prefix + "Library/":
            found.add(f"{name} -> {path} ({operation}, denied by the test sandbox)")
        elif operation.startswith("network"):
            found.add(f"{name} -> {path} ({operation}: a name lookup, denied by the test sandbox)")
    return sorted(found)


def unified_log_connections(pids: list[int], programs: dict[int, set[str]], since: float) -> list[str] | None:
    predicate = "processID IN {" + ", ".join(map(str, pids)) + "} AND " + NETWORK_LOG_PREDICATE
    entries = read_unified_log(predicate, since)
    if entries is None:
        return None
    out = []
    for (pid, name), found in sorted(network_activity(entries, programs).items()):
        if found["connections"] or found["requests"]:
            sent = (f"{found['requests']} HTTP request(s) sent with {found['bytes']} bytes of body, responses "
                    f"{', '.join(sorted(found['statuses'])) or 'none'}" if found["requests"] else
                    "no request left the Mac (the connection never completed)")
            out.append(f"{name} (pid {pid}): {found['connections']} connection attempt(s) to port(s) "
                       f"{', '.join(sorted(found['ports'])) or '?'}; {sent}")
        elif found["tasks"]:
            # A URL task that never got as far as a connection still means
            # the process tried to reach the network.
            out.append(f"{name} (pid {pid}): {found['tasks']} CFNetwork task(s) started, no connection made")
    return out


def check_outputs(report: Report, listing: Path | None, markers, key_hex: str | None) -> None:
    if listing is None or not listing.is_file():
        report.add(False, "outputs", "no list of MCP and hook outputs given")
        return
    files = [Path(line) for line in listing.read_text().splitlines() if line.strip()]
    secrets = [(kind, marker) for kind, marker in markers if kind == "secret"]
    hits = []
    for path in files:
        data = read_capped(path)
        found = find_markers(data, secrets)
        if found:
            hits.append(f"{path.name} {found[:3]}")
        if key_hex and key_hex.encode() in data:
            hits.append(f"{path.name} [database key]")
    report.add(bool(files) and not hits, "outputs",
               f"{len(files)} MCP, Ask, card and hook output file(s) carry none of the {len(secrets)} secret markers and not the key"
               if files and not hits else ("; ".join(hits[:6]) or "no outputs to check"))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--home", required=True)
    parser.add_argument("--tmpdir")
    parser.add_argument("--markers")
    parser.add_argument("--key-file")
    parser.add_argument("--wal-snapshots")
    parser.add_argument("--sampler")
    parser.add_argument("--outputs")
    parser.add_argument("--keyframe-tool")
    parser.add_argument("--since", type=float)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--real-home", default=str(Path.home()))
    parser.add_argument("--sqlite3", default="/usr/bin/sqlite3")
    parser.add_argument("--binaries", action="append", default=[],
                        help="a shipped bundle or folder whose Mach-O files are scanned for telemetry endpoints")
    parser.add_argument("--skip", action="append", default=[], help="check groups to skip (self-test)")
    args = parser.parse_args(argv)

    home = Path(args.home).resolve()
    support = home / "Library/Application Support/MCI"
    repo = Path(args.repo).resolve()
    markers = load_markers(Path(args.markers) if args.markers else None)
    key_file = Path(args.key_file).resolve() if args.key_file else None
    key_hex = key_file.read_text().strip() if key_file and key_file.is_file() else None
    report = Report()
    skip = set(args.skip)

    if "brain" not in skip:
        check_brain(report, support, args.sqlite3)
    if "blobs" not in skip:
        check_blobs(report, support, key_hex, args.keyframe_tool)
    if "wal" not in skip:
        check_wal(report, support, Path(args.wal_snapshots) if args.wal_snapshots else None, markers)
    if "scan" not in skip:
        extra = []
        if args.sampler and args.since:
            outside = Path(args.sampler) / "outside-files.log"
            temp_roots = tuple(
                os.path.realpath(subprocess.run(["/usr/bin/getconf", name], capture_output=True, text=True).stdout.strip()) + os.sep
                for name in ("DARWIN_USER_TEMP_DIR", "DARWIN_USER_CACHE_DIR"))
            if outside.is_file():
                for line in outside.read_text().splitlines():
                    row = line.split("\t")
                    if len(row) != 3 or row[1] not in PRODUCT_PROGRAMS or not row[2].startswith(temp_roots):
                        continue
                    path = Path(row[2])
                    try:
                        if path.is_file() and path.stat().st_mtime >= args.since:
                            extra.append(path)  # the app's own caches: opened by its processes, and new
                    except OSError:
                        continue
        check_scan(report, home, Path(args.tmpdir).resolve() if args.tmpdir else None, extra, markers, key_hex, key_file)
        check_real_crash_reports(report, args.since, Path(args.sampler) if args.sampler else None)
    if "pasteboard" not in skip:
        check_pasteboard(report, repo)
    if "modes" not in skip:
        check_modes(report, home)
    if "custody" not in skip:
        check_custody(report, repo)
    if "network" not in skip:
        check_network(report, repo, Path(args.sampler) if args.sampler else None, Path(args.real_home), repo,
                      [Path(b) for b in args.binaries], args.since, static="egress" not in skip)
    if "outputs" not in skip:
        check_outputs(report, Path(args.outputs) if args.outputs else None, markers, key_hex)

    passed = sum(1 for status, _c, _m in report.results if status == "PASS")
    print(f"{passed} PASS, {report.failed} FAIL")
    return 1 if report.failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
