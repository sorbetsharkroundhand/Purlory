// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Purlory",
    platforms: [
        // MLX는 Apple Silicon + macOS 14+ 필요
        .macOS(.v14)
    ],
    products: [
        .library(name: "PurloryCore", targets: ["PurloryCore"]),
    ],
    dependencies: [
        // 온디바이스 LLM 추론. MLXLLM/MLXLMCommon은 mlx-swift-examples에서
        // mlx-swift-lm 저장소로 이전됨.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.32.3"),
        // MLXArray 등 코어 타입 직접 사용 — 이어쓰기(continuation) 프롬프트는
        // 챗 템플릿 없이 수동 토크나이즈로 LMInput을 만든다.
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.32.3"),
        // Hugging Face 허브 다운로드 + 토크나이저.
        // Downloads and the local tokenizer bridge use these APIs directly.
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        // 수식 블록 LaTeX 렌더링 (iosMath의 Swift 포트, CoreText 기반 네이티브).
        .package(url: "https://github.com/mgriebling/SwiftMath", from: "1.5.0"),
    ],
    targets: [
        .target(name: "PurloryFoundation"),
        .target(name: "PurloryStorage", dependencies: ["PurloryFoundation"]),
        .target(name: "PurloryInference", dependencies: [
                "PurloryFoundation",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
        ]),
        .target(name: "PurloryDocumentEngine", dependencies: ["PurloryFoundation", .product(name: "SwiftMath", package: "SwiftMath")],
                resources: [.process("Resources/Fonts")]),
        // Prepared from the checksum-pinned manifest before package loading/building.
        .binaryTarget(name: "Kiwi", path: "Packages/PurloryKoreanBackend/Artifacts/KiwiStatic.xcframework"),
        .target(name: "CKiwiBridge", dependencies: ["Kiwi"],
            path: "Packages/PurloryKoreanBackend/Sources/CKiwiBridge",
            exclude: ["Upstream/LICENSE", "Upstream/MIMALLOC-LICENSE", "Upstream/provenance.json", "Upstream/README.md"],
            cxxSettings: [.headerSearchPath("Upstream"), .define("KIWI_USE_MIMALLOC")],
            linkerSettings: [.linkedLibrary("c++"), .linkedLibrary("z")]),
        .target(name: "PurloryKoreanBackend", dependencies: ["CKiwiBridge"],
            path: "Packages/PurloryKoreanBackend/Sources/PurloryKoreanBackend",
            resources: [.copy("Resources/Kiwi")]),
        // 앱의 화면·로직은 라이브러리 타깃에 둔다.
        //  · SwiftUI 프리뷰는 executableTarget에서 ENABLE_DEBUG_DYLIB 제약으로 막히지만,
        //    라이브러리 타깃의 뷰는 프리뷰가 정상 동작한다.
        //  · PLAN의 "관심사 분리는 모듈로"(Editor/Inference/Storage) 방향과도 맞다.
        .target(
            name: "PurloryCore",
            dependencies: [
                "PurloryFoundation", "PurloryStorage", "PurloryInference", "PurloryDocumentEngine",
                "PurloryKoreanBackend",
                .product(name: "SwiftMath", package: "SwiftMath"),
            ],
            path: "Sources/PurloryCore",
            resources: [.process("Resources/Icons")]
        ),
        // @main 진입점만 담은 얇은 실행 셸. 실제 화면/로직은 PurloryCore에 있다.
        .executableTarget(
            name: "Purlory",
            dependencies: ["PurloryCore"],
            path: "Sources/Purlory"
        ),
        // M2 추론 리스크 선검증 CLI (PLAN §6 M2).
        // Mac에서: swift run -c release PurloryBench [--model <hf-id>] …
        .executableTarget(
            name: "PurloryBench",
            dependencies: ["PurloryCore", "PurloryInference"],
            path: "Sources/PurloryBench"
        ),
        // Deterministic editor/storage and pinned offline NLP regressions.
        // No Ghost model or Metal execution is required.
        .testTarget(
            name: "PurloryCoreTests",
            dependencies: ["PurloryCore", "PurloryKoreanBackend", "PurloryFoundation", "PurloryStorage", "PurloryInference", "PurloryDocumentEngine"],
            path: "Tests/PurloryCoreTests",
            resources: [.copy("Fixtures/KoreanDiagnostics"), .copy("Fixtures/NativeWorkspaceHTML")]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
