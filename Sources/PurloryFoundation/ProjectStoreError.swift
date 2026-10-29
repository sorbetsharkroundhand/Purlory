import Foundation

public enum ProjectStoreError: Error, LocalizedError, Sendable {
    case unsafePath(String)
    case invalidManifest
    case unsupportedSchema(Int)
    case damagedFile(String)
    case invalidLegacy
    case projectAlreadyExists
    case changedDuringSave

    public var errorDescription: String? {
        switch self {
        case .unsafePath(let path): "프로젝트 밖 경로나 심볼릭 링크는 사용할 수 없습니다: \(path)"
        case .invalidManifest: "프로젝트 정보가 손상되었거나 문서 ID가 중복됩니다."
        case .unsupportedSchema(let version): "지원하지 않는 프로젝트 저장 버전입니다: \(version)"
        case .damagedFile(let path): "저장된 파일 검증에 실패했습니다: \(path)"
        case .invalidLegacy: "기존 원고를 읽을 수 없거나 문서 ID가 중복됩니다. 원본은 보존됩니다."
        case .projectAlreadyExists: "같은 프로젝트가 이미 저장되어 있습니다. 원본과 기존 프로젝트는 보존됩니다."
        case .changedDuringSave: "프로젝트가 변경되어 작가 설정을 적용하지 않았습니다. 다시 열어 주세요."
        }
    }
}
