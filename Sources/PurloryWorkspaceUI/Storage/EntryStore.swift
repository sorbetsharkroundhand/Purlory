import Foundation
import SwiftUI

/// 사이드바 정렬 비교에 필요한 공통 필드 — JournalEntry·JournalFolder 공용.
protocol SortOrderable {
    var id: UUID { get }
    var createdAt: Date { get }
    var sortOrder: Double? { get }
}

extension JournalEntry: SortOrderable {}
extension JournalFolder: SortOrderable {}

/// 여러 저널을 로컬 JSON 하나에 보관하는 스토어 (에디터 v3).
///
/// - 저장 위치: `~/Documents/Purlory/entries.json`
/// - 본문 타이핑은 디바운스 autosave, 생성/삭제/이름변경 같은 구조 변경은 즉시 저장.
///   인코딩+쓰기는 전용 직렬 라이터 액터에서 — 대형 원고도 메인 스레드를 막지 않는다.
/// - 첫 실행 시 M1의 단일 문서(`journal.md`)가 있으면 첫 저널로 이관한다
///   (원본 파일은 안전을 위해 남겨둔다).
/// - 목록은 항상 1편 이상 유지한다 — 마지막 저널을 지우면 빈 저널을 새로 만든다.
@MainActor
public final class EntryStore: ObservableObject {
    @Published public private(set) var entries: [JournalEntry]
    @Published public private(set) var folders: [JournalFolder]
    @Published public private(set) var activeID: UUID
    /// 사이드바에서 펼쳐진 폴더들 — 함께 저장해 재실행 시 트리 모양을 유지한다.
    @Published public private(set) var expandedFolderIDs: Set<UUID>
    /// 에디터에 포커스를 달라는 요청 카운터 — 새 저널 생성 시 올려, 곧바로 타이핑할
    /// 수 있게 한다("＋ 누르고 다시 클릭해야 써지는" 마찰 제거). 이름 변경과 충돌하지
    /// 않도록 선택(select)에서는 올리지 않는다.
    @Published public private(set) var editorFocusRequests = 0

    /// 에디터 포커스를 명시적으로 요청한다.
    public func requestEditorFocus() {
        editorFocusRequests += 1
    }

    /// 사이드바 검색 필드에 포커스를 달라는 요청 카운터 (⌘⇧F).
    @Published public private(set) var searchFocusRequests = 0

    public func requestSearchFocus() {
        searchFocusRequests += 1
    }

    /// 전역 검색 결과 클릭 → 에디터가 해당 저널의 매치 위치로 스크롤·표시하라는
    /// 요청. seq가 바뀔 때만 한 번 소비된다 (같은 결과를 다시 눌러도 다시 이동).
    public struct SearchJump: Equatable, Sendable {
        public let entryID: UUID
        public let query: String
        public let seq: Int
    }

    @Published public private(set) var searchJump: SearchJump?

    /// 검색 결과 선택 — 저널을 열고 본문 매치 위치로 이동을 요청한다.
    /// 타임라인의 씬·사건·경고 클릭(M7)도 이 통로를 쓴다: 본문 스니펫을
    /// 질의로 넘기면 마크다운 오프셋 ↔ 에디터 스토리지 오프셋의 좌표 불일치를
    /// 구조적으로 피한다 (에디터는 자기 텍스트에서 스니펫을 찾아 이동).
    public func requestSearchJump(_ id: UUID, query: String) {
        select(id)
        searchJump = SearchJump(entryID: id, query: query, seq: (searchJump?.seq ?? 0) + 1)
    }

    /// 문서 종류 전환 (저널⇄소설) — 원문은 그대로, 메타만 바뀐다.
    /// 소설로 바꾸면 다음 유휴부터 이해 파이프라인이 돌기 시작한다.
    public func setKind(_ kind: EntryKind, for id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
            entries[index].resolvedKind != kind
        else { return }
        commitEntryChange(id, name: "종류 변경") { $0.kind = kind }
        scheduleSave()
        // 전환도 인덱서에겐 신호 — 소설이 됐으면 유휴 타이머를 감는다.
        documentDidChange?(id)
    }

    /// 제목·본문에서 질의어를 포함하는 저널 (대소문자 무시). 전역 검색용.
    public func search(_ query: String) -> [JournalEntry] {
        Self.filterMatches(entries, query: query)
    }

