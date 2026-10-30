import SwiftUI

struct WorkspaceCharacterCards: View {
    @ObservedObject var session: ProjectSession
    @ObservedObject var requests: ProjectEditorRequests
    @ObservedObject var completion: CompletionController
    @ObservedObject var model: SpatialWorkspaceController
    var indexer: BackgroundIndexer? = nil
    let theme: PurloryTheme
    private struct Record: Identifiable {
        let documentID: WritingDocumentID
        let card: CharacterCard
        var id: UUID { card.id }
    }
    private var records: [Record] {
        guard let project = session.activeProject else { return [] }
        var seen: Set<UUID> = []
        return project.documents.filter { !project.trashedDocumentIDs.contains($0.id) }.flatMap { document in
            let writer = try? WriterDocumentData.decode(project.userData[WriterDocumentData.key(for: document.id)], documentID: document.id)
            return (writer?.characters ?? []).filter { seen.insert($0.id).inserted }.map { Record(documentID: document.id, card: $0) }
        }
    }
    private func knowledge(for documentID: WritingDocumentID) -> KnowledgeSnapshot? {
        guard let indexer, let snapshot = indexer.snapshot,
              snapshot.entryID == documentID.rawValue else { return nil }
        return snapshot
    }
    var body: some View {
        let allNames = Dictionary(uniqueKeysWithValues: records.map { ($0.card.id, $0.card.name) })
        return VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if let indexer, let snapshot = session.selectedDocumentSnapshot, snapshot.mode == .fiction {
                        ProjectCandidateReviewList(indexer: indexer, session: session, snapshot: snapshot, theme: theme)
                    }
                    ForEach(records) { record in
                        let card = record.card
                        let snap = knowledge(for: record.documentID)
                        let understanding = snap.map { CharacterSummarizer.understanding(of: card.id, snapshot: $0) } ?? []
                        let chronicle = snap.map { CharacterSummarizer.chronicle(of: card.id, snapshot: $0) } ?? []
                        let knowledgeLines = snap.map { CharacterSummarizer.knowledgeLines(of: card.id, snapshot: $0) } ?? []
                        let relations = snap.map { CharacterSummarizer.relationLines(of: card.id, snapshot: $0, names: allNames) } ?? []
                        let conversations = snap.map { CharacterSummarizer.conversationLines(of: card, snapshot: $0, names: allNames) } ?? []
                        WorkspaceCompactCard(model: model, id: card.id.uuidString, title: card.name.isEmpty ? "새 인물" : card.name,
                            detail: card.note, term: card.name, theme: theme, initial: String(card.name.prefix(1)),
                            role: card.role ?? "", sourceDocumentID: record.documentID) {
                            Text(card.note.isEmpty ? "아직 적은 소개가 없어요." : card.note).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                            if !understanding.isEmpty {
                                VStack(alignment: .leading, spacing: 3) {
                                    ForEach(understanding, id: \.self) { line in
                                        HStack(alignment: .top, spacing: 4) {
                                            Image(systemName: "sparkle").font(.system(size: 8.5)).foregroundStyle(theme.novelC).padding(.top, 2)
                                            Text(line).purloryUIFont(10).foregroundStyle(theme.ink2C)
                                        }
                                    }
                                }.padding(.top, 2)
                            }
                            if !chronicle.isEmpty {
                                DisclosureGroup("연대기 (\(chronicle.count))") {
                                    VStack(alignment: .leading, spacing: 3) {
                                        ForEach(Array(chronicle.enumerated()), id: \.offset) { _, line in
                                            Text(line).purloryUIFont(10).foregroundStyle(theme.ink2C)
                                        }
                                    }.padding(.top, 2)
                                }.purloryUIFont(10, .medium).foregroundStyle(theme.ink2C)
                            }
                            if !knowledgeLines.isEmpty {
                                jumpableSection("아는 것 (\(knowledgeLines.count))", items: knowledgeLines, documentID: record.documentID)
                            }
                            if !relations.isEmpty {
                                jumpableSection("관계 (\(relations.count))", items: relations, documentID: record.documentID)
                            }
                            if !conversations.isEmpty {
                                jumpableSection("대화 (\(conversations.count))", items: conversations, documentID: record.documentID)
                            }
                            HStack(alignment: .top, spacing: 4) {
                                Text((card.traits ?? []).map { "#\($0)" }.joined(separator: "  "))
                                    .purloryUIFont(9.5).foregroundStyle(theme.workspaceMutedC)
                                Spacer(minLength: 4)
                                Button("편집") {
                                    session.selectDocument(record.documentID)
                                    model.selectTile(.characters); model.pouchSection = .object
                                }.buttonStyle(.plain).purloryUIFont(10, .medium).foregroundStyle(theme.ink2C)
                                if let reference = reference(for: record) {
                                    Button("본문 이동 →") { jump(reference) }.buttonStyle(.plain).purloryUIFont(10, .medium).foregroundStyle(theme.novelC)
                                }
                            }
                        }
                        .contextMenu {
                            Button("인물 편집…") { session.selectDocument(record.documentID); model.selectTile(.characters); model.pouchSection = .object }
                            Button("작품 정보 편집…") { model.selectTile(.characters); model.pouchSection = .object }
                        }
                        .accessibilityAction(named: Text("인물 편집")) { session.selectDocument(record.documentID); model.selectTile(.characters); model.pouchSection = .object }
                    }
                    if records.isEmpty {
                        Text("아직 등록한 인물이 없어요. 아래 버튼이나 주머니의 인물·작품 도구에서 추가할 수 있어요.")
                            .purloryUIFont(11).foregroundStyle(theme.workspaceMutedC).padding(2)
                    }
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 6) {
                Button {
                    model.selectTile(.characters); model.pouchSection = .object
                } label: {
                    Label("인물·작품 편집", systemImage: "slider.horizontal.3").purloryUIFont(10.5, .medium)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(theme.ink2C)
                .accessibilityIdentifier("purlory.characters.edit-sheet")
                Spacer(minLength: 4)
                if let indexer, session.activeProject?.mode == .fiction {
                    ManualIndexButton(indexer: indexer, theme: theme)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .contextMenu { Button("작품 정보 편집…") { model.selectTile(.characters); model.pouchSection = .object } }
    }
    private func jumpableSection(_ title: String, items: [(text: String, jump: String?)], documentID: WritingDocumentID) -> some View {
        DisclosureGroup(title) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    if let query = item.jump {
                        Button {
                            jumpQuery(query, documentID: documentID)
                        } label: {
                            HStack(alignment: .top, spacing: 4) {
                                Text(item.text).purloryUIFont(10).foregroundStyle(theme.ink2C).multilineTextAlignment(.leading)
                                Image(systemName: "arrow.up.forward").font(.system(size: 8)).foregroundStyle(theme.novelC)
                            }
                        }.buttonStyle(.plain)
                    } else {
                        Text(item.text).purloryUIFont(10).foregroundStyle(theme.ink2C)
                    }
                }
            }.padding(.top, 2)
        }.purloryUIFont(10, .medium).foregroundStyle(theme.ink2C)
    }
    private func jumpQuery(_ query: String, documentID: WritingDocumentID) {
        guard let project = session.activeProject, let doc = project.documents.first(where: { $0.id == documentID }) else { return }
        let resolved = SourceAnchor.resilientQuery(for: query, in: doc.body) ?? query
        if let ref = OriginalSourceReference.exact(EvidenceAnchor(documentID: documentID, quote: resolved), in: project) {
            jump(ref)
        } else {
            requests.issueJump(documentID: documentID, query: resolved)
        }
    }
    private func reference(for record: Record) -> OriginalSourceReference? {
        guard let project = session.activeProject, let document = project.documents.first(where: { $0.id == record.documentID }), !record.card.name.isEmpty else { return nil }
        let source = document.body as NSString, name = source.range(of: record.card.name)
        guard name.location != NSNotFound else { return nil }
        let paragraph = source.paragraphRange(for: name)
        return .exact(.init(documentID: document.id, quote: source.substring(with: paragraph), utf16Hint: paragraph.location), in: project)
    }
    private func jump(_ reference: OriginalSourceReference) {
        let inspection = ProjectSourceInspection(session: session)
        if let token = inspection.capture() { requests.jump(to: reference, inspection: inspection, token: token, in: session) }
    }
}

