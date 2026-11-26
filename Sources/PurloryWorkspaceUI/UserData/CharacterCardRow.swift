import SwiftUI
import PurloryDocumentEngine
import PurloryInference
import PurloryIntelligence

/// Editable character card row with read-only derived understanding, chronicle, and source jump links.
struct CharacterCardRow: View {
    @Binding var card: CharacterCard
    let theme: PurloryTheme
    let understanding: [String]
    let chronicle: [String]
    let knowledge: [(text: String, jump: String?)]
    let relations: [(text: String, jump: String?)]
    let conversations: [(text: String, jump: String?)]
    var onJump: ((String) -> Void)?
    let onDelete: () -> Void
    @State private var deleteHovered = false
    @State private var narrativeArcExpanded = false
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
                if card.autoRegistered == true {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.novelC)
                        .help("자동 등록된 인물 — 이름·별칭을 고치거나 삭제할 수 있어요")
                }
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
                .accessibilityLabel(Text(card.locked == true ? "카드 잠금 해제" : "카드 잠금"))
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
                .accessibilityLabel(Text("인물 삭제"))
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
            Button {
                narrativeArcExpanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: narrativeArcExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Text("서사 동학 (동기·목표·갈등)")
                        .purloryUIFont(10.5, .medium)
                    if card.hasNarrativeArc {
                        Circle()
                            .fill(theme.novelC)
                            .frame(width: 5, height: 5)
                    }
                    Spacer()
                }
                .foregroundStyle(card.hasNarrativeArc ? theme.ink2C : theme.ink3C)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("purlory.writer.character.arc.toggle.\(card.id)")
            if narrativeArcExpanded {
                VStack(spacing: 5) {
                    TextField(
                        "동기 — 왜 움직이는가 (추상적 욕망)",
                        text: Binding(
                            get: { card.motivation ?? "" },
                            set: { card.motivation = $0.isEmpty ? nil : $0 }
                        )
                    )
                    .accessibilityIdentifier("purlory.writer.character.motivation.\(card.id)")
                    TextField(
                        "목표 — 무엇을 얻으려 하는가 (구체적 목표)",
                        text: Binding(
                            get: { card.goal ?? "" },
                            set: { card.goal = $0.isEmpty ? nil : $0 }
                        )
                    )
                    .accessibilityIdentifier("purlory.writer.character.goal.\(card.id)")
                    TextField(
                        "갈등 — 무엇이 가로막는가 (장애물)",
                        text: Binding(
                            get: { card.conflict ?? "" },
                            set: { card.conflict = $0.isEmpty ? nil : $0 }
                        )
                    )
                    .accessibilityIdentifier("purlory.writer.character.conflict.\(card.id)")
                    TextField(
                        "깨달음·변화 — 결말에서 어떻게 달라지는가",
                        text: Binding(
                            get: { card.epiphany ?? "" },
                            set: { card.epiphany = $0.isEmpty ? nil : $0 }
                        )
                    )
                    .accessibilityIdentifier("purlory.writer.character.epiphany.\(card.id)")
                }
                .textFieldStyle(.roundedBorder)
                .purloryUIFont(11)
                .padding(.leading, 4)
            }
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
            jumpSection(
                title: "앎", count: knowledge.count,
                expanded: $knowledgeExpanded, entries: knowledge)
            jumpSection(
                title: "관계", count: relations.count,
                expanded: $relationsExpanded, entries: relations)
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
