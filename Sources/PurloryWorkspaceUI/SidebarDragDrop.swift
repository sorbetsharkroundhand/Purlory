import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 사이드바 드래그&드롭 배관 (파일 탐색기 DnD).
///
/// 설계 메모:
/// - `.draggable`/`.dropDestination` 대신 `.onDrag` + `DropDelegate`를 쓴다 —
///   삽입선을 드래그 중 실시간으로 그리려면 `dropUpdated`의 연속 location이
///   필요하고, 커스텀 UTType은 Info.plist 없는 SPM 실행파일에서 선언할 수 없다.
/// - NSItemProvider에는 UUID 문자열만 싣는다. 어떤 항목을 옮기는지는 인앱
///   `SidebarDragModel.dragged`가 진실이고, 드롭 적용 직전에 페이로드와
///   대조한다 — 취소된 이전 드래그의 잔존 상태로 외부 텍스트 드롭이
///   오작동하지 않게 하는 안전망.
/// - DropDelegate 콜백은 nonisolated지만 실제로는 메인 스레드에서 온다 —
///   델리게이트를 `@MainActor` + `@preconcurrency` 적합으로 선언해 동적
///   격리 검증에 맡긴다 (Swift 6).
enum SidebarDnD {
    /// 드롭 존 계산용 행 높이 — 행 레이아웃(패딩 9/7 + 내용 20)에서 온 상수.
    /// 행 구조가 바뀌면 함께 조정한다.
    static let entryRowHeight: CGFloat = 38
    static let folderRowHeight: CGFloat = 34
    /// 상/하단 몇 %를 "사이 삽입" 존으로 볼지 (나머지 가운데는 "안으로").
    static let edgeZoneFraction: CGFloat = 0.25
    /// 접힌 폴더 위에 머무르면 펼치기까지의 대기 (Finder 스프링 로딩 관용).
    static let springLoadDelay: Duration = .milliseconds(600)
}

/// 드래그 중인 항목 — 저널·폴더가 UUID 공간을 공유하므로 종류를 함께 든다.
enum SidebarDragNode: Equatable, Sendable {
    case entry(id: UUID)
    case folder(id: UUID)

    var id: UUID {
        switch self {
        case .entry(let id), .folder(let id): id
        }
    }
}

/// 드롭 시각 피드백 — 어느 행의 어느 위치에 내려앉을지.
enum SidebarDropIndicator: Equatable, Sendable {
    /// 행 위쪽 삽입선.
    case before(UUID)
    /// 행 아래쪽 삽입선.
    case after(UUID)
    /// 행 하이라이트 — 폴더로 이동, 또는 저널 병합(새 폴더).
    case into(UUID)
    /// 목록 아래 빈 영역 — 루트 맨 끝으로 이동.
    case root
}

/// 드래그 세션 상태 — `.onDrag`가 시작 시 세팅, 델리게이트가 갱신·해제한다.
@MainActor
final class SidebarDragModel: ObservableObject {
    /// 드롭 재배치 애니메이션 — Reduce Motion이면 nil(즉시) (#27).
    /// DropDelegate는 Environment를 못 받으므로 시스템 설정을 직접 읽는다.
    static var dropAnimation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(duration: 0.25)
    }

    @Published private(set) var dragged: SidebarDragNode?
    @Published private(set) var indicator: SidebarDropIndicator?
    private var springLoadTask: Task<Void, Never>?

    func beginDrag(_ node: SidebarDragNode) {
        dragged = node
        indicator = nil
    }

    /// 같은 값이면 무시 — dropUpdated가 마우스 이동마다 불려 재렌더를 아낀다.
    func setIndicator(_ new: SidebarDropIndicator?) {
        if indicator != new { indicator = new }
    }

    /// 이 행을 가리키는 표시만 지운다 — 다른 행이 이미 새 표시를 세웠을 수 있다.
    func clearIndicator(for id: UUID) {
        switch indicator {
        case .before(let x), .after(let x), .into(let x):
            if x == id { indicator = nil }
        case .root, nil:
            break
        }
    }

    func clearRootIndicator() {
        if indicator == .root { indicator = nil }
    }

    /// 접힌 폴더 위에 머무르면 잠시 후 펼친다 — 드래그를 놓지 않고 안으로
    /// 파고들 수 있게 (스프링 로딩).
    func scheduleSpringLoad(of folderID: UUID, in store: EntryStore) {
        cancelSpringLoad()
        springLoadTask = Task { [weak store] in
            try? await Task.sleep(for: SidebarDnD.springLoadDelay)
            guard !Task.isCancelled else { return }
            store?.expand(folderID)
        }
    }

    func cancelSpringLoad() {
        springLoadTask?.cancel()
        springLoadTask = nil
    }

    func endDrag() {
        cancelSpringLoad()
        dragged = nil
        indicator = nil
    }
}