struct ProjectCandidateReviewList: View {
    @ObservedObject var indexer: BackgroundIndexer
    @ObservedObject var session: ProjectSession
    let snapshot: ProjectDocumentSnapshot
    let theme: PurloryTheme

    private func candidateDetail(_ candidate: CharacterDetector.Candidate) -> String {
        var pieces = ["언급 \(candidate.mentions)회 · 씬 \(candidate.sceneCount)곳"]
        pieces.append("신뢰 \(candidate.confidence.rawValue)")
        if !candidate.aliasForms.isEmpty {
            pieces.append("표기: \(candidate.aliasForms.joined(separator: "·"))")
        }
        return pieces.joined(separator: " · ")
    }

    var body: some View {
        if indexer.candidatesEntryID == snapshot.identity.key.documentID.rawValue,
           !indexer.characterCandidates.isEmpty {
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
                            .purloryUIFont(11, .medium)
                            .foregroundStyle(theme.inkC)
                            Text(candidateDetail(candidate))
                                .purloryUIFont(9.5)
                                .foregroundStyle(theme.ink3C)
                        }
                        Spacer(minLength: 4)
                        if let owner = candidate.aliasOfKnown {
                            Button("별칭") {
                                indexer.approveCandidateAsAlias(candidate, of: owner, in: session, identity: snapshot.identity)
                            }
                            .purloryUIFont(10.5, .semibold)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                            .tint(theme.novelC)
                        }
                        if candidate.aliasOfKnown == nil {
                            Button("등록") {
                                indexer.approveCandidate(candidate, in: session, identity: snapshot.identity)
                            }
                            .purloryUIFont(10.5, .semibold)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                            .tint(theme.novelC)
                        } else {
                            Button("새 인물") {
                                indexer.approveCandidate(candidate, in: session, identity: snapshot.identity)
                            }
                            .purloryUIFont(10.5)
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                        Button("무시") {
                            indexer.rejectCandidate(candidate, in: session, identity: snapshot.identity)
                        }
                        .purloryUIFont(10.5)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    .padding(7)
                    .background(
                        RoundedRectangle(cornerRadius: PurloryRadius.md, style: .continuous)
                            .fill(theme.novelBgC)
                    )
                }
            }
        }
    }
}
