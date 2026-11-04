import CryptoKit
import Foundation

/// 작품 아웃라인 — 마크다운 헤딩(`#`·`##`·`###`)을 장·절·씬 트리로 읽는
/// 결정적 파서 (PLAN §5). LLM 없음 (CLAUDE.md §2-5).
///
/// 사용자의 헤딩 구조가 곧 타임라인 골격이다 (PLAN §8):
/// - 씬 배열 순서(담화 순서)가 v1의 시간축 — `scenes(upTo:)`가 "커서 이전
///   지식만 주입"(CLAUDE.md §2-4) 질의의 원형이다.
/// - 씬별 콘텐츠 해시는 M6 증분 파이프라인(더티 추적·추출 메모이제이션)의
///   키가 된다 (PLAN §9) — 프로세스 간 안정성이 필요해 Hasher가 아닌 SHA-256.
public struct DocumentOutline: Equatable, Sendable {

    /// 헤딩과 다음 헤딩 사이의 연속 본문 한 덩어리 — 단, **크기 상한을 함께
    /// 지킨다** (docs/m6-scene-split.md). 헤딩 본문이 상한을 넘으면 문장 경계에서
    /// 여러 세그먼트로 쪼개져 각각이 씬이 된다. 헤딩 없는 문서(저널의 보통
    /// 모습)는 전체가 씬 하나 — 상한을 넘으면 그것도 쪼개진다.
    ///
    /// 왜 쪼개는가: 이해 상한(`maxSegmentUTF16` = 인덱서의 씬 읽기 상한)만 있고
    /// 씬 크기 상한이 없으면, 넘는 만큼 **조용히** 이해에서 사라진다 — 실측에서
    /// 「개츠비」(헤딩 7개)가 10.2%, 「날개」가 6.7%만 읽혔다. 분할로 100%가 된다.
    public struct Scene: Equatable, Sendable {
        /// 이 씬을 여는 헤딩 레벨 (1–3). 0이면 문서 서두(첫 헤딩 이전).
        public let level: Int
        /// 뿌리부터 이 씬까지의 헤딩 제목 경로 — 예: ["1부", "3장", "밤"].
        /// 레벨을 건너뛴 헤딩(`#` 다음 바로 `###`)은 중간이 빈 문자열로 채워진다.
        public let headingPath: [String]
        /// 본문 내 위치(UTF-16, 여는 헤딩 줄 포함) — 에디터 커서(NSString 좌표)와
        /// 같은 단위라 변환 없이 비교할 수 있다.
        public let utf16Range: Range<Int>
        /// 씬 원문 SHA-256 앞 16자 — "같은 입력 재처리 금지"의 키 (CLAUDE.md §4).
        public let contentHash: String
        /// Typed content revision used for memoization and invalidation. This value is
        /// deliberately not a persistent scene or manuscript identity.
        public var contentVersion: SceneContentVersion {
            SceneContentVersion(rawValue: contentHash)
        }
        /// 같은 헤딩 본문이 상한 초과로 쪼개졌을 때의 순번 (0부터).
        /// 분할되지 않은 씬은 0. UI 라벨("제1장 (3/14)")용 — Pos는 여전히
        /// scenes 배열 인덱스다 (분할이 Pos 의미를 바꾸지 않는다).
        public let segmentIndex: Int

        init(
            level: Int, headingPath: [String], utf16Range: Range<Int>,
            contentHash: String, segmentIndex: Int = 0
        ) {
            self.level = level
            self.headingPath = headingPath
            self.utf16Range = utf16Range
            self.contentHash = contentHash
            self.segmentIndex = segmentIndex
        }
    }

