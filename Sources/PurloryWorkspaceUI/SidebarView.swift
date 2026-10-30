import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 사이드바 섹션 (M6-8) — VSCode의 활동 바처럼 사이드바가 여러 패널을 담는다.
/// 문자열 raw값은 `@AppStorage("purlory.sidebarSection")` 키의 값 — 툴바(소설 배지)와
/// 사이드바가 같은 키로 섹션을 전환한다.
enum SidebarSection: String {
    case files  // 문서(폴더 트리) — 기존 사이드바
    case bible  // 스토리 바이블 (PLAN §7)
    /// 서사 (v5 통합) — 이해 타임라인 + 서사 그래프가 하나의 화면이 됐다
    /// (PLAN §6.6). raw값 "timeline" 유지 — 기존 사용자의 저장된 섹션이 살아남는다.
    case narrative = "timeline"
    case context  // AI 컨텍스트 인스펙터 (v4, 요구사항 §17)
    case margin  // shared General/Fiction intelligence presentation (#105)
}

/// 일관성 경고 존재 표시 점 (M7) — indexer를 관찰해 경고가 생기는 즉시 뜬다.
///
/// 상태 의미는 색 하나에만 맡기지 않는다 (#38): 점은 시각 신호일 뿐, VoiceOver에는
/// "일관성 경고 N개"라는 읽을 수 있는 값으로 전달한다. 점 자체를 장식(hidden)으로
/// 빼 AX 트리 오염을 막는다.
private struct WarningDot: View {
    @ObservedObject var indexer: BackgroundIndexer
    @ObservedObject var store: EntryStore
    let theme: PurloryTheme

    private var warningCountForActiveEntry: Int {
        guard indexer.snapshot?.entryID == store.activeID else { return 0 }
        return indexer.warnings.count
    }

    var body: some View {
        // 일관성 경고 — "확인해 보세요" 신호.
        if warningCountForActiveEntry > 0 {
            Circle()
                .fill(theme.novelC)
                .frame(width: 5, height: 5)
                .offset(x: -3, y: 3)
                .hidden()  // 장식 — 대신 아래 요소가 AX 값을 말한다 (#38).
            Text("일관성 경고 \(warningCountForActiveEntry)개")
                .purloryUIFont(0.1)
                .foregroundStyle(.clear)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel(Text("일관성 경고 \(warningCountForActiveEntry)개 — 서사 탭에서 검토"))
        } else {
            EmptyView()
        }
    }
}

/// 섹션이 보여줄 내용이 없을 때의 안내 문구 한 장.
private struct SidebarSectionHint: View {
    let theme: PurloryTheme
    let text: String

    var body: some View {
        VStack {
            Text(text)
                .purloryUIFont(11)
                .foregroundStyle(theme.ink3C)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            Spacer(minLength: 0)
        }
    }
}

/// 좌측 사이드바 (에디터 v3 — 디자인 이식, 파일시스템 v1 · 섹션화 M6-8).
///
/// 상단: 신호등 옆을 채우는 52px 헤더(우측 날짜 툴바와 같은 높이) —
/// 새 폴더(폴더＋) + 새 소설(책) + 새 저널(＋).
/// 그 아래 섹션 탭(문서·바이블·타임라인) — 팝오버였던 바이블·타임라인을
/// 상시 패널로 승격한다 (열람이 잦아졌다 — 팝오버는 열 때마다 닫힌다).
/// 목록(문서 섹션): 폴더 트리(펼침/접힘) + 저널 행.
enum SidebarPresentation { case legacy, navigator, context }

struct SidebarView: View {
    @Environment(\.purloryWindowChromeLeadingInset) private var windowChromeLeadingInset
    var presentation: SidebarPresentation = .legacy
    @ObservedObject var store: EntryStore
    /// AI 폴더 명명(requestFolderName)과 진행 표시(namingFolderIDs)에 쓴다.
    @ObservedObject var completion: CompletionController
    let theme: PurloryTheme
    /// 바이블·타임라인 섹션의 데이터 소스 — nil이면 문서 섹션만 (프리뷰 등).
    var indexer: BackgroundIndexer?

    /// 현재 섹션 — 툴바의 소설 배지도 이 키를 써서 바이블 섹션을 연다.
    @AppStorage("purlory.sidebarSection") private var sectionRaw = SidebarSection.files.rawValue
    private var section: SidebarSection {
        SidebarSection(rawValue: sectionRaw) ?? .files
    }

    /// 드래그&드롭 세션 상태 — 드래그 원본·드롭 표시 위치.
    @StateObject private var dragModel = SidebarDragModel()

