import SwiftUI

/// 스토리 바이블 — 장르·인물 카드 편집 + 자동 이해 열람 팝오버 (PLAN §7, M6-8).
///
/// 툴바의 "소설" 배지에서 연다. 여기 적은 내용이 소설 예측 프롬프트의
/// A 헤더에 그대로 실린다 — 카드가 짧을수록 토큰당 품질이 좋다 (PLAN §11).
///
/// M6 마감 형태 (CLAUDE.md §1-5 "기억은 사용자의 것"):
/// - **열람**: 카드마다 백그라운드가 이해한 것(상태·최근 사건·말투)을 보여준다.
/// - **수정**: 카드 필드는 언제나 편집 가능 — 사용자 수정이 자동 추출을 이긴다.
/// - **locked**: 소개를 직접 고치면 자동 잠금 — 프로파일링이 덮지 못한다.
/// - **미확인 검토**: 감지된 후보를 전부 나열 — 등록은 사용자 확인 (CLAUDE.md §3).
struct CharacterBibleView: View {
    @ObservedObject var store: EntryStore
    let theme: PurloryTheme
    /// 인물 감지 깔때기 + 자동 이해 열람 (M6) — nil이면 수동 카드만 (프리뷰 등).
    var indexer: BackgroundIndexer?
    /// 사이드바 섹션에 임베드됐는가 — 고정 폭·높이 상한을 풀고 공간을 채운다.
    var embedded = false

    /// 카드별 파생 지식 캐시 (#48) — 키 입력이 store를 무효화해도 카드·스냅샷
    /// 세대가 그대로면 카드당 지식 폴딩(understanding·연대기·앎·관계·대화,
    /// O(카드 × 델타))을 다시 하지 않는다.
    private struct CardLines {
        var understanding: [String] = []
        var chronicle: [String] = []
        var knowledge: [(text: String, jump: String?)] = []
        var relations: [(text: String, jump: String?)] = []
        var conversations: [(text: String, jump: String?)] = []
    }
    private struct BibleCacheKey: Equatable {
        var entryID: UUID?
        /// 카드 배열 전체 동등 비교 — 필드가 짧은 문자열뿐이라 저렴한다.
        var cards: [CharacterCard]
        var generation: Int
    }
    @State private var bibleCache: (key: BibleCacheKey, lines: [UUID: CardLines])?

