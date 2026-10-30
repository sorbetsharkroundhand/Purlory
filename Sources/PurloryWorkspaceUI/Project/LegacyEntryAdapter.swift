public enum LegacyEntryAdapter {
    /// 문서 값만 투영한다. 기존 메타데이터의 저장·이관은 별도 책임이다 (PLAN §5.1).
    public static func document(from entry: JournalEntry) -> WritingDocument {
        WritingDocument(
            id: WritingDocumentID(rawValue: entry.id),
            title: entry.title,
            body: entry.body,
            kind: .manuscript)
    }
}
