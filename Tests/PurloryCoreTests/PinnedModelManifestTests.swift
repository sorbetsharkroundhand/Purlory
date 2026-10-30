@testable import PurloryIntelligence
@_spi(Benchmark) @testable import PurloryInference
import XCTest
@testable import PurloryCore
@testable import PurloryWorkspaceUI

final class PinnedModelManifestTests: XCTestCase {
    private func manifest() -> ModelInstallManifest {
        .init(id: "fixture/model", revision: String(repeating: "a", count: 40),
              files: ["config.json", "tokenizer.json", "model.safetensors"].map {
                  .init(path: $0, size: 3, digest: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", algorithm: .sha256)
              })
    }
    func testRejectsMutableRevisionsMissingIntegrityAndTraversal() throws {
        var bad = manifest(); bad.revision = "main"
        XCTAssertThrowsError(try bad.validate())
        bad = manifest(); bad.files[0].digest = ""
        XCTAssertThrowsError(try bad.validate())
        for path in ["../outside", "/tmp/outside", "a/../config.json", "receipt.json"] {
            bad = manifest(); bad.files[0].path = path
            XCTAssertThrowsError(try bad.validate())
        }
        bad = manifest(); bad.files.removeLast()
        XCTAssertThrowsError(try bad.validate())
        bad = manifest(); bad.files.append(bad.files[0])
        XCTAssertThrowsError(try bad.validate())
        bad = manifest(); bad.id = "../model"
        XCTAssertThrowsError(try bad.validate())
    }
    func testEveryPresetRequiresCompletePinnedMetadata() throws {
        for id in ModelPresets.all {
            let pin = try XCTUnwrap(PinnedModelCatalog.manifest(for: id), id)
            try pin.validate()
        }
    }
}