    /// 이름 변경 중인 항목 — 저널·폴더가 id 공간을 공유한다.
    @State private var editingID: UUID?
    @State private var draftTitle = ""
    @State private var hoveredID: UUID?
    /// 휴지통 화면 표시 중 — 복원·영구 삭제는 여기서만 (#9).
    @State private var showingTrash = false
    @FocusState private var renameFieldFocused: Bool
    /// 전역 검색어 — 비어 있지 않으면 트리 대신 검색 결과(평탄)를 보여준다.
    @State private var searchText = ""
    /// 검색 결과 — body 패스마다 전체 본문 스캔하지 않게 .task(id:)로 디바운스해
    /// 갱신한다 (이슈 #52). 스캔은 스토어의 결정적 search가 담당한다.
    @State private var cachedSearchResults: [JournalEntry] = []
    @FocusState private var searchFieldFocused: Bool

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if presentation != .context {
                header
                theme.sepC.frame(height: 1)
            }
            if presentation != .navigator {
                sectionStrip
                theme.sepC.frame(height: 1)
            }
            switch presentation == .navigator ? .files : section {
            case .files: filesSection
            case .bible: bibleSection
            case .narrative: narrativeSection
            case .context: contextSection
            case .margin:
                SidebarSectionHint(theme: theme, text: "글 도구에서 리빙 마진을 열어 주세요.")
            }
        }
        .background(theme.sidebarTintC)
        .overlay(alignment: .trailing) { theme.sepC.frame(width: 1) }
        .onChange(of: renameFieldFocused) { _, focused in
            // Enter(onSubmit) 외에 포커스를 잃어도 커밋 — Esc는 editingID를
            // 먼저 비우므로 여기 걸리지 않는다.
            if !focused, let id = editingID { commitRename(id) }
        }
        // 검색어 변경 → 200ms 디바운스 후 백그라운드에서 한 번만 전체 스캔
        // (이슈 #52·#33). 메인은 값 스냅샷만 떼어 넘긴다 — 30만 자 원고의
        // 본문 스캔이 타이핑 프레임을 먹지 않게.
        .task(id: searchText) {
            guard isSearching else { cachedSearchResults = []; return }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let snapshot = store.entries
            let query = searchText
            let results = await Task.detached(priority: .userInitiated) {
                EntryStore.filterMatches(snapshot, query: query)
            }.value
            guard !Task.isCancelled else { return }
            cachedSearchResults = results
        }
        .onChange(of: store.searchFocusRequests) { _, _ in
            // ⌘⇧F — 검색 필드로 포커스 (문서 섹션으로 전환해서).
            sectionRaw = SidebarSection.files.rawValue
            if presentation != .context { searchFieldFocused = true }
        }
        .onChange(of: store.renameRequests) { _, _ in
            // 메뉴 "저널 이름 바꾸기" — 현재 저널의 인라인 편집을 시작한다.
            sectionRaw = SidebarSection.files.rawValue
            if presentation != .context, let entry = store.activeEntry { startRename(entry) }
        }
        .sheet(isPresented: $showingTrash) {
            TrashSheetView(store: store, trash: store.trash, theme: theme)
        }
    }

    /// Section strip for legacy/context tool surfaces.
    ///
    /// In the new workspace the Project Navigator exclusively owns document navigation.
    /// The context/tool presentation therefore omits the legacy Files tab instead of
    /// exposing a duplicate "return to document" action (#117).
    private var sectionStrip: some View {
        HStack(spacing: 4) {
            if presentation != .context {
                sectionTab(.files, icon: "doc.text", help: "문서")
            }
            Spacer()
            WriterCompatibilityMenu(section: $sectionRaw).frame(width: 26, height: 28)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func sectionTab(
        _ target: SidebarSection, icon: String, help: String
    ) -> some View {
        Button {
            sectionRaw = target.rawValue
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(section == target ? theme.novelC : theme.ink3C)
                .frame(width: 30, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: PurloryRadius.sm, style: .continuous)
                        .fill(section == target ? theme.novelBgC : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    /// 바이블 섹션 — 팝오버와 같은 뷰를 임베드 모드로 (M6-8 패널 승격).
    /// 저널이면 안내 + **소설 전환 버튼** — 여기서 막힌 사용자가 바로 풀 수 있게
    /// (M7 요청: 기존 문서를 소설로 바꾸는 통로가 없었다).
    @ViewBuilder private var bibleSection: some View {
        if store.activeEntry?.resolvedKind == .novel {
            CharacterBibleView(store: store, theme: theme, indexer: indexer, embedded: true)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("이 문서는 일반 저널이에요. 소설로 전환하면 인물·장르 관리와 백그라운드 이해(요약·사건·타임라인)가 켜져요.")
                    .purloryUIFont(11)
                    .foregroundStyle(theme.ink3C)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    store.setKind(.novel, for: store.activeID)
                } label: {
                    Label("소설로 전환", systemImage: "book.closed")
                        .purloryUIFont(12, .medium)
                }
                Text("원문은 그대로예요 — 언제든 우클릭 메뉴에서 일반 저널로 되돌릴 수 있어요.")
                    .purloryUIFont(10)
                    .foregroundStyle(theme.ink3C)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(14)
        }
    }

    /// 서사 섹션 (v5 통합) — 뷰 자체가 비소설 안내를 갖고 있다.
    @ViewBuilder private var narrativeSection: some View {
        if let indexer {
            NarrativeView(indexer: indexer, store: store, theme: theme, embedded: true)
        } else {
            SidebarSectionHint(theme: theme, text: "이해 파이프라인이 준비되지 않았어요.")
        }
    }

    /// AI 컨텍스트 섹션 (v4) — 최근 예측이 실제로 참고한 정보의 열람.
    private var contextSection: some View {
        ContextInspectorView(completion: completion, store: store, theme: theme)
    }

    /// 문서(폴더 트리) 섹션 — 기존 사이드바 본문 그대로.
    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
            theme.sepC.frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 2) {
                    if isSearching {
                        searchResults
                    } else {
                        ForEach(items) { item in
                            switch item {
                            case .folder(let folder, let depth):
                                folderRow(folder, depth: depth)
                            case .entry(let entry, let depth):
                                row(entry, depth: depth)
                            }
                        }
                        // 목록 바로 아래 빈 띠 — 루트 맨 끝으로 드롭하는 받이.
                        Color.clear
                            .frame(height: 44)
                            .contentShape(Rectangle())
                            .overlay(alignment: .top) {
                                if dragModel.indicator == .root {
                                    SidebarInsertionLine(theme: theme, depth: 0)
                                        .offset(y: 2)
                                }
                            }
                            .onDrop(
                                of: [.plainText],
                                delegate: RootAreaDropDelegate(
                                    store: store, model: dragModel))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            // 짧은 목록에서 받이 띠 아래의 넓은 빈 영역도 루트 드롭을 받는다 —
            // 행 위 드롭은 더 깊은 히트 테스트가 이기므로 충돌하지 않는다.
            .onDrop(
                of: [.plainText],
                delegate: RootAreaDropDelegate(store: store, model: dragModel))
        }
    }

    // MARK: - 트리 평탄화

    private enum SidebarItem: Identifiable {
        case folder(JournalFolder, depth: Int)
        case entry(JournalEntry, depth: Int)

        var id: UUID {
            switch self {
            case .folder(let folder, _): folder.id
            case .entry(let entry, _): entry.id
            }
        }
    }

    /// 트리 캐시 키 (#48) — 본문 타이핑은 entries 배열을 바꾸지만 트리 모양
    /// (id·소속·순서·종류)은 그대로다. 배열 전체가 아니라 모양 서명만 비교해
    /// 평탄화(O(n log n) 정렬 포함)를 건너뛴다.
    struct TreeKey: Equatable {
        struct EntrySig: Equatable {
            var id: UUID
            var folderID: UUID?
            var sortOrder: Double?
            var kind: EntryKind?
        }
        struct FolderSig: Equatable {
            var id: UUID
            var parentID: UUID?
            var sortOrder: Double?
        }
        var entrySigs: [EntrySig]
        var folderSigs: [FolderSig]
        var expanded: Set<UUID>
    }

    @State private var treeCache: (key: TreeKey, items: [SidebarItem])?

    /// 현재 스토어 상태의 트리 모양 서명.
    private func treeKey() -> TreeKey {
        Self.treeKey(
            entries: store.entries, folders: store.folders,
            expanded: store.expandedFolderIDs)
    }

    /// 트리 모양 서명 빌더 — 본문·제목 같은 표시 필드는 의도적으로 제외했다:
    /// 키 입력의 주범(entries[i].body 변화)이 서명을 바꾸지 않아야 캐시가
    /// 적중한다 (#48). 정적이라 단위 테스트가 규약을 고정한다.
    static func treeKey(
        entries: [JournalEntry], folders: [JournalFolder], expanded: Set<UUID>
    ) -> TreeKey {
        TreeKey(
            entrySigs: entries.map {
                .init(id: $0.id, folderID: $0.folderID, sortOrder: $0.sortOrder, kind: $0.kind)
            },
            folderSigs: folders.map {
                .init(id: $0.id, parentID: $0.parentID, sortOrder: $0.sortOrder)
            },
            expanded: expanded)
    }

    /// 트리를 위에서 아래로 편 목록 — 각 단계에서 폴더 먼저, 그다음 저널.
    /// 모양이 바뀐 것으로 보일 때만 다시 평탄화한다 (#48).
    private var items: [SidebarItem] {
        let key = treeKey()
        if let cache = treeCache, cache.key == key { return cache.items }
        var result: [SidebarItem] = []
        appendChildren(of: nil, depth: 0, into: &result)
        treeCache = (key, result)
        return result
    }

    private func appendChildren(of parentID: UUID?, depth: Int, into result: inout [SidebarItem]) {
        for folder in store.childFolders(of: parentID) {
            result.append(.folder(folder, depth: depth))
            if store.isExpanded(folder.id) {
                appendChildren(of: folder.id, depth: depth + 1, into: &result)
            }
        }
        for entry in store.childEntries(of: parentID) {
            result.append(.entry(entry, depth: depth))
        }
    }

    // MARK: - 삭제

    /// 저널 삭제 요청 — 휴지통으로 가며 ⌘Z를 안내한다. 확인 Alert는 영구
    /// 삭제(휴지통 비우기)의 마지막 단계에만 쓴다 (이슈 #9).
    private func requestDelete(_ entry: JournalEntry) {
        store.delete(entry.id)
    }

    /// 폴더 삭제 요청 — 내용물째 휴지통으로.
    private func requestDeleteFolder(_ folder: JournalFolder) {
        store.deleteFolder(folder.id)
    }

    // MARK: - 헤더

    private var header: some View {
        // 로고 없이 액션만 — 앱 이름은 메뉴바가 이미 말한다. 왼쪽 빈 자리를
        // 남기지 않고 아이콘을 trailing으로 몰아 우측 툴바와 축을 맞춘다.
        HStack(spacing: 8) {
            Text("내 글")
                .purloryUIFont(12, .semibold)
                .foregroundStyle(theme.ink2C)
            Spacer(minLength: 18)
            Menu {
                Button {
                    store.newEntry()
                } label: {
                    Label("새 저널", systemImage: "doc.badge.plus")
                }
                Button {
                    store.newEntry(kind: .novel)
                } label: {
                    Label("새 소설", systemImage: "book.closed")
                }
                Divider()
                Button {
                    store.newFolder()
                } label: {
                    Label("새 폴더", systemImage: "folder.badge.plus")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.ink2C)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: PurloryRadius.sm, style: .continuous)
                            .fill(theme.chipC)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: PurloryRadius.sm, style: .continuous)
                            .strokeBorder(theme.chipBorderC)
                    )
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("새로 만들기")
            .accessibilityLabel("새로 만들기")
            HeaderIconButton(theme: theme, help: "휴지통") {
                showingTrash = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12.5, weight: .medium))
            }
            .accessibilityLabel(Text("휴지통"))
        }
        // Preserve the native traffic-light safe region. The shell already supplies material.
        .padding(.leading, windowChromeLeadingInset)
        .padding(.trailing, 12)
        .frame(minHeight: 52)
    }

    // MARK: - 전역 검색

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.ink3C)
            TextField("모든 저널 검색", text: $searchText)
                .textFieldStyle(.plain)
                .purloryUIFont(13)
                .foregroundStyle(theme.inkC)
                .focused($searchFieldFocused)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchFieldFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.ink3C)
                }
                .buttonStyle(.plain)
                .help("검색 지우기")
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: PurloryRadius.md, style: .continuous).fill(theme.chipC))
        .overlay(
            RoundedRectangle(cornerRadius: PurloryRadius.md, style: .continuous)
                .strokeBorder(theme.chipBorderC))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var searchResults: some View {
        let results = cachedSearchResults
        if results.isEmpty {
            Text("일치하는 저널이 없어요")
                .purloryUIFont(12)
                .foregroundStyle(theme.ink3C)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 11)
                .padding(.top, 6)
        } else {
            ForEach(results) { entry in
                searchRow(entry)
            }
        }
    }

    @ViewBuilder
    private func searchRow(_ entry: JournalEntry) -> some View {
        let active = entry.id == store.activeID
        Button {
            // 저널만 여는 게 아니라 본문 매치 위치로 스크롤·표시까지 (요구 2).
            store.requestSearchJump(entry.id, query: searchText)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    // 트리와 같은 종류 아이콘 규칙 — 검색 결과에서도 저널/소설이 갈리게.
                    if entry.resolvedKind == .novel {
                        Image(systemName: "book.closed.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(theme.novelC)
                    } else {
                        Image(systemName: "doc.text")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(active ? theme.blueC : theme.ink3C)
                    }
                    Text(entry.title)
                        .purloryUIFont(13, .semibold)
                        .foregroundStyle(active ? theme.inkC : theme.ink2C)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(store.dayLabel(for: entry))
                        .purloryUIFont(11)
                        .foregroundStyle(theme.ink3C)
                }
                if let snippet = Self.snippet(entry.body, query: searchText) {
                    Text(snippet)
                        .purloryUIFont(11.5)
                        .foregroundStyle(theme.ink3C)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 11)
            .background(
                RoundedRectangle(cornerRadius: PurloryRadius.md, style: .continuous)
                    .fill(active ? theme.activeBgC : .clear))
            .contentShape(RoundedRectangle(cornerRadius: PurloryRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// 본체는 SourceAnchor.searchSnippet으로 통합 (#61 PR1).
    private static func snippet(_ body: String, query: String) -> String? {
        SourceAnchor.searchSnippet(body, query: query)
    }

    // MARK: - 폴더 행

    @ViewBuilder
    private func folderRow(_ folder: JournalFolder, depth: Int) -> some View {
        let expanded = store.isExpanded(folder.id)
        let editing = editingID == folder.id
        let hovered = hoveredID == folder.id
        let dropTarget = dragModel.indicator == .into(folder.id)
        let naming = completion.namingFolderIDs.contains(folder.id)

        HStack(spacing: 7) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.ink3C)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .modifier(ReduceMotionAnimation(animation: .easeOut(duration: 0.15), value: expanded))
                .frame(width: 12)

            Image(systemName: "folder")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.ink2C)

            if editing {
                TextField("폴더 이름", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .purloryUIFont(13, .semibold)
                    .foregroundStyle(theme.inkC)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 7)
                    .background(RoundedRectangle(cornerRadius: PurloryRadius.sm).fill(theme.kbdC))
                    .overlay(
                        RoundedRectangle(cornerRadius: PurloryRadius.sm).strokeBorder(theme.blueC)
                    )
                    .focused($renameFieldFocused)
                    .onSubmit { commitRename(folder.id) }
                    .onExitCommand {
                        editingID = nil
                        renameFieldFocused = false
                    }
            } else {
                Text(folder.name)
                    .purloryUIFont(13, .semibold)
                    .foregroundStyle(theme.ink2C)
                    .lineLimit(1)
                // AI가 이름을 짓는 동안 — 임시 이름("새 폴더") 옆 진행 점.
                if naming {
                    PulsingDots(color: theme.ink3C)
                }
            }

            Spacer(minLength: 6)

            if !editing {
                // opacity 토글 — 조건부 삽입이면 hover 때 행 높이가 튄다.
                HStack(spacing: 2) {
                    RowIconButton(
                        systemName: "folder.badge.plus", help: "새 하위 폴더", theme: theme
                    ) { store.newFolder(in: folder.id) }
                    RowIconButton(systemName: "plus", help: "폴더에 새 저널", theme: theme) {
                        store.newEntry(in: folder.id)
                    }
                }
                .opacity(hovered ? 1 : 0)
                .allowsHitTesting(hovered)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 11)
        .padding(.leading, CGFloat(depth) * 14)
        .background(
            RoundedRectangle(cornerRadius: PurloryRadius.md, style: .continuous)
                .fill(dropTarget ? theme.activeBgC : (hovered ? theme.hoverC : .clear))
        )
        // 드롭 "안으로" 대상 표시 — 파란 링 (접힌 폴더에도 이동을 약속).
        .overlay {
            if dropTarget {
                RoundedRectangle(cornerRadius: PurloryRadius.md, style: .continuous)
                    .strokeBorder(theme.blueC, lineWidth: 1.5)
            }
        }
        // 형제 폴더 사이 삽입선.
        .overlay(alignment: .top) {
            if dragModel.indicator == .before(folder.id) {
                SidebarInsertionLine(theme: theme, depth: depth).offset(y: -2)
            }
        }
        .overlay(alignment: .bottom) {
            if dragModel.indicator == .after(folder.id) {
                SidebarInsertionLine(theme: theme, depth: depth).offset(y: 2)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: PurloryRadius.md, style: .continuous))
        .onHover { hoveredID = $0 ? folder.id : nil }
        // 저널 행과 같은 이유 — 첫 탭 즉시 펼침/접힘 (더블탭이 오면 두 번
        // 토글돼 원상복구된 채 이름변경으로 들어간다).
        .simultaneousGesture(TapGesture().onEnded { store.toggleExpanded(folder.id) })
        .simultaneousGesture(TapGesture(count: 2).onEnded { startRenameFolder(folder) })
        .onDrag {
            guard editingID == nil else { return NSItemProvider() }
            dragModel.beginDrag(.folder(id: folder.id))
            return NSItemProvider(object: folder.id.uuidString as NSString)
        }
        .onDrop(
            of: [.plainText],
            delegate: FolderRowDropDelegate(
                folder: folder, expanded: expanded, store: store, model: dragModel,
                requestNaming: { completion.requestFolderName(for: $0, in: store) }))
        .contextMenu {
            Button("새 저널") { store.newEntry(in: folder.id) }
            Button("새 소설") { store.newEntry(in: folder.id, kind: .novel) }
            Button("새 하위 폴더") { store.newFolder(in: folder.id) }
            Button("이름 바꾸기") { startRenameFolder(folder) }
            Button("삭제", role: .destructive) { requestDeleteFolder(folder) }
        }
        // 행이 사라지면(삭제·접힘·필터) AI 이름 생성을 접는다 — 안 보이는
        // 스피너를 위해 수 분 생성을 돌려두지 않는다 (이슈 #47).
        .onDisappear { completion.cancelFolderName(for: folder.id) }
        // 표준 트리 탐색 모델의 VO 축 (#23): 행 = 버튼, 펼침 상태 = 값,
        // 트리 작업 = 사용자 지정 액션 (Full Keyboard Access로도 활성 가능).
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("폴더 \(folder.name)"))
        .accessibilityValue(Text(expanded ? "펼침" : "접힘"))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("클릭으로 펼치거나 접어요"))
        .accessibilityAction(named: Text("펼치기/접기")) {
            store.toggleExpanded(folder.id)
        }
        .accessibilityAction(named: Text("새 저널")) {
            store.newEntry(in: folder.id)
        }
        .accessibilityAction(named: Text("이름 바꾸기")) {
            startRenameFolder(folder)
        }
        .accessibilityAction(named: Text("삭제")) {
            requestDeleteFolder(folder)
        }
    }

    // MARK: - 저널 행

    // 표시·장식·상호작용을 나눠 CI Swift 컴파일러의 타입 추론 부담을 제한한다.
    @ViewBuilder
    private func rowContent(_ entry: JournalEntry) -> some View {
        let active = entry.id == store.activeID
        let editing = editingID == entry.id

        HStack(spacing: 11) {
            // 종류별 아이콘 — 일반은 문서, 소설은 책. 소설은 비활성에서도 보라
            // 정체성을 유지해 목록만 훑어도 종류가 갈린다 (파랑 계열 = 저널).
            Group {
                if entry.resolvedKind == .novel {
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(
                            active ? theme.novelC : theme.novelC.opacity(0.6))
                } else {
                    Image(systemName: "doc.text")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(active ? theme.blueC : theme.ink3C)
                }
            }
            .frame(width: 11)

            if editing {
                TextField("제목", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .purloryUIFont(13, .semibold)
                    .foregroundStyle(theme.inkC)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 7)
                    .background(RoundedRectangle(cornerRadius: PurloryRadius.sm).fill(theme.kbdC))
                    .overlay(
                        RoundedRectangle(cornerRadius: PurloryRadius.sm).strokeBorder(theme.blueC)
                    )
                    .focused($renameFieldFocused)
                    .onSubmit { commitRename(entry.id) }
                    .onExitCommand {
                        editingID = nil
                        renameFieldFocused = false
                    }
            } else {
                // 소설 제목은 본문과 같은 세리프 — 목록에서도 "책" 느낌이 나게.
                Text(entry.title)
                    .purlorySerifFont(13, active ? .semibold : .medium, enabled: entry.resolvedKind == .novel)
                    .foregroundStyle(active ? theme.inkC : theme.ink2C)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if active && !editing {
                DeleteButton(theme: theme) { requestDelete(entry) }
            } else if !editing {
                Text(store.dayLabel(for: entry))
                    .purloryUIFont(11)
                    .foregroundStyle(theme.ink3C)
            }
        }
    }

    private func rowSurface(_ entry: JournalEntry, depth: Int) -> some View {
        let active = entry.id == store.activeID
        let hovered = hoveredID == entry.id
        let dropTarget = dragModel.indicator == .into(entry.id)

        return rowContent(entry)
        .padding(.vertical, 9)
        .padding(.horizontal, 11)
        .padding(.leading, CGFloat(depth) * 14)
        .background(
            RoundedRectangle(cornerRadius: PurloryRadius.md, style: .continuous)
                .fill(dropTarget
                    ? theme.activeBgC
                    : active
                        ? (entry.resolvedKind == .novel ? theme.novelBgC : theme.activeBgC)
                        : (hovered ? theme.hoverC : .clear))
        )
        // 드롭 "안으로"(= 두 저널을 새 폴더로 병합) 대상 표시 — 파란 링.
        .overlay {
            if dropTarget {
                RoundedRectangle(cornerRadius: PurloryRadius.md, style: .continuous)
                    .strokeBorder(theme.blueC, lineWidth: 1.5)
            }
        }
        // 형제 사이 삽입선 — 행 위/아래 2pt 간격에 걸쳐 그린다.
        .overlay(alignment: .top) {
            if dragModel.indicator == .before(entry.id) {
                SidebarInsertionLine(theme: theme, depth: depth).offset(y: -2)
            }
        }
        .overlay(alignment: .bottom) {
            if dragModel.indicator == .after(entry.id) {
                SidebarInsertionLine(theme: theme, depth: depth).offset(y: 2)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: PurloryRadius.md, style: .continuous))
    }

    private func row(_ entry: JournalEntry, depth: Int) -> some View {
        let active = entry.id == store.activeID

        return rowSurface(entry, depth: depth)
        .onHover { hoveredID = $0 ? entry.id : nil }
        // onTapGesture(count:2)+onTapGesture 조합은 단일 클릭이 더블클릭 판별
        // 타임아웃(수백 ms)을 기다린다 — 전환이 느려 보이는 주범. simultaneous로
        // 첫 탭에서 즉시 select하고, 두 번째 탭이 오면 그때 이름변경에 들어간다.
        .accessibilityAction { store.select(entry.id) }
        .focusable(editingID != entry.id)
        .onKeyPress(.return) { store.select(entry.id); return .handled }
        .simultaneousGesture(TapGesture().onEnded { store.select(entry.id) })
        .simultaneousGesture(TapGesture(count: 2).onEnded { startRename(entry) })
        .onDrag {
            // 이름 변경 중엔 드래그를 시작하지 않는다 — 빈 프로바이더를 돌려주면
            // 델리게이트들이 dragged==nil로 거부한다.
            guard editingID == nil else { return NSItemProvider() }
            dragModel.beginDrag(.entry(id: entry.id))
            return NSItemProvider(object: entry.id.uuidString as NSString)
        }
        .onDrop(
            of: [.plainText],
            delegate: EntryRowDropDelegate(
                entry: entry, store: store, model: dragModel,
                requestNaming: { completion.requestFolderName(for: $0, in: store) }))
        // VO 축 (#23): 문서 행 = 버튼(선택), 트리 작업 = 사용자 지정 액션.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("purlory.entry.\(entry.id.uuidString)")
        .accessibilityLabel(Text("\(entry.resolvedKind == .novel ? "소설" : "저널") \(entry.title)"))
        .accessibilityValue(Text(active ? "열려 있음 · \(store.dayLabel(for: entry))" : store.dayLabel(for: entry)))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("클릭으로 열어요"))
        .accessibilityAction(named: Text("이름 바꾸기")) { startRename(entry) }
        .accessibilityAction(named: Text("작성일 바꾸기")) { promptForDate(entry) }
        .accessibilityAction(named: Text("삭제")) { requestDelete(entry) }
        .contextMenu {
            Button("이름 바꾸기") { startRename(entry) }
            // 작성일 바꾸기 (L9) — 상단바 달력 버튼이 사라진 뒤의 유일한 진입점.
            // 저널마다 붙는 속성이라 앱 설정이 아니라 이 문맥 메뉴가 제자리다
            // (이름 바꾸기·종류 전환·내보내기와 같은 층).
            Button("작성일 바꾸기…") { promptForDate(entry) }
            moveMenu(for: entry)
            // 종류 전환 (M7 요청) — 원문 불변, 소설이 되면 이해 파이프라인이
            // 돌기 시작하고 저널이 되면 멈춘다 (지식은 파생이라 안전).
            if entry.resolvedKind == .novel {
                Button("일반 저널로 전환") { store.setKind(.journal, for: entry.id) }
            } else {
                Button("소설로 전환") { store.setKind(.novel, for: entry.id) }
            }
            // 소설만 — 전자책(EPUB)으로 내보내기 (요구 7).
            if entry.resolvedKind == .novel {
                Button("EPUB으로 내보내기…") { EpubExporter.exportWithPanel(entry) }
            }
            Button("삭제", role: .destructive) { requestDelete(entry) }
        }
    }

    /// 작성일 선택 — 문맥 메뉴에서 부르므로 SwiftUI 팝오버(앵커 없음) 대신
    /// NSAlert + NSDatePicker로 띄운다. 취소하면 아무것도 바꾸지 않는다.
    private func promptForDate(_ entry: JournalEntry) {
        let picker = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 300, height: 160))
        picker.datePickerStyle = .clockAndCalendar
        picker.datePickerElements = [.yearMonthDay]
        picker.dateValue = entry.createdAt

        let alert = NSAlert()
        alert.messageText = "작성일 바꾸기"
        alert.informativeText = "어제 일을 오늘 적었다면 날짜를 맞춰 두세요."
        alert.accessoryView = picker
        alert.addButton(withTitle: "바꾸기")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.setDate(entry.id, to: picker.dateValue)
    }

    /// 저널을 다른 폴더/루트로 옮기는 문맥 메뉴 — 이미 만든 글도 정리할 수 있게 (M3).
    @ViewBuilder
    private func moveMenu(for entry: JournalEntry) -> some View {
        Menu("이동") {
            Button("루트로 이동") { store.move(entry.id, toFolder: nil) }
                .disabled(entry.folderID == nil)
            if !store.folders.isEmpty {
                Divider()
                ForEach(store.folders) { folder in
                    Button(folder.name) { store.move(entry.id, toFolder: folder.id) }
                        .disabled(entry.folderID == folder.id)
                }
            }
        }
    }

    // MARK: - 이름 변경

    private func startRename(_ entry: JournalEntry) {
        store.select(entry.id)
        draftTitle = entry.title
        editingID = entry.id
        // 필드가 뷰 트리에 붙은 다음 틱에 포커스를 준다.
        Task { renameFieldFocused = true }
    }

    private func startRenameFolder(_ folder: JournalFolder) {
        draftTitle = folder.name
        editingID = folder.id
        Task { renameFieldFocused = true }
    }

    private func commitRename(_ id: UUID) {
        if store.folders.contains(where: { $0.id == id }) {
            store.renameFolder(id, to: draftTitle)
        } else {
            store.rename(id, to: draftTitle)
        }
        editingID = nil
    }
}

