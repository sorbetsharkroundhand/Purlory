import Foundation

/// 저널을 임의 목적지의 일반 Markdown(.md)으로 내보낸다 (이슈 #13).
///
/// 문서의 이미지 참조는 Purlory 폴더 기준 상대경로(`images/<uuid>`)라 본문만
/// 쓰면 외부 편집기(Typora·VS Code)에서 전부 깨진다. 내보내면서:
/// - 관리 asset·외부 절대경로 파일은 `.md` 옆 `images/`로 **복사**하고,
/// - 같은 이름이 이미 있으면 내용이 같을 땐 재사용, 다르면 `-1`·`-2` 접미사를
///   붙여 참조를 함께 고친다 (충돌 없는 상대경로).
/// - 원격(http/s)·차단 소스는 주소 그대로 둔다 — 로컬 파일로 오해하지 않는다(#12).
/// - 원본 파일이 없는 참조는 경고하고 그대로 보존한다 (#15가 placeholder 몫).
///
/// 이미지가 하나도 없으면 `images/` 폴더를 만들지 않는다 — 임의 목적지를
/// 더럽히지 않는다. 본문 텍스트는 destination 스플라이스 외에 한 글자도
/// 바꾸지 않는다 (Gate 3 무손실 왕복).
public enum MarkdownExporter {

    /// 내보내기 결과 — 성공 알림과 정책 경고의 재료.
    public struct Report: Equatable, Sendable {
        /// 이번 내보내기에서 실제로 새로 쓴 asset 파일 수.
        public var copiedAssets = 0
        /// 대상에 같은 내용이 이미 있어 복사 대신 재사용한 소스 수.
        public var reusedAssets = 0
        /// 경로를 다시 쓴 참조 수 (참조 정의 줄 포함).
        public var rewrittenReferences = 0
        /// 원본 파일을 찾지 못해 참조만 남긴 소스 (상대경로 표기).
        public var missingSources: [String] = []
        /// http(s) 이미지 수 — 주소 그대로 내보냈다 (오프라인 뷰어에선 안 보임).
        public var remoteCount = 0
        /// data: 등 해석 불가 참조 수 — 그대로 남겼다.
        public var blockedCount = 0

        public init() {}
    }

    /// UI 없이 파일만 쓴다. 실패 시 던지고, 원본(Purlory 폴더)엔 손대지 않는다.
    /// PurloryImageStore.url 해석이 메인 격리를 거치므로 같은 격리를 따른다 (이슈 #45).
    @MainActor
    @discardableResult
    public static func export(
        _ entry: JournalEntry, to destination: URL
    ) throws -> Report {
        try exportBody(entry.body, to: destination) { reference in
            guard let url = PurloryImageStore.url(for: reference) else { return nil }
            return try? Data(contentsOf: url)
        }
    }

    @discardableResult
    public static func export(
        _ document: WritingDocument, assets: ProjectAssetCatalog, to destination: URL
    ) throws -> Report {
        try exportBody(document.body, to: destination, resolve: assets.data(for:))
    }

