@testable import PurloryIntelligence
import CryptoKit
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class SmokeConfigurationTests: XCTestCase {
    func testProjectStateVerifierReadsBodyReferencedByActiveManifest() throws {
        let fixture = try SmokeScriptFixture()
        defer { fixture.remove() }
        let body = "edited-smoke-token"
        try fixture.writeProject(body: body)

        let result = try fixture.runUISmoke(
            arguments: ["--verify-project-state", fixture.library.path, body])

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("project state verified"), result.output)
    }

    func testProjectStateVerifierAcceptsCanonicalPathForEveryDocumentKind() throws {
        for kind in ["manuscript", "note", "reference"] {
            let fixture = try SmokeScriptFixture()
            defer { fixture.remove() }
            let body = "\(kind)-body"
            try fixture.writeProject(body: body, kind: kind)

            let result = try fixture.runUISmoke(
                arguments: ["--verify-project-state", fixture.library.path, body])

            XCTAssertEqual(result.status, 0, "\(kind): \(result.output)")
            XCTAssertTrue(
                result.output.contains("project state verified"),
                "\(kind): \(result.output)")
        }
    }

    func testProjectStateVerifierRejectsLegacyEntriesFallback() throws {
        let fixture = try SmokeScriptFixture()
        defer { fixture.remove() }
        let body = "project-owned-body"
        try fixture.writeProject(body: body)
        try Data(#"{"entries":[]}"#.utf8)
            .write(to: fixture.library.appendingPathComponent("entries.json"))

        let result = try fixture.runUISmoke(
            arguments: ["--verify-project-state", fixture.library.path, body])

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("created entries.json"), result.output)
    }

    func testProjectStateVerifierRejectsUnreferencedEditedBody() throws {
        let fixture = try SmokeScriptFixture()
        defer { fixture.remove() }
        try fixture.writeProject(body: "stale-project-body")

        let result = try fixture.runUISmoke(
            arguments: ["--verify-project-state", fixture.library.path, "edited-body"])

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("expected body absent"), result.output)
    }

    func testProjectStateVerifierRequiresExactTrailingNewlineBytes() throws {
        let fixture = try SmokeScriptFixture()
        defer { fixture.remove() }
        let expectedBody = "edited-token"
        try fixture.writeProject(body: "\(expectedBody)\n")

        let result = try fixture.runUISmoke(
            arguments: ["--verify-project-state", fixture.library.path, expectedBody])

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("expected body absent"), result.output)
    }

    func testProjectStateVerifierRejectsContentWhoseHashNoLongerMatchesManifest() throws {
        let fixture = try SmokeScriptFixture()
        defer { fixture.remove() }
        let body = "original-body"
        try fixture.writeProject(body: body)
        try fixture.overwriteReferencedContent(originalBody: body, with: "tampered-body")

        let result = try fixture.runUISmoke(
            arguments: ["--verify-project-state", fixture.library.path, "tampered-body"])

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("content hash mismatch"), result.output)
    }

    func testProjectStateVerifierRejectsHashValidNoncanonicalDocumentPath() throws {
        let fixture = try SmokeScriptFixture()
        defer { fixture.remove() }
        let body = "hash-valid-body"
        try fixture.writeProject(
            body: body,
            relativePath: "Documents/44444444-4444-4444-4444-444444444444/arbitrary.md")

        let result = try fixture.runUISmoke(
            arguments: ["--verify-project-state", fixture.library.path, body])

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("noncanonical document path"), result.output)
    }

    func testProjectStateVerifierRejectsSymlinkedProjectDirectory() throws {
        let fixture = try SmokeScriptFixture()
        defer { fixture.remove() }
        let body = "outside-project-body"
        try fixture.writeProject(body: body)
        try fixture.replaceProjectDirectoryWithSymlink()

        let result = try fixture.runUISmoke(
            arguments: ["--verify-project-state", fixture.library.path, body])

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("unsafe project directory"), result.output)
    }

    @MainActor
    func testBundleSmokeStartsOfflineWithoutModelSetup() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent(
            "scripts/fixtures/smoke-preferences.plist"))
        let values = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any])
        let suiteName = "Purlory-smoke-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.setPersistentDomain(values, forName: suiteName)

        // The legacy smoke fixture remains offline and migrates without presenting a model gate.
        let settings = CompletionSettings(defaults: defaults)
        XCTAssertEqual(settings.authorization, .disabled)
        XCTAssertFalse(settings.autocompleteEnabled)
    }
}

private struct SmokeScriptFixture {
    let root: URL
    let library: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purlory-smoke-script-tests-\(UUID().uuidString)", isDirectory: true)
        library = root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("scripts", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("build/Purlory.app/Contents/MacOS", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        try FileManager.default.copyItem(
            at: repositoryRoot.appendingPathComponent("scripts/ui-smoke-purlory-app.sh"),
            to: root.appendingPathComponent("scripts/ui-smoke-purlory-app.sh"))
        let placeholder = root.appendingPathComponent("build/Purlory.app/Contents/MacOS/Purlory")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: placeholder)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: placeholder.path)
    }

    func runUISmoke(arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [root.appendingPathComponent("scripts/ui-smoke-purlory-app.sh").path]
            + arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, output)
    }

    func writeProject(
        body: String,
        kind: String = "manuscript",
        relativePath customRelativePath: String? = nil
    ) throws {
        let projectID = "33333333-3333-3333-3333-333333333333"
        let documentID = "44444444-4444-4444-4444-444444444444"
        let hash = SHA256.hash(data: Data(body.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let folder = kind == "note" ? "Notes" : "Documents"
        let relativePath = customRelativePath ?? "\(folder)/\(documentID)/\(hash).md"
        let projectDirectory = library
            .appendingPathComponent("Projects/\(projectID)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectDirectory.appendingPathComponent(relativePath).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(body.utf8).write(to: projectDirectory.appendingPathComponent(relativePath))
        try Data(#"{"rawValue":"33333333-3333-3333-3333-333333333333"}"#.utf8)
            .write(to: library.appendingPathComponent("Projects/active-project.json"))
        let manifest = """
        {"schemaVersion":1,"id":{"rawValue":"\(projectID)"},"title":"Smoke","mode":"fiction","documents":[{"id":{"rawValue":"\(documentID)"},"title":"Chapter 1","kind":"\(kind)","relativePath":"\(relativePath)","contentHash":"\(hash)"}],"trashedDocumentIDs":[],"assets":[]}
        """
        try Data(manifest.utf8).write(to: projectDirectory.appendingPathComponent("project.json"))
    }

    func overwriteReferencedContent(originalBody: String, with newBody: String) throws {
        let documentID = "44444444-4444-4444-4444-444444444444"
        let hash = SHA256.hash(data: Data(originalBody.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        try Data(newBody.utf8).write(
            to: projectDirectory.appendingPathComponent("Documents/\(documentID)/\(hash).md"))
    }

    func replaceProjectDirectoryWithSymlink() throws {
        let escapedProject = root.appendingPathComponent("escaped-project", isDirectory: true)
        try FileManager.default.moveItem(at: projectDirectory, to: escapedProject)
        try FileManager.default.createSymbolicLink(
            at: projectDirectory, withDestinationURL: escapedProject)
    }

    private var projectDirectory: URL {
        library.appendingPathComponent(
            "Projects/33333333-3333-3333-3333-333333333333", isDirectory: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
