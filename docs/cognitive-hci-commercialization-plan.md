# Purlory 인지공학·HCI 기반 상용화 아키텍처 및 코드베이스 개선 계획서 (안티그래비티 최신 작업 반영판)

> **문서 목적**: 외부 인지공학·HCI 전략 보고서(Flower & Hayes 40-20-40 모델, 인지 부하 이론 CLT, 신경생리학적 타이핑 레이턴시, 한국형 HWPX 해자, 온디바이스 AI 스캐폴딩)를 **안티그래비티(Antigravity)가 방금 완료한 커밋(`b62f5652`, `93dbc431`) 및 워킹 트리의 25개 파일 초저지연 최적화 패치**까지 반영하여 재진단하고, 중복 작업 없이 다음 단계로 즉시 착수할 수 있는 정밀 엔지니어링 로드맵을 정의한다.

---

## 1. 안티그래비티(Antigravity) 완료 작업 리뷰 및 아키텍처 달성도 평가

안티그래비티에서 방금 완료한 3단계 작업(Git 기반 원고 버전 엔진 → 작가 워크플로 M8-1~M8-5 → 24만 자 장편 120Hz 한글 연타 Zero-Materialization 최적화)을 코드 수준에서 리뷰한 결과, 보고서에서 요구한 **Phase 1(120Hz 8.3ms 프레임 예산 및 O(1) 증분 파이프라인)**과 **Phase 2의 핵심 구조(초고/퇴고 진단 분리, 장면 섹션 드래그 재정렬, Story Map 분량/사건 밀도, 인물 서사 동학, Polish 원문 대조 UI)**가 매우 높은 완성도로 이미 달성되었다.

### 1.1 안티그래비티가 방금 해결한 핵심 엔지니어링 성과 (검증 완료)

