@testable import PurloryIntelligence
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

@MainActor
final class PurloryPreferencesTests: XCTestCase {
    func testImportsLegacyValuesWithoutOverwritingNewPreferencesOrSource() throws {
        let suite = "purlory.preferences-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("new author", forKey: "purlory.authorName")
        let legacy: [String: Any] = ["mint.authorName": "old author", "mint.chromeHidden": false,
                                   "editor.fontSize": 22.0, "completion.enabled": false,
                                   "NSUnrelated": "ignore", "mint.recentProjects": ["old-id"]]
        PurloryPreferences.importLegacy(legacy, into: defaults)
        XCTAssertEqual(defaults.string(forKey: "purlory.authorName"), "new author")
        XCTAssertEqual(defaults.object(forKey: "purlory.chromeHidden") as? Bool, false)
        XCTAssertEqual(defaults.double(forKey: "editor.fontSize"), 22)
        XCTAssertEqual(defaults.object(forKey: "completion.enabled") as? Bool, false)
        XCTAssertNil(defaults.object(forKey: "NSUnrelated"))
        // Project IDs belong to the old storage root and must not become dangling active selections.
        XCTAssertNil(defaults.object(forKey: "purlory.recentProjects"))
        XCTAssertEqual(legacy["mint.authorName"] as? String, "old author")
        defaults.removeObject(forKey: "editor.fontSize")
        PurloryPreferences.importLegacy(legacy, into: defaults)
        XCTAssertNil(defaults.object(forKey: "editor.fontSize"), "Migration must not repeat after a reset")
    }

    func testMigrationDoesNotGrantAIConsentOrReplaceNewFalseValues() throws {
        let suite = "purlory.preferences-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "purlory.chromeHidden")
        PurloryPreferences.importLegacy(["mint.chromeHidden": true, "completion.enabled": true,
                                        "completion.authorization": "authorized",
                                        "mint.initialModelConfirmed": true], into: defaults)
        XCTAssertFalse(defaults.bool(forKey: "purlory.chromeHidden"))
        XCTAssertNil(defaults.object(forKey: "completion.authorization"))
        XCTAssertNil(defaults.object(forKey: "purlory.initialModelConfirmed"))
    }
}
