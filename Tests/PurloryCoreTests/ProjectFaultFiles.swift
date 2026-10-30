@testable import PurloryIntelligence
@testable import PurloryStorage
import Foundation
@testable import PurloryCore
@testable import PurloryWorkspaceUI

/// Models atomic-write interruption before commit through the production filesystem seam.
/// Staged replacement bytes belong only to the fresh fixture root, never the destination.
final class ProjectFaultFiles: ProjectFileSystem, @unchecked Sendable {
    enum Phase: CaseIterable, Sendable { case beforeWrite, stagedReplacement }
    enum Failure: Swift.Error, Equatable { case interrupted }
    struct Hit: Sendable { let path: String; let phase: Phase; let stagedBytes: Int }
    private let phase: Phase
    private let target: String
    private let real = LocalProjectFileSystem()
    private let lock = NSLock()
    private var recorded: [Hit] = []

    init(phase: Phase, target: String) { self.phase = phase; self.target = target }
    var hits: [Hit] { lock.withLock { recorded } }
    func createDirectory(at url: URL) throws { try real.createDirectory(at: url) }
    func read(_ url: URL) throws -> Data { try real.read(url) }
    func fileExists(at url: URL) -> Bool { real.fileExists(at: url) }

    func writeAtomically(_ data: Data, to url: URL) throws {
        let matches = target.contains("/") ? url.path.contains(target) : url.lastPathComponent == target
        guard matches else { return try real.writeAtomically(data, to: url) }
        var stagedBytes = 0
        if phase == .stagedReplacement {
            let staging = url.deletingLastPathComponent().appendingPathComponent("fault-staged-\(UUID())")
            defer { try? FileManager.default.removeItem(at: staging) }
            let partial = Data(data.prefix(max(1, data.count / 2)))
            try partial.write(to: staging, options: .withoutOverwriting)
            stagedBytes = try Data(contentsOf: staging).count
        }
        lock.withLock { recorded.append(Hit(path: url.path, phase: phase, stagedBytes: stagedBytes)) }
        throw Failure.interrupted
    }
}