    /// 캐시된 카드별 줄 — 키가 같으면 전 패스의 폴딩 결과를 재사용한다.
    private func cachedLines() -> [UUID: CardLines] {
        let key = BibleCacheKey(
            entryID: store.activeID, cards: cards,
            generation: indexer?.snapshotGeneration ?? -1)
        if let cache = bibleCache, cache.key == key { return cache.lines }
        guard let snapshot else {
            bibleCache = (key, [:])
            return [:]
        }
        let names = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0.name) })
        var lines: [UUID: CardLines] = [:]
        lines.reserveCapacity(cards.count)
        for card in cards {
            var item = CardLines()
            item.understanding = Self.understanding(of: card.id, snapshot: snapshot)
            item.chronicle = Self.chronicle(of: card.id, snapshot: snapshot)
            item.knowledge = Self.knowledgeLines(of: card.id, snapshot: snapshot)
            item.relations = Self.relationLines(of: card.id, snapshot: snapshot, names: names)
            item.conversations =
                Self.conversationLines(of: card, snapshot: snapshot, names: names)
            lines[card.id] = item
        }
        bibleCache = (key, lines)
        return lines
    }

    var body: some View {
        let linesByCard = cachedLines()
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.novelC)
                Text("스토리 바이블")
                    .purloryUIFont(13, .semibold)
                    .foregroundStyle(theme.inkC)
                Spacer()
                // 수동 이해 트리거 (M6-8) — 자동(유휴)만이 아니라 사용자가
                // 원할 때도 이해를 만든다. 자동완성이 꺼져 있어도 동작한다.
                if let indexer {
                    ManualIndexButton(indexer: indexer, theme: theme)
                }
            }

            // 인물 후보 검토 — 비모달, 감지된 후보 전부 (PLAN §7 깔때기 2단).
            if let indexer {
                CandidateReviewList(indexer: indexer, store: store, theme: theme)
            }

            TextField("장르 (예: 판타지 · 로맨스 · 추리)", text: genreBinding)
                .textFieldStyle(.roundedBorder)
                .purloryUIFont(12)

            Text("제목·장르·인물 카드가 예측에 함께 실려요. 최근 본문에 이름이 등장하는 인물이 우선돼요 (최대 3명).")
                .purloryUIFont(10.5)
                .foregroundStyle(theme.ink2C)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(cards) { card in
                        let lines = linesByCard[card.id] ?? CardLines()
                        CharacterCardRow(
                            card: binding(for: card),
                            theme: theme,
                            understanding: lines.understanding,
                            chronicle: lines.chronicle,
                            knowledge: lines.knowledge,
                            relations: lines.relations,
                            conversations: lines.conversations,
                            onJump: { query in
                                // 재앵커 사다리 (요구사항 §28) — 인용이 수정됐으면
                                // 어절 지문으로 되찾는다.
                                let resolved = store.activeEntry.flatMap {
                                    SourceAnchor.resilientQuery(for: query, in: $0.body)
                                } ?? query
                                store.requestSearchJump(store.activeID, query: resolved)
                            },
                            onDelete: { remove(card) }
                        )
                    }
                    if cards.isEmpty {
                        Text("아직 인물이 없어요 — 주요 인물을 등록하면 제안이 이름과 말투를 지켜요.")
                            .purloryUIFont(11)
                            .foregroundStyle(theme.ink3C)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                }
            }
            .frame(maxHeight: embedded ? .infinity : 320)

            Button {
                addCard()
            } label: {
                Label("인물 추가", systemImage: "plus")
                    .purloryUIFont(12, .medium)
            }
        }
        .padding(14)
        // 적응형 폭 (#30) — 고정 대신 min/ideal/max: 좁은 사이드바에선 줄어들고
        // 넓은 팝오버에선 이상 폭을 유지한다. embedded(nil)는 공간을 채운다.
        .frame(
            minWidth: embedded ? nil : 320,
            idealWidth: embedded ? nil : 400,
            maxWidth: embedded ? nil : 520)
    }

    private var cards: [CharacterCard] {
        store.activeEntry?.characters ?? []
    }

    /// 활성 문서의 스냅샷 (문서 일치 확인 포함).
    private var snapshot: KnowledgeSnapshot? {
        guard let snapshot = indexer?.snapshot, snapshot.entryID == store.activeID
        else { return nil }
        return snapshot
    }






    private var genreBinding: Binding<String> {
        Binding(
            get: { store.activeEntry?.genre ?? "" },
            set: { value in
                if let id = store.activeEntry?.id { store.setGenre(value, for: id) }
            }
        )
    }

    /// 카드 필드 편집 → 스토어 upsert. 잠금·자동등록 해제 규칙은 **스토어 커밋
    /// 경계**로 옮겨졌다 (#49/H1) — 뷰는 값만 넘긴다. 저장도 스토어 정책을 따른다:
    /// 연속 타이핑은 디바운스, 새 카드·잠금 토글은 즉시.
    private func binding(for card: CharacterCard) -> Binding<CharacterCard> {
        Binding(
            get: {
                store.activeEntry?.characters?.first(where: { $0.id == card.id }) ?? card
            },
            set: { updated in
                guard let id = store.activeEntry?.id else { return }
                store.upsertCharacter(updated, in: id)
            }
        )
    }

    private func addCard() {
        guard let id = store.activeEntry?.id else { return }
        store.upsertCharacter(CharacterCard(), in: id)
    }

    private func remove(_ card: CharacterCard) {
        guard let id = store.activeEntry?.id else { return }
        store.removeCharacter(card.id, from: id)
    }
    // MARK: - 프레젠테이션 위임 (#61 PR4 — 본체는 Knowledge/CharacterSummarizer)
    // 기존 호출부·테스트(ObservationFanOutTests) 호환용 얇은 게이트.

    static func understanding(
        of characterID: UUID, snapshot: KnowledgeSnapshot
    ) -> [String] {
        CharacterSummarizer.understanding(of: characterID, snapshot: snapshot)
    }

    static func chronicle(
        of characterID: UUID, snapshot: KnowledgeSnapshot
    ) -> [String] {
        CharacterSummarizer.chronicle(of: characterID, snapshot: snapshot)
    }

    static func knowledgeLines(
        of characterID: UUID, snapshot: KnowledgeSnapshot
    ) -> [(text: String, jump: String?)] {
        CharacterSummarizer.knowledgeLines(of: characterID, snapshot: snapshot)
    }

    static func relationLines(
        of characterID: UUID, snapshot: KnowledgeSnapshot, names: [UUID: String]
    ) -> [(text: String, jump: String?)] {
        CharacterSummarizer.relationLines(of: characterID, snapshot: snapshot, names: names)
    }

    static func conversationLines(
        of card: CharacterCard, snapshot: KnowledgeSnapshot, names: [UUID: String]
    ) -> [(text: String, jump: String?)] {
        CharacterSummarizer.conversationLines(of: card, snapshot: snapshot, names: names)
    }

}