    private static func exportBody(
        _ body: String, to destination: URL, resolve: (String) -> Data?
    ) throws -> Report {
        let destination = try ExportDestination.validatedFile(destination)
        let definitions = ImageReferenceParser.collectDefinitions(in: body)
        let destinationDir = destination.deletingLastPathComponent()
        let imagesDir = destinationDir.appendingPathComponent("images", isDirectory: true)

        // 1단계 — 계획과 복사. 소스별 새 이름을 정하고, 필요한 만큼만 images/를 만든다.
        // 키는 이스케이프를 벗긴 원래 경로 — 다른 표기(`<>`, escape)로 쓰인 같은
        // asset이 하나의 파일로 모인다.
        var newPaths: [String: String] = [:]
        var report = Report()
        var inFence = false
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                continue
            }
            guard !inFence else { continue }
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if let ref = ImageReferenceParser.parse(line, definitions: definitions) {
                switch ref.destinationKind {
                case .remote:
                    report.remoteCount += 1
                case .blocked:
                    report.blockedCount += 1
                case .managedRelative, .externalFile:
                    _ = try planCopy(
                        ref.destinationRaw, into: imagesDir, created: &newPaths,
                        report: &report, resolve: resolve)
                }
            } else if isDefinitionLine(line), let oldRaw = definitionDestination(line) {
                // 참조 형태 이미지의 경로는 정의 줄에 있다 — 정의 줄도 같은 정책으로.
                switch ImageReferenceParser.classify(oldRaw) {
                case .managedRelative, .externalFile:
                    _ = try planCopy(oldRaw, into: imagesDir, created: &newPaths, report: &report, resolve: resolve)
                default:
                    break  // 원격·차단 정의는 건드리지 않는다
                }
            }
        }

        // 2단계 — 경로 재작성 출력. 계획 단계에서 바뀐 소스만 스플라이스한다.
        var out: [String] = []
        out.reserveCapacity(body.split(separator: "\n", omittingEmptySubsequences: false).count)
        inFence = false
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("```") {
                inFence.toggle()
                out.append(String(rawLine))
                continue
            }
            guard !inFence else {
                out.append(String(rawLine))
                continue
            }
            out.append(rewriteLine(rawLine, definitions: definitions, newPaths: newPaths, report: &report))
        }
        let exported = out.joined(separator: "\n")

        try ExportDestination.write(Data(exported.utf8), to: destination)
        return report
    }

    // MARK: - 복사 계획

    /// 소스 하나의 새 이름을 정하고 파일을 복사한다. 같은 소스 재등장은 메모이즈.
    /// 반환값은 새 상대경로 (누락이면 nil).
    private static func planCopy(
        _ sourceRaw: String, into imagesDir: URL,
        created newPaths: inout [String: String], report: inout Report,
        resolve: (String) -> Data?
    ) throws -> String? {
        if let memoized = newPaths[sourceRaw] {
            return memoized.isEmpty ? nil : memoized
        }
        let fm = FileManager.default
        let sourceURL = URL(fileURLWithPath: sourceRaw)
        guard let bytes = resolve(sourceRaw) else {
            report.missingSources.append(sourceRaw)
            newPaths[sourceRaw] = ""  // 누락도 메모이즈 — 줄마다 경고를 늘리지 않는다
            return nil
        }
        try ProjectPaths.rejectSymlink(imagesDir)
        try fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)

        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension.isEmpty ? "" : "." + sourceURL.pathExtension
        var candidate = sourceURL.lastPathComponent
        var index = 1
        while true {
            let target = try ProjectPaths.checked(candidate, under: imagesDir)
            if fm.fileExists(atPath: target.path) {
                if (try? Data(contentsOf: target)) == bytes {
                    // 같은 내용이 이미 있다 — 복사 없이 재사용 (재내보내기 멱등성).
                    newPaths[sourceRaw] = "images/\(candidate)"
                    report.reusedAssets += 1
                    return "images/\(candidate)"
                }
                candidate = "\(stem)-\(index)\(ext)"
                index += 1
                continue
            }
            try bytes.write(to: target, options: .atomic)
            newPaths[sourceRaw] = "images/\(candidate)"
            report.copiedAssets += 1
            return "images/\(candidate)"
        }
    }

    // MARK: - 한 줄 재작성

    /// 한 줄에서 바뀐 경로만 골라 스플라이스한다. 앞뒤 공백과 나머지 텍스트는
    /// 원문 그대로 — title·{옵션}·escape 표기가 살아남는다.
    private static func rewriteLine(
        _ rawLine: Substring, definitions: [String: ImageReferenceParser.Definition],
        newPaths: [String: String], report: inout Report
    ) -> String {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

        if let ref = ImageReferenceParser.parse(trimmed, definitions: definitions),
            let range = ref.destinationRange,
            let newPath = newPaths[ref.destinationRaw], !newPath.isEmpty,
            newPath != ref.destinationRaw
        {
            // angle 괄호 안이었으면 괄호가 범위 밖에 걸려 있다 — 새 이름은 항상
            // 안전한 문자(uuid·stem-N.ext)라 괄호 유지가 무해하다. 맨글링 이름에
            // 공백 등이 남으면(외부 파일 유래) 괄호를 새로 두른다.
            var replacement = newPath
            if needsAngleWrapping(newPath), !isAngleWrapped(trimmed, at: range) {
                replacement = "<\(newPath)>"
            }
            report.rewrittenReferences += 1
            return splice(trimmed: trimmed, range: range, with: replacement, original: rawLine)
        }

        if isDefinitionLine(trimmed), let oldRaw = definitionDestination(trimmed),
            let newPath = newPaths[oldRaw], !newPath.isEmpty,
            let range = definitionDestinationRange(trimmed), newPath != oldRaw
        {
            var replacement = newPath
            if needsAngleWrapping(newPath), !isAngleWrapped(trimmed, at: range) {
                replacement = "<\(newPath)>"
            }
            report.rewrittenReferences += 1
            return splice(trimmed: trimmed, range: range, with: replacement, original: rawLine)
        }

        return String(rawLine)
    }

    /// trimmed 문자열의 range를 replacement로 바꾸되, 원문 줄의 앞뒤 공백은 보존한다.
    private static func splice(
        trimmed: String, range: Range<String.Index>, with replacement: String, original: Substring
    ) -> String {
        var newTrimmed = String(trimmed[..<range.lowerBound]) + replacement
            + String(trimmed[range.upperBound...])
        // 앞뒤 공백 복원 — 인덱스가 아니라 개수로 복구한다 (trim이 제거한 것만큼).
        let leading = leadingWhitespace(original)
        let trailing = trailingWhitespace(original)
        newTrimmed = leading + newTrimmed + trailing
        return newTrimmed
    }

    private static func leadingWhitespace(_ s: Substring) -> String {
        String(s.prefix(while: { $0 == " " || $0 == "\t" }))
    }

    private static func trailingWhitespace(_ s: Substring) -> String {
        String(s.reversed().prefix(while: { $0 == " " || $0 == "\t" }).reversed())
    }

    /// 새 경로에 공백·괄호 등이 남아 있으면 angle destination으로 감싸야 한다 —
    /// 일반 destination은 공백에서 끊겨 일반 편집기가 못 읽는다.
    private static func needsAngleWrapping(_ path: String) -> Bool {
        path.contains(where: { " \t()<>".contains($0) })
    }

    /// range 바로 앞 글자가 `<`인가 — 기존 angle destination 판별.
    private static func isAngleWrapped(_ line: String, at range: Range<String.Index>) -> Bool {
        range.lowerBound > line.startIndex && line[line.index(before: range.lowerBound)] == "<"
    }

    // MARK: - 참조 정의 줄

    private static func isDefinitionLine(_ line: String) -> Bool {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
            line.index(after: close) < line.endIndex,
            line[line.index(after: close)] == ":"
        else { return false }
        return true
    }

    /// 정의 줄의 destination 값(이스케이프 벗김) — collectDefinitions과 같은 스캔 규칙.
    private static func definitionDestination(_ line: String) -> String? {
        guard let range = definitionDestinationRange(line) else { return nil }
        return ImageReferenceParser.unescape(String(line[range]))
    }

    /// 정의 줄에서 destination **원문**의 범위 — collectDefinitions의 스캔을
    /// 범위 반환으로만 변형했다. 어긋나면 재작성이 아니라 미적용으로 실패 안전하게 간다.
    private static func definitionDestinationRange(_ line: String) -> Range<String.Index>? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        var i = line.index(close, offsetBy: 2)
        while i < line.endIndex, line[i] == " " || line[i] == "\t" {
            i = line.index(after: i)
        }
        guard i < line.endIndex else { return nil }
        if line[i] == "<",
            let end = ImageReferenceParser.scanUntilUnescaped(
                Substring(line), from: line.index(after: i), stoppingAt: ">")
        {
            return line.index(after: i)..<end
        }
        return ImageReferenceParser.scanPlainDestination(Substring(line), from: i).map { i..<$0 }
    }
}