// MARK: - 공용 헬퍼

/// 드롭 페이로드(UUID 문자열)가 현재 드래그 항목과 일치할 때만 적용한다.
/// NSItemProvider 로드는 비동기라 performDrop은 낙관적으로 true를 돌려주고,
/// 실제 변경은 검증을 통과한 뒤 메인 액터에서 실행된다.
@MainActor
private func applyVerified(
    info: DropInfo,
    expecting node: SidebarDragNode,
    then apply: @escaping @MainActor () -> Void
) -> Bool {
    guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
    let expected = node.id.uuidString
    _ = provider.loadObject(ofClass: String.self) { payload, _ in
        guard payload == expected else { return }
        Task { @MainActor in apply() }
    }
    return true
}

// MARK: - 저널 행 델리게이트

/// 저널 행 위 드롭: 상/하단 = 형제 사이 삽입, 가운데 = 두 저널을 새 폴더로 병합.
@MainActor
struct EntryRowDropDelegate: DropDelegate {
    let entry: JournalEntry
    let store: EntryStore
    let model: SidebarDragModel
    /// 병합으로 만든 새 폴더의 AI 명명 요청 — SidebarView가 컨트롤러로 배선.
    let requestNaming: @MainActor (UUID) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        model.dragged != nil && info.hasItemsConforming(to: [.plainText])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard case .entry(let draggedID) = model.dragged, draggedID != entry.id else {
            // 폴더는 저널 행 사이에 놓일 수 없다(폴더 먼저 불변식) — 자기 자신도 금지.
            model.clearIndicator(for: entry.id)
            return DropProposal(operation: .forbidden)
        }
        model.setIndicator(Self.zone(at: info.location.y, target: entry.id))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        model.clearIndicator(for: entry.id)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard case .entry(let draggedID) = model.dragged, draggedID != entry.id else {
            model.endDrag()
            return false
        }
        let zone = Self.zone(at: info.location.y, target: entry.id)
        let target = entry
        let store = store
        let requestNaming = requestNaming
        let accepted = applyVerified(info: info, expecting: .entry(id: draggedID)) {
            withAnimation(SidebarDragModel.dropAnimation) {
                switch zone {
                case .before:
                    store.moveEntry(draggedID, toFolder: target.folderID, before: target.id)
                case .after:
                    // 대상 바로 다음 형제 앞 = 대상 바로 뒤.
                    let siblings = store.childEntries(of: target.folderID)
                    let next = siblings.drop(while: { $0.id != target.id })
                        .dropFirst().first
                    store.moveEntry(draggedID, toFolder: target.folderID, before: next?.id)
                case .into, .root:
                    if let folderID = store.createFolder(
                        merging: draggedID, onto: target.id)
                    {
                        requestNaming(folderID)
                    }
                }
            }
        }
        model.endDrag()
        return accepted
    }

    private static func zone(at y: CGFloat, target: UUID) -> SidebarDropIndicator {
        let h = SidebarDnD.entryRowHeight
        if y < h * SidebarDnD.edgeZoneFraction { return .before(target) }
        if y > h * (1 - SidebarDnD.edgeZoneFraction) { return .after(target) }
        return .into(target)
    }
}

// MARK: - 폴더 행 델리게이트