/// 헤더의 아이콘 버튼 — 본체는 Components/HoverIconButton (#61 PR3).
private struct HeaderIconButton<Label: View>: View {
    let theme: PurloryTheme
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        HoverIconButton(
            theme: theme, help: help,
            contentWidth: 30, contentHeight: 30, cornerRadius: PurloryRadius.md,
            action: action, label: label)
    }
}

/// 폴더 행 hover 시 나타나는 작은 추가 버튼 — HoverIconButton 위임 (#61 PR3).
private struct RowIconButton: View {
    let systemName: String
    let help: String
    let theme: PurloryTheme
    let action: () -> Void

    var body: some View {
        HoverIconButton(
            theme: theme, help: help,
            contentWidth: 20, contentHeight: 20, cornerRadius: PurloryRadius.sm,
            action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
        }
    }
}

/// Delete control uses the shared hover button with the destructive-state tint.
private struct DeleteButton: View {
    let theme: PurloryTheme
    let action: () -> Void

    var body: some View {
        HoverIconButton(
            theme: theme, help: "이 저널 삭제", tint: theme.dangerC,
            contentWidth: 20, contentHeight: 20, cornerRadius: PurloryRadius.sm,
            action: action) {
            Image(systemName: "xmark").font(.system(size: 12))
        }
    }
}