    /// 검색 필터 본체 — 비격리 순수 함수. 값 스냅샷만 받으므로 백그라운드에서
    /// 돌 수 있다 (#33): 사이드바는 메인에서 스냅샷을 떼어 이 함수로 넘긴다.
    nonisolated static func filterMatches(
        _ entries: [JournalEntry], query rawQuery: String
    ) -> [JournalEntry] {
        let q = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return entries.filter {
            $0.title.range(of: q, options: .caseInsensitive) != nil
                || $0.body.range(of: q, options: .caseInsensitive) != nil
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    /// 본문 autosave까지 기다리는 시간. 입력이 멈춘 뒤에만 쓴다.
    private let autosaveDelay: Duration
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?
    /// 마지막으로 예약된 저장의 세대 — 이전 세대 쓰기의 완료가 `isSaving`을
    /// 되살리지 못하게 (새 저장이 예약된 상태에서 "저장됨"으로 깜빡임 방지).
    private var saveGeneration = 0
    /// 원고 저장의 유일한 통로 (아래 `SnapshotWriter`).
    private let writer = SnapshotWriter()

    // MARK: - 복구 모드 (이슈 #6)

    /// 손상 복구 안내에 쓰는 컨텍스트 — UI가 원본·사본·세션 파일 위치를 보여준다.
    public struct RecoveryContext: Equatable, Sendable {
        public enum Cause: Equatable, Sendable {
            /// 파일을 읽었으나 JSON 디코딩 실패 — 부분쓰기·외부 훼손.
            case corrupted(reason: String)
            /// 권한·I/O 오류로 읽기 자체가 실패 — 원본은 제자리에 무사하다.
            case unreadable(message: String)
        }

        public let cause: Cause
        /// 라이브러리 원본(entries.json) — 복구 모드에서는 절대 덮지 않는다.
        public let originalURL: URL
        /// 손상 직후 남긴 타임스탬프 사본. 읽기 자체가 실패하면 nil.
        public let preservedCopyURL: URL?
        /// 이번 세션 편집이 기록되는 우회 파일 (`entries-recovered-<시각>.json`).
        public let sessionURL: URL

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.originalURL == rhs.originalURL
                && lhs.preservedCopyURL == rhs.preservedCopyURL
                && lhs.sessionURL == rhs.sessionURL
                && "\(lhs.cause)" == "\(rhs.cause)"
        }
    }

    /// nil이 아니면 복구 모드 — 저장은 세션 복구 파일로 우회되고 손상 원본은
    /// 건드리지 않는다. 사용자 결정(승계·내보내기·새 시작)은 ContentView 안내
    /// 대화가 받는다.
    @Published public private(set) var pendingRecovery: RecoveryContext?

    /// 복구 모드에서 이번 세션 편집이 기록되는 파일. nil이면 정상 모드.
    private var recoveredSessionURL: URL?

    /// 실제 쓰기 대상 — 정상이면 라이브러리 파일, 복구 모드면 세션 복구 파일.
    /// 모든 저장 경로(autosave·saveNow·flush)는 이 값을 써야 손상 원본을
    /// 덮는 사고가 구조적으로 불가능해진다.
    private var writeTargetURL: URL { recoveredSessionURL ?? fileURL }

    /// Compatibility lookup only. The explicit legacy controller owns lifecycle flushing;
    /// project shutdown must never resolve its write owner through this weak reference.
    public static weak var current: EntryStore?

    // MARK: - 구조 변경 Undo + 휴지통 (이슈 #9)

    /// 구조 변경(삭제·이동·재정렬·종류 전환·바이블 메타)이 등록될 창의
    /// undo manager. ContentView가 창과 함께 배선한다 — 텍스트 편집 undo와
    /// 같은 ⌘Z 흐름을 타게 하기 위해서다.
    public weak var structureUndoManager: UndoManager?

    /// `UndoManager.registerUndo` uses a `@Sendable` handler in the current SDK while
    /// `UndoManager` itself is AppKit main-thread state and not Sendable.  Capture this
    /// weak, explicitly-audited box instead of the manager directly so undo stays
    /// synchronous on MainActor without generating Swift concurrency warnings.
    private final class WeakUndoManagerBox: @unchecked Sendable {
        weak var value: UndoManager?
        init(_ value: UndoManager) { self.value = value }
    }

    /// 앱 휴지통 — ⌘Z 유예가 지난 실수의 내구 복제본. 삭제는 즉시 여기로
    /// 가고, 영구 삭제(비우기)만 확인 Alert를 묻는다.
    public private(set) var trash: TrashStore

    /// 사용자 피드백 한 줄 — 상태 바에 잠깐 떴다 사라진다 ("⌘Z로 되돌릴 수
    /// 있어요" 안내). nil이면 표시 중 아님.
    @Published public private(set) var notice: String?

    private var noticeClearTask: Task<Void, Never>?

    /// 구조 변경 하나를 원자적으로 적용하고 이름 있는 undo/redo를 등록한다.
    ///
    /// 스냅샷은 값 타입(JournalEntry·JournalFolder)이라 before/after 배열만으로
    /// 완전 복원이 성립한다 — 원인별 복원 코드를 만들지 않는다 (#9).
    private func commitStructure(
        _ name: String,
        before: @escaping () -> Void,
        after: @escaping () -> Void
    ) {
        guard let um = structureUndoManager else {
            after()
            return
        }
        after()
        registerRevert(
            StructureChange(name: name, forward: after, backward: before), in: um)
    }

    @MainActor
    private struct StructureChange {
        let name: String
        let forward: () -> Void
        let backward: () -> Void
    }

    /// undo 시 역동작을 실행하고 그 결과(=redo)를 다시 등록한다 — 표준 코코아
    /// 상호 등록 패턴. 연속 ⌘Z/⇧⌘Z가 끊기지 않는다.
    private func registerRevert(_ change: StructureChange, in um: UndoManager) {
        um.setActionName(change.name)
        let manager = WeakUndoManagerBox(um)
        um.registerUndo(withTarget: self) { store in
            // Cocoa invokes this synchronously from the window's undo flow.  Do not hop
            // through Task: redo must be registered in the same undo group.
            MainActor.assumeIsolated {
                guard let um = manager.value else { return }
                store.structureUndoManager = um
                change.backward()
                store.registerRevert(
                    StructureChange(
                        name: change.name,
                        forward: change.backward,
                        backward: change.forward),
                    in: um)
            }
        }
    }

    /// 저널 목록에서 해당 id 항목을 스냅샷으로 되돌린다. 없으면 원래 위치 근처에
    /// 다시 심는다 — sortOrder가 순서의 단일 진실이라 값 복원이 곧 위치 복원이다.
    private func restoreEntries(_ snapshots: [JournalEntry]) {
        for snapshot in snapshots {
            if let index = entries.firstIndex(where: { $0.id == snapshot.id }) {
                entries[index] = snapshot
            } else {
                // 순서의 단일 진실은 sortOrder라 **배열 위치는 무의미**하다.
                // (새 항목은 sortOrder를 음수로 내려가며 넣기도 한다 — insert
                // 위치 계산은 함정.) 없으면 끝에 붙인다.
                entries.append(snapshot)
            }
        }
    }

    private func restoreFolders(_ snapshots: [JournalFolder]) {
        for snapshot in snapshots {
            if let index = folders.firstIndex(where: { $0.id == snapshot.id }) {
                folders[index] = snapshot
            } else {
                folders.append(snapshot)
            }
        }
    }

    /// 구조 변경 후 안내 문구. 기존 타이머를 취소하고 4초 뒤에 지운다.
    func showNotice(_ text: String) {
        notice = text
        noticeClearTask?.cancel()
        noticeClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// 저장 정책 — 연속 편집(타이핑)은 디바운스, 이산 구조 변경만 즉시 (#49/H1).
    enum SavePolicy { case immediate, debounced }

    /// 디바운스 버스트별 undo 코얼레싱 상태 — 버스트 시작 시점의 before 스냅샷을
    /// 저장해, 여러 글자 입력이 **하나의 undo 단위**로 되돌아가게 한다 (#65 H1).
    private struct DebouncedBurst {
        let name: String
        let before: JournalEntry
    }
    private var debouncedBursts: [UUID: DebouncedBurst] = [:]

    /// 단일 저널의 필드 변경을 스냅샷 undo로 감싼다 — 바이블 메타(인물·핵심
    /// 장면·무시한 후보·대화 기록)와 종류 전환이 공유한다 (#9).
    private func commitEntryChange(
        _ id: UUID, name: String,
        policy: SavePolicy = .immediate,
        mutate: (inout JournalEntry) -> Void
    ) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let before = entries[index]
        var after = before
        mutate(&after)
        guard after != before else { return }
        entries[index] = after

        switch policy {
        case .immediate:
            flushDebouncedUndo(for: id)  // 직전 버스트 먼저 확정해 순서 보존
            commitStructure(name, before: { [weak self] in
                guard let self else { return }
                self.restoreEntries([before])
                self.saveNow()
            }, after: { [weak self] in
                guard let self else { return }
                self.restoreEntries([after])
                self.saveNow()
            })
        case .debounced:
            // 같은 저널 연속 편집은 최초 before만 유지 — 여러 글자가 한 undo 단위.
            if debouncedBursts[id] == nil {
                debouncedBursts[id] = DebouncedBurst(name: name, before: before)
            }
            scheduleSave()
        }
    }

    /// 모든 대기 버스트 undo 확정 — 디바운스 저장·flush 직전에 호출 (#49/H1).
    private func flushAllDebouncedUndo() {
        for id in Array(debouncedBursts.keys) {
            flushDebouncedUndo(for: id)
        }
    }

    /// 버스트 undo 등록 — before(버스트 시작)↔현재(after) 쌍 하나.
    private func flushDebouncedUndo(for id: UUID) {
        guard let burst = debouncedBursts.removeValue(forKey: id),
              let um = structureUndoManager,
              let currentIndex = entries.firstIndex(where: { $0.id == id })
        else { return }
        let before = burst.before
        let after = entries[currentIndex]
        um.setActionName(burst.name)
        let manager = WeakUndoManagerBox(um)
        um.registerUndo(withTarget: self) { store in
            // Burst restore/save/redo registration must complete before undo returns.
            MainActor.assumeIsolated {
                guard let um = manager.value else { return }
                store.structureUndoManager = um
                store.restoreEntries([before]); store.saveNow()
                um.registerUndo(withTarget: store) { s2 in
                    MainActor.assumeIsolated {
                        guard let um = manager.value else { return }
                        s2.structureUndoManager = um
                        s2.restoreEntries([after]); s2.saveNow()
                    }
                }
            }
        }
    }

    /// 휴지통 항목을 문서 구조로 되살린다 — 폴더 묶음이면 폴더와 저널 전체.
    public func restoreFromTrash(itemID: UUID) {
        guard let item = trash.peek(id: itemID) else { return }
        let previousEntries = entries
        let previousFolders = folders
        let previousActiveID = activeID
        let previousExpanded = expandedFolderIDs
        restoreFolders(item.folders)
        restoreEntries(item.entries)
        fixActiveAfterStructureChange(prefer: nil)
        saveNow()
        if case .failed = savePhase {
            entries = previousEntries
            folders = previousFolders
            activeID = previousActiveID
            expandedFolderIDs = previousExpanded
            showNotice("복원 내용을 저장하지 못해 휴지통에 그대로 두었어요")
            return
        }
        guard trash.take(id: itemID) != nil else {
            showNotice("휴지통에서 ‘\(item.title)’을(를) 복원했어요")
            return
        }
        showNotice("휴지통에서 ‘\(item.title)’을(를) 복원했어요")
    }

    /// 본문 편집·문서 전환 알림 (M6) — BackgroundIndexer가 배선한다.
    /// 지식 로직은 여기 두지 않는다 (CLAUDE.md §4) — 신호만 내보낸다.
    public var documentDidChange: ((UUID) -> Void)?

    /// 스냅샷 — 저장 파일 한 벌. 값 타입뿐이라 라이터 액터로 건너갈 수 있다 (Sendable).
    private struct Snapshot: Codable, Sendable {
        var entries: [JournalEntry]
        var activeID: UUID?
        // 파일시스템 v1 이전 파일엔 없는 키 — 옵셔널로 하위 호환.
        var folders: [JournalFolder]? = nil
        var expandedFolderIDs: [UUID]? = nil
    }

    public convenience init(
        autosaveDelay: Duration = .milliseconds(800),
        storageLocation: PurloryStorageLocation = .standard
    ) {
        self.init(directory: Self.storageDirectory(at: storageLocation), autosaveDelay: autosaveDelay)
    }

    /// 저장 위치를 지정하는 내부 초기자 — 테스트가 임시 디렉터리로 격리하기 위함.
    init(directory: URL, autosaveDelay: Duration) {
        self.autosaveDelay = autosaveDelay
        self.fileURL = directory.appendingPathComponent("entries.json", isDirectory: false)
        self.trash = TrashStore(directory: directory)

        let loaded: Snapshot
        var recovery: RecoveryContext?
        var sessionTarget: URL?
        // 클로저가 초기화 도중의 self를 잡지 않게 원본 위치를 지역 상수로.
        let original = fileURL
        switch Self.loadSnapshot(from: fileURL) {
        case .loaded(let snapshot):
            loaded = snapshot
        case .missing:
            loaded = Self.migratedOrEmptySnapshot(in: directory)
        case .corrupted(let reason, let preservedCopy):
            // 원본은 .corrupt-* 사본으로 보존됐다 — M1 이관(journal.md)은 정상 첫
            // 실행 전용이라 여기선 하지 않는다.
            (loaded, sessionTarget) = Self.recoverySetup(
                in: directory, originalURL: original,
                cause: .corrupted(reason: reason), preservedCopyURL: preservedCopy)
            recovery = sessionTarget.map {
                RecoveryContext(
                    cause: .corrupted(reason: reason), originalURL: original,
                    preservedCopyURL: preservedCopy, sessionURL: $0)
            }
        case .unreadable(let message):
            // 읽기 자체가 실패한 경우엔 사본도 못 만든다 — 원본 파일 자체가 무사히
            // 제자리에 남고, 여기선 그 사실만 컨텍스트로 넘긴다.
            (loaded, sessionTarget) = Self.recoverySetup(
                in: directory, originalURL: original,
                cause: .unreadable(message: message), preservedCopyURL: nil)
            recovery = sessionTarget.map {
                RecoveryContext(
                    cause: .unreadable(message: message), originalURL: original,
                    preservedCopyURL: nil, sessionURL: $0)
            }
        }
        self.pendingRecovery = recovery
        self.recoveredSessionURL = sessionTarget
        var entries = loaded.entries
        if entries.isEmpty { entries = [JournalEntry()] }
        // 마이그레이션: 예전 파생 버그로 제목에 인라인 마크업(<font …>)이 얼어붙은
        // 항목 정리. 파생 제목은 본문에서 다시 만들고, 직접 지은 이름은 글자를
        // 보존한 채 태그만 벗긴다 (제목에 태그가 남는 건 어느 쪽이든 의도가 아니다).
        for index in entries.indices where entries[index].title.contains("<") {
            if entries[index].titleIsCustom == true {
                let cleaned = Self.strippedInlineTags(entries[index].title)
                    .trimmingCharacters(in: .whitespaces)
                entries[index].title = cleaned.isEmpty ? "제목 없음" : cleaned
            } else {
                let derived = Self.derivedTitle(from: entries[index].body)
                entries[index].title = derived.isEmpty ? "새 저널" : derived
                entries[index].titleIsCustom = false
            }
        }
        var folders = loaded.folders ?? []
        // 마이그레이션: sortOrder 없는 항목(DnD 재정렬 도입 이전 파일)은 기존 표시
        // 순서 그대로 시드한다 — 엔트리는 폴더별 작성일 내림차순(M5), 폴더는 배열
        // 순서. 메모리만 바꾸고 저장은 첫 구조 변경 때 이뤄진다.
        if entries.contains(where: { $0.sortOrder == nil })
            || folders.contains(where: { $0.sortOrder == nil }) {
            Self.seedSortOrders(entries: &entries, folders: &folders)
        }
        self.entries = entries
        self.folders = folders
        self.expandedFolderIDs = Set(loaded.expandedFolderIDs ?? [])
            .intersection(folders.map(\.id))
        self.activeID = loaded.activeID.flatMap { id in
            entries.contains(where: { $0.id == id }) ? id : nil
        } ?? entries[0].id
        Self.current = self
        // 고아 asset 청소 — 장부에 유예 중인 후보가 있을 때만 실제로 돈다.
        // 시작 직후 한 번, 메인 액터 상속 Task라 편집 경로와 겹치지 않는다 (이슈 #17).
        // 활성 엔트리뿐 아니라 휴지통·백업·복구 파일의 본문도 함께 보호한다 (F07).
        let storageLocation = PurloryStorageLocation(rootDirectory: directory)
        if !AssetJanitor.hasPendingCandidates(storageLocation: storageLocation) {
            // 장부가 비었으면 파일 접근조차 하지 않는다.
        } else if let protectedBodies = Self.collectSweepProtectedBodies(
            in: directory, activeEntries: entries, trash: trash
        ) {
            Task(priority: .utility) { [protectedBodies, storageLocation] in
                _ = AssetJanitor.sweepAll(bodies: protectedBodies, storageLocation: storageLocation)
            }
        }
    }

    /// 활성 저널·휴지통·일일 백업·복구/손상 사본이 참조하는 모든 본문을 수집한다.
    /// 백업이나 휴지통 파일이 존재하지만 읽거나 해석할 수 없으면 nil을 반환해
    /// 청소를 건너뛴다(fail-safe).
    private static func collectSweepProtectedBodies(
        in directory: URL,
        activeEntries: [JournalEntry],
        trash: TrashStore
    ) -> [String]? {
        guard !trash.hasUnreadableOrCorruptState else { return nil }
        var bodies = activeEntries.map(\.body)
        bodies.append(contentsOf: trash.items.flatMap(\.entries).map(\.body))

        let fm = FileManager.default
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let rootFiles = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for fileURL in rootFiles {
            let name = fileURL.lastPathComponent
            if name.hasPrefix("entries-recovered-") && name.hasSuffix(".json") {
                guard let data = try? Data(contentsOf: fileURL),
                      let snapshot = try? decoder.decode(Snapshot.self, from: data)
                else { return nil }
                bodies.append(contentsOf: snapshot.entries.map(\.body))
            } else if name.contains(".corrupt-") && name.hasSuffix(".json") {
                if let data = try? Data(contentsOf: fileURL) {
                    if let snapshot = try? decoder.decode(Snapshot.self, from: data) {
                        bodies.append(contentsOf: snapshot.entries.map(\.body))
                    } else if let rawText = String(data: data, encoding: .utf8) {
                        bodies.append(rawText)
                    } else {
                        return nil
                    }
                } else {
                    return nil
                }
            }
        }

        let backupsDir = directory.appendingPathComponent("backups", isDirectory: true)
        if fm.fileExists(atPath: backupsDir.path) {
            guard let backupFiles = try? fm.contentsOfDirectory(at: backupsDir, includingPropertiesForKeys: nil) else {
                return nil
            }
            for backupURL in backupFiles where backupURL.pathExtension == "json" {
                guard let data = try? Data(contentsOf: backupURL),
                      let snapshot = try? decoder.decode(Snapshot.self, from: data)
                else { return nil }
                bodies.append(contentsOf: snapshot.entries.map(\.body))
            }
        }

        return bodies
    }

    /// `~/Documents/Purlory/` 경로. 디렉터리가 없으면 만든다.
    private static func storageDirectory(at location: PurloryStorageLocation) -> URL {
        let dir = location.rootDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 스냅샷 로드 결과 — "파일 없음"(정상 첫 실행)과 "손상"(보존 대상)을 구분한다.
    /// 둘을 하나로 뭉개면 디스크 장애·스키마 붕괴 시 빈 원고로 시작한 뒤 첫 autosave가
    /// 유일한 원본을 통째로 덮어쓴다 — 원문 전멸(AGENTS.md §1 "원문이 안전") 위반이다.
    private enum SnapshotLoad {
        case loaded(Snapshot)
        case missing
        /// 파일을 읽었으나 디코딩에 실패 — 부분쓰기·외부 훼손. 사본 위치를 함께 돌려준다.
        case corrupted(reason: String, preservedCopy: URL?)
        /// 권한·I/O 오류로 읽기 자체가 실패 — 원본 파일은 제자리에 무사하다.
        case unreadable(message: String)
    }

    private static func loadSnapshot(from url: URL) -> SnapshotLoad {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // 읽기 실패엔 복구할 바이트도 없다 — 사본 만들기는 의미가 없고,
            // 원본 파일 자체가 그대로 남는 것이 곧 보존이다 (이슈 #6).
            return .unreadable(message: error.localizedDescription)
        }
        return decodeSnapshot(from: data, originalURL: url)
    }

    private static func decodeSnapshot(from data: Data, originalURL url: URL) -> SnapshotLoad {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return .loaded(try decoder.decode(Snapshot.self, from: data))
        } catch {
            let preserved = preserveCorruptedFile(at: url)
            return .corrupted(reason: error.localizedDescription, preservedCopy: preserved)
        }
    }

