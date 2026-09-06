// SPDX-License-Identifier: TBD-private
import XCTest

final class BuildAppScriptTests: XCTestCase {
    private enum ChangelogFixture {
        case currentRelease
        case unreleasedOnly
    }

    private enum StatusAuditFixture: Equatable {
        case valid
        case missingSHA
        case missingCommit
        case stale
        case nonAncestor
    }

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

    private func repositoryRoot() -> URL? {
        guard let path = scriptPath else { return nil }
        return URL(fileURLWithPath: path)
            .deletingLastPathComponent()  // Resources/
            .deletingLastPathComponent()  // hippocampus/
            .deletingLastPathComponent()  // apps/
            .deletingLastPathComponent()  // repository root
    }

    private func makeFixture(
        includeChangelog: Bool = true,
        includeManifest: Bool = true,
        includeEmbedder: Bool = false,
        includeNER: Bool = false,
        includeQwen: Bool = false,
        changelog: ChangelogFixture = .currentRelease,
        statusAudit: StatusAuditFixture = .valid
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
        guard let sourceRepositoryRoot = repositoryRoot() else {
            throw XCTSkip("repository root not found from build-app.sh")
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
        let staticDependencies = [
            "NOTICE",
            "scripts/lib/app-group-contract.sh",
            "scripts/product-source-digest.py",
            "scripts/build-provenance.py",
            "scripts/verify-toml-license-contract.py",
            "third_party/licenses",
            "apps/hippocampus/Package.swift",
            "apps/hippocampus/Package.resolved",
            "apps/hippocampus/Resources/Hippocampus.entitlements",
            "apps/hippocampus/Resources/MCICaptureHelper.entitlements",
            "apps/hippocampus/Sources/HippocampusKit/Resources/keychain-sharing-contract.json",
            "extensions/safari/appex/HippocampusSafariExtension.entitlements",
        ]
        for relativePath in staticDependencies {
            let source = sourceRepositoryRoot.appendingPathComponent(relativePath)
            let destination = repoRoot.appendingPathComponent(relativePath)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: source, to: destination)
        }

        // This suite tests assembly with /usr/bin/true and synthetic models.
        // Real verifier failure propagation is covered by test_release_safety.py.
        for name in ["verify-models.sh", "verify-app-launches.sh"] {
            let verifier = repoRoot.appendingPathComponent("scripts/\(name)")
            try writeFile(verifier, contents: "#!/bin/bash\nexit 0\n")
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: verifier.path)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: repoRoot) }

        let executableFixture = URL(fileURLWithPath: "/usr/bin/true")
        let executablePaths = [
            "apps/hippocampus/.build/debug/Hippocampus",
            "adapters/macos/MCICaptureHelper/.build/debug/mci-capture-helper",
            "target/debug/mci-agent",
            "apps/recall-ui/.build/debug/recall-ui",
            "apps/onboarding/.build/debug/onboarding",
            "target/debug/hippocampus-native-host",
        ]
        for relativePath in executablePaths {
            let destination = repoRoot.appendingPathComponent(relativePath)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: executableFixture, to: destination)
        }

        let kitBundle = packageRoot.appendingPathComponent(".build/debug/Hippocampus_HippocampusKit.bundle")
        try fileManager.createDirectory(at: kitBundle, withIntermediateDirectories: true)
        try writeFile(kitBundle.appendingPathComponent("placeholder.txt"), contents: "fixture\n")
        try writeFile(repoRoot.appendingPathComponent("assets/branding/AppIcon.icns"))
        try writeFile(repoRoot.appendingPathComponent("assets/branding/statusbar-icon.png"))
        try writeFile(repoRoot.appendingPathComponent("assets/branding/statusbar-icon@2x.png"))
        try writeFile(repoRoot.appendingPathComponent("assets/branding/statusbar-icon@3x.png"))

        if includeChangelog {
            let contents: String
            switch changelog {
            case .currentRelease:
                contents = """
                # Changelog

                All notable changes to Hippocampus.

                ## [Unreleased]

                ## [0.1.0] - 2026-09-01

                ### Highlights

                - fixture release notes
                """
            case .unreleasedOnly:
                contents = """
                # Changelog

                All notable changes to Hippocampus.

                ## [Unreleased]

                ### Highlights

                - future fixture note
                """
            }
            try writeFile(repoRoot.appendingPathComponent("CHANGELOG.md"), contents: contents)
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
                at: repoRoot.appendingPathComponent("models/ArcticEmbedS_FP16.mlmodelc"),
                requireStructure: true
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

        try initializeFixtureRepository(at: repoRoot, statusAudit: statusAudit)

        return ScriptFixture(repoRoot: repoRoot, scriptURL: scriptURL)
    }

    private func initializeFixtureRepository(
        at repoRoot: URL,
        statusAudit: StatusAuditFixture
    ) throws {
        try runGit(["init", "-q"], in: repoRoot)
        try runGit(["config", "user.name", "Fixture User"], in: repoRoot)
        try runGit(["config", "user.email", "fixture@example.invalid"], in: repoRoot)
        try runGit(["add", "."], in: repoRoot)
        try runGit(["commit", "-q", "-m", "fixture baseline"], in: repoRoot)

        let baselineSHA = try gitHead(in: repoRoot)
        var auditSHA = baselineSHA

        if statusAudit == .missingCommit {
            auditSHA = String(repeating: "0", count: 40)
        }

        if statusAudit == .nonAncestor {
            try runGit(["checkout", "-q", "-b", "audit-side"], in: repoRoot)
            try writeFile(repoRoot.appendingPathComponent("audit-side.txt"), contents: "side\n")
            try runGit(["add", "audit-side.txt"], in: repoRoot)
            try runGit(["commit", "-q", "-m", "side audit"], in: repoRoot)
            auditSHA = try gitHead(in: repoRoot)
            try runGit(
                ["checkout", "-q", "-b", "fixture-main", baselineSHA],
                in: repoRoot
            )
        }

        let statusContents: String
        if statusAudit == .missingSHA {
            statusContents = "# Hippocampus Status\n\nAudit baseline is missing.\n"
        } else {
            statusContents = """
            # Hippocampus Status

            Audited code baseline: `\(auditSHA)`

            Release builds allow at most 3 commits after this baseline.
            """
        }
        try writeFile(repoRoot.appendingPathComponent("docs/STATUS.md"), contents: statusContents)
        try runGit(["add", "docs/STATUS.md"], in: repoRoot)
        try runGit(["commit", "-q", "-m", "document status"], in: repoRoot)

        if statusAudit == .stale {
            for index in 1...3 {
                let path = "stale-\(index).txt"
                try writeFile(repoRoot.appendingPathComponent(path), contents: "\(index)\n")
                try runGit(["add", path], in: repoRoot)
                try runGit(
                    ["commit", "-q", "-m", "advance \(index)"],
                    in: repoRoot
                )
            }
        }
    }

    private func gitHead(in directory: URL) throws -> String {
        let result = try runGit(["rev-parse", "HEAD"], in: directory)
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private func runGit(_ arguments: [String], in directory: URL) throws -> ScriptRunResult {
        let result = try runCommand("/usr/bin/git", arguments, in: directory)
        guard result.status == 0 else {
            throw NSError(
                domain: "BuildAppScriptTests",
                code: Int(result.status),
                userInfo: [NSLocalizedDescriptionKey: result.output]
            )
        }
        return result
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
        return try runCommand(
            "/bin/bash",
            [fixture.scriptURL.path, "--debug", "--development-ad-hoc"],
            in: fixture.repoRoot,
            environment: ProcessInfo.processInfo.environment
        )
    }

    private func runCommand(
        _ executable: String,
        _ arguments: [String],
        in directory: URL? = nil,
        environment: [String: String]? = nil
    ) throws -> ScriptRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        if let environment {
            process.environment = environment
        }

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

    func test_missing_sparkle_is_only_tolerated_for_ad_hoc_development() throws {
        guard let path = scriptPath else {
            throw XCTSkip("build-app.sh not found at expected source-tree location")
        }
        let source = try String(contentsOfFile: path, encoding: .utf8)

        XCTAssertTrue(source.contains("if [[ \"$SIGNING_MODE\" == \"ad-hoc\" ]]; then"))
        XCTAssertTrue(source.contains("Sparkle.framework was not embedded"))
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

    func test_changelog_without_current_bundle_version_exits_with_release_note_message() throws {
        let fixture = try makeFixture(changelog: .unreleasedOnly)
        let result = try runFixture(fixture)
        XCTAssertTrue(
            result.status != 0,
            "an Unreleased-only changelog must fail the build, got: \(result.output)"
        )
        XCTAssertTrue(
            result.output.contains("FATAL: CHANGELOG.md has no nonempty 0.1.0 release"),
            "expected current-version changelog failure, got: \(result.output)"
        )
    }

    func test_repository_changelog_resolves_current_bundle_version_with_actual_parser() throws {
        guard let repoRoot = repositoryRoot() else {
            throw XCTSkip("repository root not found from build-app.sh")
        }
        guard let infoPlistURL = infoPlistPath() else {
            throw XCTSkip("Info.plist not found next to build-app.sh")
        }

        let plistData = try Data(contentsOf: infoPlistURL)
        guard let plist = try PropertyListSerialization.propertyList(
            from: plistData,
            options: [],
            format: nil
        ) as? [String: Any],
            let version = plist["CFBundleShortVersionString"] as? String
        else {
            XCTFail("Info.plist has no CFBundleShortVersionString")
            return
        }

        let parserURL = repoRoot.appendingPathComponent(
            "apps/recall-ui/Sources/RecallUIKit/ChangelogParser.swift"
        )
        let changelogURL = repoRoot.appendingPathComponent("CHANGELOG.md")
        let probeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChangelogParserProbe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: probeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: probeRoot) }

        let mainURL = probeRoot.appendingPathComponent("main.swift")
        let executableURL = probeRoot.appendingPathComponent("changelog-probe")
        try writeFile(
            mainURL,
            contents: """
            import Darwin
            import Foundation

            let version = CommandLine.arguments[1]
            let source = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
            if let release = ChangelogParser.release(forVersion: version, in: source), !release.isEmpty {
                print("resolved \\(release.version)")
            } else {
                fputs("no nonempty release for \\(version)\\n", stderr)
                exit(1)
            }
            """
        )

        let compile = try runCommand(
            "/usr/bin/xcrun",
            ["swiftc", parserURL.path, mainURL.path, "-o", executableURL.path],
            in: repoRoot
        )
        XCTAssertEqual(compile.status, 0, "parser probe failed to compile: \(compile.output)")
        guard compile.status == 0 else { return }

        let probe = try runCommand(
            executableURL.path,
            [version, changelogURL.path],
            in: repoRoot
        )
        XCTAssertEqual(
            probe.status,
            0,
            "current bundle version \(version) did not resolve to nonempty notes: \(probe.output)"
        )
    }

    func test_missing_status_audit_sha_exits_with_status_message() throws {
        let fixture = try makeFixture(statusAudit: .missingSHA)
        let result = try runFixture(fixture)
        XCTAssertTrue(result.status != 0, "missing status audit SHA must fail: \(result.output)")
        XCTAssertTrue(
            result.output.contains("FATAL: docs/STATUS.md has no audited code baseline SHA"),
            "expected missing status SHA failure, got: \(result.output)"
        )
    }

    func test_status_audit_sha_missing_from_clone_exits_with_status_message() throws {
        let fixture = try makeFixture(statusAudit: .missingCommit)
        let result = try runFixture(fixture)
        XCTAssertTrue(result.status != 0, "unknown status audit SHA must fail: \(result.output)")
        XCTAssertTrue(
            result.output.contains(
                "FATAL: docs/STATUS.md audit baseline does not exist: 0000000000000000000000000000000000000000"
            ),
            "expected nonexistent status SHA failure, got: \(result.output)"
        )
    }

    func test_stale_status_audit_sha_exits_with_refresh_message() throws {
        let fixture = try makeFixture(statusAudit: .stale)
        let result = try runFixture(fixture)
        XCTAssertTrue(result.status != 0, "stale status audit SHA must fail: \(result.output)")
        XCTAssertTrue(
            result.output.contains("FATAL: docs/STATUS.md audit baseline is 4 commits behind HEAD; maximum is 3"),
            "expected stale status SHA failure, got: \(result.output)"
        )
    }

    func test_non_ancestor_status_audit_sha_exits_with_status_message() throws {
        let fixture = try makeFixture(statusAudit: .nonAncestor)
        let result = try runFixture(fixture)
        XCTAssertTrue(result.status != 0, "non-ancestor status audit SHA must fail: \(result.output)")
        XCTAssertTrue(
            result.output.contains("FATAL: docs/STATUS.md audit baseline is not an ancestor of HEAD"),
            "expected non-ancestor status SHA failure, got: \(result.output)"
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
            result.output.contains("FATAL: ArcticEmbedS_FP16"),
            "expected embedder failure, got: \(result.output)"
        )
        XCTAssertTrue(
            result.output.contains("python scripts/convert_embedder.py"),
            "missing embedder must name convert_embedder.py, got: \(result.output)"
        )
    }

    func test_missing_ner_uses_tier_one_extraction_instead_of_blocking_release() throws {
        let fixture = try makeFixture(
            includeChangelog: true,
            includeManifest: true,
            includeEmbedder: true
        )
        let result = try runFixture(fixture)
        XCTAssertEqual(result.status, 0, "missing optional NER must not block: \(result.output)")
        XCTAssertTrue(
            result.output.contains("BERT NER is unavailable; Tier 1 entity extraction remains active"),
            "expected truthful NER fallback, got: \(result.output)"
        )
    }

    func test_missing_qwen_uses_extractive_briefs_instead_of_blocking_release() throws {
        let fixture = try makeFixture(
            includeChangelog: true,
            includeManifest: true,
            includeEmbedder: true,
            includeNER: true
        )
        let result = try runFixture(fixture)
        XCTAssertEqual(result.status, 0, "missing optional Qwen must not block: \(result.output)")
        XCTAssertTrue(
            result.output.contains("Qwen3 is unavailable; evidence-cited extractive briefs remain active"),
            "expected truthful brief fallback, got: \(result.output)"
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
