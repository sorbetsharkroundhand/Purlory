import AppKit
import Foundation

/// 문서에서 **원본 파일이 없는** 로컬 이미지 소스를 찾는다 (이슈 #15).
///
/// export 전 검증의 단일 진실 — Markdown·EPUB 양쪽이 같은 정의를 쓴다:
/// 관리 asset·외부 파일 중 디스크에 없는 것만 누락이다. 원격(URL)은 로컬
/// 원본이 필요 없고(#12), 차단 소스는 렌더 대상이 아니므로 누락이 아니다.
@MainActor
public enum ImageAssetScanner {

    /// 펜스 밖 이미지 참조(인라인·참조형 정의 줄 모두) 중 원본 없는 소스 —
    /// 발견 순서, 중복 없이.
    public static func missingSources(in body: String) -> [String] {
        let definitions = ImageReferenceParser.collectDefinitions(in: body)
        var seen = Set<String>()
        var missing: [String] = []
        var inFence = false

        func note(_ rawDestination: String) {
            switch ImageReferenceParser.classify(rawDestination) {
            case .managedRelative, .externalFile:
                guard seen.insert(rawDestination).inserted else { return }
                guard let url = PurloryImageStore.url(for: rawDestination),
                    FileManager.default.fileExists(atPath: url.path)
                else {
                    missing.append(rawDestination)
                    return
                }
            case .remote, .blocked:
                break  // 로컬 원본이 필요 없는 소스 — 누락이 아니다 (#12)
            }
        }

        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                continue
            }
            guard !inFence else { continue }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let ref = ImageReferenceParser.parse(line, definitions: definitions) {
                note(ref.destinationRaw)
            } else if line.hasPrefix("["), let close = line.firstIndex(of: "]"),
                line.index(after: close) < line.endIndex,
                line[line.index(after: close)] == ":"
            {
                // 참조형 이미지의 경로는 정의 줄에 있다 — 같은 정책으로 검사.
                let label = String(line[line.index(after: line.startIndex)..<close])
                if let def = definitions[
                    label.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" })
                        .joined(separator: " ")]
                {
                    note(def.destinationRaw)
                }
            }
        }
        return missing
    }

    /// export **전** 누락을 검증해 명시적 계속을 받는다 (이슈 #15) — 조용히
    /// 깨진 결과물을 만들지 않는다. Markdown·EPUB 양쪽 진입점이 공유한다.
    /// 취소면 false.
    @MainActor
    @discardableResult
    public static func confirmContinueDespiteMissing(in body: String) -> Bool {
        let missing = missingSources(in: body)
        guard !missing.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "파일을 찾을 수 없는 이미지 \(missing.count)건"
        alert.informativeText = """
            다음 이미지는 원본 파일이 없어요:

            \(missing.joined(separator: "\n"))

            이대로 내보낼까요? (Markdown은 참조를 남기고, EPUB에서는 제외돼요)
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "계속 내보내기")
        alert.addButton(withTitle: "취소")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