/// 휴지통 화면 — 삭제된 저널·폴더 묶음의 복원과 **영구 삭제** (이슈 #9).
/// 영구 삭제만 확인 Alert를 묻는다: 일반 삭제는 언제든 여기서 되살아난다.
struct TrashSheetView: View {
    @ObservedObject var store: EntryStore
    @ObservedObject var trash: TrashStore
    let theme: PurloryTheme
    @Environment(\.dismiss) private var dismiss
    @State private var purgeCandidate: TrashStore.Item?
    @State private var purgeAllRequested = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("휴지통")
                    .purloryUIFont(15, .semibold)
                Spacer()
                if !trash.items.isEmpty {
                    Button("비우기", role: .destructive) { purgeAllRequested = true }
                        .controlSize(.small)
                }
                Button("닫기") { dismiss() }
                    .controlSize(.small)
            }
            .padding(14)

            theme.sepC.frame(height: 1)

            if trash.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "trash")
                        .foregroundStyle(theme.ink3C)
                    Text("비어 있어요")
                        .purloryUIFont(12)
                        .foregroundStyle(theme.ink2C)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(trash.items) { item in
                    HStack {
                        Image(systemName: item.isFolderBundle ? "folder" : "doc.text")
                            .foregroundStyle(theme.ink2C)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .purloryUIFont(12.5)
                                .lineLimit(1)
                            Text(item.deletedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(PurloryFonts.monoUI(10))
                                .foregroundStyle(theme.ink3C)
                        }
                        Spacer()
                        Button("복원") { store.restoreFromTrash(itemID: item.id) }
                            .controlSize(.small)
                        Button(role: .destructive) { purgeCandidate = item } label: {
                            Text("영구 삭제")
                        }
                        .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 420, height: 380)
        .background(theme.glassWinC)
        .alert(
            "‘\(purgeCandidate?.title ?? "")’을(를) 영구 삭제할까요?",
            isPresented: Binding(
                get: { purgeCandidate != nil },
                set: { if !$0 { purgeCandidate = nil } }
            ),
            presenting: purgeCandidate
        ) { item in
            Button("영구 삭제", role: .destructive) { trash.purge(id: item.id) }
            Button("취소", role: .cancel) {}
        } message: { _ in
            Text("휴지통에서도 사라지며 되돌릴 수 없어요.")
        }
        .alert(
            "휴지통을 비울까요?",
            isPresented: $purgeAllRequested
        ) {
            Button("비우기", role: .destructive) { trash.purgeAll() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("\(trash.items.count)개 항목이 완전히 사라져요.")
        }
    }
}
