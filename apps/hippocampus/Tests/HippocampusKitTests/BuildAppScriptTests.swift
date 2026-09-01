// SPDX-License-Identifier: TBD-private
import XCTest

final class BuildAppScriptTests: XCTestCase {
    private struct ScriptFixture {
        let repoRoot: URL
        let scriptURL: URL
    }

    private struct ScriptRunResult {
        let status: Int32
        let output: String
    }

    private var scriptPath: String? {
        let testFile = URL(fileURLWithPath: #filePath)
        // Tests/HippocampusKitTests/BuildAppScriptTests.swift
        //   → ../.. = package root → Resources/build-app.sh
        let pkgRoot = testFile
            .deletingLastPathComponent()  // HippocampusKitTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // package root
        let candidate = pkgRoot
            .appendingPathComponent("Resources")
            .appendingPathComponent("build-app.sh")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate.path
        }
        return nil
    }

    private func infoPlistPath() -> URL? {
        guard let path = scriptPath else { return nil }
        return URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("Info.plist")
    }

    private func modelsManifestPath() -> URL? {
        guard let path = scriptPath else { return nil }
        return URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
            .appendingPathComponent("HippocampusKit")
            .appendingPathComponent("Resources")
            .appendingPathComponent("models.json")
    }

    private func makeFixture(
        includeChangelog: Bool = true,
        includeManifest: Bool = true,
        includeEmbedder: Bool = false,
        includeNER: Bool = false,
        includeQwen: Bool = false
    ) throws -> ScriptFixture {
        guard let scriptPath else {
            throw XCTSkip("build-app.sh not found at expected source-tree location")
        }
        guard let infoPlistURL = infoPlistPath() else {
            throw XCTSkip("Info.plist not found next to build-app.sh")
        }
        guard let modelsManifestURL = modelsManifestPath() else {
            throw XCTSkip("models.json not found in HippocampusKit resources")
        }

        let fileManager = FileManager.default
        let repoRoot = fileManager.temporaryDirectory
            .appendingPathComponent("BuildAppScriptTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: repoRoot, withIntermediateDirectories: true)

        let packageRoot = repoRoot
            .appendingPathComponent("apps")
            .appendingPathComponent("hippocampus")
        let resourcesDir = packageRoot.appendingPathComponent("Resources")
        try fileManager.createDirectory(at: resourcesDir, withIntermediateDirectories: true)

        let scriptURL = resourcesDir.appendingPathComponent("build-app.sh")
        try fileManager.copyItem(at: URL(fileURLWithPath: scriptPath), to: scriptURL)
        try fileManager.copyItem(at: infoPlistURL, to: resourcesDir.appendingPathComponent("Info.plist"))

        try writeFile(packageRoot.appendingPathComponent(".build/release/Hippocampus"))
        try writeFile(repoRoot.appendingPathComponent("adapters/macos/MCICaptureHelper/.build/release/mci-capture-helper"))
        try writeFile(repoRoot.appendingPathComponent("target/release/mci-agent"))
        try writeFile(repoRoot.appendingPathComponent("apps/recall-ui/.build/release/recall-ui"))
        try writeFile(repoRoot.appendingPathComponent("apps/onboarding/.build/release/onboarding"))
        try writeFile(repoRoot.appendingPathComponent("target/release/hippocampus-native-host"))

        let kitBundle = packageRoot.appendingPathComponent(".build/release/Hippocampus_HippocampusKit.bundle")
        try fileManager.createDirectory(at: kitBundle, withIntermediateDirectories: true)
        try writeFile(kitBundle.appendingPathComponent("placeholder.txt"), contents: "fixture\n")
        try writeFile(repoRoot.appendingPathComponent("assets/branding/AppIcon.icns"))
        try writeFile(repoRoot.appendingPathComponent("assets/branding/statusbar-icon.png"))
        try writeFile(repoRoot.appendingPathComponent("assets/branding/statusbar-icon@2x.png"))
        try writeFile(repoRoot.appendingPathComponent("assets/branding/statusbar-icon@3x.png"))

        if includeChangelog {
            try writeFile(
                repoRoot.appendingPathComponent("CHANGELOG.md"),
                contents: """
                # Changelog

                All notable changes to Hippocampus.

                ## [Unreleased] - 2026-09-01

                ### Features

                - fixture release notes
                """
            )
        }

        if includeManifest {
            try fileManager.createDirectory(
                at: repoRoot.appendingPathComponent("apps/hippocampus/Sources/HippocampusKit/Resources"),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(
                at: modelsManifestURL,
                to: repoRoot
                    .appendingPathComponent("apps/hippocampus/Sources/HippocampusKit/Resources/models.json")
            )
        }

        if includeEmbedder {
            try makeModelDirectory(
                at: repoRoot.appendingPathComponent("models/ArcticEmbedS_INT8.mlmodelc"),
                requireStructure: false
            )
        }

        if includeNER {
            try makeModelDirectory(
                at: repoRoot.appendingPathComponent("models/bert_base_NER_INT8.mlmodelc"),
                requireStructure: true
            )
        }

        if includeQwen {
            try makeModelDirectory(
                at: repoRoot.appendingPathComponent("models/Qwen3-1.7B-FP16.mlmodelc"),
                requireStructure: true
            )
        }

        return ScriptFixture(repoRoot: repoRoot, scriptURL: scriptURL)
    }

    private func writeFile(_ url: URL, contents: String = "") throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeModelDirectory(at url: URL, requireStructure: Bool) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try writeFile(url.appendingPathComponent("marker.txt"), contents: "fixture\n")
        if requireStructure {
            try writeFile(url.appendingPathComponent("model.mil"))
            try writeFile(url.appendingPathComponent("coremldata.bin"))
            try FileManager.default.createDirectory(
                at: url.appendingPathComponent("weights"),
                withIntermediateDirectories: true
            )
        }
    }

    private func runFixture(_ fixture: ScriptFixture) throws -> ScriptRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [fixture.scriptURL.path]
        process.currentDirectoryURL = fixture.repoRoot
        process.environment = [
            "HOME": fixture.repoRoot.path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
            "DEVELOPER_ID": "Test Identity"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return ScriptRunResult(status: process.terminationStatus, output: output)
    }

    func test_help_flag_exits_zero() throws {
        guard let path = scriptPath else {
            throw XCTSkip("build-app.sh not found at expected source-tree location")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [path, "--help"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0, "build-app.sh --help should exit 0")

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains("Assemble Hippocampus.app"), "Expected usage text in --help output")
        XCTAssertTrue(output.contains("--debug"), "Expected --debug option in help")
        XCTAssertTrue(output.contains("--dist"), "Expected --dist option in help")
    }

    func test_unknown_flag_exits_nonzero() throws {
        guard let path = scriptPath else {
            throw XCTSkip("build-app.sh not found at expected source-tree location")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [path, "--bogus"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        XCTAssertNotEqual(process.terminationStatus, 0, "build-app.sh --bogus should exit nonzero")
    }

    func test_missing_changelog_exits_with_rebuild_command() throws {
        let fixture = try makeFixture(includeChangelog: false, includeManifest: true)
        let result = try runFixture(fixture)
        XCTAssertTrue(
            result.status != 0,
            "missing CHANGELOG.md must fail the build, got: \(result.output)"
        )
        XCTAssertTrue(
            result.output.contains("FATAL: CHANGELOG.md missing"),
            "expected missing changelog failure, got: \(result.output)"
        )
        XCTAssertTrue(
            result.output.contains("scripts/gen-changelog.sh"),
            "missing changelog must name the reconstruction command, got: \(result.output)"
        )
    }

    func test_missing_pinned_models_manifest_exits_with_restore_command() throws {
        let fixture = try makeFixture(includeChangelog: true, includeManifest: false)
        let result = try runFixture(fixture)
        XCTAssertTrue(
            result.status != 0,
            "missing models.json must fail the build, got: \(result.output)"
        )
        XCTAssertTrue(
            result.output.contains("FATAL: models.json missing"),
            "expected missing models.json failure, got: \(result.output)"
        )
        XCTAssertTrue(
            result.output.contains("git restore apps/hippocampus/Sources/HippocampusKit/Resources/models.json"),
            "missing models.json must name the restore command, got: \(result.output)"
        )
    }

    func test_missing_embedder_exits_with_convert_command() throws {
        let fixture = try makeFixture(includeChangelog: true, includeManifest: true)
        let result = try runFixture(fixture)
        XCTAssertTrue(
            result.status != 0,
            "missing embedder must fail the build, got: \(result.output)"
        )
        XCTAssertTrue(
            result.output.contains("FATAL: ArcticEmbedS_INT8"),
            "expected embedder failure, got: \(result.output)"
        )
        XCTAssertTrue(
            result.output.contains("python scripts/convert_embedder.py"),
            "missing embedder must name convert_embedder.py, got: \(result.output)"
        )
    }

    func test_missing_ner_exits_with_convert_command() throws {
        let fixture = try makeFixture(
            includeChangelog: true,
            includeManifest: true,
            includeEmbedder: true
        )
        let result = try runFixture(fixture)
        XCTAssertTrue(
            result.status != 0,
            "missing NER model must fail the build, got: \(result.output)"
        )
        XCTAssertTrue(
            result.output.contains("FATAL: bert_base_NER_INT8"),
            "expected NER failure, got: \(result.output)"
        )
        XCTAssertTrue(
            result.output.contains("python scripts/convert_ner.py"),
            "missing NER must name convert_ner.py, got: \(result.output)"
        )
    }

    func test_missing_qwen_exits_with_download_command() throws {
        let fixture = try makeFixture(
            includeChangelog: true,
            includeManifest: true,
            includeEmbedder: true,
            includeNER: true
        )
        let result = try runFixture(fixture)
        XCTAssertTrue(
            result.status != 0,
            "missing Qwen model must fail the build, got: \(result.output)"
        )
        XCTAssertTrue(
            result.output.contains("FATAL: Qwen3-1.7B-FP16"),
            "expected Qwen failure, got: \(result.output)"
        )
        XCTAssertTrue(
            result.output.contains("curl -L"),
            "missing Qwen must name the documented download command, got: \(result.output)"
        )
    }

    /// Static shellcheck-style sanity: the script must still parse
    /// with `bash -n` after our edits. Catches copy-paste breakage.
    func test_bash_syntax_check_passes() throws {
        guard let path = scriptPath else {
            throw XCTSkip("build-app.sh not found")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", path]

        let pipe = Pipe()
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let err = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(
            process.terminationStatus, 0,
            "bash -n on build-app.sh should be clean; got: \(err)"
        )
    }
}
