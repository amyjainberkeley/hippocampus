// SPDX-License-Identifier: Apache-2.0
//
// Single source of truth for whether the optional Qwen3 brief author is
// installed. Evidence-cited extractive briefs do not depend on this model.
//
// This file is the one approved sync filesystem check. Keep the path
// computation in lock-step with:
//   - `apps/agent/src/brief_worker.rs::default_model_dir()`
//     + `QWEN3_MODEL_ID` + `QWEN3_MODEL_BASENAME`
//   - `BriefModelProvisioner`, which seeds a custom build's bundled
//     model into the `modelID` subdir (no build downloads one)
//   - `apps/recall-ui/Sources/RecallUI/MCIRecallApp.swift
//     ::ModelPresenceProbe`

import Foundation

public enum BriefModelPresence {
    /// `modelID` from `apps/hippocampus/Resources/models.json`. The model
    /// lives in a per-`modelID` subdirectory; the brief worker reads
    /// `<dir>/<id>/<basename>`.
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
        let modelDirectory = modelsDir.appendingPathComponent(modelID)
        let modelPath = modelDirectory.appendingPathComponent(basename)
        let tokenizerPath = modelDirectory.appendingPathComponent("tokenizer.json")
        var isModelDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: modelPath.path,
            isDirectory: &isModelDirectory
        )
            && isModelDirectory.boolValue
            && FileManager.default.fileExists(atPath: tokenizerPath.path)
    }

    /// URL of an optional Qwen3 model included inside a custom .app bundle at
    /// `Contents/Resources/Models/qwen3-1.7b-fp16/Qwen3-1.7B-FP16.mlmodelc`.
    ///
    /// Standard release builds omit it. `build-app.sh` validates the model and
    /// tokenizer together when a custom build includes both source artifacts.
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
        let tokenizer = candidate.deletingLastPathComponent()
            .appendingPathComponent("tokenizer.json")
        return FileManager.default.fileExists(atPath: candidate.path)
            && FileManager.default.fileExists(atPath: tokenizer.path)
            ? candidate
            : nil
    }

    /// Outcome of `removeUnusedQwen3IfNeeded()`.
    public enum CleanupOutcome: Equatable, Sendable {
        /// The directory was there and is gone.
        case removed
        /// There was nothing to remove.
        case nothingThere
        /// This build includes the model, so its copy stays.
        case keptForBundledModel
        /// An earlier launch already looked.
        case alreadyDone
        /// The path is not a plain directory (a link, a file): left alone.
        case leftAlone
        /// Removing failed; the next launch tries again.
        case failed(String)
    }

    /// Set once the unused copy is gone, or was never there.
    public static let cleanupDoneKey = "HippocampusRemovedUnusedQwen3Model"

    /// Remove the Qwen3 copy an earlier version downloaded into
    /// `~/Library/Application Support/MCI/Models/qwen3-1.7b-fp16/` (about
    /// 3.2 GB), once, when this build does not include the model.
    ///
    /// Nothing in a standard build uses it (ADR-0039): briefs are extractive,
    /// the opt-in naming worker needs `MCI_QWEN_NER_ENABLED=1`, which the app
    /// never sets, `mci-agent brief` falls back to the extractive author
    /// without it, and nothing downloads it again. It is a cache, not the
    /// person's data. Only that one directory goes, never through a link and
    /// never anything else in `Models`. A custom build that bundles the model
    /// keeps the copy it seeds.
    @discardableResult
    public static func removeUnusedQwen3IfNeeded(
        modelsDir: URL = defaultModelsDir(),
        modelID: String = qwen3ModelID,
        bundledModel: URL? = bundledQwen3URL(),
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> CleanupOutcome {
        if defaults.bool(forKey: cleanupDoneKey) { return .alreadyDone }
        if bundledModel != nil { return .keptForBundledModel }
        let directory = modelsDir.appendingPathComponent(modelID, isDirectory: true)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: directory.path)
        } catch {
            guard !fileManager.fileExists(atPath: directory.path) else {
                return .failed(String(describing: error))
            }
            defaults.set(true, forKey: cleanupDoneKey)
            return .nothingThere
        }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            defaults.set(true, forKey: cleanupDoneKey)
            return .leftAlone
        }
        do {
            try fileManager.removeItem(at: directory)
        } catch {
            return .failed(String(describing: error))
        }
        defaults.set(true, forKey: cleanupDoneKey)
        return .removed
    }

    /// Outcome of `seedBundledQwen3IfNeeded()`. Reported for observability;
    /// call sites treat all cases as non-fatal because the extractive author
    /// remains available.
    public enum SeedOutcome: Equatable, Sendable {
        /// The Application Support copy was already present; no work done.
        case alreadyPresent
        /// The bundled model was hardlinked/copied into Application Support.
        case seeded
        /// No optional model exists inside the .app. The default extractive
        /// brief author remains active.
        case noBundle
        /// FileManager error during seed. Richer prose remains unavailable,
        /// but evidence-cited briefs continue to work. Details in the string.
        case seedError(String)
    }

    /// Seed the bundled Qwen3 model from the .app's Resources/Models/ into
    /// `~/Library/Application Support/MCI/Models/qwen3-1.7b-fp16/` if that
    /// path does not yet exist.
    ///
    /// Custom builds can put the optional model inside the app. The Rust worker
    /// resolves models from Application Support, so first launch links or
    /// copies the bundle artifact into that canonical directory.
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
        let destTokenizer = destDir.appendingPathComponent("tokenizer.json")
        if isQwen3Installed(modelsDir: modelsDir, modelID: modelID, basename: basename) {
            return .alreadyPresent
        }
        guard let bundledURL = bundledQwen3URL(
            bundle: bundle, modelID: modelID, basename: basename
        ) else {
            return .noBundle
        }
        let bundledTokenizer = bundledURL.deletingLastPathComponent()
            .appendingPathComponent("tokenizer.json")
        do {
            try fileManager.createDirectory(
                at: destDir, withIntermediateDirectories: true
            )
            // Prefer hardlink (instant, zero disk cost) since the bundle and
            // Application Support both live on the boot volume in every
            // supported deployment. `linkItem` falls back to failing if the
            // volumes differ; on that failure we `copyItem` instead.
            if !fileManager.fileExists(atPath: destModel.path) {
                do {
                    try fileManager.linkItem(at: bundledURL, to: destModel)
                } catch {
                    try fileManager.copyItem(at: bundledURL, to: destModel)
                }
            }
            if !fileManager.fileExists(atPath: destTokenizer.path) {
                do {
                    try fileManager.linkItem(at: bundledTokenizer, to: destTokenizer)
                } catch {
                    try fileManager.copyItem(at: bundledTokenizer, to: destTokenizer)
                }
            }
            return .seeded
        } catch {
            return .seedError(String(describing: error))
        }
    }
}