    /// 세그먼트 크기 상한 (UTF-16) — 인덱서의 씬 읽기 상한과 같은 값이어야
    /// "쪼갰는데 또 잘리는" 일이 없다 (`BackgroundIndexer.maxSceneCharacters`가
    /// 이 값을 참조한다). UTF-16 단위 ≤ 1500이면 문자 수도 ≤ 1500이라
    /// `.prefix(1500)`이 절대 자르지 않는다.
    public static let maxSegmentUTF16 = 1_500
    /// 세그먼트 크기 하한 — 이보다 작으면 경계를 찾지 않는다 (토막 씬 방지).
    package static let minSegmentUTF16 = 800
    /// CDC 경계 확률 = 1/8 (문장당). [800,1500] 여유 ≈ 20문장에서 경계를 못
    /// 찾을 확률 (7/8)^20 ≈ 7% — 강제 절단이 드물어야 내용 정의의 성질(편집
    /// 영향의 국소화)이 산다 (docs/m6-scene-split.md §2.4).
    package static let boundaryDivisor: UInt64 = 8

    /// 담화 순서의 씬들 — 이 배열 인덱스가 Pos v1이다 (PLAN §5).
    public let scenes: [Scene]

    /// 본문을 씬 배열로 파싱한다. 문서 전체를 한 번 훑는 O(n) —
    /// 30만 자 장편도 밀리초 단위라 편집 직후 백그라운드에서 부담 없이 돈다.
    public static func parse(_ body: String) -> DocumentOutline {
        var scenes: [Scene] = []
        /// 현재 헤딩 경로 스택 (레벨 1…3).
        var stack: [String] = []
        var sceneLevel = 0
        var scenePath: [String] = []
        var sceneStartUTF16 = 0
        var sceneStartIndex = body.startIndex

        /// 진행 중 씬을 닫아 배열에 붙인다. 헤딩 이전 서두가 공백뿐이면 버린다 —
        /// 빈 서두 씬은 앵커로서 의미가 없다.
        /// 상한 초과 본문은 세그먼트로 쪼개 각각을 씬으로 붙인다 (분할의 유일한
        /// 진입점 — docs/m6-scene-split.md).
        func closeScene(endUTF16: Int, endIndex: String.Index) {
            guard endUTF16 > sceneStartUTF16 else { return }
            let text = body[sceneStartIndex..<endIndex]
            if sceneLevel == 0,
                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return
            }
            // 상한 이하 + 명시적 장면 구분자 없음 = 통째로 하나 — 대부분의 씬이
            // 이 빠른 경로다. 구분자("***" 등)가 있으면 크기와 무관하게 의미
            // 경계에서 쪼갠다 (요구사항 §32 — 작가가 그은 경계는 씬 경계다).
            guard endUTF16 - sceneStartUTF16 > maxSegmentUTF16
                || containsSceneBreakLine(text)
            else {
                scenes.append(
                    Scene(
                        level: sceneLevel,
                        headingPath: scenePath,
                        utf16Range: sceneStartUTF16..<endUTF16,
                        contentHash: hash(text)
                    ))
                return
            }
            // 세그먼트는 **원문에 대한 범위**로만 정의한다 — 문자열을 쪼갰다
            // 이어붙이면 경계 문자를 유실할 수 있다 (시뮬레이션에서 실제로
            // 개행을 잃었다). 범위 타일링은 유실을 구조적으로 불가능하게 한다.
            var utf16Cursor = sceneStartUTF16
            for (index, segment) in segmentRanges(of: text).enumerated() {
                let segmentText = text[segment]
                let length = segmentText.utf16.count
                scenes.append(
                    Scene(
                        level: sceneLevel,
                        headingPath: scenePath,
                        utf16Range: utf16Cursor..<(utf16Cursor + length),
                        contentHash: hash(segmentText),
                        segmentIndex: index
                    ))
                utf16Cursor += length
            }
            assert(utf16Cursor == endUTF16, "세그먼트 타일링이 원문을 빈틈없이 덮어야 한다")
        }

