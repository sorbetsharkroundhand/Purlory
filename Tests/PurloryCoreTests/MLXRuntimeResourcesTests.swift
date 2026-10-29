@_spi(Benchmark) @testable import PurloryInference
import Foundation
import XCTest
@testable import PurloryCore

final class MLXRuntimeResourcesTests: XCTestCase {
    func testUsesPackagedLibraryWithoutWorkingDirectoryLookup() throws {
        let fixture = try appFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data([1]).write(to: fixture.library)
        var loaded: URL?
        let resolved = try MLXRuntimeResources.validate(in: fixture.bundle) { loaded = $0 }
        XCTAssertEqual(resolved, fixture.library)
        XCTAssertEqual(loaded, fixture.library)
    }

    func testDeveloperColocatedLibraryMatchesMLXLookupPrecedence() throws {
        let fixture = try appFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let colocated = try XCTUnwrap(fixture.bundle.executableURL)
            .deletingLastPathComponent().appendingPathComponent("mlx.metallib")
            .standardizedFileURL
        try Data([1]).write(to: fixture.library)
        try Data([2]).write(to: colocated)
        let resolved = try MLXRuntimeResources.validate(in: fixture.bundle) { _ in }
        XCTAssertEqual(resolved, colocated)
    }

    func testMissingEmptyDirectoryAndEscapingLibraryNeverReachMLX() throws {
        for failure in ["missing", "empty", "directory", "link"] {
            let fixture = try appFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            if failure == "empty" { try Data().write(to: fixture.library) }
            if failure == "directory" {
                try FileManager.default.createDirectory(at: fixture.library, withIntermediateDirectories: true)
            }
            if failure == "link" {
                let outside = fixture.root.appendingPathComponent("outside.metallib")
                try Data([1]).write(to: outside)
                try FileManager.default.createSymbolicLink(at: fixture.library, withDestinationURL: outside)
            }
            var loaded = false
            XCTAssertThrowsError(try MLXRuntimeResources.validate(in: fixture.bundle) { _ in loaded = true }) {
                XCTAssertTrue($0.localizedDescription.contains("편집"))
            }
            XCTAssertFalse(loaded, "Unsafe resources must fail before Metal/MLX initialization")
        }
    }

    func testCorruptLibraryReturnsActionableError() throws {
        let fixture = try appFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("corrupt library".utf8).write(to: fixture.library)
        XCTAssertThrowsError(try MLXRuntimeResources.validate(in: fixture.bundle) { _ in
            throw NSError(domain: "MTLLibraryErrorDomain", code: 1)
        }) {
            XCTAssertTrue($0.localizedDescription.contains("다시 설치"))
        }
    }

    private func appFixture() throws -> (root: URL, bundle: Bundle, library: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Purlory-Metal-\(UUID())")
            .resolvingSymlinksInPath()
        let app = root.appendingPathComponent("Purlory.app")
        let resources = app.appendingPathComponent("Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let binary = app.appendingPathComponent("Contents/MacOS/Purlory")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: binary)
        let appInfo: [String: Any] = ["CFBundleIdentifier": "app.purlory.fixture.\(UUID())",
            "CFBundlePackageType": "APPL", "CFBundleExecutable": "Purlory"]
        let packageInfo: [String: Any] = ["CFBundleIdentifier": "app.purlory.package.\(UUID())",
            "CFBundlePackageType": "BNDL"]
        for (info, url) in [(appInfo, app.appendingPathComponent("Contents/Info.plist")),
                           (packageInfo, resources.deletingLastPathComponent().appendingPathComponent("Info.plist"))] {
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url)
        }
        return (root, try XCTUnwrap(Bundle(url: app)), resources.appendingPathComponent("default.metallib"))
    }
}