| 영역 | 반영된 커밋 / 워킹 트리 파일 | 실제 구현 내용 및 인지공학적 의의 |
| :--- | :--- | :--- |
| **120Hz(8.0ms) 장편 한글 자모 연타 프레임 예산 달성**<br>(워킹 트리 25개 파일) | • `DocumentSource.swift`<br>• `ParagraphRenderIndex.swift`<br>• `BlockTextView+RenderIndex.swift`<br>• `WorkspaceWritingStatistics.swift`<br>• `BlockTextView+Codec.swift`<br>• `BlockTextView+Input.swift`<br>• `LongNovelLagRegressionTests.swift` | • **O(1) 트리 통계**: `DocumentSource.Node`와 `ParagraphRenderIndex.Record`에 `newlines` 집계를 추가하여, 24만 자(6,600줄) 장편에서도 문자열 실체화(`materializationCount == 0`)나 스캔 없이 **O(1)**로 글자수·문단수를 즉시 계산<br>• **문단 첫머리 한글 IME 빠른 경로 수정**: `clamped.location >= para.location` 조건 보정으로 문단 맨 앞에서 한글 자모를 조합할 때도 6,600줄 전체 재직렬화가 발생하지 않음(`serialCacheRebuildCount == 0`)<br>• **인라인/블록 마크다운 변환 가드**: 마지막 글자(`$`, `*`, `~`, `=`, `` ` ``, `)`) 및 문단 첫 글자(`[`, `>`, `#`, `-` 등) O(1) 선판정으로 일반 한글 타이핑 시 정규식·문단 복사를 완전 생략<br>• **실측 회귀 테스트(`testRapidHangulBurstTypingWithVersionsAndCharacterCardsNeverMaterializesLongNovel`)**: 버전 기록과 인물 카드를 모두 열어둔 상태에서 200+ CPM 한글 자모 연타 시 **P95 < 8.0ms** 검증 완료 |
| **SwiftUI 관찰 팬아웃(Fan-out) 및 String 실체화 완전 차단**<br>(워킹 트리) | • `ManuscriptVersion.swift`<br>• `WorkspacePouchTools.swift`<br>• `WorkspaceCharacterCards.swift`<br>• `SpatialWorkspaceCanvas.swift`<br>• `ProjectSession.swift` | • **`ManuscriptResumeBrief.build` 슬라이스 역방향 스캔**: 24만 자 원고 전체를 `document.body`로 합치지 않고 `source.clampedSlice`(16KB 윈도우) 역방향 탐색으로 현재 장 제목과 직전 문단 발췌를 추출(`materializationCount == 0`)<br>• **`projectPresentation` / `documentPresentation` 분리**: 본문 타이핑 중 주머니(`WorkspacePouchTools`), 인물 카드(`WorkspaceCharacterCards`), 타일 크롬이 매 자모마다 불필요하게 재평가되지 않도록 절연 |
| **작가 중심 40-20-40 워크플로 M8-1 ~ M8-5 완결**<br>(`93dbc431`, `b62f5652`) | • `ProjectGitRepository.swift`<br>• `WritingDiagnosticsWorkspaceBinding.swift`<br>• `DocumentOutlineProjection.swift`<br>• `StoryMapProjection.swift`<br>• `CharacterBibleView.swift`<br>• `WorkspaceAssistancePanel.swift` | • **M8-1 (초고 몰입 보호)**: 현재 타이핑 중인 문단 밑줄 유예 및 `focusDimming` 시 진단 밑줄 자동 억제<br>• **M8-2 (비선형 장면 이동)**: 개요(`DocumentOutlineView`)에서 `# 장면` 섹션 전체 드래그 이동 + `"장면 순서 변경 전 자동 보관"` 안전핀 버전 자동 생성<br>• **M8-3 (Story Map 밀도)**: 전체 분량 대비 위치(`progressRatio`), 비중(`lengthRatio`), 사건 밀도(`eventCount`) 배지 시각화<br>• **M8-4 (인물 서사 동학)**: `CharacterCard`에 접이식 `motivation`, `goal`, `conflict`, `epiphany` 필드 추가<br>• **M8-5 (비파괴 Polish 대조)**: `.polish` 실행 시 원문 덮어쓰기 대신 `선택한 원문` vs `다듬은 제안` 비교 후 수락 |

---

## 2. 안티그래비티 작업 반영 후 **진짜 남은 핵심 개선 과제 (Next-Gen Action Plan)**

안티그래비티가 에디터 코어 성능(P95 < 8ms)과 M8-1~M8-5 워크플로를 완수했기 때문에, 이제 Purlory가 인지공학 보고서의 상용화 전략을 100% 달성하기 위해 **실제로 구현해야 할 남은 격차(Gap)는 아래 4대 과제**로 명확히 압축된다.

| 우선순위 | 핵심 과제명 | 현재 코드 상태 (안티그래비티 작업 이후) | 구체적 구현 목표 (Actionable Spec) |
| :--- | :--- | :--- | :--- |
| **Priority 1**<br>(즉시 체감 UX) | **한국형 웹소설·출판 멀티 플랫폼 글자수 & 가변 문단 폭·모바일 뷰어** | • `WorkspaceWritingStatistics.swift`가 `utf16Length - newlines`로 O(1) 글자수만 표시하며, 공백 제외/200자 원고지/플랫폼별 정산 기준은 미구현<br>• `EditorMetrics.maxContentWidth = 760` 고정 | • `DocumentSource.Node` 및 `ParagraphRenderIndex.Record`에 `nonWhitespaceCount`를 함께 집계해 **O(1) 무지연**으로 **공백 포함 / 공백 제외 / 200자 원고지 매수 / 웹소설 플랫폼(카카오·네이버·문피아·리디) 정산 글자수** 동시 제공<br>• 주머니(`WorkspacePouchTools`)에 **본문 폭 슬라이더(560~880pt)** 및 **원클릭 모바일 리더기 뷰포트(390pt) 프리뷰 토글** 추가 |
| **Priority 2**<br>(퇴고 인지공학) | **키로깅 휴지기(Pause)·수정(Backspace) 기반 '인지 병목 문단' 진단 & 호흡 히트맵** | • `KoreanSentenceRules.swift`가 형태소·문장 길이(`> 120자`)·절 개수(`>= 4`)는 진단하지만, 집필 중 타이핑 정체(Pause)나 반복 수정(Backspace) 흔적은 기록하지 않음 | • [IRIS (2026)](https://arxiv.org/html/2608.19614v1) 및 [Yao et al. (IJHCI 2026)](https://www.tandfonline.com/doi/full/10.1080/10447318.2026.2628994) 연구에 기반한 `WritingTraceRecorder` 신설: 문단별 휴지기(`pause > 2.0s`)와 백스페이스 밀도를 경량 기록하여 퇴고 시 **"집필 중 고민·수정이 깊었던 인지 병목 문단"**으로 하이라이트<br>• 문장 길이(14어절 쾌적 vs 35~43어절 과부하) 단계별 시각 히트맵 연동 |
| **Priority 3**<br>(집필 몰입 & AI) | **DND 우측 단일 핀(Pin) 참고 카드 & 인라인 국어/유의어 사전·다중 윤문 비교** | • `WorkspaceAssistancePanel.swift`의 `.polish`가 원문 vs 단일 제안 비교까지는 구현되었으나, 다중 대안 비교(인지 강제 함수)와 드래그 시 인라인 국어사전 팝오버는 부재 | • **집필 중 단일 핀(Pin) 카드 오버레이**: `focusDimming`/`whisperTyping` 집중 중에도 핀으로 고정한 참고 노트·인물 카드 1장만 우측 여백에 반투명 표시<br>• **인라인 국어/유의어 사전 팝오버**: 선택 툴바에서 창 전환(`Alt+Tab`) 없이 macOS Dictionary Services + Kiwi 유의어 + 원문 용례 즉시 조회<br>• **인지 강제 함수 다중 윤문**: `.polish`에서 호흡 단축안 vs 원문 리듬 유지안 2종 병렬 제시 |
| **Priority 4**<br>(한국 시장 해자) | **Zero-Dependency 네이티브 HWPX/HWP 양방향 브릿지** | • `Export/`에 `MarkdownExporter.swift`와 `EpubExporter.swift`만 존재하며 `.hwpx`/`.hwp` 입출력은 미구현 | • `Sources/PurloryDocumentEngine/HWPX/` 및 `Sources/PurloryWorkspaceUI/Export/HwpxExporter.swift` 신설<br>• [kordoc](https://github.com/chrisryugj/kordoc) 파싱 구조와 `patchHwp` 무결성 기법을 이식해 외부 Pandoc/한컴오피스 없이 병합 표(`rowspan`/`colspan`)·각주·스타일이 보존되는 `.hwpx`/`.hwp` 양방향 임포트·익스포트 구현 |

---

## 3. 세부 모듈별 설계 및 파일 수정 계획

### 3.1 [Priority 1] O(1) 한국형 멀티 플랫폼 글자수 카운터 & 모바일 프리뷰어
안티그래비티가 구축한 `DocumentSource` 및 `ParagraphRenderIndex`의 O(1) 트리 집계 아키텍처를 훼손하지 않고 그대로 확장한다.

1. **수정 대상 파일**:
   - `Sources/PurloryFoundation/DocumentSource.swift`
   - `Sources/PurloryDocumentEngine/ParagraphRenderIndex.swift`
   - `Sources/PurloryWorkspaceUI/Editor/BlockTextView+RenderIndex.swift`
   - `Sources/PurloryWorkspaceUI/Workspace/WorkspaceWritingStatistics.swift`
   - `Sources/PurloryWorkspaceUI/Editor/PurloryBlockEditor.swift`
   - `Sources/PurloryWorkspaceUI/Workspace/WorkspacePouchTools.swift`
2. **구현 명세**:
   - `DocumentSource.Node`와 `ParagraphRenderIndex.Record`에 `newlines`와 함께 `whitespaceCount`(공백·탭·줄바꿈 UTF-16 개수)를 저장하여, 24만 자 문서에서도 **O(1)**로 `charactersWithSpaces`(`utf16Length - newlines`)와 `charactersWithoutSpaces`(`utf16Length - whitespaceCount`), 그리고 `manuscriptPages200`(`ceil(Double(charactersWithSpaces) / 200.0)`)을 즉시 계산한다.
   - `SpatialDocumentTile` 하단 통계 바에 마우스를 올리거나 클릭하면 **공백 포함 · 공백 제외 · 200자 원고지 매수 · 플랫폼별(카카오/네이버/문피아/리디) 기준 글자수**를 즉시 보여준다.
   - `CompletionSettings` 및 `WorkspacePouchTools.swift`에 **본문 폭 조절(좁게 580pt · 표준 680pt · 넓게 800pt · 모바일 뷰어 390pt)** 옵션을 추가하여 원클릭으로 모바일 연재 호흡을 점검할 수 있게 한다.

### 3.2 [Priority 2] 키로깅 휴지기(Pause) · 백스페이스 기반 '인지 병목 문단' 진단기
1. **신규/수정 대상 파일**:
   - `Sources/PurloryDocumentEngine/WritingTraceRecorder.swift` (신규)
   - `Sources/PurloryWorkspaceUI/Editor/BlockTextView+Input.swift`
   - `Sources/PurloryWorkspaceUI/Editor/WritingDiagnosticsDecoration.swift`
   - `Sources/PurloryIntelligence/WritingQuality/WritingDiagnostics.swift`
2. **구현 명세**:
   - 사용자가 문단을 입력할 때 문단(또는 씬/해시) 단위로 ① **2초 이상 타이핑 멈춤(Long Pause) 횟수/시간**과 ② **백스페이스/범위 삭제(Revision Burst) 횟수**를 O(1) 메모리 카운터로 기록한다(타이핑 핫패스 비용 0.001ms 미만).
   - 초고 집중 모드를 끄고 **퇴고/교정 밑줄**을 켰을 때, 유독 멈춤과 삭제가 반복됐던 문단을 `"집필 중 고민·수정이 집중된 문단입니다. 문장 호흡과 논리 연결을 점검해 보세요"`로 표시하고, `KoreanSentenceRules.swift`의 장문(`> 120자`)·다중 절(`>= 4절`) 진단과 결합해 인지 부하 히트맵으로 보여준다.

### 3.3 [Priority 3] DND 단일 핀(Pin) 참고 카드 & 인라인 사전 팝오버
1. **수정 대상 파일**:
   - `Sources/PurloryWorkspaceUI/Workspace/SpatialWorkspaceController.swift`
   - `Sources/PurloryWorkspaceUI/Workspace/SpatialWorkspaceCanvas.swift`
   - `Sources/PurloryWorkspaceUI/Editor/BlockTextView+Overlays.swift`
   - `Sources/PurloryWorkspaceUI/Workspace/WorkspaceAssistance.swift`
2. **구현 명세**:
   - `SpatialWorkspaceController`에 `pinnedNoteID: WritingDocumentID?` / `pinnedCharacterID: UUID?`를 추가하여, `focusDimming`이나 `whisperTyping`으로 주변 크롬이 모두 페이드아웃된 상태에서도 우측 상단 여백에 반투명 참고 카드 1장을 고정해 볼 수 있게 한다.
   - `BlockTextView` 텍스트 드래그 선택 툴바에 **사전/용례(`book.closed`)** 버튼을 추가하여 macOS 네이티브 사전(`DCSCopyTextDefinition`) 뜻풀이와 프로젝트 내 등장 문단을 즉시 팝오버로 띄운다.

### 3.4 [Priority 4] 네이티브 HWPX/HWP 양방향 무손실 코덱 (`PurloryDocumentEngine`)
1. **신규/수정 대상 파일**:
   - `Sources/PurloryDocumentEngine/HWPX/HwpxArchiver.swift` & `HwpxDocumentCodec.swift` (신규)
   - `Sources/PurloryWorkspaceUI/Export/HwpxExporter.swift` (신규)
   - `Sources/PurloryWorkspaceUI/Export/ExportDestination.swift`
2. **구현 명세**:
   - OWPML 표준(`.hwpx` ZIP 아카이브 내 `Contents/section0.xml`, `Contents/header.xml`)을 생성·파싱하는 네이티브 코덱을 구현하여, 마크다운 헤딩·문단·인라인 강조·병합 표·이미지를 한컴오피스 없이 `.hwpx`로 즉시 내보내고 불러온다.

---

## 4. 즉시 실행 전 체크포인트

1. **현재 워킹 트리의 안티그래비티 변경사항(25개 파일) 보존 및 커밋 여부**:
   - 현재 워킹 트리에 안티그래비티가 작업한 24만 자 장편 120Hz 최적화 코드(`DocumentSource.swift`, `WorkspaceWritingStatistics.swift`, `LongNovelLagRegressionTests.swift` 등 25개 파일)가 `unstaged` 상태로 놓여 있습니다.
   - 새로운 개선 작업(Priority 1~4)을 시작하기 전에 이 25개 파일의 테스트 통과 여부를 확인하고 먼저 깔끔하게 커밋(또는 그대로 유지한 채 확장)하는 것이 안전합니다.
