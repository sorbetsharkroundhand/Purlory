import Foundation

public struct ModelInstallManifest: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public enum Algorithm: String, Codable, Sendable { case sha256, gitBlobSHA1 }
        public var path: String
        public var size: Int64
        public var digest: String
        public var algorithm: Algorithm
    }
    public var id: String
    public var revision: String
    public var files: [File]

    public func validate() throws {
        try ProjectPaths.validateRelative(id)
        guard case .success(let validated) = ModelIDCommit.validate(id), validated == id,
              Self.isHex(revision, count: 40),
              Set(files.map(\.path)).count == files.count,
              files.contains(where: { $0.path == "config.json" }),
              files.contains(where: { $0.path == "tokenizer.json" }),
              files.contains(where: { $0.path.hasSuffix(".safetensors") })
        else { throw ModelInstallError.metadata }
        for file in files {
            try ProjectPaths.validateRelative(file.path)
            guard file.path != "receipt.json", file.size > 0,
                  Self.isHex(file.digest, count: file.algorithm == .sha256 ? 64 : 40)
            else { throw ModelInstallError.metadata }
        }
    }
    private static func isHex(_ text: String, count: Int) -> Bool {
        text.utf8.count == count && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

package enum ModelInstallError: LocalizedError {
    case metadata, integrity, busy
    package var errorDescription: String? {
        switch self {
        case .metadata: "이 모델의 고정된 설치 정보가 없습니다. 다른 모델을 선택하세요. 원고 편집은 계속할 수 있습니다."
        case .integrity: "모델 파일 검증에 실패했습니다. 다시 내려받으세요. 원고 편집은 계속할 수 있습니다."
        case .busy: "모델 설치가 진행 중입니다. 취소한 뒤 다시 시도하세요."
        }
    }
}
