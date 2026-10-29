import Foundation

@propertyWrapper
public struct BenchmarkNullable<Value: Codable & Sendable>: Codable, Sendable {
    public var wrappedValue: Value?
    public init(wrappedValue: Value?) { self.wrappedValue = wrappedValue }
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = container.decodeNil() ? nil : try container.decode(Value.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue { try container.encode(wrappedValue) } else { try container.encodeNil() }
    }
}
public struct BenchmarkContamination: Codable, Equatable, Sendable {
    public var hanCharacters = 0
    public var reasoningTags = 0
    public var chatBoilerplate = 0
    public static func count(_ text: String) -> BenchmarkContamination {
        let ranges: [ClosedRange<UInt32>] = [0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F, 0x30000...0x323AF]
        let han = text.unicodeScalars.filter { scalar in ranges.contains { $0.contains(scalar.value) } }.count
        let markers = ["<|im_start|>assistant", "<|assistant|>", "### assistant", "assistant:", "답변:", "다음은 이어지는"]
        func matches(_ pattern: String) -> Int {
            (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive))?.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) ?? 0
        }
        return .init(hanCharacters: han, reasoningTags: matches("</?(?:think|analysis|reasoning)>"),
                     chatBoilerplate: matches(markers.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")))
    }
    func adding(_ other: Self) -> Self {
        .init(hanCharacters: hanCharacters + other.hanCharacters, reasoningTags: reasoningTags + other.reasoningTags,
              chatBoilerplate: chatBoilerplate + other.chatBoilerplate)
    }
}
public struct ReleaseBenchmarkSample: Sendable {
    public var coldText: String
    public var warmText: String
    public var rawColdText: String
    public var rawWarmText: String
    public var truth: String
    public var coldTTFC: Double?
    public var warmTTFC: Double?
    public var coldTTFT: Double?
    public var warmTTFT: Double?
    public var warmPromptTokens: Int
    public var warmReusedTokens: Int
    public init(coldText: String, warmText: String, rawColdText: String, rawWarmText: String, truth: String,
                coldTTFC: Double?, warmTTFC: Double?, warmPromptTokens: Int, warmReusedTokens: Int,
                coldTTFT: Double? = nil, warmTTFT: Double? = nil) {
        self.coldText = coldText; self.warmText = warmText; self.rawColdText = rawColdText; self.rawWarmText = rawWarmText
        self.truth = truth; self.coldTTFC = coldTTFC; self.warmTTFC = warmTTFC
        self.warmPromptTokens = warmPromptTokens; self.warmReusedTokens = warmReusedTokens
        self.coldTTFT = coldTTFT; self.warmTTFT = warmTTFT
    }
}
public struct ReleaseBenchmarkReport: Codable, Sendable {
    public struct Metadata: Codable, Sendable {
        public var modelID: String
        public var revision: String
        public var fixtureSHA256: String
        public var physicalMemoryBytes: UInt64
        public var recommendedWorkingSetBytes: UInt64
        public var device: String
        public var os: String
        public var toolchain: String
        public var style: PromptStyle
        public var maxTokens: Int
        public var temperature: Double
        public var contextCharacters: Int
        /// Absent on historical reports; do not infer their strategy.
        public var ghostContextMode: GhostContextMode?
        public var originalAnchorNames: [String]?
        public var originalAnchorOpportunities: Int?
        public var declaredPeakBudgetBytes: UInt64?
        public var topP = 0.9
        public var maxPromptTokens = 3_072
        public var kvCacheEnabled = true
        public var truthCharacters = 40
        public var knowledgeEnabled = false
        public var title = ""
        public var genre = ""
        public init(modelID: String, revision: String, fixtureSHA256: String, physicalMemoryBytes: UInt64,
                    recommendedWorkingSetBytes: UInt64, device: String, os: String, toolchain: String, style: PromptStyle,
                    maxTokens: Int, temperature: Double, contextCharacters: Int, declaredPeakBudgetBytes: UInt64?) {
            self.modelID = modelID; self.revision = revision; self.fixtureSHA256 = fixtureSHA256
            self.physicalMemoryBytes = physicalMemoryBytes; self.recommendedWorkingSetBytes = recommendedWorkingSetBytes
            self.device = device; self.os = os; self.toolchain = toolchain; self.style = style
            self.maxTokens = maxTokens; self.temperature = temperature; self.contextCharacters = contextCharacters
            self.declaredPeakBudgetBytes = declaredPeakBudgetBytes
        }
    }
    public var schemaVersion = 2
    public var metadata: Metadata
    public var completedSamples = 0
    public var failedSamples = 0
    public var coldLatencySamples = 0
    public var warmLatencySamples = 0
    public var coldFirstTokenSamples = 0
    public var warmFirstTokenSamples = 0
    @BenchmarkNullable public var coldTTFCMean: Double?
    @BenchmarkNullable public var warmTTFCMean: Double?
    @BenchmarkNullable public var coldTTFTMean: Double?
    @BenchmarkNullable public var warmTTFTMean: Double?
    @BenchmarkNullable public var prefixHitRate: Double?
    @BenchmarkNullable public var eojeolHitRate: Double?
    @BenchmarkNullable public var kvReuseRate: Double?
    public var rawContamination = BenchmarkContamination()
    public var displayedContamination = BenchmarkContamination()
    @BenchmarkNullable public var mlxPeakBytes: UInt64?
    @BenchmarkNullable public var processPeakBytes: UInt64?
    public init(metadata: Metadata, samples: [ReleaseBenchmarkSample], attempted: Int, mlxPeakBytes: UInt64?, processPeakBytes: UInt64?) throws {
        guard attempted >= samples.count, attempted >= 0,
              metadata.maxTokens > 0, metadata.contextCharacters > 0, metadata.temperature.isFinite, metadata.temperature >= 0,
              samples.allSatisfy({ sample in
                  [sample.coldTTFC, sample.warmTTFC, sample.coldTTFT, sample.warmTTFT].compactMap { $0 }.allSatisfy { $0.isFinite && $0 >= 0 }
                  && sample.warmPromptTokens >= 0 && sample.warmReusedTokens >= 0 && sample.warmReusedTokens <= sample.warmPromptTokens
              }) else { throw ReportError.invalid }
        self.metadata = metadata; self.mlxPeakBytes = mlxPeakBytes; self.processPeakBytes = processPeakBytes
        completedSamples = samples.count; failedSamples = attempted - samples.count
        let cold = samples.compactMap(\.coldTTFC), warm = samples.compactMap(\.warmTTFC)
        coldLatencySamples = cold.count; warmLatencySamples = warm.count
        coldTTFCMean = cold.isEmpty ? nil : cold.reduce(0, +) / Double(cold.count)
        warmTTFCMean = warm.isEmpty ? nil : warm.reduce(0, +) / Double(warm.count)
        let coldTokens = samples.compactMap(\.coldTTFT), warmTokens = samples.compactMap(\.warmTTFT)
        coldFirstTokenSamples = coldTokens.count; warmFirstTokenSamples = warmTokens.count
        coldTTFTMean = coldTokens.isEmpty ? nil : coldTokens.reduce(0, +) / Double(coldTokens.count)
        warmTTFTMean = warmTokens.isEmpty ? nil : warmTokens.reduce(0, +) / Double(warmTokens.count)
        prefixHitRate = samples.isEmpty ? nil : Double(samples.filter { zip($0.coldText, $0.truth).prefix { $0 == $1 }.count >= 2 }.count) / Double(samples.count)
        eojeolHitRate = samples.isEmpty ? nil : Double(samples.filter { Self.sharesEojeol($0.coldText, $0.truth) }.count) / Double(samples.count)
        let prompts = samples.reduce(0.0) { $0 + Double($1.warmPromptTokens) }, reused = samples.reduce(0.0) { $0 + Double($1.warmReusedTokens) }
        kvReuseRate = prompts > 0 ? reused / prompts : nil
        rawContamination = samples.reduce(.init()) { $0.adding(.count($1.rawColdText)).adding(.count($1.rawWarmText)) }
        displayedContamination = samples.reduce(.init()) { $0.adding(.count($1.coldText)).adding(.count($1.warmText)) }
    }
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, metadata, completedSamples, failedSamples, coldLatencySamples, warmLatencySamples
        case coldFirstTokenSamples, warmFirstTokenSamples, coldTTFCMean, warmTTFCMean, coldTTFTMean, warmTTFTMean
        case prefixHitRate, eojeolHitRate, kvReuseRate, rawContamination, displayedContamination, mlxPeakBytes, processPeakBytes
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        metadata = try values.decode(Metadata.self, forKey: .metadata)
        completedSamples = try values.decode(Int.self, forKey: .completedSamples)
        failedSamples = try values.decode(Int.self, forKey: .failedSamples)
        coldLatencySamples = try values.decode(Int.self, forKey: .coldLatencySamples)
        warmLatencySamples = try values.decode(Int.self, forKey: .warmLatencySamples)
        // Schema 1 recorded chunks only. Missing token timing remains unknown.
        coldFirstTokenSamples = try values.decodeIfPresent(Int.self, forKey: .coldFirstTokenSamples) ?? 0
        warmFirstTokenSamples = try values.decodeIfPresent(Int.self, forKey: .warmFirstTokenSamples) ?? 0
        _coldTTFTMean = try values.decodeIfPresent(BenchmarkNullable<Double>.self, forKey: .coldTTFTMean) ?? .init(wrappedValue: nil)
        _warmTTFTMean = try values.decodeIfPresent(BenchmarkNullable<Double>.self, forKey: .warmTTFTMean) ?? .init(wrappedValue: nil)
        _coldTTFCMean = try values.decode(BenchmarkNullable<Double>.self, forKey: .coldTTFCMean)
        _warmTTFCMean = try values.decode(BenchmarkNullable<Double>.self, forKey: .warmTTFCMean)
        _prefixHitRate = try values.decode(BenchmarkNullable<Double>.self, forKey: .prefixHitRate)
        _eojeolHitRate = try values.decode(BenchmarkNullable<Double>.self, forKey: .eojeolHitRate)
        _kvReuseRate = try values.decode(BenchmarkNullable<Double>.self, forKey: .kvReuseRate)
        rawContamination = try values.decode(BenchmarkContamination.self, forKey: .rawContamination)
        displayedContamination = try values.decode(BenchmarkContamination.self, forKey: .displayedContamination)
        _mlxPeakBytes = try values.decode(BenchmarkNullable<UInt64>.self, forKey: .mlxPeakBytes)
        _processPeakBytes = try values.decode(BenchmarkNullable<UInt64>.self, forKey: .processPeakBytes)
    }
    public static func sharesEojeol(_ a: String, _ b: String) -> Bool {
        func words(_ text: String) -> Set<String> {
            Set(text.split(whereSeparator: { $0.isWhitespace }).map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { $0.count >= 2 })
        }
        return !words(a).isDisjoint(with: words(b))
    }
    public func write(to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .withoutOverwriting)
    }
    enum ReportError: Error { case invalid }
}
