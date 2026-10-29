import AppKit
import ImageIO

/// 저널에 붙인 이미지의 파일 저장·로드 (에디터 v3.1).
///
/// - 원본 데이터는 `~/Documents/Purlory/images/<uuid>.<ext>`에 복사한다. 저장
///   마크다운에는 `![](images/<uuid>.<ext>)`처럼 **Purlory 폴더 기준 상대경로**만
///   남겨, Purlory 폴더를 통째로 옮겨도 참조가 깨지지 않는다.
/// - 렌더 이미지는 경로별로 캐시한다 (편집·드로잉 모두 메인 스레드).
///
/// Default paths come from PurloryStorageLocation; the existing test override remains supported.
/// 캐시의 "메인 전용" 불변식은 주석이 아니라 격리로 강제한다 (이슈 #45) —
/// 호출부(BlockTextView·EpubExporter.export·테스트)는 모두 MainActor 맥락이다.
@MainActor
public enum PurloryImageStore {
    /// 지원 이미지 확장자 (붙여넣기·드롭·파일 선택 공통 필터).
    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "tif", "webp", "bmp",
    ]

    /// 렌더 캐시 — **바이트 상한 LRU** (#53). 과거의 count 기반 `removeAll()`
    /// 클리프(128장 도달 → 전부 비움 → 스크롤 스파이크)를 없앤다: 한도를 넘기면
    /// 가장 오래 안 쓴 항목부터 하나씩 내보내 재디코딩 스파이크가 사라진다.
    private static var cache = ImageLRU(budgetBytes: 128 * 1024 * 1024)

    /// 테스트 전용 저장소 격리 — 기본값 nil(실제 `~/Documents/Purlory`).
    /// 회귀 테스트가 사용자 원고·asset을 건드리지 않게 한다 (이슈 #7).
    private static var directoryOverride: URL?

    public static func setDirectoryOverride(_ url: URL?) {
        directoryOverride = url
        cache.removeAll()
    }

    /// 테스트 전용 — LRU 축출 규약을 작은 한도로 검증한다 (#53).
    static func _testResetCache(budgetBytes: Int) {
        cache = ImageLRU(budgetBytes: budgetBytes)
    }

    /// `~/Documents/Purlory/` — 없으면 만든다.
    private static func purloryDirectory() -> URL {
        if let override = directoryOverride { return override }
        let dir = PurloryStorageLocation.standard.rootDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `~/Documents/Purlory/images/` — 없으면 만든다.
    private static func imagesDirectory() -> URL? {
        guard let dir = try? ProjectPaths.checked("images", under: purloryDirectory()) else {
            return nil
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 이미지 데이터를 images 폴더에 복사하고 상대경로("images/<uuid>.<ext>")를 돌려준다.
    /// 실패하면 nil. 저장된 asset은 장부에 후보 등록 — 삽입이 취소돼도 유예 후
    /// 참조 기반으로 정리된다 (이슈 #17).
    public static func save(_ data: Data, ext rawExt: String) -> String? {
        let ext = normalizedExtension(rawExt)
        let name = "\(UUID().uuidString).\(ext)"
        guard let directory = imagesDirectory() else { return nil }
        let url = directory.appendingPathComponent(name, isDirectory: false)
        do {
            try data.write(to: url, options: .atomic)
            let relative = "images/\(name)"
            AssetJanitor.record(relative)
            return relative
        } catch {
            return nil
        }
    }

    /// Resolve local references, rejecting unsafe managed paths and symlinks.
    /// Explicit external files remain supported; the test override is respected.
    public static func url(for reference: String) -> URL? {
        resolveURL(for: reference, under: purloryDirectory())
    }

    /// Resolve against the default store without a main-actor hop or test override.
    /// Both entry points share the same syntax and filesystem safety checks.
    public nonisolated static func resolveURL(for reference: String) -> URL? {
        resolveURL(for: reference, under: PurloryStorageLocation.standard.rootDirectory)
    }

    nonisolated static func resolveURL(for reference: String, under root: URL) -> URL? {
        switch ImageReferenceParser.classify(reference) {
        case .managedRelative(let path):
            guard let url = try? ProjectPaths.checked(path, under: root) else { return nil }
            // Image references must not trigger recursive directory copies (which
            // could contain unchecked links). Missing files still resolve for recovery.
            if let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type]
                as? FileAttributeType, type != .typeRegular {
                return nil
            }
            return url
        case .externalFile(let path):
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        case .remote, .blocked:
            return nil
        }
    }

    /// 상대경로의 이미지를 로드한다 (경로별 캐시). 없거나 못 읽으면 nil.
    /// 원격·차단 소스는 로컬 파일로 오해하지 않고 nil — 완전 로컬 원칙 (이슈 #12).
    public static func image(for relativePath: String) -> NSImage? {
        guard let fileURL = url(for: relativePath) else { return nil }
        let key = "F|\(relativePath)"
        if let hit = cache.find(key) { return hit }
        guard let image = NSImage(contentsOf: fileURL), image.size.width > 0 else {
            return nil
        }
        cache.insert(
            key: key, image: image,
            bytes: approximateBytes(width: Int(image.size.width), height: Int(image.size.height)))
        return image
    }

    /// 표시용 다운샘플 이미지 (#53) — `CGImageSourceCreateThumbnailAtIndex`로
    /// **디코딩 자체를 표시 크기에서** 끝낸다. 4000px 사진을 그리려고 전체
    /// 해상도를 메모리에 올리고 리사이즈하던 비용(스크롤 프레임 직격)이 사라진다.
    /// 가로세로비는 원본과 같아 `imageDisplaySize` 계산이 변하지 않는다.
    ///
    /// - Parameter maxPixelWidth: 결과의 최대 가로 픽셀. 화면 폭 × 배율 상한으로
    ///   넘기는 것이 정답이다 (복사·내보내기 등 원본이 필요한 곳은 `image(for:)`).
    public static func displayImage(
        for relativePath: String, maxPixelWidth: CGFloat
    ) -> NSImage? {
        guard let fileURL = url(for: relativePath) else { return nil }
        let width = max(64, min(Int(maxPixelWidth), 4096))
        let key = "D|\(width)|\(relativePath)"
        if let hit = cache.find(key) { return hit }
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
            let cg = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    // 최대 변(가로 기준 요청) 상한 — 세로형 사진은 높이가 잘린다.
                    kCGImageSourceThumbnailMaxPixelSize: width,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        else { return nil }
        let image = NSImage(
            cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.insert(
            key: key, image: image, bytes: approximateBytes(width: cg.width, height: cg.height))
        return image
    }

    /// Decode verified project bytes without consulting global roots or filesystem paths.
    public static func displayImage(data: Data, maxPixelWidth: CGFloat) -> NSImage? {
        let width = max(64, min(Int(maxPixelWidth), 4096))
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: width,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// 대략적 디코딩 바이트 — RGBA 4바이트 가정. LRU 한도 판정용이라 정밀도 불필요.
    private static func approximateBytes(width: Int, height: Int) -> Int {
        max(1, width * height * 4)
    }

    // MARK: - 고아 정리는 금지 (이슈 #7)

    /// 과거 `pruneUnreferenced(keeping:)`는 정규식 하나로 "참조 중"을 판정해
    /// 나머지를 **영구 삭제**했다. title·angle destination·괄호·reference 문법을
    /// 못 읽어 실제 참조 중인 파일을 지웠고(이슈 #7 재현), 다른 저널 삭제만으로
    /// 표지 이미지가 사라질 수 있었다. 파서와 같은 참조 모델(#12)과 휴지통/지연
    /// GC(#17)가 준비될 때까지 **어떤 자동 삭제도 하지 않는다** — 고아 파일은
    /// 디스크 몇 KB의 비용이지만, 오삭제는 원고 일부의 영구 손실이다 (AGENTS §1).

    private static func normalizedExtension(_ ext: String) -> String {
        let lowered = ext.lowercased()
        guard imageExtensions.contains(lowered) else { return "png" }
        return lowered == "jpeg" ? "jpg" : lowered
    }
}