        var lineStart = body.startIndex
        var utf16Pos = 0
        while lineStart < body.endIndex {
            let lineEnd =
                body[lineStart...].firstIndex(of: "\n")
                .map { body.index(after: $0) } ?? body.endIndex
            let line = body[lineStart..<lineEnd]
            if let (level, title) = headingLine(line) {
                closeScene(endUTF16: utf16Pos, endIndex: lineStart)
                // 경로 갱신 — 상위 레벨은 유지, 같은/하위 레벨은 잘라내고 대체.
                if stack.count >= level {
                    stack.removeSubrange((level - 1)...)
                }
                while stack.count < level - 1 { stack.append("") }
                stack.append(title)
                sceneLevel = level
                scenePath = stack
                sceneStartUTF16 = utf16Pos
                sceneStartIndex = lineStart
            }
            utf16Pos += line.utf16.count
            lineStart = lineEnd
        }
        closeScene(endUTF16: utf16Pos, endIndex: body.endIndex)
        return DocumentOutline(scenes: scenes)
    }

    /// 커서(UTF-16)가 속한 씬 인덱스. 씬이 없거나 커서가 첫 씬 앞이면 nil.
    public func sceneIndex(at utf16Offset: Int) -> Int? {
        scenes.lastIndex(where: { $0.utf16Range.lowerBound <= utf16Offset })
    }

    /// 커서 이전(커서가 속한 씬 포함) 씬들 — 커서 위치 **이후**의 지식을
    /// 프롬프트에 주입하지 않기 위한 시점 차단 질의 (CLAUDE.md §2-4).
    public func scenes(upTo utf16Offset: Int) -> ArraySlice<Scene> {
        guard let index = sceneIndex(at: utf16Offset) else { return scenes[..<0] }
        return scenes[...index]
    }

    // MARK: - 씬 분할 (docs/m6-scene-split.md)

    /// 상한 초과 본문 → 세그먼트 범위들 (원문을 빈틈없이 타일링).
    ///
    /// 바닥 단위는 **문장** (실측: 개츠비 최장 블록 17,060자 — 문단으론 부족,
    /// 최장 문장은 185자라 문장이면 충분). 경계는 위치가 아니라 **내용**으로
    /// 정한다(CDC): 문장 해시가 조건을 만족하는 곳에서 끊으므로, 앞쪽 편집이
    /// 뒤 세그먼트 경계를 연쇄로 밀지 않고 다음 경계에서 재동기화된다 —
    /// 한 글자 편집의 재요약 반경이 국소에 갇힌다 (CLAUDE.md §2-3 증분이 기본).
    /// 명시적 장면 전환 구분자 (요구사항 §32) — 작가가 그은 경계는 CDC보다
    /// 우선한다. 이 줄에서 끊긴 세그먼트는 의미 단위와 정확히 일치한다.
    package static func isSceneBreakLine(_ piece: Substring) -> Bool {
        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 8 else { return false }
        // "***"·"* * *"·"⁂"·"§" 등 — 산문에 나올 수 없는 구분자 문자만으로 된 줄.
        let breakChars = Set("*-—─―⁂§◇◆·• ")
        return trimmed.allSatisfy { breakChars.contains($0) }
            && trimmed.contains(where: { $0 != " " })
    }

    /// 구분자 경계 성립을 위한 최소 세그먼트 크기 — 토막 방지 (하한보다 작게
    /// 잡는다: 작가의 명시 경계는 CDC 하한을 기다릴 이유가 없다).
    package static let minBreakSegmentUTF16 = 200

    /// 본문에 장면 구분자 줄이 있는가 — closeScene 빠른 경로의 게이트.
    /// 씬 크기는 상한(1,500) 이하라 줄 단위 스캔 비용이 미미하다.
    package static func containsSceneBreakLine(_ text: Substring) -> Bool {
        text.split(separator: "\n").contains { isSceneBreakLine($0) }
    }

    package static func segmentRanges(of text: Substring) -> [Range<String.Index>] {
        let pieces = capOversized(sentencePieces(in: text), in: text)
        var segments: [Range<String.Index>] = []
        var segmentStart = text.startIndex
        var segmentLength = 0
        for piece in pieces {
            let length = text[piece].utf16.count
            // 상한 보호 — 이 조각을 더하면 넘친다 → 조각 앞에서 강제로 끊는다.
            if segmentLength > 0, segmentLength + length > maxSegmentUTF16 {
                segments.append(segmentStart..<piece.lowerBound)
                segmentStart = piece.lowerBound
                segmentLength = 0
            }
            segmentLength += length
            // 의미 경계 (요구사항 §32) — 명시적 장면 구분자 줄에서 끊는다.
            // 내용에 매인 경계라 CDC의 국소성(앞 편집이 뒤 경계를 안 민다)을
            // 그대로 갖는다.
            if segmentLength >= minBreakSegmentUTF16, isSceneBreakLine(text[piece]) {
                segments.append(segmentStart..<piece.upperBound)
                segmentStart = piece.upperBound
                segmentLength = 0
                continue
            }
            // 내용 정의 경계 — 하한을 넘겼고, 이 문장의 해시가 1/8에 걸리면 끊는다.
            if segmentLength >= minSegmentUTF16,
                fnv1a(text[piece]) % boundaryDivisor == 0
            {
                segments.append(segmentStart..<piece.upperBound)
                segmentStart = piece.upperBound
                segmentLength = 0
            }
        }
        // 꼬리는 하한 미만이어도 붙인다 — 공백뿐이어도 버리지 않는다
        // (조용한 원문 유실이 이 설계가 없애려는 바로 그 결함이다).
        if segmentStart < text.endIndex {
            segments.append(segmentStart..<text.endIndex)
        }
        return segments
    }

    /// 문장 조각들 — 종결부호(+닫는 따옴표) 뒤 공백, 또는 개행 뭉치에서 끊는다.
    /// 각 조각은 꼬리 공백을 포함해 원문을 빈틈없이 덮는다.
    /// "3.5초"·"1930." 같은 숫자 소수점은 뒤가 공백이 아니라 끊기지 않는다.
    package static func sentencePieces(in text: Substring) -> [Range<String.Index>] {
        let terminals: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
        let closers: Set<Character> = ["”", "\"", "」", "』", "’", "'"]
        var pieces: [Range<String.Index>] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if char == "\n" {
                // 개행 뭉치 = 문단 경계 — 종결부호 없는 문단도 여기서 끊긴다.
                var end = text.index(after: index)
                while end < text.endIndex, text[end] == "\n" {
                    end = text.index(after: end)
                }
                pieces.append(start..<end)
                start = end
                index = end
                continue
            }
            if terminals.contains(char) {
                var end = text.index(after: index)
                while end < text.endIndex, terminals.contains(text[end]) {
                    end = text.index(after: end)  // "?!"·"…!" 연속 종결부호
                }
                while end < text.endIndex, closers.contains(text[end]) {
                    end = text.index(after: end)  // 닫는 따옴표는 문장에 붙인다
                }
                if end == text.endIndex || text[end].isWhitespace {
                    // 꼬리 공백(개행 제외 — 개행 뭉치는 위에서 제 조각이 된다)까지 포함.
                    while end < text.endIndex, text[end].isWhitespace, text[end] != "\n" {
                        end = text.index(after: end)
                    }
                    pieces.append(start..<end)
                    start = end
                    index = end
                    continue
                }
                index = end
                continue
            }
            index = text.index(after: index)
        }
        if start < text.endIndex { pieces.append(start..<text.endIndex) }
        return pieces
    }

    /// 폴백 사슬 — 상한을 넘는 "문장"(종결부호 없는 붙여쓴 텍스트)을 어절로,
    /// 그것도 안 되면 강제로 자른다. 이 사슬이 없으면 종결부호 없는 4,000자가
    /// 세그먼트 하나가 되어 잘림이 되돌아온다 (docs/m6-scene-split.md §2.2).
    package static func capOversized(
        _ pieces: [Range<String.Index>], in text: Substring
    ) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        for piece in pieces {
            guard text[piece].utf16.count > maxSegmentUTF16 else {
                result.append(piece)
                continue
            }
            // 어절 경계(공백 뭉치 뒤)에서 상한 이하로 욱여넣는다.
            var chunkStart = piece.lowerBound
            var chunkLength = 0
            var lastBreak: String.Index?  // 마지막 어절 경계 (공백 직후)
            var index = piece.lowerBound
            var previousWasSpace = false
            while index < piece.upperBound {
                let char = text[index]
                if previousWasSpace, !char.isWhitespace { lastBreak = index }
                previousWasSpace = char.isWhitespace
                let charLength = String(char).utf16.count
                if chunkLength + charLength > maxSegmentUTF16 {
                    // 어절 경계가 있으면 거기서, 없으면 여기서 강제 절단.
                    let cut = (lastBreak.map { $0 > chunkStart ? $0 : index }) ?? index
                    result.append(chunkStart..<cut)
                    chunkStart = cut
                    chunkLength = text[cut..<index].utf16.count
                    lastBreak = nil
                }
                chunkLength += charLength
                index = text.index(after: index)
            }
            if chunkStart < piece.upperBound {
                result.append(chunkStart..<piece.upperBound)
            }
        }
        return result
    }

    /// CDC 경계 판정용 해시 — **프로세스 간 안정**이 필수다. Swift `Hasher`는
    /// 실행마다 시드가 달라 경계가 매 실행 바뀌고, 그러면 콘텐츠 해시 메모가
    /// 전부 빗나가 매 실행 전체 재요약이 된다. FNV-1a는 결정적이고 싸다.
    package static func fnv1a(_ text: Substring) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// `#{1,3} 제목` 꼴이면 (레벨, 제목). `####` 이상·공백 없는 `#텍스트`는 본문.
    /// 에디터의 제목 파생(`EntryStore.derivedTitle`)과 같은 판정 기준이다.
    package static func headingLine(_ line: Substring) -> (Int, String)? {
        var level = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#", level < 4 {
            level += 1
            index = line.index(after: index)
        }
        guard (1...3).contains(level), index < line.endIndex, line[index] == " "
        else { return nil }
        let title = line[line.index(after: index)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (level, title)
    }

    /// Extracts a single-line synopsis preview (up to 80 characters) from the first prose paragraph of a scene section.
    package static func synopsisPreview(of line: Substring) -> String {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)[...]
        if text.isEmpty || isSceneBreakLine(text) || headingLine(text) != nil {
            return ""
        }
        while text.hasPrefix(">") || text.hasPrefix("-") || text.hasPrefix("*") {
            let next = text.dropFirst()
            if next.first == " " || next.first == "\t" {
                text = next.drop(while: { $0 == " " || $0 == "\t" })
            } else {
                break
            }
        }
        let cleaned = text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }
        if let firstSentenceRange = sentencePieces(in: cleaned[...]).first {
            let firstSentence = cleaned[firstSentenceRange].trimmingCharacters(in: .whitespacesAndNewlines)
            if !firstSentence.isEmpty {
                return firstSentence.count > 80 ? String(firstSentence.prefix(80)) + "…" : firstSentence
            }
        }
        return cleaned.count > 80 ? String(cleaned.prefix(80)) + "…" : cleaned
    }

    /// Content revisions cannot identify repeated source occurrences. Omit ambiguous keys.
    package var unambiguousSceneIndicesByHash: [String: Int] {
        var indices: [String: Int] = [:], repeated: Set<String> = []
        for (index, scene) in scenes.enumerated() {
            if indices.updateValue(index, forKey: scene.contentHash) != nil { repeated.insert(scene.contentHash) }
        }
        for hash in repeated { indices[hash] = nil }
        return indices
    }

    private static func hash(_ text: Substring) -> String {
        stableHash(String(text))
    }

    /// 프로세스 간 안정 해시 — 씬 해시와 같은 규격 (SHA-256 앞 16자).
    /// 장·작품 노드의 결합 해시(BackgroundIndexer)도 이 규격을 쓴다.
    package static func stableHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