/// 폴더 행 위 드롭: 저널은 행 전체가 "안으로", 폴더는 상/하단 = 형제 재정렬,
/// 가운데 = 하위로 이동 (순환은 금지).
@MainActor
struct FolderRowDropDelegate: DropDelegate {
    let folder: JournalFolder
    let expanded: Bool
    let store: EntryStore
    let model: SidebarDragModel
    /// 자동 생성 이름("새 폴더")이 남은 폴더에 저널이 추가되면 명명을 재시도.
    let requestNaming: @MainActor (UUID) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        model.dragged != nil && info.hasItemsConforming(to: [.plainText])
    }

    func dropEntered(info: DropInfo) {
        // 접힌 폴더 위에 머무르면 펼쳐서 안으로 계속 드래그할 수 있게.
        if model.dragged != nil, !expanded {
            model.scheduleSpringLoad(of: folder.id, in: store)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        switch model.dragged {
        case .entry:
            // 저널은 폴더 행 어디에 놓아도 "안으로" — 폴더 블록 사이에 저널이
            // 끼는 삽입선은 거짓 약속이라 그리지 않는다.
            model.setIndicator(.into(folder.id))
            return DropProposal(operation: .move)
        case .folder(let draggedID):
            guard draggedID != folder.id else {
                model.clearIndicator(for: folder.id)
                return DropProposal(operation: .forbidden)
            }
            guard let zone = zoneForFolderDrag(draggedID: draggedID, y: info.location.y)
            else {
                model.clearIndicator(for: folder.id)
                return DropProposal(operation: .forbidden)
            }
            model.setIndicator(zone)
            return DropProposal(operation: .move)
        case nil:
            return DropProposal(operation: .forbidden)
        }
    }

    func dropExited(info: DropInfo) {
        model.cancelSpringLoad()
        model.clearIndicator(for: folder.id)
    }

    func performDrop(info: DropInfo) -> Bool {
        model.cancelSpringLoad()
        defer { model.endDrag() }
        switch model.dragged {
        case .entry(let draggedID):
            let target = folder
            let store = store
            let requestNaming = requestNaming
            return applyVerified(info: info, expecting: .entry(id: draggedID)) {
                withAnimation(SidebarDragModel.dropAnimation) {
                    store.moveEntry(draggedID, toFolder: target.id, before: nil)
                }
                // 이름이 아직 자동 생성 기본값이면(명명 실패·미실행) 새 멤버까지
                // 반영해 다시 짓는다 — 진행 중이면 컨트롤러 가드가 무시한다.
                if target.name == JournalFolder.placeholderName {
                    requestNaming(target.id)
                }
            }
        case .folder(let draggedID):
            guard draggedID != folder.id,
                let zone = zoneForFolderDrag(draggedID: draggedID, y: info.location.y)
            else { return false }
            let target = folder
            let store = store
            return applyVerified(info: info, expecting: .folder(id: draggedID)) {
                withAnimation(SidebarDragModel.dropAnimation) {
                    switch zone {
                    case .before:
                        store.moveFolder(
                            draggedID, toParent: target.parentID, before: target.id)
                    case .after:
                        let siblings = store.childFolders(of: target.parentID)
                        let next = siblings.drop(while: { $0.id != target.id })
                            .dropFirst().first
                        store.moveFolder(
                            draggedID, toParent: target.parentID, before: next?.id)
                    case .into, .root:
                        store.moveFolder(draggedID, toParent: target.id, before: nil)
                    }
                }
            }
        case nil:
            return false
        }
    }

    /// 폴더 드래그의 존 결정 — 존마다 도착 부모가 달라 순환 검사도 존별로 한다.
    /// nil = 허용되는 위치가 아님(forbidden).
    private func zoneForFolderDrag(draggedID: UUID, y: CGFloat) -> SidebarDropIndicator? {
        let h = SidebarDnD.folderRowHeight
        if y < h * SidebarDnD.edgeZoneFraction {
            guard store.canMoveFolder(draggedID, toParent: folder.parentID) else {
                return nil
            }
            return .before(folder.id)
        }
        // 펼친 폴더의 하단 엣지는 "안으로"에 넘긴다 — 아래 삽입선은 첫 자식
        // 위 자리처럼 보이는 거짓말이 된다 ("첫 자식 앞"은 그 자식 행의 상단 존).
        if y > h * (1 - SidebarDnD.edgeZoneFraction), !expanded {
            guard store.canMoveFolder(draggedID, toParent: folder.parentID) else {
                return nil
            }
            return .after(folder.id)
        }
        guard store.canMoveFolder(draggedID, toParent: folder.id) else { return nil }
        return .into(folder.id)
    }
}

// MARK: - 루트 빈 영역 델리게이트

/// 목록 아래 빈 영역 드롭 — 루트 맨 끝으로 이동.
@MainActor
struct RootAreaDropDelegate: DropDelegate {
    let store: EntryStore
    let model: SidebarDragModel

    func validateDrop(info: DropInfo) -> Bool {
        model.dragged != nil && info.hasItemsConforming(to: [.plainText])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard model.dragged != nil else { return DropProposal(operation: .forbidden) }
        model.setIndicator(.root)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        model.clearRootIndicator()
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { model.endDrag() }
        guard let dragged = model.dragged else { return false }
        let store = store
        return applyVerified(info: info, expecting: dragged) {
            withAnimation(SidebarDragModel.dropAnimation) {
                switch dragged {
                case .entry(let id):
                    store.moveEntry(id, toFolder: nil, before: nil)
                case .folder(let id):
                    store.moveFolder(id, toParent: nil, before: nil)
                }
            }
        }
    }
}

// MARK: - 삽입선

/// 행 사이 삽입 위치 표시 — 선단 고리 + 가로선 (Finder·Notes 관용구).
struct SidebarInsertionLine: View {
    let theme: PurloryTheme
    let depth: Int

    var body: some View {
        HStack(spacing: 1) {
            Circle()
                .stroke(theme.blueC, lineWidth: 1.5)
                .frame(width: 5, height: 5)
            Capsule()
                .fill(theme.blueC)
                .frame(height: 2)
        }
        .padding(.leading, CGFloat(depth) * 14 + 8)
        .padding(.trailing, 4)
        .allowsHitTesting(false)
    }
}
