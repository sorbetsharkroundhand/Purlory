import SwiftUI

/// Existing author-data tools use the project owner directly, without a legacy store.
struct ProjectWriterToolsView: View {
    @ObservedObject var session: ProjectSession
    @ObservedObject var completion: CompletionController
    @ObservedObject var editorRequests: ProjectEditorRequests
    let section: SidebarSection
    let theme: PurloryTheme
    var spatial: SpatialWorkspaceController? = nil
    var indexer: BackgroundIndexer? = nil
    var embedded = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let snapshot = session.selectedDocumentSnapshot,
                let writer = try? read(snapshot) {
                Group {
                    if embedded { content(writer, snapshot) }
                    else { ScrollView { content(writer, snapshot) } }
                }
                .disabled(!session.isEditorEditable)
            } else {
                Text("문서를 선택하거나 작가 설정을 확인해 주세요.")
                    .purloryUIFont(11).foregroundStyle(theme.ink3C).padding(14)
            }
        }
        .alert("설정을 변경할 수 없어요", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("확인") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }

    private func content(_ writer: WriterDocumentData, _ snapshot: ProjectDocumentSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            switch section {
            case .bible: bible(writer, snapshot)
            case .narrative: records(writer, snapshot)
            case .context: context(writer, snapshot)
            default: EmptyView()
            }
        }.purloryUIFont(11).foregroundStyle(theme.ink2C).padding(embedded ? 8 : 14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func activeKnowledge(for snapshot: ProjectDocumentSnapshot) -> KnowledgeSnapshot? {
        guard let indexer, indexer.snapshotRuntimeIdentity == snapshot.identity,
              let knowledge = indexer.snapshot,
              knowledge.entryID == snapshot.identity.key.documentID.rawValue else { return nil }
        return knowledge
    }

    @ViewBuilder private func bible(_ writer: WriterDocumentData, _ snapshot: ProjectDocumentSnapshot) -> some View {
        // Mode changes do not erase the author's existing settings or their edit route.
        if snapshot.mode == .fiction || !(writer.genre ?? "").isEmpty
            || !writer.characters.isEmpty || !writer.rejectedCharacterNames.isEmpty {
            if snapshot.mode == .fiction, let indexer {
                HStack {
                    Text("작품 설정 및 인물").purloryUIFont(12, .semibold).foregroundStyle(theme.inkC)
                    Spacer()
                    ManualIndexButton(indexer: indexer, theme: theme)
                }
                ProjectCandidateReviewList(indexer: indexer, session: session, snapshot: snapshot, theme: theme)
            }
            TextField("장르 (예: 판타지 · 로맨스 · 추리)", text: binding(
                writer.genre ?? "", snapshot: snapshot, get: { $0.genre ?? "" }, edit: { .genre($0) }))
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("purlory.writer.genre")
            Text("직접 적은 설정은 이 문서에 저장돼요.")
                .foregroundStyle(theme.ink3C)
            let knowledge = activeKnowledge(for: snapshot)
            let names = Dictionary(uniqueKeysWithValues: writer.characters.map { ($0.id, $0.name) })
            ForEach(writer.characters) { card in
                let understanding = knowledge.map { CharacterSummarizer.understanding(of: card.id, snapshot: $0) } ?? []
                let chronicle = knowledge.map { CharacterSummarizer.chronicle(of: card.id, snapshot: $0) } ?? []
                let knowledgeLines = knowledge.map { CharacterSummarizer.knowledgeLines(of: card.id, snapshot: $0) } ?? []
                let relations = knowledge.map { CharacterSummarizer.relationLines(of: card.id, snapshot: $0, names: names) } ?? []
                let conversations = knowledge.map { CharacterSummarizer.conversationLines(of: card, snapshot: $0, names: names) } ?? []
                compactCard(card.id.uuidString, title: card.name.isEmpty ? "새 인물" : card.name, detail: card.note, term: card.name) {
                    CharacterCardRow(
                        card: binding(card, snapshot: snapshot,
                            get: { $0.characters.first { $0.id == card.id } }, edit: { .character($0) }),
                        theme: theme,
                        understanding: understanding,
                        chronicle: chronicle,
                        knowledge: knowledgeLines,
                        relations: relations,
                        conversations: conversations,
                        onJump: { query in jumpToQuery(query, in: snapshot) },
                        onDelete: { apply(.removeCharacter(card.id), identity: snapshot.identity) }
                    )
                    if !card.name.isEmpty { evidence(EvidenceAnchor(documentID: writer.documentID, quote: card.name), snapshot) }
                }
            }
            if snapshot.mode == .fiction {
                Button("인물 추가") {
                    let card = CharacterCard()
                    apply(.character(card), identity: snapshot.identity)
                    spatial?.expandedItem = card.id.uuidString
                }
                .accessibilityIdentifier("purlory.writer.add-character")
            }
            if !writer.rejectedCharacterNames.isEmpty {
                Divider(); Text("거부한 인물 후보")
                ForEach(Array(writer.rejectedCharacterNames.enumerated()), id: \.offset) { _, name in
                    HStack {
                        Text(name); Spacer()
                        Button("복원") { apply(.restoreName(name), identity: snapshot.identity) }
                    }
                }
            }
        } else { Text("아직 저장된 인물이나 작품 정보가 없어요.") }
    }

    @ViewBuilder private func records(_ writer: WriterDocumentData, _ snapshot: ProjectDocumentSnapshot) -> some View {
        Text("작가 수정과 기록").purloryUIFont(12, .semibold)
        if writer.narrativeOverrides.isEmpty && writer.decisions.isEmpty && writer.recordedConversations.isEmpty {
            Text("아직 저장된 수정이나 기록이 없어요.").foregroundStyle(theme.ink3C)
        }
        ForEach(Array(writer.narrativeOverrides.enumerated()), id: \.offset) { index, value in
            compactCard("override.\(value.id)", title: overrideLabel(value.kind), detail: value.value, term: value.anchor ?? "") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(overrideLabel(value.kind)) · \(index + 1)")
                    Spacer()
                    removeButton("수정 삭제") { apply(.removeOverride(value.kind, value.key), identity: snapshot.identity) }
                }
                TextField("수정 내용", text: binding(value.value, snapshot: snapshot,
                    get: { $0.narrativeOverrides.last { $0.id == value.id }?.value }, edit: {
                        var updated = value; updated.value = $0; updated.updatedAt = .now
                        return .override(updated)
                    }), axis: .vertical).textFieldStyle(.roundedBorder)
                if let quote = value.anchor, !quote.isEmpty {
                    evidence(EvidenceAnchor(documentID: writer.documentID, quote: quote), snapshot)
                }
            }
            Divider()
            }
        }
        ForEach(writer.decisions) { value in
            compactCard("decision.\(value.id)", title: decisionLabel(value.kind), detail: value.statement, term: value.evidence.first?.quote ?? "") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(decisionLabel(value.kind)); Spacer()
                    removeButton("판정 삭제") { apply(.removeDecision(value.id), identity: snapshot.identity) }
                }
                TextField("작가 판정", text: binding(value.statement, snapshot: snapshot,
                    get: { $0.decisions.first { $0.id == value.id }?.statement }, edit: {
                        var updated = value; updated.statement = $0; return .decision(updated)
                    }), axis: .vertical).textFieldStyle(.roundedBorder)
                ForEach(Array(value.evidence.enumerated()), id: \.offset) { _, anchor in evidence(anchor, snapshot) }
            }
            Divider()
            }
        }
        ForEach(writer.recordedConversations) { record in
            compactCard("record.\(record.id)", title: "기록한 대화", detail: record.firstLine, term: record.firstLine) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("기록한 대화"); Spacer()
                    removeButton("대화 기록 삭제") { apply(.removeRecord(record.id), identity: snapshot.identity) }
                }
                Text("\(record.firstLine) … \(record.lastLine)").textSelection(.enabled)
                evidence(EvidenceAnchor(documentID: writer.documentID, quote: record.firstLine), snapshot)
            }
            Divider()
            }
        }
    }

    @ViewBuilder private func compactCard<Content: View>(_ id: String, title: String, detail: String, term: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        if let spatial { WorkspaceCompactCard(model: spatial, id: id, title: title, detail: detail, term: term, theme: theme, content: content) }
        else { content() }
    }

    @ViewBuilder private func context(_ writer: WriterDocumentData, _ snapshot: ProjectDocumentSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("문맥 모드").purloryUIFont(11, .medium).foregroundStyle(theme.inkC)
                Spacer()
                Picker("문맥 모드", selection: Binding(
                    get: { completion.settings.ghostContextMode },
                    set: { completion.changeContextMode(to: $0) }
                )) {
                    ForEach(GhostContextMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 190)
                .accessibilityIdentifier("purlory.writer.context.mode")
            }
            Text("A/B는 요약을 넣지 않아요. 모델이 준비되면 원문 범위를 넓히되, 모델의 한도 안에서 읽어요. 기본은 C예요.")
                .purloryUIFont(10).foregroundStyle(theme.ink3C)
        }
        Divider()
        if let report = completion.lastContextReport, report.runtimeIdentity == snapshot.identity {
            HStack {
                Text("\(report.contextMode.label) · 최근 제안이 실제로 참고한 정보예요. 커서 앞 원문을 함께 읽어요.")
                    .foregroundStyle(theme.ink3C)
                Spacer()
                Text("\(report.items.count)개 항목")
                    .purloryUIFont(10, .medium).foregroundStyle(theme.ink3C)
            }
            ForEach(Array(report.items.enumerated()), id: \.offset) { _, item in
                let pinned = !item.stableKey.isEmpty && NarrativeOverrides(writer.narrativeOverrides).value(.contextPin, key: item.stableKey) != nil
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(item.kind.rawValue)
                            .purloryUIFont(9.5, .semibold)
                            .foregroundStyle(theme.novelC)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(theme.novelBgC))
                        if pinned || item.pinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(theme.novelC)
                        }
                        Spacer()
                        if !item.stableKey.isEmpty {
                            Button(pinned ? "고정 해제" : "고정") {
                                apply(pinned ? .removeOverride(.contextPin, item.stableKey)
                                    : .override(NarrativeOverride(kind: .contextPin, key: item.stableKey, value: "고정")),
                                    identity: snapshot.identity)
                            }
                            .controlSize(.mini)
                            Button("제외") {
                                apply(.override(NarrativeOverride(kind: .contextExclude, key: item.stableKey, value: "제외")),
                                    identity: snapshot.identity)
                            }
                            .controlSize(.mini)
                        }
                    }
                    Text(item.text).textSelection(.enabled)
                    if let anchor = item.evidence {
                        evidence(anchor, snapshot)
                    } else if let quote = item.jumpQuery {
                        evidence(EvidenceAnchor(documentID: writer.documentID, quote: quote), snapshot)
                    } else if let offset = item.jumpUTF16,
                        let quote = NarrativeView.jumpSnippet(in: snapshot.body, atUTF16: offset) {
                        evidence(EvidenceAnchor(documentID: writer.documentID, quote: quote, utf16Hint: offset), snapshot)
                    }
                }
                Divider()
            }
        } else { Text("아직 이 문서의 제안 기록이 없어요.").foregroundStyle(theme.ink3C) }
        let excluded = writer.narrativeOverrides.filter { $0.kind == .contextExclude }
        if !excluded.isEmpty {
            Text("제외한 항목").purloryUIFont(12, .semibold)
            ForEach(Array(excluded.enumerated()), id: \.offset) { _, value in
                HStack {
                    Text(ContextInspectorView.readableExclusion(value.key)); Spacer()
                    Button("복원") { apply(.removeOverride(.contextExclude, value.key), identity: snapshot.identity) }
                }
            }
        }
    }

    private func jumpToQuery(_ query: String, in snapshot: ProjectDocumentSnapshot) {
        guard session.runtimeIdentity == snapshot.identity, let project = session.activeProject else { return }
        let resolved = SourceAnchor.resilientQuery(for: query, in: snapshot.body) ?? query
        let anchor = EvidenceAnchor(documentID: snapshot.identity.key.documentID, quote: resolved)
        if let reference = OriginalSourceReference.exact(anchor, in: project) {
            let inspection = ProjectSourceInspection(session: session)
            if let token = inspection.capture() { editorRequests.jump(to: reference, inspection: inspection, token: token, in: session) }
        } else {
            editorRequests.issueJump(documentID: snapshot.identity.key.documentID, query: resolved)
        }
    }

    @ViewBuilder private func evidence(_ anchor: EvidenceAnchor, _ snapshot: ProjectDocumentSnapshot) -> some View {
        Text(anchor.quote).purloryUIFont(10).foregroundStyle(theme.ink3C).textSelection(.enabled)
        if let project = session.activeProject, let reference = OriginalSourceReference.exact(anchor, in: project) {
            Button("원문 보기") {
                guard session.runtimeIdentity == snapshot.identity else { return }
                let inspection = ProjectSourceInspection(session: session)
                if let token = inspection.capture() { editorRequests.jump(to: reference, inspection: inspection, token: token, in: session) }
            }
        } else { Text("원문을 찾을 수 없어요. 설정은 보관돼요.").foregroundStyle(theme.ink3C) }
    }

    private func removeButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "trash") }
            .buttonStyle(.plain).accessibilityLabel(label).help(label)
    }

    private func read(_ snapshot: ProjectDocumentSnapshot) throws -> WriterDocumentData {
        let id = snapshot.identity.key.documentID
        return try WriterDocumentData.decode(snapshot.userData[WriterDocumentData.key(for: id)], documentID: id)
    }

    private func binding<Value>(_ initial: Value, snapshot: ProjectDocumentSnapshot,
                                get: @escaping (WriterDocumentData) -> Value?,
                                edit: @escaping (Value) -> ProjectWriterEdit) -> Binding<Value> {
        let field = WriterToolMutation(identity: snapshot.identity)
        return Binding(get: {
            guard let current = session.selectedDocumentSnapshot, current.identity.key == snapshot.identity.key,
                let writer = try? read(current) else { return initial }
            return get(writer) ?? initial
        }, set: { value in
            do { try field.perform(edit(value), in: session) }
            catch { errorMessage = error.localizedDescription }
        })
    }

    private func apply(_ edit: ProjectWriterEdit, identity: ProjectRuntimeIdentity) {
        do { try ProjectWriterEditing.perform(edit, in: session, identity: identity) }
        catch { errorMessage = error.localizedDescription }
    }

    private func overrideLabel(_ kind: NarrativeOverride.Kind) -> String {
        switch kind {
        case .sceneTitle: "장면 제목"
        case .sceneType: "장면 유형"
        case .eventImportance: "사건 중요도"
        case .eventSummary: "사건 요약"
        case .contextPin: "컨텍스트 고정"
        case .contextExclude: "컨텍스트 제외"
        default: "서사 수정"
        }
    }

    private func decisionLabel(_ kind: WriterDecision.Kind) -> String {
        switch kind {
        case .intentional: "의도한 설정"
        case .dismissed: "숨긴 제안"
        case .confirmed: "확인한 설정"
        }
    }
}
