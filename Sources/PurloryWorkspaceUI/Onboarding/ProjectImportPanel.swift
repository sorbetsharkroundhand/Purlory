import AppKit

struct ProjectFolderSelection {
    let directory: URL
    let legacyMode: WritingMode
    var legacyFileName: String? = nil
}

@MainActor
enum ProjectImportPanel {
    static func selectLegacyArchive() -> ProjectFolderSelection? { select(legacyArchive: true) }

    static func select(legacyArchive: Bool = false) -> ProjectFolderSelection? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "가져오기"
        panel.message = legacyArchive
            ? "이전 원고 또는 복구 파일이 들어 있는 폴더를 선택하세요. 다음 단계에서 파일을 고릅니다. 원본과 이미지는 보존됩니다."
            : "프로젝트 폴더 또는 이전 앱의 저장 폴더를 선택하세요. 원본은 보존됩니다."
        guard panel.runModal() == .OK, let directory = panel.url else { return nil }
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        if !legacyArchive, ImportProjectCoordinator.containsProjectManifest(in: directory) {
            return ProjectFolderSelection(directory: directory, legacyMode: .general)
        }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { ($0.hasPrefix("entries") && $0.hasSuffix(".json")) || $0 == "journal.md" }.sorted()
        guard !names.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Purlory 원고가 있는 폴더를 선택하세요"
            alert.informativeText = "entries.json, 원고 복구 파일 또는 journal.md가 들어 있는 폴더를 선택해주세요."
            alert.runModal()
            return nil
        }
        let alert = NSAlert()
        alert.messageText = "가져올 프로젝트 종류"
        alert.informativeText = "원고에 맞는 작업 공간을 선택하세요."
        let archivePicker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26), pullsDown: false)
        archivePicker.addItems(withTitles: names)
        if names.contains("entries.json") { archivePicker.selectItem(withTitle: "entries.json") }
        alert.accessoryView = archivePicker
        alert.addButton(withTitle: "Fiction")
        alert.addButton(withTitle: "General")
        alert.addButton(withTitle: "취소")
        let response = alert.runModal()
        guard response != .alertThirdButtonReturn else { return nil }
        return ProjectFolderSelection(directory: directory,
            legacyMode: response == .alertFirstButtonReturn ? .fiction : .general,
            legacyFileName: archivePicker.titleOfSelectedItem)
    }
}