/// 감지된 인물 후보 검토 목록 (M6-8, PLAN §7) — 후보 전부를 나열한다.
/// "등록"은 카드 생성 + 백그라운드 프로파일링, "무시"는 거부 목록행(재질문 금지).
/// 답하기 전엔 아무것도 바꾸지 않는다 — 자동 등록 절대 금지 (CLAUDE.md §3).
private struct CandidateReviewList: View {
    @ObservedObject var indexer: BackgroundIndexer
    @ObservedObject var store: EntryStore
    let theme: PurloryTheme

    /// 후보 근거 요약 한 줄 — 신뢰도·별칭 변형까지 (요구사항 §16·§17).
    fileprivate func candidateDetail(_ candidate: CharacterDetector.Candidate) -> String {
        var pieces = ["언급 \(candidate.mentions)회 · 씬 \(candidate.sceneCount)곳"]
        pieces.append("신뢰 \(candidate.confidence.rawValue)")
        if !candidate.aliasForms.isEmpty {
            pieces.append("표기: \(candidate.aliasForms.joined(separator: "·"))")
        }
        return pieces.joined(separator: " · ")
    }

    var body: some View {
        if indexer.candidatesEntryID == store.activeID,
            !indexer.characterCandidates.isEmpty
        {
            VStack(spacing: 4) {
                ForEach(indexer.characterCandidates, id: \.name) { candidate in
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.badge.questionmark")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.novelC)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(
                                candidate.aliasOfKnown.map {
                                    "'\(candidate.name)' — '\($0)'의 별칭일까요?"
                                } ?? "'\(candidate.name)' — 인물로 등록할까요?"
                            )
                            .purloryUIFont(11.5, .medium)
                            .foregroundStyle(theme.inkC)
                            Text(candidateDetail(candidate))
                                .purloryUIFont(10)
                                .foregroundStyle(theme.ink3C)
                        }
                        Spacer()
                        // 별칭 후보 (요구사항 §17) — 병합은 사용자 결정.
                        if let owner = candidate.aliasOfKnown {
                            Button("별칭으로") {
                                indexer.approveCandidateAsAlias(candidate, of: owner)
                            }
                            .purloryUIFont(11, .semibold)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(theme.novelC)
                        }
                        if candidate.aliasOfKnown == nil {
                            Button("등록") { indexer.approveCandidate(candidate) }
                                .purloryUIFont(11, .semibold)
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .tint(theme.novelC)
                        } else {
                            Button("새 인물") { indexer.approveCandidate(candidate) }
                                .purloryUIFont(11)
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                        Button("무시") { indexer.rejectCandidate(candidate) }
                            .purloryUIFont(11)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: PurloryRadius.md, style: .continuous)
                            .fill(theme.novelBgC)
                    )
                }
            }
        }
    }
}

