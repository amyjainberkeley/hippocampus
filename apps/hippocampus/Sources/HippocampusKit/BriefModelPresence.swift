// SPDX-License-Identifier: TBD-private
//
// BriefModelPresence — single source of truth for "is the Qwen3
// brief-author model currently installed on disk?".
//
// Why this exists (CEO dogfood 2026-05-26): the prior implementation
// used `UserDefaults.bool(forKey: "MCIBriefModelDownloaded")` to gate
// the menu-bar Daily Briefs toggle, the onboarding skip path, and the
// supervisor's brief-worker spawn. But UserDefaults survives across
// installs (persisted under `~/Library/Preferences/ai.hippocampus.plist`
// AND in `cfprefsd`'s in-memory cache), and the model directory does
// not. After a partial reset (Time Machine restore, manual delete of
// `~/Library/Application Support/MCI/Models/`, or a wipe that missed
// `cfprefsd`), the bool flag kept saying "downloaded" while the
// filesystem said "missing" — the user saw a UI that lied about state.
//
// Fix: ALL UI gating reads the filesystem directly. The UserDefaults
// bool is kept as a one-way cache (still written by the manager on a
// successful download) for legacy consumers, but never READ by the
// gating logic.
//
// This file is the one approved sync filesystem check. Keep the path
// computation in lock-step with:
//   - `apps/agent/src/brief_worker.rs::default_model_dir()`
//     + `QWEN3_MODEL_ID` + `QWEN3_MODEL_BASENAME`
//   - `apps/hippocampus/Sources/HippocampusKit/ModelDownloadManager
//     .swift::modelsDir` + `modelID` subdir
//   - `apps/recall-ui/Sources/RecallUI/MCIRecallApp.swift
//     ::ModelPresenceProbe`

import Foundation

public enum BriefModelPresence {
    /// `modelID` from `apps/hippocampus/Resources/models.json`. The
    /// download manager unpacks the tarball into a per-`modelID`
    /// subdirectory; the brief worker reads `<dir>/<id>/<basename>`.
    public static let qwen3ModelID = "qwen3-1.7b-fp16"

    /// `.mlmodelc` directory name inside the per-`modelID` subdir.
    public static let qwen3Basename = "Qwen3-1.7B-FP16.mlmodelc"

    /// Default install root: `~/Library/Application Support/MCI/Models`.
    public static func defaultModelsDir() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MCI/Models")
    }

    /// True iff the Qwen3 brief-author model is actually on disk under
    /// the canonical layout. Reads filesystem only — never UserDefaults.
    public static func isQwen3Installed(
        modelsDir: URL = defaultModelsDir(),
        modelID: String = qwen3ModelID,
        basename: String = qwen3Basename
    ) -> Bool {
        let path = modelsDir
            .appendingPathComponent(modelID)
            .appendingPathComponent(basename)
        return FileManager.default.fileExists(atPath: path.path)
    }

    /// URL of the Qwen3 model that ships INSIDE the .app bundle at
    /// `Contents/Resources/Models/qwen3-1.7b-fp16/Qwen3-1.7B-FP16.mlmodelc`.
    ///
    /// Populated by `apps/hippocampus/Resources/build-app.sh` and gated by
    /// `scripts/build-installer.sh` — a DMG that ships without the bundled
    /// model trips a FATAL in the installer script before codesign +
    /// notarize (see the "Completeness gate" comment blocks in both scripts).
    ///
    /// Returns nil in test/CLI contexts where `Bundle.main` is the swift
    /// test-runner rather than Hippocampus.app.
    public static func bundledQwen3URL(
        bundle: Bundle = .main,
        modelID: String = qwen3ModelID,
        basename: String = qwen3Basename
    ) -> URL? {
        guard let resourceURL = bundle.resourceURL else { return nil }
        let candidate = resourceURL
            .appendingPathComponent("Models")
            .appendingPathComponent(modelID)
            .appendingPathComponent(basename)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Outcome of `seedBundledQwen3IfNeeded()`. Reported for observability;
    /// call sites treat all cases as non-fatal (a missing bundle model is
    /// gated at build time, not runtime).
    public enum SeedOutcome: Equatable {
        /// The Application Support copy was already present; no work done.
        case alreadyPresent
        /// The bundled model was hardlinked/copied into Application Support.
        case seeded
        /// No bundled model exists inside the .app (e.g. a "lite edition"
        /// DMG). Runtime falls back to `RealModelDownloader` (HuggingFace).
        case noBundle
        /// FileManager error during seed; brief worker will run_disabled_idle
        /// until the user retries via the download UI. Details in the string.
        case seedError(String)
    }

    /// Seed the bundled Qwen3 model from the .app's Resources/Models/ into
    /// `~/Library/Application Support/MCI/Models/qwen3-1.7b-fp16/` if that
    /// path does not yet exist.
    ///
    /// Why this exists (cycle 8.42, EnviousWispr peer-study §5 fix): the
    /// runtime brief worker resolves the model from `default_model_dir()` in
    /// `apps/agent/src/brief_worker.rs`, which points at
    /// `~/Library/Application Support/MCI/Models`. Bundling the model INTO
    /// the .app removes the HuggingFace-throttling first-run outage class
    /// entirely, but the Rust runtime cannot see files under
    /// `Contents/Resources/Models/` without a bridging step. This seed runs
    /// FIRST on `applicationDidFinishLaunching` (before the supervisor starts
    /// `mci-agent`) and copies (or hardlinks) the bundled `.mlmodelc` into
    /// the Application Support directory the runtime already resolves —
    /// zero change to `apps/agent/src/` resolution logic.
    ///
    /// Idempotent: if the destination already exists (user completed a prior
    /// download OR a prior seed), no work is done. Users who ran an old
    /// pre-bundling install and downloaded the model into Application
    /// Support keep their existing copy on upgrade; users who install the
    /// bundled DMG fresh get the seed on first launch.
    @discardableResult
    public static func seedBundledQwen3IfNeeded(
        modelsDir: URL = defaultModelsDir(),
        modelID: String = qwen3ModelID,
        basename: String = qwen3Basename,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> SeedOutcome {
        let destDir = modelsDir.appendingPathComponent(modelID)
        let destModel = destDir.appendingPathComponent(basename)
        if fileManager.fileExists(atPath: destModel.path) {
            return .alreadyPresent
        }
        guard let bundledURL = bundledQwen3URL(
            bundle: bundle, modelID: modelID, basename: basename
        ) else {
            return .noBundle
        }
        do {
            try fileManager.createDirectory(
                at: destDir, withIntermediateDirectories: true
            )
            // Prefer hardlink (instant, zero disk cost) since the bundle and
            // Application Support both live on the boot volume in every
            // supported deployment. `linkItem` falls back to failing if the
            // volumes differ; on that failure we `copyItem` instead.
            do {
                try fileManager.linkItem(at: bundledURL, to: destModel)
            } catch {
                try fileManager.copyItem(at: bundledURL, to: destModel)
            }
            // Set the legacy UserDefaults flag so pre-cycle-8.14 consumers
            // that still read it see a consistent state. Real gating uses
            // the filesystem via `isQwen3Installed()`.
            UserDefaults.standard.set(true, forKey: "MCIBriefModelDownloaded")
            return .seeded
        } catch {
            return .seedError(String(describing: error))
        }
    }
}
