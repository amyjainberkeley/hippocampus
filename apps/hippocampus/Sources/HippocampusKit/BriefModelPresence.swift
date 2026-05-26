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
}
