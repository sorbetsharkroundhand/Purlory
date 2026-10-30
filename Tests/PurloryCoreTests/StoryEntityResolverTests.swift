@testable import PurloryIntelligence
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class StoryEntityResolverTests: XCTestCase {
    func testExactTrimmedAliasesResolveOnlyRegisteredUniqueDomainIdentities() {
        let a = UUID(), b = UUID(), object = UUID(), rule = UUID()
        let resolver = StoryEntityResolver(
            characters: [.init(id: a, name: "민아", aliases: " 미나, A, shared, 한"),
                         .init(id: b, name: "민아의 동생", aliases: "shared, 한")],
            objects: [.init(id: object, name: "A", aliases: ["열쇠"])], rules: [.init(id: rule, name: "A")])
        XCTAssertEqual(resolver.character(named: " 미나 "), a)
        XCTAssertEqual(resolver.character(named: "A"), a)
        XCTAssertEqual(resolver.object(named: "A"), object)
        XCTAssertEqual(resolver.rule(named: "A"), rule)
        for name in ["민", "민아의", "shared", "한", "한", "", "a"] { XCTAssertNil(resolver.character(named: name), name) }
        XCTAssertEqual(resolver.character(named: "민아의 동생"), b)
        XCTAssertNil(resolver.object(named: "민아"))
        XCTAssertNil(resolver.rule(named: "열쇠"))
    }
}
