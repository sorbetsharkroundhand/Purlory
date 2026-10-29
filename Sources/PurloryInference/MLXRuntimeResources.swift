import Foundation
import Metal
import MLX

public enum MLXRuntimeResources {
    /// Validate packaged resources before MLX can reach its process-fatal default loader.
    @discardableResult
    public static func initialize(in bundle: Bundle = .main) throws -> URL {
        let url = try validate(in: bundle) { url in
            guard let device = MTLCreateSystemDefaultDevice() else { throw ResourceError.unavailableGPU }
            let library = try device.makeLibrary(URL: url)
            guard !library.functionNames.isEmpty else { throw ResourceError.invalidLibrary }
        }
        do {
            try MLX.withError { error in
                let input = MLXArray([Int32(20)])
                try error.check()
                let output = input + 22
                try error.check()
                eval(output)
                try error.check()
                guard output.item(Int32.self) == 42 else { throw ResourceError.initializationFailed }
            }
        } catch { throw ResourceError.initializationFailed }
        return url
    }

    static func validate(in bundle: Bundle, load: (URL) throws -> Void) throws -> URL {
        var candidates: [URL] = []
        if let directory = bundle.executableURL?.deletingLastPathComponent() {
            candidates += [directory.appendingPathComponent("mlx.metallib"),
                           directory.appendingPathComponent("Resources/mlx.metallib")]
        }
        if let resources = bundle.resourceURL,
           let package = Bundle(url: resources.appendingPathComponent("mlx-swift_Cmlx.bundle")),
           let library = package.url(forResource: "default", withExtension: "metallib") {
            candidates.append(library)
        }
        let root = bundle.bundleURL.standardizedFileURL
        for candidate in candidates {
            do {
                let path = candidate.standardizedFileURL.path
                guard path.hasPrefix(root.path + "/") else { throw ResourceError.invalidLibrary }
                let relative = String(path.dropFirst(root.path.count + 1))
                let url = try ProjectPaths.checked(relative, under: root)
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { continue }
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0
                else { throw ResourceError.invalidLibrary }
                try load(url)
                return url
            } catch let error as ResourceError { throw error }
            catch { throw ResourceError.invalidLibrary }
        }
        throw ResourceError.missingLibrary
    }

    private enum ResourceError: LocalizedError {
        case missingLibrary, invalidLibrary, unavailableGPU, initializationFailed
        var errorDescription: String? {
            switch self {
            case .missingLibrary, .invalidLibrary:
                "AI 실행 리소스가 없거나 손상되었습니다. Purlory 앱을 다시 설치하세요. 원고 편집은 계속할 수 있습니다."
            case .unavailableGPU, .initializationFailed:
                "이 Mac에서 AI 실행을 초기화하지 못했습니다. 앱을 다시 실행하세요. 원고 편집은 계속할 수 있습니다."
            }
        }
    }
}