    /// 손상된 원고 파일을 타임스탬프 사본으로 보존한다 — 스토어는 빈 상태로 다시
    /// 시작하지만 원본은 항상 디스크에 남아 수동 복구가 가능하게 (조용한 전멸 금지).
    /// 성공하면 사본 위치를 돌려준다 (복구 안내 UI가 쓴다).
    static func preserveCorruptedFile(at url: URL) -> URL? {
        let stamp = Self.corruptStampFormatter.string(from: .now)
        let backup = url.deletingPathExtension()
            .appendingPathExtension("corrupt-\(stamp).json")
        guard (try? FileManager.default.copyItem(at: url, to: backup)) != nil else {
            return nil
        }
        return backup
    }

    /// 과거 세션의 복구 파일(`entries-recovered-*.json`) 중 최신 것 — 수정일 내림차순.
    private static func newestRecoveredFile(in directory: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]))
            ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("entries-recovered-") }
            .sorted { lhs, rhs -> Bool in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return l > r
            }
            .first
    }

    /// 손상 감지 후의 시작 상태를 정한다 (이슈 #6).
    ///
    /// 1. 과거 세션 복구 파일이 디코딩되면 **라이브러리로 승계**해 마지막 작업을
    ///    그대로 이어준다 — 사용자 개입 없이 되돌아오는 게 최선의 복구다. 이때는
    ///    정상 모드로 돌아간다 (손상 원본은 이미 .corrupt-* 사본이 남아 있다).
    /// 2. 아니면 빈 저널로 시작하되, 이번 세션 저장은 `entries-recovered-<시각>.json`
    ///    으로 우회해 손상 원본을 절대 덮지 않게 한다. 세션 URL을 돌려주면 호출부가
    ///    복구 모드(pendingRecovery)로 진입한다.
    private static func recoverySetup(
        in directory: URL,
        originalURL: URL,
        cause: RecoveryContext.Cause,
        preservedCopyURL: URL?
    ) -> (snapshot: Snapshot, sessionTarget: URL?) {
        if let previous = newestRecoveredFile(in: directory),
           case .loaded(let snapshot) = decodeSnapshotFromDisk(previous) {
            // 손상 원본을 복구 파일로 원자적 승계 — 스테이징 복사·검증·교체가 모두
            // 성공한 뒤에만 이전 복구 파일을 지운다 (F05).
            if promoteRecoveredFile(from: previous, to: originalURL) {
                return (snapshot, nil)
            }
            // 승계 교체가 실패하면 이전 복구 파일과 스냅샷을 그대로 유지한 채 복구 모드로 진입한다.
            return (snapshot, previous)
        }

        let stamp = corruptStampFormatter.string(from: .now)
        let session = directory.appendingPathComponent(
            "entries-recovered-\(stamp).json", isDirectory: false)
        return (Snapshot(entries: [], activeID: nil), session)
    }

    /// 복구 세션 파일을 원본 라이브러리 위치로 안전하게 승계한다.
    /// 임시 파일 복사 및 디코딩 검증 후 원본을 교체하며, 교체가 검증되기 전에는
    /// 원본이나 복구 파일을 삭제하지 않는다.
    static func promoteRecoveredFile(from sourceURL: URL, to destinationURL: URL) -> Bool {
        let fm = FileManager.default
        guard case .loaded = decodeSnapshotFromDisk(sourceURL) else { return false }
        let dir = destinationURL.deletingLastPathComponent()
        let stagingURL = dir.appendingPathComponent(
            ".entries-promote-\(UUID().uuidString).tmp", isDirectory: false)
        defer { try? fm.removeItem(at: stagingURL) }

        do {
            try fm.copyItem(at: sourceURL, to: stagingURL)
            guard case .loaded = decodeSnapshotFromDisk(stagingURL) else { return false }
            if fm.fileExists(atPath: destinationURL.path) {
                _ = try fm.replaceItemAt(destinationURL, withItemAt: stagingURL)
            } else {
                try fm.moveItem(at: stagingURL, to: destinationURL)
            }
            guard case .loaded = decodeSnapshotFromDisk(destinationURL) else { return false }
            if sourceURL.standardizedFileURL != destinationURL.standardizedFileURL {
                try? fm.removeItem(at: sourceURL)
            }
            return true
        } catch {
            return false
        }
    }

    private static func decodeSnapshotFromDisk(_ url: URL) -> SnapshotLoad {
        guard let data = try? Data(contentsOf: url) else { return .unreadable(message: "읽기 실패") }
        return decodeSnapshot(from: data, originalURL: url)
    }

    /// M1 단일 문서(journal.md) 이관 — 없으면 빈 저널 하나로 시작.
    private static func migratedOrEmptySnapshot(in dir: URL) -> Snapshot {
        let legacy = dir.appendingPathComponent("journal.md", isDirectory: false)
        guard let body = try? String(contentsOf: legacy, encoding: .utf8),
            !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return Snapshot(entries: [JournalEntry()], activeID: nil)
        }
        let modified =
            (try? FileManager.default.attributesOfItem(atPath: legacy.path)[.modificationDate])
            as? Date ?? .now
        let entry = JournalEntry(
            title: Self.derivedTitle(from: body), createdAt: modified, body: body)
        return Snapshot(entries: [entry], activeID: entry.id)
    }

    /// sortOrder가 없는 파일을 위한 시드 — 사용자가 보던 순서를 그대로 굳힌다.
    /// 엔트리는 폴더별 작성일 내림차순(도입 전 표시 순서), 폴더는 배열 순서.
    /// nil이 섞인 형제 그룹만 다시 시드한다 — 이미 손으로 정렬한 폴더는 건드리지 않는다.
    private static func seedSortOrders(
        entries: inout [JournalEntry], folders: inout [JournalFolder]
    ) {
        let entryGroups = Dictionary(grouping: entries.indices) { entries[$0].folderID }
        for indices in entryGroups.values
        where indices.contains(where: { entries[$0].sortOrder == nil }) {
            let ordered = indices.sorted { entries[$0].createdAt > entries[$1].createdAt }
            for (position, index) in ordered.enumerated() {
                entries[index].sortOrder = Double(position)
            }
        }
        let folderGroups = Dictionary(grouping: folders.indices) { folders[$0].parentID }
        for indices in folderGroups.values
        where indices.contains(where: { folders[$0].sortOrder == nil }) {
            for (position, index) in indices.sorted().enumerated() {
                folders[index].sortOrder = Double(position)
            }
        }
    }

    /// 첫 비어 있지 않은 줄에서 마크다운 마커·인라인 마크업을 벗겨 제목으로 쓴다.
    /// 본문이 길어도 앞부분만 훑는다 — 매 키 입력마다 호출되므로 비용을 묶어 둔다.
    /// 파생할 내용이 없으면 빈 문자열(호출부에서 기본 제목으로 대체).
    /// 인라인 래퍼 태그(<font …>·</font>·<p align="…">·</p>)만 벗긴다 —
    /// 안의 글자는 남는다. 제목 파생·마이그레이션 공용.
    nonisolated static func strippedInlineTags(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"</?(?:font|p)\b[^>]*>"#,
            with: "", options: .regularExpression)
    }

    static func derivedTitle(from body: String) -> String {
        for line in body.prefix(500).split(separator: "\n") {
            var stripped = strippedInlineTags(
                String(line)
                    // 블록 마커 (#·>·목록·번호) 제거.
                    .replacingOccurrences(
                        of: #"^(#{1,3}\s+|>\s?|- \[[ x]\]\s?|[-*]\s+|\d+\.\s+)"#,
                        with: "", options: .regularExpression))
                // 인라인 마커(*** ** * `)도 글자만 남긴다.
                .replacingOccurrences(
                    of: #"[*`]+"#,
                    with: "", options: .regularExpression)
            stripped = stripped.trimmingCharacters(in: .whitespaces)
            guard !stripped.isEmpty else { continue }
            // 산문이 아닌 줄(수식·이미지·코드 펜스·구분선)은 제목이 될 수 없다.
            if stripped.hasPrefix("$$") || stripped.hasPrefix("![") { continue }
            if stripped.range(of: #"^-{3,}$"#, options: .regularExpression) != nil {
                continue
            }
            return String(stripped.prefix(30))
        }
        return ""
    }

    // MARK: - 조회

    public var activeEntry: JournalEntry? {
        entries.first(where: { $0.id == activeID })
    }

    /// 한 폴더의 하위 폴더들 (nil = 루트). 사용자 정렬(sortOrder) 순.
    public func childFolders(of parentID: UUID?) -> [JournalFolder] {
        folders.filter { $0.parentID == parentID }
            .sorted(by: Self.bySortOrder)
    }

    /// 한 폴더에 담긴 저널들 (nil = 루트). 사용자 정렬(sortOrder) 순 — DnD 재정렬
    /// 도입으로 작성일 내림차순(M5)은 초기 시드로만 남는다. 이에 따라 setDate(L9)는
    /// 더 이상 목록 위치를 바꾸지 않는다 (검색 결과는 여전히 작성일 순).
    public func childEntries(of folderID: UUID?) -> [JournalEntry] {
        entries.filter { $0.folderID == folderID }
            .sorted(by: Self.bySortOrder)
    }

    /// sortOrder 오름차순, nil은 뒤로. 동률은 작성일 내림차순 → id로 안정화.
    private static func bySortOrder(
        _ a: some SortOrderable, _ b: some SortOrderable
    ) -> Bool {
        switch (a.sortOrder, b.sortOrder) {
        case let (x?, y?) where x != y: return x < y
        case (.some, .none): return true
        case (.none, .some): return false
        default:
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            return a.id.uuidString < b.id.uuidString
        }
    }

    public func isExpanded(_ folderID: UUID) -> Bool {
        expandedFolderIDs.contains(folderID)
    }

    /// 폴더 안에 저널이나 하위 폴더가 하나라도 있는지 — 삭제 확인 알림용.
    public func folderHasContents(_ folderID: UUID) -> Bool {
        entries.contains(where: { $0.folderID == folderID })
            || folders.contains(where: { $0.parentID == folderID })
    }

    /// id와 그 아래 모든 하위 폴더 id — 재귀 삭제 범위.
    private func descendantFolderIDs(of folderID: UUID) -> Set<UUID> {
        var result: Set<UUID> = [folderID]
        var queue = [folderID]
        while let current = queue.popLast() {
            for child in folders where child.parentID == current {
                if result.insert(child.id).inserted { queue.append(child.id) }
            }
        }
        return result
    }

    /// 툴바 제목 — "7월 3일 금요일".
    public var activeDateLabel: String {
        guard let entry = activeEntry else { return "" }
        return Self.fullDateFormatter.string(from: entry.createdAt)
    }

    /// 사이드바 보조 라벨 — 오늘/어제/요일 한 글자/짧은 날짜.
    public func dayLabel(for entry: JournalEntry) -> String {
        let calendar = Self.koCalendar
        if calendar.isDateInToday(entry.createdAt) { return "오늘" }
        if calendar.isDateInYesterday(entry.createdAt) { return "어제" }
        let days =
            calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: entry.createdAt),
                to: calendar.startOfDay(for: .now)
            ).day ?? .max
        if days < 7 { return Self.weekdayFormatter.string(from: entry.createdAt) }
        return Self.shortDateFormatter.string(from: entry.createdAt)
    }

    // MARK: - 변경

    public func select(_ id: UUID) {
        guard id != activeID, entries.contains(where: { $0.id == id }) else { return }
        activeID = id
        // 전환은 잦고 activeID만 바뀐다 — 동기 디스크 쓰기 대신 디바운스 저장.
        scheduleSave()
        // 문서 전환도 인덱서에겐 "활동" — 새 문서의 유휴 타이머를 감는다 (M6).
        documentDidChange?(id)
    }

    @discardableResult
    public func newEntry(in folderID: UUID? = nil, kind: EntryKind = .journal) -> UUID {
        // titleIsCustom=false — 이름을 직접 바꾸기 전까지 본문에서 계속 파생한다.
        // (nil이면 첫 파생 직후 제목이 플레이스홀더가 아니게 돼 한 글자에서 얼어붙는다.)
        let entry = JournalEntry(
            title: kind == .novel ? "새 소설" : "새 저널", folderID: folderID,
            titleIsCustom: false, kind: kind,
            // 새 저널은 목록 맨 위 — 첫 형제보다 작은 sortOrder.
            sortOrder: (childEntries(of: folderID).first?.sortOrder ?? 0) - 1)
        entries.insert(entry, at: 0)
        activeID = entry.id
        // 새 저널이 접힌 폴더 안에 숨지 않게 부모를 펼친다.
        if let folderID { expandedFolderIDs.insert(folderID) }
        // 새 저널은 곧바로 쓸 수 있게 에디터로 포커스를 옮긴다.
        editorFocusRequests += 1
        saveNow()
        return entry.id
    }

    /// 저널 삭제 — 확인 Alert 없이 휴지통으로 보내고 ⌘Z를 안내한다 (이슈 #9).
    /// 영구 삭제는 휴지통 화면의 몫이다.
    public func delete(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let snapshot = entries[index]
        guard trash.add(folders: [], entries: [snapshot]) else {
            showNotice("휴지통 저장에 실패해 ‘\(snapshot.title)’ 삭제를 취소했어요")
            return
        }
        commitStructure("저널 삭제", before: { [weak self] in
            guard let self else { return }
            self.restoreEntries([snapshot])
            self.fixActiveAfterStructureChange(prefer: nil)
            self.saveNow()
        }, after: { [weak self] in
            guard let self else { return }
            self.entries.removeAll { $0.id == id }
            if self.entries.isEmpty { self.entries = [JournalEntry()] }
            self.fixActiveAfterStructureChange(prefer: nil)
            self.saveNow()
        })
        showNotice("‘\(snapshot.title)’을(를) 휴지통으로 옮겼어요 — ⌘Z로 되돌릴 수 있어요")
    }

    /// 구조 변경 후 활성 문서가 목록에 남아 있게 유지한다.
    private func fixActiveAfterStructureChange(prefer: UUID?) {
        if let prefer, entries.contains(where: { $0.id == prefer }) {
            activeID = prefer
        } else if !entries.contains(where: { $0.id == activeID }) {
            activeID = entries[0].id
        }
    }

    /// 저널의 작성일을 바꾼다 — 어제 일을 오늘 적었을 때 날짜를 맞추도록 (L9).
    public func setDate(_ id: UUID, to date: Date) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
            entries[index].createdAt != date
        else { return }
        entries[index].createdAt = date
        saveNow()
    }

    /// 저널을 다른 폴더(또는 루트=nil)로 옮긴다 — 이미 만든 글도 정리할 수 있게.
    /// (컨텍스트 메뉴 "이동"용 — 위치는 대상 폴더 맨 끝.)
    public func move(_ id: UUID, toFolder folderID: UUID?) {
        moveEntry(id, toFolder: folderID, before: nil)
    }

    // MARK: - 정렬·이동 (사이드바 DnD)

    /// 저널을 대상 폴더로 옮기고 beforeID 앞에 놓는다 (nil = 맨 끝).
    /// 같은 폴더 안이면 순수 재정렬. 이동 후 형제 그룹 전체를 0…n으로 재번호한다 —
    /// 목록이 작아 분수 순서 관리보다 단순한 쪽을 택한다. ⌘Z로 되돌릴 수 있다 (#9).
    public func moveEntry(_ id: UUID, toFolder folderID: UUID?, before beforeID: UUID?) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        // 변화가 없으면 스택을 오염시키지 않고 끝낸다.
        let movedNow = entries[index]
        if movedNow.folderID == folderID,
            childEntries(of: folderID).firstIndex(where: { $0.id == id })
                == beforeID.flatMap({ b in childEntries(of: folderID).firstIndex { $0.id == b } })
        {
            return
        }
        let movedBefore = movedNow
        let siblingsBefore = childEntries(of: movedBefore.folderID)
            + childEntries(of: folderID).filter { $0.id != id }
        commitStructure("저널 이동", before: { [weak self] in
            guard let self else { return }
            self.restoreEntries(siblingsBefore + [movedBefore])
            self.saveNow()
        }, after: { [weak self] in
            guard let self else { return }
            var siblings = self.childEntries(of: folderID).filter { $0.id != id }
            let insertAt = beforeID.flatMap { b in siblings.firstIndex { $0.id == b } }
                ?? siblings.count
            var moved = self.entries.first(where: { $0.id == id }) ?? movedBefore
            moved.folderID = folderID
            siblings.insert(moved, at: insertAt)
            self.renumberEntries(siblings)
            if let i = self.entries.firstIndex(where: { $0.id == id }) {
                self.entries[i].folderID = folderID
            }
            // 옮긴 저널이 접힌 폴더에 숨지 않게 대상 폴더를 펼친다.
            if let folderID { self.expandedFolderIDs.insert(folderID) }
            self.saveNow()
        })
    }

    /// 폴더를 다른 부모로 옮기고 beforeID 앞에 놓는다 (nil = 맨 끝).
    /// 자기 자신·자기 자손으로의 이동은 거부한다 (순환 방지). ⌘Z 지원 (#9).
    @discardableResult
    public func moveFolder(_ id: UUID, toParent parentID: UUID?, before beforeID: UUID?) -> Bool {
        guard canMoveFolder(id, toParent: parentID),
            let index = folders.firstIndex(where: { $0.id == id })
        else { return false }
        let insertAt = beforeID.flatMap { b in
            childFolders(of: parentID).firstIndex { $0.id == b }
        } ?? childFolders(of: parentID).count
        let moved = folders[index]
        let orderUnchanged = moved.parentID == parentID
            && childFolders(of: parentID).firstIndex(where: { $0.id == id }) == insertAt
        guard !orderUnchanged else { return true }
        let movedBefore = moved
        let siblingsBefore = childFolders(of: movedBefore.parentID)
            + childFolders(of: parentID).filter { $0.id != id }
        commitStructure("폴더 이동", before: { [weak self] in
            guard let self else { return }
            self.restoreFolders(siblingsBefore + [movedBefore])
            self.saveNow()
        }, after: { [weak self] in
            guard let self else { return }
            var sibs = self.childFolders(of: parentID).filter { $0.id != id }
            var m = self.folders.first(where: { $0.id == id }) ?? movedBefore
            m.parentID = parentID
            sibs.insert(m, at: insertAt)
            self.renumberFolders(sibs)
            if let i = self.folders.firstIndex(where: { $0.id == id }) {
                self.folders[i].parentID = parentID
            }
            if let parentID { self.expandedFolderIDs.insert(parentID) }
            self.saveNow()
        })
        return true
    }

    /// 폴더를 해당 부모로 옮겨도 되는가 — 드롭 중 시각 피드백(forbidden)용.
    /// 자기 자신 또는 자기 자손 폴더 안으로는 옮길 수 없다.
    public func canMoveFolder(_ id: UUID, toParent parentID: UUID?) -> Bool {
        guard let parentID else { return true }
        return !descendantFolderIDs(of: id).contains(parentID)
    }

    /// 저널을 저널 위에 떨어뜨리면 둘을 묶는 새 폴더를 만든다 (사이드바 DnD).
    /// 대상 저널이 있던 폴더 아래, 폴더 블록 맨 끝에 생긴다. 이름은 플레이스홀더 —
    /// 호출부가 AI 명명(requestFolderName)을 이어서 요청한다.
    @discardableResult
    public func createFolder(merging draggedID: UUID, onto targetID: UUID) -> UUID? {
        guard draggedID != targetID,
            let target = entries.first(where: { $0.id == targetID }),
            entries.contains(where: { $0.id == draggedID })
        else { return nil }
        let parent = target.folderID
        let folder = JournalFolder(
            parentID: parent,
            // 폴더 블록 맨 끝 — 대상 저널이 있던 엔트리 영역과 시각적으로 가깝게.
            sortOrder: (childFolders(of: parent).last?.sortOrder ?? -1) + 1)
        folders.insert(folder, at: 0)
        expandedFolderIDs.insert(folder.id)
        // 대상을 먼저, 드래그한 저널을 그 뒤에 — 떨어뜨린 방향 그대로 읽히게.
        moveEntryWithoutSave(targetID, toFolder: folder.id, position: 0)
        moveEntryWithoutSave(draggedID, toFolder: folder.id, position: 1)
        saveNow()
        return folder.id
    }

    /// 이름이 아직 자동 생성 기본값("새 폴더")일 때만 바꾼다 — AI 명명이 끝나기 전에
    /// 사용자가 직접 이름을 붙였다면 그쪽을 존중한다.
    public func renameFolderIfPlaceholder(_ id: UUID, to name: String) {
        guard let index = folders.firstIndex(where: { $0.id == id }),
            folders[index].name == JournalFolder.placeholderName
        else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        folders[index].name = trimmed
        saveNow()
    }

    /// 펼침 전용 — 드래그 hover 스프링 로딩용. toggle이 아니라서 hover 중
    /// 재호출돼도 도로 접히지 않는다.
    public func expand(_ folderID: UUID) {
        guard !expandedFolderIDs.contains(folderID),
            folders.contains(where: { $0.id == folderID })
        else { return }
        expandedFolderIDs.insert(folderID)
        saveNow()
    }

    /// AI 폴더 명명 입력 — 멤버 저널의 제목 + 본문 앞부분을 이어 붙인다.
    public func folderNamingContext(for folderID: UUID, maxCharacters: Int) -> String {
        let members = childEntries(of: folderID)
        guard !members.isEmpty else { return "" }
        let joined = members.enumerated().map { index, entry in
            "[문서 \(index + 1)] 제목: \(entry.title)\n\(entry.body.prefix(300))"
        }
        .joined(separator: "\n\n")
        return String(joined.prefix(maxCharacters))
    }

    /// folderID 변경 + 지정 위치 삽입 — createFolder(merging:) 내부 전용
    /// (saveNow는 호출부가 한 번만).
    private func moveEntryWithoutSave(_ id: UUID, toFolder folderID: UUID?, position: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var siblings = childEntries(of: folderID).filter { $0.id != id }
        var moved = entries[index]
        moved.folderID = folderID
        siblings.insert(moved, at: min(position, siblings.count))
        renumberEntries(siblings)
        entries[index].folderID = folderID
    }

    /// 형제 그룹을 표시 순서대로 0…n 재번호 — sortOrder를 항상 촘촘하게 유지한다.
    private func renumberEntries(_ ordered: [JournalEntry]) {
        for (position, sibling) in ordered.enumerated() {
            if let i = entries.firstIndex(where: { $0.id == sibling.id }) {
                entries[i].sortOrder = Double(position)
            }
        }
    }

    private func renumberFolders(_ ordered: [JournalFolder]) {
        for (position, sibling) in ordered.enumerated() {
            if let i = folders.firstIndex(where: { $0.id == sibling.id }) {
                folders[i].sortOrder = Double(position)
            }
        }
    }

    /// 메뉴에서 "이름 바꾸기"를 눌렀을 때 사이드바가 현재 저널의 인라인 편집을
    /// 시작하도록 하는 요청 카운터.
    @Published public private(set) var renameRequests = 0

    public func requestRename() {
        renameRequests += 1
    }

    // MARK: - 폴더 변경

    @discardableResult
    public func newFolder(in parentID: UUID? = nil) -> UUID {
        let folder = JournalFolder(
            parentID: parentID,
            // 새 폴더는 형제 폴더 맨 위.
            sortOrder: (childFolders(of: parentID).first?.sortOrder ?? 0) - 1)
        folders.insert(folder, at: 0)
        expandedFolderIDs.insert(folder.id)
        if let parentID { expandedFolderIDs.insert(parentID) }
        saveNow()
        return folder.id
    }

    public func renameFolder(_ id: UUID, to name: String) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        folders[index].name = trimmed.isEmpty ? "제목 없음" : trimmed
        saveNow()
    }

    /// 폴더와 그 안의 하위 폴더·저널을 전부 삭제한다.
    /// 폴더 삭제 — 하위 폴더·저널 전체가 **휴지통으로** 가고 ⌘Z로 복원된다 (#9).
    public func deleteFolder(_ id: UUID) {
        let doomed = descendantFolderIDs(of: id)
        let removedFolders = folders.filter { doomed.contains($0.id) }
        let removedEntries = entries.filter { $0.folderID.map(doomed.contains) ?? false }
        guard !removedFolders.isEmpty || !removedEntries.isEmpty else { return }
        let name = removedFolders.first(where: { $0.id == id })?.name ?? "폴더"
        guard trash.add(folders: removedFolders, entries: removedEntries) else {
            showNotice("휴지통 저장에 실패해 ‘\(name)’ 삭제를 취소했어요")
            return
        }
        commitStructure("폴더 삭제", before: { [weak self] in
            guard let self else { return }
            self.restoreFolders(removedFolders)
            self.restoreEntries(removedEntries)
            self.expandedFolderIDs.formUnion(removedFolders.map(\.id))
            self.fixActiveAfterStructureChange(prefer: nil)
            self.saveNow()
        }, after: { [weak self] in
            guard let self else { return }
            self.folders.removeAll { doomed.contains($0.id) }
            self.entries.removeAll { $0.folderID.map(doomed.contains) ?? false }
            self.expandedFolderIDs.subtract(doomed)
            if self.entries.isEmpty { self.entries = [JournalEntry()] }
            self.fixActiveAfterStructureChange(prefer: nil)
            self.saveNow()
        })
        showNotice(
            "‘\(name)’을(를) 휴지통으로 옮겼어요 — 저널 \(removedEntries.count)개가 함께 들어갔어요")
    }

    public func toggleExpanded(_ folderID: UUID) {
        if expandedFolderIDs.contains(folderID) {
            expandedFolderIDs.remove(folderID)
        } else {
            expandedFolderIDs.insert(folderID)
        }
        saveNow()
    }

    public func rename(_ id: UUID, to title: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        entries[index].title = trimmed.isEmpty ? "제목 없음" : trimmed
        // 사용자가 직접 붙인 이름 — 이후 본문 편집으로 덮어쓰지 않는다.
        entries[index].titleIsCustom = true
        saveNow()
    }

    // MARK: - 작품 메타·인물 카드 (스토리 바이블 v0, PLAN §7)

    /// 예측 조립에 쓰는 활성 문서 스냅샷 — CompletionController가 예측 직전
    /// pull한다 (값 복사로 actor 격리 경계를 넘긴다, CompletionParameters 패턴).
    public var activeDocumentContext: DocumentContext? {
        guard let entry = activeEntry else { return nil }
        return DocumentContext(
            // 플레이스홀더 제목은 신호가 아니라 소음 — 헤더에서 뺀다.
            title: JournalEntry.placeholderTitles.contains(entry.title) ? "" : entry.title,
            kind: entry.resolvedKind,
            genre: entry.genre,
            characters: entry.characters ?? [],
            // 리포트·오버라이드 소속 판정용 (이슈 #8).
            entryID: entry.id
        )
    }

    /// 작품 장르 갱신 — 바이블 팝오버의 타이핑 필드라 디바운스 저장.
    public func setGenre(_ genre: String, for id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = genre.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String? = trimmed.isEmpty ? nil : trimmed
        guard entries[index].genre != value else { return }
        entries[index].genre = value
        scheduleSave()
    }

    /// 인물 카드 추가/수정 — 팝오버 텍스트 필드가 매 키 입력마다 부르므로 디바운스 저장.
    /// 인물 카드 추가/수정.
    ///
    /// 커밋 경계 규칙을 **스토어에서** 적용한다 (이슈 #49/H1-5 — 뷰 의존 제거):
    /// - 소개를 직접 수정하면 잠긴다 (자동 프로파일링이 덮지 못하게).
    /// - 사용자가 손대면 자동등록 표식이 사라진다.
    ///
    /// 저장 정책(#49/H1): 새 카드·잠금 토글 같은 이산 변경은 즉시, 이름/별칭/
    /// 소개 연속 타이핑은 디바운스 — 글자마다 entries.json 전체 쓰기 금지.
    public func upsertCharacter(_ cardInput: CharacterCard, in id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let existing = entries[index].characters?.first(where: { $0.id == cardInput.id })
        var card = cardInput
        if let existing {
            if card.note != existing.note
                || card.motivation != existing.motivation
                || card.goal != existing.goal
                || card.conflict != existing.conflict
                || card.epiphany != existing.epiphany
            {
                card.locked = true
            }
            if card != existing { card.autoRegistered = nil }
        }
        let isDiscrete = existing == nil || card.locked != existing?.locked

        commitEntryChange(id, name: "인물 카드 편집",
                          policy: isDiscrete ? .immediate : .debounced) { entry in
            var cards = entry.characters ?? []
            if let i = cards.firstIndex(where: { $0.id == card.id }) {
                cards[i] = card
            } else {
                cards.append(card)
            }
            entry.characters = cards
        }
    }

    /// 인물 감지 후보 "무시" — 거부 목록에 넣어 같은 후보를 다시 묻지 않는다
    /// (M6, PLAN §7). 사용자 결정 = 구조 변경이라 즉시 저장.
    public func rejectCharacterName(_ name: String, in id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var rejected = entries[index].rejectedCharacterNames ?? []
        guard !rejected.contains(name) else { return }
        rejected.append(name)
        entries[index].rejectedCharacterNames = rejected
        saveNow()
    }

    // MARK: - Narrative 사용자 수정 (PLAN §6.5, CLAUDE.md §1-5)

    /// 오버라이드 변경 알림 — ContentView가 인덱서의 오버레이 재적용
    /// (`rehydrate`)에 배선한다. LLM 없이 스냅샷만 다시 조립하는 신호다.
    public var narrativeOverridesDidChange: ((UUID) -> Void)?

    /// AI 분석 결과 수정 저장 — 같은 (kind, key)는 최신 값으로 대체된다.
    /// 사용자 결정 = 구조 변경이라 즉시 저장 (rejectCharacterName과 같은 규칙).
    public func setNarrativeOverride(_ override: NarrativeOverride, in id: UUID) {
        commitEntryChange(id, name: "분석 결과 수정") { entry in
            var overrides = entry.narrativeOverrides ?? []
            overrides.removeAll { $0.kind == override.kind && $0.key == override.key }
            overrides.append(override)
            entry.narrativeOverrides = overrides
        }
        narrativeOverridesDidChange?(id)
    }

    /// 오버라이드 제거 — "AI 분석으로 되돌리기".
    public func removeNarrativeOverride(
        kind: NarrativeOverride.Kind, key: String, in id: UUID
    ) {
        commitEntryChange(id, name: "분석 결과 되돌리기") { entry in
            var overrides = entry.narrativeOverrides ?? []
            overrides.removeAll { $0.kind == kind && $0.key == key }
            entry.narrativeOverrides = overrides.isEmpty ? nil : overrides
        }
        narrativeOverridesDidChange?(id)
    }

    // MARK: - 기록된 대화 (요구사항 §20–§21)

    /// 대화 기록 승인 — 사용자 결정 = 즉시 저장. 스냅샷 재조립 신호까지 쏜다
    /// (기록이 대화 인덱스에 바로 보이도록).
    public func recordConversation(_ record: RecordedConversation, in id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
            !(entries[index].recordedConversations ?? []).contains(where: { $0.contentHash == record.contentHash })
        else { return }
        commitEntryChange(id, name: "대화 기록") { entry in
            var records = entry.recordedConversations ?? []
            records.append(record)
            entry.recordedConversations = records
        }
        narrativeOverridesDidChange?(id)
    }

    /// 기록 삭제 — 사용자만 지울 수 있다 (재분석은 절대 지우지 않는다).
    public func removeRecordedConversation(id recordID: UUID, in id: UUID) {
        commitEntryChange(id, name: "대화 기록 삭제") { entry in
            var records = entry.recordedConversations ?? []
            records.removeAll { $0.id == recordID }
            entry.recordedConversations = records.isEmpty ? nil : records
        }
        narrativeOverridesDidChange?(id)
    }

    /// 인물 카드 삭제 — ⌘Z로 복원된다 (#9). 구조 변경은 즉시 저장 (기존 규칙).
    public func removeCharacter(_ cardID: UUID, from id: UUID) {
        commitEntryChange(id, name: "인물 삭제") { entry in
            var cards = entry.characters ?? []
            cards.removeAll { $0.id == cardID }
            entry.characters = cards.isEmpty ? nil : cards
        }
    }

    /// 활성 본문 변경 카운터 — 상태 바의 디바운스 통계가 `.task(id:)` 키로
    /// 쓴다. @Published가 아니어도 된다: entries 변이가 이미 objectWillChange를
    /// 쏘고, 뷰는 다시 그려질 때 이 값을 읽는다.
    public private(set) var bodyVersion = 0

    /// 에디터 바인딩이 매 키 입력마다 호출 — 본문 갱신 + 디바운스 autosave.
    /// 제목이 사용자 지정이 아니면 첫 줄에서 자동 파생한다 — 사이드바가 "새 저널"
    /// 무더기가 되지 않도록 (자동 저널링의 기본 기대).
    public func updateActiveBody(_ text: String) {
        guard let index = entries.firstIndex(where: { $0.id == activeID }) else { return }
        // 무변경 가드 — 길이(UTF-8, O(1))가 다르면 전체 비교(O(n))를 건너뛴다.
        // 타이핑은 길이가 항상 변하므로 키 입력 경로에서 전체 비교가 사라진다.
        let current = entries[index].body
        if current.utf8.count == text.utf8.count, current == text { return }
        entries[index].body = text
        bodyVersion &+= 1
        if entries[index].allowsAutoTitle {
            let derived = Self.derivedTitle(from: text)
            let fallback = entries[index].resolvedKind == .novel ? "새 소설" : "새 저널"
            entries[index].title = derived.isEmpty ? fallback : derived
            // 파생 제목임을 명시 — 레거시(nil) 항목이 첫 파생 후 플레이스홀더
            // 판정에서 벗어나 한 글자 제목으로 얼어붙던 버그 방지.
            entries[index].titleIsCustom = false
        }
        scheduleSave()
        // 타이핑 = 인덱서 선점 신호 (M6) — 진행 중 백그라운드 이해를 멈추고
        // 유휴 타이머를 다시 감는다.
        documentDidChange?(activeID)
    }

    // MARK: - 저장

    private var currentSnapshot: Snapshot {
        Snapshot(
            entries: entries, activeID: activeID,
            folders: folders,
            // Set 순서는 매번 달라진다 — 정렬해 저장 파일 diff를 안정화.
            expandedFolderIDs: expandedFolderIDs.sorted { $0.uuidString < $1.uuidString })
    }

    // MARK: - 저장 상태 (이슈 #10)

    /// 저장 결과의 정직한 상태 — 실패를 "저장됨"으로 위장하지 않는다.
    /// 디스크 부족·권한 오류는 실제로 자주 있고, 거짓 안심이 곧 데이터 손실이다.
    public enum SavePhase: Equatable {
        /// 아직 저장 요청이 없다.
        case idle
        case saving
        /// 마지막 성공 시각.
        case saved(Date)
        case failed(message: String, date: Date)
    }

    @Published public private(set) var savePhase: SavePhase = .idle

    /// 지금 진행 중인 저장이 있는가 — 상태 바 표시용 파생 값.
    public var isSaveInFlight: Bool {
        if case .saving = savePhase { return true }
        return false
    }

    /// 상태 바·오류 안내가 가리킬 현재 저장 대상 파일명 — 복구 모드면 세션 파일.
    public var saveTargetFileName: String { writeTargetURL.lastPathComponent }

    /// 마지막으로 실패한 저장을 다시 시도한다 — 현재 메모리 상태 전체를 쓴다.
    /// 실패 후에도 타이핑을 계속했더라도 그 최신 내용이 반영된다.
    public func retrySave() { saveNow() }

    /// 저장 결과를 상태로 기록한다. 성공/실패 공통.
    private func noteOutcome(_ failure: String?) {
        if let failure {
            savePhase = .failed(message: failure, date: .now)
        } else {
            savePhase = .saved(Date.now)
        }
    }

    /// 원고 저장 전용 직렬 라이터 (이슈 #44).
    ///
    /// 수백 KB~MB 스냅샷의 JSON 인코딩+쓰기는 수십~수백 ms 걸리고, 메인에서
    /// 돌면 타이핑 재개와 겹쳐 프리즈가 된다(고스트 지연 예산 PLAN §10 직격).
    /// 그래서 **스냅샷 캡처·취소 판정만 메인에 남기고 인코딩+쓰기는 여기서
    /// 돌린다**. 예전엔 MainActor 직렬화가 "캡처 순서 = 디스크 반영 순서"를
    /// 보장했는데, 액터의 FIFO 직렬화가 그 역할을 승계한다 — 세 스냅샷은 전부
    /// 전체 상태라 순서만 지켜지면 마지막 쓰기가 곧 최신 상태다.
    private actor SnapshotWriter {
        /// 쓰고 실패 이유를 돌려준다 — nil이면 성공 (이슈 #10).
        func write(_ snapshot: Snapshot, to url: URL) -> String? {
            EntryStore.performWrite(snapshot, to: url)
        }
    }

    /// 디바운스 autosave — 입력이 멈춘 뒤에만 쓴다.
    /// 메인에서 하는 일: 이전 예약 취소 → 스냅샷 캡처 → 지연 대기. 실제 쓰기는
    /// 라이터 액터로 hop하므로 대형 원고에서도 메인이 막히지 않는다.
    private func scheduleSave() {
        saveTask?.cancel()
        // 이미 saving이면 재발행하지 않는다 — 타이핑마다 objectWillChange가
        // 상태 바를 다시 그리지 않게 (이슈 #51).
        if case .saving = savePhase {} else { savePhase = .saving }
        saveGeneration += 1
        let generation = saveGeneration
        let snapshot = currentSnapshot
        // 복구 모드면 세션 파일로 — 손상 원본을 덮는 길을 없앤다 (이슈 #6).
        let target = writeTargetURL
        saveTask = Task { [weak self, autosaveDelay, target] in
            try? await Task.sleep(for: autosaveDelay)
            guard !Task.isCancelled else { return }
            self?.flushAllDebouncedUndo()
            await self?.persist(snapshot, to: target, generation: generation)
        }
    }

    /// 라이터 액터로 쓰기를 넘기고, 끝나면 메인으로 돌아와 최신성 검사 후 표시 정리.
    /// 새 저장이 먼저 예약된(stale) 완료는 상태를 건드리지 않는다 — 새 저장의
    /// 결과가 이어서 보고한다.
    private func persist(_ snapshot: Snapshot, to url: URL, generation: Int) async {
        guard generation == saveGeneration else { return }
        noteOutcome(await writer.write(snapshot, to: url))
    }

    /// 라이터 액터에 쓰기를 맡기고 **완료까지 기다린다** — 구조 변경 즉시 저장과
    /// flush처럼 "반환 시점 = 디스크 반영 시점" 계약이 필요한 경로용 (AGENTS §6:
    /// ⌘Q 직전 flush로 마지막 문장 보존). 라이터는 메인을 필요로 하지 않으므로
    /// 메인에서 기다려도 교착하지 않는다. 밀린 autosave 쓰기도 FIFO로 이 안에서
    /// 먼저 마쳐지므로, 반환 시 파일은 항상 이 스냅샷이다. 실패 이유를 돌려준다.
    @discardableResult
    private func writeAndWait(_ snapshot: Snapshot) -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        let writer = self.writer
        // 복구 모드면 세션 파일로 — flush 계약("반환 = 디스크 반영")은 대상 파일
        // 기준으로 지켜진다 (이슈 #6).
        let url = writeTargetURL
        // 클로저→메인 결과 전달은 세마포어가 순서를 보장한다 (wait가 먼저 풀리고
        // 읽는다). 박스로 감싸 동시성 검사를 통과한다.
        let outcome = OutcomeBox()
        Task.detached(priority: .userInitiated) {
            outcome.value = await writer.write(snapshot, to: url)
            semaphore.signal()
        }
        semaphore.wait()
        return outcome.value
    }

    private final class OutcomeBox: @unchecked Sendable {
        var value: String?
    }

    /// 구조 변경(생성·삭제·이름변경 등) 즉시 저장 — 호출이 끝나면 디스크에 반영돼 있다.
    /// 즉시 저장 호출 횟수 — 저장 정책(즉시 vs 디바운스) 회귀의 관측 훅 (이슈 #49).
    public private(set) var immediateSaveCount = 0

    private func saveNow() {
        saveTask?.cancel()
        saveGeneration += 1
        immediateSaveCount += 1
        noteOutcome(writeAndWait(currentSnapshot))
    }

    /// 대기 중인 디바운스 버스트의 undo 확정 — 종료 직전에도 마지막 타이핑 묶음이
    /// 되돌아갈 수 있게 한다 (flush 계약과 짝, 이슈 #49/H1 게이트 4).

    /// 대기 중인 디바운스 저장을 즉시 디스크에 쓴다 — 앱 종료·백그라운드 전환 직전에
    /// 호출해, 입력 직후 ⌘Q로 마지막 문장을 잃는 일을 막는다 (원자적 쓰기라 반복 호출도 안전).
    public func flush() {
        flushAllDebouncedUndo()  // 마지막 타이핑 묶음의 undo도 확정 (H1 게이트 4)
        saveTask?.cancel()
        saveTask = nil
        saveGeneration += 1
        noteOutcome(writeAndWait(currentSnapshot))
    }

    /// Lifecycle saves yield the main actor while the writer persists each accepted generation.
    /// Returns the failure message without discarding the in-memory manuscript or undo state.
    public func flushAsync() async -> String? {
        while true {
            flushAllDebouncedUndo()
            saveTask?.cancel()
            saveTask = nil
            saveGeneration += 1
            let generation = saveGeneration
            let snapshot = currentSnapshot
            savePhase = .saving
            let failure = await writer.write(snapshot, to: writeTargetURL)
            if let failure {
                noteOutcome(failure)
                return failure
            }
            guard generation == saveGeneration else { continue }
            noteOutcome(nil)
            return nil
        }
    }

    // MARK: - 복구 액션 (이슈 #6)

    /// 복구 파일을 라이브러리로 승계하고 정상 모드로 복귀한다 — 사용자가 안내
    /// 대화에서 "새 라이브러리로 시작"을 고른 때만 호출된다. 지금까지의 세션
    /// 편집은 사라지지 않고 원본 자리로 옮겨진다. 손상 원본은 이미 .corrupt-*
    /// 사본으로 남아 있다.
    public func adoptRecoveredAsLibrary() {
        guard pendingRecovery != nil else { return }
        let fm = FileManager.default
        if let session = recoveredSessionURL {
            if !fm.fileExists(atPath: session.path) {
                if let failure = writeAndWait(currentSnapshot) {
                    noteOutcome(failure)
                    return
                }
            }
            guard Self.promoteRecoveredFile(from: session, to: fileURL) else {
                noteOutcome("복구 파일을 라이브러리로 승계하지 못했습니다")
                return
            }
        } else {
            if let failure = Self.performWrite(currentSnapshot, to: fileURL) {
                noteOutcome(failure)
                return
            }
        }
        pendingRecovery = nil
        recoveredSessionURL = nil
        saveNow()  // 정상 경로 복귀를 바로 검증한다 — 실패하면 #10 상태 표시가 받는다.
    }

    /// 세션 스냅샷을 사용자가 고른 위치로 내보낸다 — 백업 로테이션 없는 순수 사본.
    /// 복구 모드가 아니어도 동작한다 (안전한 별도 내보내기).
    @discardableResult
    public func exportSessionCopy(to url: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(currentSnapshot) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// JSON 인코딩 + 원자적 쓰기 — 라이터 액터(백그라운드)에서만 호출된다.
    /// MainActor 격리로 두면 액터가 다시 메인으로 hop해 이 개선의 목적이 사라진다.
    /// 실패를 삼키지 않고 이유를 돌려준다 (nil = 성공, 이슈 #10).
    private nonisolated static func performWrite(
        _ snapshot: Snapshot, to url: URL
    ) -> String? {
        rotateDailyBackup(of: url)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else {
            return "원고를 JSON으로 변환하지 못했습니다"
        }
        do {
            try data.write(to: url, options: .atomic)
            return nil
        } catch {
            // 디스크 부족·권한 오류가 여기서 온다 — 사용자에게 이유 그대로 전달.
            return "쓰기 실패 (\(url.lastPathComponent)): \(error.localizedDescription)"
        }
    }

    // MARK: - 원고 백업 (PLAN §16 "백업 로테이션도 없음 — 원고는 소중하다" 해소)

    /// 백업 보존 세대.
    private nonisolated static let backupKeepGenerations = 7

    /// 하루 1회, 그날 첫 저장 직전에 어제까지의 상태를 `backups/`에 스냅샷하고
    /// 최근 세대만 남긴다. 사본 이름은 **파일의 수정일**(그 내용이 무엇의 상태인지)을
    /// 쓰므로 며칠 켜지 않았다가 돌아와도 같은 상태의 중복 사본이 생기지 않는다.
    /// 결정적 로직 — 같은 디스크 상태면 같은 동작. 실패는 조용히 건너뛴다(최선 노력).
    /// 라이터 액터(백그라운드)에서 불리므로 nonisolated — 포맷터도 격리 밖에서
    /// 만든다(하루 한 번이라 비용 무시).
    nonisolated static func rotateDailyBackup(of url: URL) {
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "ko_KR")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
            let attrs = try? fm.attributesOfItem(atPath: url.path),
            let modified = attrs[.modificationDate] as? Date,
            !Calendar(identifier: .gregorian).isDateInToday(modified)
        else { return }
        let dir = url.deletingLastPathComponent()
            .appendingPathComponent("backups", isDirectory: true)
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil
        else { return }
        let stem = url.deletingPathExtension().lastPathComponent
        let target = dir.appendingPathComponent(
            "\(stem)-\(dayFormatter.string(from: modified)).json")
        if !fm.fileExists(atPath: target.path) {
            try? fm.copyItem(at: url, to: target)
        }
        // 로테이션 — 파일명이 날짜라 사전순 정렬이 곧 시간순이다.
        let prefix = stem + "-"
        let generations =
            ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".json") }
            .sorted()
        for stale in generations.dropLast(Self.backupKeepGenerations) {
            try? fm.removeItem(at: dir.appendingPathComponent(stale))
        }
    }

    // MARK: - 날짜 포맷터

    private static let koCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ko_KR")
        return calendar
    }()

    private static func koFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = format
        return formatter
    }

    private static let fullDateFormatter = koFormatter("M월 d일 EEEE")
    private static let weekdayFormatter = koFormatter("EEEEE")
    private static let shortDateFormatter = koFormatter("M.d")
    /// 백업 파일명·손상 사본 스탬프 — 정렬 가능성이 곧 시간순이 되게 고정 폭 형식.
    /// 백업 쪽은 라이터 액터가 nonisolated로 만들어 쓴다(위 rotateDailyBackup).
    private static let corruptStampFormatter = koFormatter("yyyy-MM-dd-HHmmss")
}
