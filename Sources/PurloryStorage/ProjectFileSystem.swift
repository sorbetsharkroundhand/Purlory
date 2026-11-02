import Darwin
import Foundation

public protocol ProjectFileSystem: Sendable {
    func createDirectory(at url: URL) throws
    /// 실패하면 기존 목적 파일이 그대로 남아야 한다.
    func writeAtomically(_ data: Data, to url: URL) throws
    func read(_ url: URL) throws -> Data
    func fileExists(at url: URL) -> Bool
    /// Nil requires strict content verification; custom filesystems opt in explicitly.
    func version(of url: URL) throws -> ProjectFileVersion?
}

public extension ProjectFileSystem {
    func version(of url: URL) throws -> ProjectFileVersion? { nil }
}

/// A local mutation signature, not a substitute for checksums at open/activation.
public struct ProjectFileVersion: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
    let mode: UInt16
}

public struct LocalProjectFileSystem: ProjectFileSystem {
    public init() {}
    public func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    public func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
    public func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    public func fileExists(at url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    public func version(of url: URL) throws -> ProjectFileVersion? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw ProjectStoreError.unsafePath(url.path) }
        return ProjectFileVersion(device: info.st_dev, inode: info.st_ino, size: info.st_size,
            modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec,
            changedSeconds: info.st_ctimespec.tv_sec, changedNanoseconds: info.st_ctimespec.tv_nsec,
            mode: info.st_mode)
    }
}
