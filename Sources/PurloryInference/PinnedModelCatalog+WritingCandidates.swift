// Owner-selected measurement candidates; these pins do not approve a shipping lineup.
// Inventories captured from immutable Hugging Face revisions on 2026-10-26.
extension PinnedModelCatalog {
    static let writingCandidates: [ModelInstallManifest] = [
        .init(id: "mlx-community/Qwen3.5-9B-4bit", revision: "8b2b98c00a6b4d291155e4890773ca8f769aee53", files: [
            .init(path: "chat_template.jinja", size: 7756, digest: "a585dec894e63da457d9440ec6aa7caa16d20860", algorithm: .gitBlobSHA1),
            .init(path: "config.json", size: 3331, digest: "0435ae3f4b3c8b907f7359a2f8f7150d316f3435", algorithm: .gitBlobSHA1),
            .init(path: "model-00001-of-00002.safetensors", size: 5349771222, digest: "a68b87558c6ef43f74c2bd63ce7e9092ceddc3101f3def0030774bae5f42aadd", algorithm: .sha256),
            .init(path: "model-00002-of-00002.safetensors", size: 600449850, digest: "b0a770bf8469c7f3f18756a0e0283f1c1174344a83e059a4e483f6af4907352d", algorithm: .sha256),
            .init(path: "model.safetensors.index.json", size: 123592, digest: "d366fa524ccd8f4ed93a67c7857597dc56172b92", algorithm: .gitBlobSHA1),
            .init(path: "preprocessor_config.json", size: 390, digest: "2ea84a437d448ff71b08df68fdd949d5cc4ebb64", algorithm: .gitBlobSHA1),
            .init(path: "processor_config.json", size: 1300, digest: "7ad6acdf4203f22b7b990e36ccc3a1fe38563d5e", algorithm: .gitBlobSHA1),
            .init(path: "tokenizer.json", size: 19989343, digest: "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4", algorithm: .sha256),
            .init(path: "tokenizer_config.json", size: 1139, digest: "a068e2468cff426a9b105006e74e044030a6faf4", algorithm: .gitBlobSHA1),
            .init(path: "video_preprocessor_config.json", size: 385, digest: "3ba673a5ad7d4d13f54155ecd38b2a94a6dac8fe", algorithm: .gitBlobSHA1),
            .init(path: "vocab.json", size: 6722759, digest: "0aa0ce0658d60ac4a5d609f4eadb0e8e43514176", algorithm: .gitBlobSHA1),
        ]),
        // This revision's optional index incorrectly references four nonexistent shards.
        // MLX also supports enumerating the two pinned, individually verified weight files.
        .init(id: "mlx-community/Ministral-3-14B-Instruct-2512-4bit", revision: "95b6f345475c8c8c92b7959d02f4ad86d3ba8384", files: [
            .init(path: "chat_template.jinja", size: 7760, digest: "02da21459d626b90d3005f88a6191bc0612393b1", algorithm: .gitBlobSHA1),
            .init(path: "config.json", size: 1989, digest: "4ccd55abb84ef3f2a8d8d323346ecf54368230e3", algorithm: .gitBlobSHA1),
            .init(path: "generation_config.json", size: 131, digest: "add11cbc06647495098ee6dd5c9cbc96841a445a", algorithm: .gitBlobSHA1),
            .init(path: "model-00001-of-00002.safetensors", size: 5339418864, digest: "b51aeb985da636eadd3744ee1f53542303795447c138c20d18054eecf64f6413", algorithm: .sha256),
            .init(path: "model-00002-of-00002.safetensors", size: 3085163974, digest: "a73d514a74619d6896a324b87addc76aca94f20dcf302632de44be2a443c5c94", algorithm: .sha256),
            .init(path: "params.json", size: 1188, digest: "9122c25709ca3cf061894360ddbcfa251ecae8c8", algorithm: .gitBlobSHA1),
            .init(path: "processor_config.json", size: 976, digest: "a37d728b12fd27ac60a437894bd51de83449bf30", algorithm: .gitBlobSHA1),
            .init(path: "tekken.json", size: 16753777, digest: "e29d19ea32eb7e26e6c0572d57cb7f9eca0f4420e0e0fe6ae1cf3be94da1c0d6", algorithm: .sha256),
            .init(path: "tokenizer.json", size: 17077402, digest: "286acad9b0e27fce778ac429763536accf618ccb6ed72963b6f94685e531c5c7", algorithm: .sha256),
            .init(path: "tokenizer_config.json", size: 21188, digest: "28d55ce8cd921df7748383f4b4837ca70e7b001d", algorithm: .gitBlobSHA1),
        ]),
        .init(id: "mlx-community/gemma-4-26b-a4b-it-4bit", revision: "0d77464eeb233a2da68ebf9d7dc4edaac7db956d", files: [
            .init(path: "chat_template.jinja", size: 17466, digest: "e61bbfe9a31db79ea1e4e557b046f895ad7899d0", algorithm: .gitBlobSHA1),
            .init(path: "config.json", size: 12180, digest: "9e6233a7e7174ab214c49dca84f2828a8fb504ef", algorithm: .gitBlobSHA1),
            .init(path: "generation_config.json", size: 208, digest: "e605bb4523b1462ea9d9a3810b9e3ecf7ab7b1f6", algorithm: .gitBlobSHA1),
            .init(path: "model-00001-of-00003.safetensors", size: 5320218487, digest: "683f420ee09550b8027bf0335c4202e196b37eb520b60a4bcbe8690b9e388c07", algorithm: .sha256),
            .init(path: "model-00002-of-00003.safetensors", size: 5363328422, digest: "feab2873c2976fb7ed666f8462549564a29409364388e0c8f6b015729d165e15", algorithm: .sha256),
            .init(path: "model-00003-of-00003.safetensors", size: 4657658867, digest: "bc607486deb1de5bc7e459932fda5c776a4f816b368feaa661bab8cfbb47e567", algorithm: .sha256),
            .init(path: "model.safetensors.index.json", size: 176940, digest: "f6f9e61c33077cc7e2ef701eff7056927a4a65e6", algorithm: .gitBlobSHA1),
            .init(path: "processor_config.json", size: 1316, digest: "a086fb7e04b477c291a120b0a004abb78b11c6d2", algorithm: .gitBlobSHA1),
            .init(path: "tokenizer.json", size: 32169626, digest: "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f", algorithm: .sha256),
            .init(path: "tokenizer_config.json", size: 2740, digest: "cf6235aee46a24bf71f251c0a4e7a0379948f7d2", algorithm: .gitBlobSHA1),
        ]),
    ]
}
