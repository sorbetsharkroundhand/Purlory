# Purlory 작가 중심 워크플로 통합 개발 계획 (Antigravity 실행 로드맵)

> **설계 원칙** (`README.md` · `CLAUDE.md` · 7대 글쓰기 연구 기반)
> 1. **Fiction first, editor first**: AI가 꺼져 있어도 장편 소설의 구상–초고–구조적 퇴고–교정을 완주할 수 있는 최고 수준의 집필 도구여야 한다.
> 2. **The writer owns the story**: 원문이 유일한 진실(Single Source of Truth)이며, 모든 파생 지식·AI 제안·구조 변경은 작가의 명시적 승인 또는 안전핀 버전(`ManuscriptVersion`)과 `⌘Z` Undo 위에서만 동작한다.
> 3. **Progressive Disclosure (점진적 노출)**: 초고(Drafting) 중에는 에디터와 최소한의 메모만 보여주고, 작가가 퇴고(Revising)·교정(Editing)·구조 설계를 요청할 때만 관련 도구를 드러낸다.

---

## 0. 이론적 배경과 Purlory 아키텍처 매핑

| 이론 / 레퍼런스 | 핵심 문제 정의 | Purlory 대응 모듈 |
| :--- | :--- | :--- |
| **[CHI 2025 — Making the Write Connections](https://zxnnic.github.io)** (Zixin Zhao 외) | 원고·노트·타임라인이 여러 앱에 흩어져 맥락 연결과 작업 재개 비용이 높음 | `ManuscriptResumeBrief`, `WorkspacePouchTools` (1줄 빠른 메모 + 원고 연결 브리프) — **완료 (`b62f565`)** |
| **[Flower & Hayes (1981)](https://publicationsncte.org/content/journals/10.58680/ccc198115885)** ([해설](https://patthomson.net/2026/03/22/the-process-of-writing/)) | 계획·문장화·검토가 문장 단위로도 재귀 발생하며, 하위 목표(교정)가 상위 목표(서사)를 방해하면 집필이 멈춤(Monitor 과부하) | **M8-1**: 초고/퇴고 단계별 진단 제어 (`WritingDiagnosticsWorkspaceBinding`) 및 빠른 참조 복귀 (`ProjectEditorRequests.sourceReturnPoint`) |
| **[MIT Writing Process](https://cmsw.mit.edu/writing-and-communication-center/resources/writers/writing-process/)** | Prewriting → Drafting(작가 중심) → Revising(독자·구조 중심) → Editing(문법·교정) 분리 원칙 | **M8-1**: 집필 중 진단 밑줄 자동 억제(Quiet Drafting) 및 퇴고/교정 토글 |
| **[Scrivener Corkboard](https://www.literatureandlatte.com/blog/integrating-scriveners-binder-corkboard-and-outliner/)** | 장면(Scene) 카드를 시각적으로 재배치하면 실제 원고 섹션이 함께 이동하는 비선형 집필 | **M8-2**: `DocumentOutlineView` / `StoryMapView` 장면 섹션 드래그 재정렬 + 자동 안전핀 버전(`captureSafetySnapshotIfNeeded`) |
| **[Save the Cat! Writes a Novel](https://savethecat.com/tips-and-tactics/a-writers-guide-to-beats-and-beat-sheets)** ([15 Beats](https://www.literatureandlatte.com/blog/outline-your-nanowrimo-novel-using-the-save-the-cat-story-structure)) | Beat(전환점) ≠ Scene(장면); 전체 분량 대비 위치(%)와 사건 밀도로 중반부 늘어짐(Sagging Middle) 방지 | **M8-3**: `StoryMapProjection`에 분량 위치(`percentageRange`)·한 줄 시놉시스·사건 밀도 배지 추가 |
| **[The Snowflake Method](https://www.advancedfictionwriting.com/articles/snowflake-method/)** (Randy Ingermanson) | 1문장 로그라인 → 1문단 요약 → 인물 동학(동기·목표·갈등·깨달음) → 장면 시트로 프랙탈 확장 | **M8-4**: `CharacterCard`에 선택형 서사 동학 필드(`motivation`, `goal`, `conflict`, `epiphany`) 및 작품 한 줄 코어(`storyPremise`) 확장 |
| **[CHI 2024 — Design Space for Writing Assistants](https://arxiv.org/abs/2403.14117)** (Mina Lee 외) | AI가 원문을 즉시 덮어쓰면 작가의 문체 소유감이 훼손됨; 비파괴적 비교(Diff)와 부분 수용이 핵심 | **M8-5**: `WorkspaceAssistance`(`.polish`)의 즉시 덮어쓰기(`runInline`)를 원문 vs 제안 비교 프리뷰 후 수락으로 전환 |

---

## 1. 완료된 기반 작업 (Step 1 ~ Step 3, Commit `b62f565`)

- [x] **실제 `.git` 원고 버전 관리 엔진**: `Sources/PurloryStorage/ProjectGitRepository.swift`
  - `Projects/<project-id>/.git/` 표준 Git v2 저장소(`blob`/`tree`/`commit`), `.gitignore`(`Intelligence/`, `Notes/`, `References/`, `UserData/` 제외), `Manuscripts/<doc-id>.md` 워킹 트리 동기화
- [x] **원고 전용 버전 관리 & 3-Way 문단 병합**: `Sources/PurloryDocumentEngine/ManuscriptVersion.swift`
  - `.note`/`.reference` 버전 관리 제외, DAG `parentIDs`, `branchName`, `lowestCommonAncestor`, `ManuscriptThreeWayMerge`
- [x] **점진적 노출 UI & 집필 흐름 보호**: `ManuscriptVersionsView.swift`, `WorkspacePouchTools.swift`, `WorkspaceShellView.swift`
  - 단일 흐름(`본편`)일 때는 브랜치/병합 UI 숨김, 주머니에서 커서 이탈 없는 1줄 빠른 메모 + `ManuscriptResumeBrief`(현재 장면·연결 메모 카드), 문단 이동 시 `"문단 이동 전 자동 보관"` 자동 스냅샷

---

## 2. Antigravity 단계별 개발 마일스톤 (M8-1 ~ M8-5)

### M8-1. 초고 몰입 보호 — Drafting vs Editing 진단 분리 (MIT Writing Process · Flower & Hayes)

**목표**: 초고 집필(Drafting) 중에 맞춤법·문장 흐름 진단 밑줄이 실시간으로 그어져 작가의 자기 검열(Monitor 과부하)을 유발하는 문제를 막고, 작가가 원할 때(퇴고·교정 시점)만 진단을 노출한다.

- **수정 대상 파일**:
  1. `Sources/PurloryWorkspaceUI/WritingQuality/WritingDiagnosticsWorkspaceBinding.swift`
  2. `Sources/PurloryWorkspaceUI/Editor/BlockTextView+WritingDiagnostics.swift`
  3. `Sources/PurloryWorkspaceUI/Workspace/WorkspacePouchTools.swift`
- **구현 명세**:
  1. **타이핑 중 현재 문단 밑줄 유예 (Active-Paragraph Quiet Window)**:
     - `WritingDiagnosticsWorkspaceBinding.publish()`에서 에디터가 포커스 중이고 커서가 위치한 현재 문단(`editor.selectedRange()`)에 해당하는 진단 항목은, 사용자가 문단 밖으로 커서를 옮기거나 일정 휴지기(또는 명시적 교정 보기) 전까지 밑줄 렌더링을 보류한다.
  2. **주머니(Pouch) 내 `교정 밑줄 표시` 토글 (Progressive Disclosure)**:
     - `CompletionSettings`(또는 `UserDefaults` 기반 프로젝트 프레젠테이션 설정)에 `showsWritingDiagnosticsInEditor: Bool` 추가.
     - 초고 집중 모드(`model.focusDimming == true`)를 켜면 자동으로 에디터 내 진단 밑줄을 숨겨 온전한 백지 몰입감을 제공하고, 마진 노트 패널(`.margin`)을 열거나 집중 모드를 끄면 다시 표시한다.
- **검증 테스트**:
  - `Tests/PurloryCoreTests/WritingDiagnosticsWorkspaceTests.swift`: `focusDimming` 활성화 시 에디터 장식(`writingDiagnostics`)이 비워지고, 해제 시 즉시 복원되는지 검증.

---

### M8-2. 비선형 장면 재구성 — 개요(Outline) 장면 섹션 드래그 이동 (Scrivener Corkboard)

**목표**: 장편 소설을 비선형으로 집필할 때 에디터 본문을 직접 드래그해 잘라 붙이지 않고도, `DocumentOutlineView`(문서 개요)에서 `# 장면 제목` 카드를 드래그해 장면 전체 섹션(`# 장면` ~ 다음 동급 `# 장면` 직전까지)을 안전하게 재배치한다.

- **수정 대상 파일**:
  1. `Sources/PurloryDocumentEngine/DocumentOutline.swift`
  2. `Sources/PurloryWorkspaceUI/Workspace/DocumentOutlineProjection.swift`
  3. `Sources/PurloryWorkspaceUI/Workspace/DocumentOutlineView.swift`
  4. `Sources/PurloryWorkspaceUI/Workspace/WorkspaceParagraphTransfer.swift`
- **구현 명세**:
  1. **`DocumentOutlineProjection.Heading`에 섹션 전체 범위(`sectionRange: Range<Int>`) 추가**:
     - 제목 한 줄의 `sourceRange`뿐 아니라, 해당 헤딩부터 다음 동급(또는 상위) 헤딩 직전까지의 UTF-16 범위(`sectionRange`)와 첫 문단 1줄 요약(`synopsisPreview: String`)을 함께 계산한다.
  2. **`WorkspaceParagraphTransfer.moveSceneSection(...)` 추가**:
     - `sourceHeading`의 `sectionRange`를 `WorkspaceParagraphAnchor`로 감싸고, 이동 직전 `ManuscriptVersionActions.captureSafetySnapshotIfNeeded(for: key, label: "장면 순서 변경 전 자동 보관", in: session)`을 호출해 안전핀 버전을 남긴 뒤 `WorkspaceDocumentTransaction.perform(..., actionName: "장면 순서 이동")`으로 원자적 이동 및 `⌘Z` Undo를 등록한다.
  3. **`DocumentOutlineView` 드래그 앤 드롭 & 한 줄 시놉시스 표시**:
     - 각 제목 행 아래에 본문 첫 문장 요약(`synopsisPreview`, 1줄)을 은은하게 표시해 Scrivener Corkboard 카드 역할을 겸하게 하고, 행 간 재정렬을 연결한다.
- **검증 테스트**:
  - `Tests/PurloryCoreTests/DocumentOutlineTests.swift`: 3개 장면(`# 1장`, `# 2장`, `# 3장`)에서 `# 3장`을 `# 1장` 뒤로 옮기면 본문 전체가 보존된 채 순서만 바뀌고, `"장면 순서 변경 전 자동 보관"` 버전이 생성되며 `UndoManager.undo()`로 즉시 복구되는지 검증.

---

### M8-3. Story Map 고도화 — 분량 비중(%) · 사건 밀도 · 장면 요약 시각화 (Save the Cat!)

**목표**: `StoryMapView`가 단순 장면/사건 평면 리스트에 그치지 않고, 전체 원고에서 각 장면과 주요 사건(Beat)이 차지하는 **분량 위치(0% ~ 100%)**와 **사건 밀도**를 함께 보여주어 중반부 늘어짐(Sagging Middle)이나 복선 공백을 한눈에 파악하게 한다.

- **수정 대상 파일**:
  1. `Sources/PurloryWorkspaceUI/Workspace/StoryMapProjection.swift`
  2. `Sources/PurloryWorkspaceUI/Workspace/StoryMapView.swift`
- **구현 명세**:
  1. **`StoryMapProjection.Row` 확장**:
     - `progressRatio: Double` (`sourceRange.lowerBound / max(1, sourceLength)` — 0.0~1.0)
     - `lengthRatio: Double` (`sourceRange.count / max(1, sourceLength)`)
     - `eventCount: Int` (해당 장면에 속한 `canonicalEvents` 개수)
  2. **`StoryMapView` 행 UI 개선**:
     - 장면(`kind == .scene`) 행 우측에 전체 원고 대비 시작 위치 배지(예: `12%`, `50%`, `78%`)와 장면 내 사건 수(`사건 3`)를 모노스페이스 캡슐로 표시한다.
     - 사건이 0개인 긴 장면(전개 정체 구간 후보)은 은은한 보조 표시로 작가가 호흡을 점검할 수 있게 돕는다.
- **검증 테스트**:
  - `Tests/PurloryCoreTests/StoryMapProjectionTests.swift`: 각 장면의 `progressRatio`와 `eventCount`가 원고 UTF-16 길이 및 인덱싱된 사건과 정확히 일치하는지 검증.

---

### M8-4. 계획형/혼합형 작가를 위한 인물 동학(Arc) 확장 (The Snowflake Method)

**목표**: Snowflake Method Step 3·5·7의 핵심인 **인물의 서사 동학(동기·목표·갈등·변화)**을 강제 입력이 아닌 **접이식(Progressive Disclosure) 상세 필드**로 `CharacterBibleView`에 추가하여, Plotter와 Plantser 모두 필요할 때만 깊이 있는 설계를 기록하고 프롬프트 컨텍스트에도 반영할 수 있게 한다.

- **수정 대상 파일**:
  1. `Sources/PurloryFoundation/WritingProject.swift` (또는 `CharacterCard` 정의 파일)
  2. `Sources/PurloryWorkspaceUI/CharacterBibleView.swift`
  3. `Sources/PurloryWorkspaceUI/Workspace/WorkspaceCharacterCards.swift`
- **구현 명세**:
  1. **`CharacterCard` 선택형 필드 추가 (하위 호환 `Codable`)**:
     - `var motivation: String?` (추상적 욕망: 왜 움직이는가)
     - `var goal: String?` (구체적 목표: 무엇을 얻으려 하는가)
     - `var conflict: String?` (장애물: 무엇이 가로막는가)
     - `var epiphany: String?` (깨달음/변화: 결말에서 어떻게 달라지는가)
  2. **점진적 노출 UI**:
     - 기본 인물 카드는 지금처럼 `이름`, `별칭`, `성격·말투·관계`만 간결하게 보여준다.
     - 카드 하단 `서사 동학 (동기·목표·갈등)` 토글을 펼쳤을 때만 4개 필드를 노출해 초보 작가나 Pantser에게 입력 부담을 주지 않는다.
- **검증 테스트**:
  - 기존 `CharacterCard` JSON 역직렬화 하위 호환성 테스트 및 필드 수정 시 `locked` 보호 규칙 유지 검증.

---

### M8-5. 작가 주도형 비파괴적 문장 다듬기 — Polish Diff 프리뷰 (CHI 2024 Writing Assistants)

**목표**: CHI 2024 연구와 CHI 2025 사용자 피드백(*"AI가 내 문체를 덮어쓰는 것이 싫다"*)에 맞춰, `WorkspaceAssistance`의 `다듬기(.polish)`가 원문을 즉시 덮어쓰지 않고 **원래 문장 vs 다듬은 문장**을 나란히 비교한 뒤 작가가 `[적용]` 또는 `[취소]`를 선택하게 한다.

- **수정 대상 파일**:
  1. `Sources/PurloryWorkspaceUI/Workspace/WorkspaceAssistance.swift`
  2. `Sources/PurloryWorkspaceUI/Workspace/WorkspaceAssistancePanel.swift`
- **구현 명세**:
  1. **`WorkspaceAssistance.runInline` 동작 개선**:
     - `.polish` 실행 시 곧바로 `insert()`를 호출해 본문을 덮어쓰는 대신, `WorkspaceAssistancePanel.present(.polish, ...)`을 열어 생성 과정을 스트리밍으로 보여준다.
  2. **원문 대조 뷰 (`WorkspaceAssistanceView`)**:
     - `model.mode == .polish`일 때 상단에 `선택한 원문`(`capturedSelection.markdown`)을, 하단에 `다듬은 제안`(`model.result`)을 나란히 보여주어 작가가 어조와 단어 변화를 직접 눈으로 비교한 뒤 `다듬은 문장 적용`(`purlory.coauthor.insert`)을 누를 때만 `WorkspaceDocumentTransaction`으로 반영한다.
- **검증 테스트**:
  - `Tests/PurloryCoreTests/WorkspaceAssistanceTests.swift`: `.polish` 생성 완료 직후에는 원고 본문이 바뀌지 않고(`capture.body` 유지), 명시적으로 `insert()`를 호출했을 때만 반영 및 `⌘Z` Undo가 등록되는지 검증.

---

## 3. Antigravity 실행 시 빌드 및 검증 명령어

Antigravity에서 각 마일스톤을 구현할 때 아래 명령어로 샌드박스 충돌 없이 전체 타겟(`Purlory`, `PurloryBench`) 컴파일과 포맷을 검증할 수 있습니다:

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
swift build --build-system native --disable-sandbox \
  -Xswiftc -sdk -Xswiftc /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  -Xcc -isysroot -Xcc /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
&& git diff --check
```
