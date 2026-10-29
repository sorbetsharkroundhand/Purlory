import Foundation

/// Validate local bench inputs before any model/network/MLX setup.
public enum ReleaseBenchmarkPreflight {
    public static func validate(modelID: String, fixture: URL?, output: URL?, candidateBudget: UInt64?, temperature: Double) throws {
        guard PinnedModelCatalog.manifest(for: modelID) != nil else { throw Failure.unpinned }
        guard temperature.isFinite, temperature >= 0, candidateBudget == nil || candidateBudget! > 0 else { throw Failure.options }
        if output != nil, fixture == nil { throw Failure.fixture }
        if let fixture {
            guard let text = try? String(contentsOf: fixture, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw Failure.fixture }
        }
        if let output {
            guard (try? FileManager.default.attributesOfItem(atPath: output.path)) == nil else { throw Failure.output }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: output.deletingLastPathComponent().path, isDirectory: &directory), directory.boolValue,
                  FileManager.default.isWritableFile(atPath: output.deletingLastPathComponent().path) else { throw Failure.output }
        }
    }
    private enum Failure: LocalizedError {
        case unpinned, options, fixture, output
        var errorDescription: String? {
            switch self {
            case .unpinned: "Choose an explicitly pinned --model ID before benchmarking."
            case .options: "Temperature must be finite/nonnegative; candidate memory budget must be positive."
            case .fixture: "A report requires a readable, nonempty local UTF-8 replay fixture."
            case .output: "Choose a new report path in a writable directory; existing files are preserved."
            }
        }
    }
}