/// 인물 카드 한 장 — 이름·별칭·소개(편집 가능) + 자동 이해(열람 전용) + 잠금 +
/// 연대기(M7 — 사건·상태 변화 담화 순서 열람).
struct CharacterCardRow: View {
    @Binding var card: CharacterCard
    let theme: PurloryTheme
    /// 백그라운드가 이해한 것 — 읽기 전용 표시 (빈 배열이면 숨김).
    let understanding: [String]
    /// 인물 연대기 — 사건 요약(+델타) 담화 순서 (빈 배열이면 숨김).
    let chronicle: [String]
    /// 앎 — 이 인물이 아는/의심하는/오해하는/숨기는 것 (v4, 요구사항 §11).
    let knowledge: [(text: String, jump: String?)]
    /// 관계 변화 이력 (v4, 요구사항 §12).
    let relations: [(text: String, jump: String?)]
    /// 대화 인덱스 (v4, 요구사항 §13) — 클릭 → 원문 대화로 이동.
    let conversations: [(text: String, jump: String?)]
    /// 원문 점프 (requestSearchJump 통로).
    var onJump: ((String) -> Void)?
    let onDelete: () -> Void
    @State private var deleteHovered = false
    @State private var chronicleExpanded = false
    @State private var knowledgeExpanded = false
    @State private var relationsExpanded = false
    @State private var conversationsExpanded = false
    @State private var traitsDraft = ""
    @FocusState private var traitsFocused: Bool

    private var nameField: some View {
        TextField("이름", text: $card.name)
            .accessibilityIdentifier("purlory.writer.character.name.\(card.id)")
            .textFieldStyle(.roundedBorder).purloryUIFont(12)
    }
    private var aliasesField: some View {
        TextField("별칭·호칭 (쉼표 구분)", text: $card.aliases)
            .textFieldStyle(.roundedBorder).purloryUIFont(12)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                // Attached index tabs can be narrower than the legacy writer sheet.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        nameField.frame(width: 110)
                        aliasesField.frame(minWidth: 100)
                    }
                    VStack(spacing: 6) { nameField; aliasesField }
                }.frame(maxWidth: .infinity)
                // 자동 등록 표식 (요구사항 §16) — HIGH 신뢰 감지로 만들어진 카드.
                // 편집하면 사라진다. 삭제는 오른쪽 휴지통 한 번이다.
                if card.autoRegistered == true {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.novelC)
                        .help("자동 등록된 인물 — 이름·별칭을 고치거나 삭제할 수 있어요")
                }
                // 잠금 토글 — 잠기면 자동 프로파일링이 소개를 채우지 않는다.
                Button {
                    card.locked = card.locked == true ? nil : true
                } label: {
                    Image(systemName: card.locked == true ? "lock.fill" : "lock.open")
                        .font(.system(size: 11))
                        .foregroundStyle(card.locked == true ? theme.novelC : theme.ink3C)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(
                    card.locked == true
                        ? "잠김 — 자동 이해가 이 카드를 고치지 않아요"
                        : "열림 — 소개가 비어 있으면 자동 이해가 채울 수 있어요")
                .accessibilityLabel(Text(card.locked == true ? "카드 잠금 해제" : "카드 잠금"))  // #55
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(deleteHovered ? theme.novelC : theme.ink3C)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { deleteHovered = $0 }
                .help("인물 삭제")
                .accessibilityLabel(Text("인물 삭제"))  // #55
            }
            TextField("성격·말투·관계 — 짧게 (예: 신중하고 직설적. 반말, \"…거든\" 버릇)",
                text: $card.note, axis: .vertical)
                .accessibilityIdentifier("purlory.writer.character.note.\(card.id)")
                .textFieldStyle(.roundedBorder)
                .purloryUIFont(12)
                .lineLimit(2...4)
            HStack(spacing: 6) {
                TextField("역할", text: Binding(get: { card.role ?? "" }, set: { card.role = $0 }))
                    .accessibilityIdentifier("purlory.writer.character.role.\(card.id)")
                TextField("특성 (쉼표 구분)", text: $traitsDraft)
                    .focused($traitsFocused)
                    .onAppear { traitsDraft = (card.traits ?? []).joined(separator: ", ") }
                    .onChange(of: traitsDraft) { _, value in
                        card.traits = value.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    }
                    .onChange(of: card.traits) { _, value in
                        if !traitsFocused { traitsDraft = (value ?? []).joined(separator: ", ") }
                    }.accessibilityIdentifier("purlory.writer.character.traits.\(card.id)")
            }.textFieldStyle(.roundedBorder).purloryUIFont(11)
            // 자동 이해 — 예측 카드 줄과 같은 질의 결과의 열람 (CLAUDE.md §1-5).
            // 편집은 원문·카드에서 한다 — 파생 지식을 직접 고치게 하면 원문과
            // 어긋난 채 다음 패스가 도로 덮는다 (원문이 유일한 진실, §2-1).
            if !understanding.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(understanding, id: \.self) { line in
                        Text(line)
                            .purloryUIFont(10.5)
                            .foregroundStyle(theme.ink2C)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
            }
            // 연대기 (M7) — 접힌 채 시작, 사건 수만 보인다 (조용한 UI).
            if !chronicle.isEmpty {
                Button {
                    chronicleExpanded.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: chronicleExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                        Text("연대기 · 사건 \(chronicle.count)")
                            .purloryUIFont(10.5, .medium)
                    }
                    .foregroundStyle(theme.ink3C)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if chronicleExpanded {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(chronicle.enumerated()), id: \.offset) { index, line in
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text("\(index + 1)")
                                    .font(PurloryFonts.monoUI(9))
                                    .foregroundStyle(theme.ink3C)
                                Text(line)
                                    .purloryUIFont(10.5)
                                    .foregroundStyle(theme.ink2C)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
                }
            }
            // 앎 (v4) — 이 인물이 아는 것만이 예측 대사에 실린다 (§11).
            jumpSection(
                title: "앎", count: knowledge.count,
                expanded: $knowledgeExpanded, entries: knowledge)
            // 관계 변화 (v4, §12) — 방향 쌍별 변화 이력.
            jumpSection(
                title: "관계", count: relations.count,
                expanded: $relationsExpanded, entries: relations)
            // 대화 인덱스 (v4, §13) — 클릭하면 원문 대화로 이동.
            jumpSection(
                title: "대화", count: conversations.count,
                expanded: $conversationsExpanded, entries: conversations)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: PurloryRadius.md, style: .continuous)
                .fill(theme.chipC)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PurloryRadius.md, style: .continuous)
                .strokeBorder(theme.chipBorderC, lineWidth: 1)
        )
    }

    /// 접힘 섹션 공용 — 연대기와 같은 조용한 UI 문법 (제목 · 개수, 접힌 채 시작).
    /// 항목에 점프 질의가 있으면 클릭 → 원문 이동.
    @ViewBuilder private func jumpSection(
        title: String, count: Int,
        expanded: Binding<Bool>, entries: [(text: String, jump: String?)]
    ) -> some View {
        if count > 0 {
            Button {
                expanded.wrappedValue.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(
                        systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right"
                    )
                    .font(.system(size: 8, weight: .semibold))
                    Text("\(title) · \(count)")
                        .purloryUIFont(10.5, .medium)
                }
                .foregroundStyle(theme.ink3C)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded.wrappedValue {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        if let jump = entry.jump, let onJump {
                            Button {
                                onJump(jump)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Image(systemName: "arrow.right.circle")
                                        .font(.system(size: 8))
                                        .foregroundStyle(theme.blueC)
                                    Text(entry.text)
                                        .purloryUIFont(10.5)
                                        .foregroundStyle(theme.ink2C)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .multilineTextAlignment(.leading)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("원문으로 이동")
                        } else {
                            Text(entry.text)
                                .purloryUIFont(10.5)
                                .foregroundStyle(theme.ink2C)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
            }
        }
    }
}
