import Combine
import CryptoKit
import Foundation

/// Maps exact, bounded provider windows under post-binding editor authority.
@MainActor
package final class WritingDiagnosticsController: ObservableObject {
    @Published package private(set) var state = WritingDiagnosticsState()
    private let engine: WritingDiagnosticsEngine
    private let clock: any WritingDiagnosticsClock
    private let currentSnapshot: @MainActor () -> ProjectDocumentSnapshot?
    private let index = WritingProjectionIndex()
    private let cache: WritingDiagnosticsCache
    private let findingBudgetBytes: Int
    private let ruleRevision: Int
    private let supportedLanguages: Set<String>
    private let reportProvider: (any WritingDiagnosticsChunkProvider)?
    private weak var activeReport: WritingDiagnosticsReportStorage?
    private var reportEpoch: UInt64 = 0
    private var snapshot: ProjectDocumentSnapshot?
    private var boundIdentity: ProjectRuntimeIdentity?
    private var nativeRevision: UInt64 = 0
    private var hasVerifiedNative = false
    private var awaitingCommit = true
    private var epoch: UInt64 = 0
    private var profileRevision: UInt64 = 0
    private var profileBytes: Data?
    private var voiceBytes: Data?
    private var voiceSubjects: [WritingVoiceSubject] = []
    private var record = WritingStyleRecord()
    private var profileReadable = true
    private var verifiedSourceRevision: String?
    private var foregroundBusy = false, lowPower = false
    private var markedRange: WritingDiagnosticRange?
    private var pressure = MemoryPressureLevel.normal
    private var thermal = ProcessInfo.ThermalState.nominal
    private var resultBudgetExhausted = false
    private var assessedWindows = Set<WritingDiagnosticRange>()
    package private(set) var workTask: Task<Void, Never>?
    package var projectionResetCount: Int { index.resetCount }
    package var lastMutationSourceUTF16: Int { index.lastMutationSourceUTF16 }
    package var lastMutationVisits: Int { index.lastMutationVisits }
    package var cacheCostBytes: Int { cache.costBytes }

    package init(engine: WritingDiagnosticsEngine, clock: any WritingDiagnosticsClock = ContinuousWritingDiagnosticsClock(),
         currentSnapshot: @escaping @MainActor () -> ProjectDocumentSnapshot?,
         cacheBudgetBytes: Int = 16 * 1024 * 1024, findingBudgetBytes: Int = 16 * 1024 * 1024,
         ruleRevision: Int = 0, supportedLanguages: Set<String> = ["ko"], reportProvider: (any WritingDiagnosticsChunkProvider)? = nil) {
        self.engine = engine; self.clock = clock; self.currentSnapshot = currentSnapshot
        cache = WritingDiagnosticsCache(budgetBytes: cacheBudgetBytes)
        self.findingBudgetBytes = max(0, findingBudgetBytes); self.ruleRevision = ruleRevision
        self.supportedLanguages = supportedLanguages; self.reportProvider = reportProvider
    }
    deinit { workTask?.cancel() }
    package func waitForCurrentWork() async { await workTask?.value }

    package func noteSnapshot(_ next: ProjectDocumentSnapshot) {
        guard currentSnapshot()?.identity == next.identity else { return }
        if snapshot?.identity == next.identity { return }
        let changedDocument = snapshot?.identity.key != next.identity.key
        invalidateWork()
        snapshot = next; awaitingCommit = true
        if changedDocument {
            index.reset(source: next.body)
            boundIdentity = next.identity; nativeRevision = 0; hasVerifiedNative = false
            verifiedSourceRevision = DocumentOutline.stableHash(next.body) // Explicit load only.
            cache.clear(); state = WritingDiagnosticsState(); resultBudgetExhausted = false; assessedWindows.removeAll()
            profileBytes = nil; profileRevision &+= 1
            state.coverage.dirty = wholeSource
        }
        readProfile(next, force: changedDocument)
        readVoiceSubjects(next, force: changedDocument)
        refreshState()
    }

    package func noteEditorCommit(_ commit: WritingEditorCommit, snapshot next: ProjectDocumentSnapshot) {
        guard currentSnapshot()?.identity == next.identity, snapshot?.identity == next.identity,
              boundIdentity == commit.baseIdentity, next.identity.key == commit.baseIdentity.key,
              commit.markedRange == nil, commit.nativeRevision >= nativeRevision else { return }
        let patch = commit.patch, old = patch.oldSourceRange.nsRange
        let empty = old.location == 0 && old.length == 0 && patch.replacement.isEmpty
        guard empty || !hasVerifiedNative || commit.nativeRevision > nativeRevision else { return }
        guard old.location >= 0, old.location <= index.sourceLength, old.length >= 0,
              old.length <= index.sourceLength - old.location else { return }
        invalidateWork()
        if !empty {
            let replacementLength = patch.replacement.reduce(0) { $0 + $1.sourceLength }
            guard index.apply(patch) else {
                state.findings.removeAll(); state.coverage.assessed.removeAll()
                state.coverage.unsupported = wholeSource; state.availability = .unsupportedInput
                refreshState(); return
            }
            let delta = replacementLength - old.length
            let invalidated = assessedWindows.filter { Self.intersects($0.nsRange, old) }
            for context in invalidated {
                state.coverage.assessed = Self.subtract(context.nsRange, from: state.coverage.assessed)
            }
            state.coverage.dirty = Self.merged(state.coverage.dirty + invalidated)
            assessedWindows = Set(assessedWindows.filter { !Self.intersects($0.nsRange, old) }.map { Self.shift($0, after: old.upperBound, by: delta) })
            verifiedSourceRevision = nil; resultBudgetExhausted = false; state.availability = .available
            let kept = state.findings.filter { !Self.intersects($0.contextRange.nsRange, old) }.map { finding in
                var value = finding
                value.sourceRanges = value.sourceRanges.map { Self.shift($0, after: old.upperBound, by: delta) }
                value.relatedSourceRanges = value.relatedSourceRanges.map { $0.map { Self.shift($0, after: old.upperBound, by: delta) } }
                value.contextRange = Self.shift(value.contextRange, after: old.upperBound, by: delta)
                if let hint = value.evidence.utf16Hint, hint >= old.upperBound { value.evidence.utf16Hint = hint + delta }
                value.relatedEvidence = value.relatedEvidence.map { anchor in
                    var shifted = anchor
                    if let hint = anchor.utf16Hint, hint >= old.upperBound { shifted.utf16Hint = hint + delta }
                    return shifted
                }
                return value
            }
            state.findings = kept
            state.coverage.assessed = Self.rebase(state.coverage.assessed, replacing: old, delta: delta)
            state.coverage.dirty = Self.rebase(state.coverage.dirty, replacing: old, delta: delta)
            state.coverage.unsupported = Self.rebase(state.coverage.unsupported, replacing: old, delta: delta)
            if index.sourceLength > 0 {
                let start = min(old.location, index.sourceLength - 1)
                state.coverage.dirty = Self.merged(state.coverage.dirty + [.init(location: start, length: min(index.sourceLength - start, max(1, replacementLength)))])
            }
        }
        boundIdentity = next.identity; nativeRevision = commit.nativeRevision
        hasVerifiedNative = true; awaitingCommit = false
        rebindFindings()
        schedule()
    }

    package func setForegroundBusy(_ busy: Bool) {
        guard foregroundBusy != busy else { return }; foregroundBusy = busy; policyChanged()
    }
    package func setMarkedRange(_ range: WritingDiagnosticRange?) {
        guard markedRange != range else { return }; markedRange = range; policyChanged()
    }
    package func setMemoryPressure(_ level: MemoryPressureLevel) {
        guard pressure != level else { return }; pressure = level
        if level != .normal { cache.clear() }
        if level == .critical {
            cache.clear(); state.findings.removeAll(); state.coverage.assessed.removeAll(); assessedWindows.removeAll()
            state.coverage.dirty = wholeSource; resultBudgetExhausted = false
        }
        policyChanged()
    }
    package func setEnergyPolicy(thermal: ProcessInfo.ThermalState, lowPower: Bool) {
        guard self.thermal != thermal || self.lowPower != lowPower else { return }
        self.thermal = thermal; self.lowPower = lowPower; policyChanged()
    }
    package func cancel() {
        invalidateWork(); state.findings.removeAll(); state.coverage.assessed.removeAll(); assessedWindows.removeAll()
        state.coverage.dirty = wholeSource; refreshState()
    }

    package var preparedStyle: (identity: ProjectRuntimeIdentity, load: WritingStyleLoad)? {
        guard let snapshot else { return nil }
        let load: WritingStyleLoad = profileReadable ? .ready(record)
            : .unreadable(original: profileBytes ?? Data(), reason: "저장된 교정 설정을 읽을 수 없습니다. 원본은 보존됩니다.")
        return (snapshot.identity, load)
    }
    package func isCurrent(_ value: WritingDiagnosticsStamp) -> Bool {
        hasVerifiedNative && !awaitingCommit && profileReadable && currentSnapshot()?.identity == boundIdentity
            && value == stamp(digest: value.windowDigest)
    }
    /// Only an explicit owned source capture supplies this proof; edits still clear it.
    package func rememberExplicitSourceRevision(_ revision: String, stamp: WritingDiagnosticsStamp) -> Bool {
        guard !revision.isEmpty, isCurrent(stamp) else { return false }
        verifiedSourceRevision = revision
        return true
    }
    package var nativeAuthorityBase: ProjectRuntimeIdentity? { boundIdentity }
    package func isNativeBound(to identity: ProjectRuntimeIdentity, revision: UInt64) -> Bool {
        hasVerifiedNative && !awaitingCommit && boundIdentity == identity && nativeRevision == revision
    }
    package func suspendNativeAuthority() {
        invalidateWork(); nativeRevision = 0; hasVerifiedNative = false; awaitingCommit = true; refreshState()
    }
    package func noteNativeLoad(_ next: ProjectDocumentSnapshot) {
        if boundIdentity != next.identity || snapshot?.identity != next.identity {
            clearContext(); noteSnapshot(next)
        }
        suspendNativeAuthority()
    }
    package func retry() { invalidateWork(); cache.clear(); schedule() }

    package func currentFinding(id: String) -> WritingDiagnosticsFinding? {
        guard hasVerifiedNative, !awaitingCommit, profileReadable,
              currentSnapshot()?.identity == boundIdentity,
              let finding = state.findings.first(where: { $0.id == id }),
              finding.stamp == stamp(digest: finding.stamp.windowDigest) else { return nil }
        return finding
    }

    /// A refused action invalidates only its assessed input context, never reloads source.
    package func requestRecheck(findingID: String) {
        let finding = currentFinding(id: findingID)
        invalidateWork()
        if let context = finding?.contextRange {
            state.findings.removeAll { Self.intersects($0.contextRange.nsRange, context.nsRange) }
            state.coverage.assessed = Self.subtract(context.nsRange, from: state.coverage.assessed)
            assessedWindows = Set(assessedWindows.filter { !Self.intersects($0.nsRange, context.nsRange) })
            state.coverage.dirty = Self.merged(state.coverage.dirty + [context])
            cache.clear(); resultBudgetExhausted = false
        }
        schedule()
    }

    package func clearContext() {
        cancel(); cache.clear(); index.reset(source: "")
        snapshot = nil; boundIdentity = nil; hasVerifiedNative = false; awaitingCommit = true
        verifiedSourceRevision = nil; assessedWindows.removeAll(); resultBudgetExhausted = false
        state = WritingDiagnosticsState()
    }

    package func cancelReport() { reportEpoch &+= 1; activeReport?.cancel(); activeReport = nil }

    package func scanDocument(_ target: ProjectDocumentSnapshot) -> WritingDiagnosticsReport {
        cancelReport()
        let ownedReport = reportEpoch, ownedProfile = profileRevision
        let owner = currentSnapshot()?.identity
        let storage = WritingDiagnosticsReportStorage(runtime: target.identity, profileRevision: ownedProfile)
        let channel = storage.channel
        activeReport = storage
        let provider = reportProvider, profile = record, revision = ruleRevision, configuration = engine.configurationRevision
        let initialAvailability: WritingDiagnosticsAvailability?
        if policyPaused { initialAvailability = .pausedPolicy }
        else if !profileReadable { initialAvailability = .unavailableProfile }
        else if !languageSupported { initialAvailability = .unsupportedLanguage }
        else if owner?.key.projectID != target.identity.key.projectID || owner?.generation != target.identity.generation { initialAvailability = .unavailableProvider }
        else if provider == nil { initialAvailability = .unavailableProvider }
        else { initialAvailability = nil }
        let check: @MainActor @Sendable () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.reportEpoch == ownedReport && self.profileRevision == ownedProfile
                && self.currentSnapshot()?.identity == owner && !self.policyPaused && self.profileReadable
        }
        let waitForLocal: @MainActor @Sendable () async -> Void = { [weak self] in await self?.waitForCurrentWork() }
        let task = Task(priority: .background) {
            await withTaskCancellationHandler {
                do {
                    if let initialAvailability {
                        try await channel.send(.failed(initialAvailability)); await channel.finish(); return
                    }
                    guard let provider else { return }
                    let preparing = Task.detached(priority: .utility) {
                        let projection = try WritingProjectionSnapshot.prepare(source: target.body)
                        try Task.checkCancellation()
                        var prose = "", cursor = 0
                        for window in projection.windows(intersecting: .init(location: 0, length: projection.sourceLength)) {
                            try Task.checkCancellation()
                            let lower = max(0, cursor - window.coveredRange.location)
                            prose += (window.text as NSString).substring(from: lower)
                            cursor = window.coveredRange.location + window.coveredRange.length
                        }
                        return (projection, prose, DocumentOutline.stableHash(target.body))
                    }
                    let prepared = try await withTaskCancellationHandler { try await preparing.value } onCancel: { preparing.cancel() }
                    guard check(), !Task.isCancelled else { throw CancellationError() }
                    let mapper = WritingReportMapper(projection: prepared.0, prose: prepared.1, sourceRevision: prepared.2, profile: profile,
                        identity: target.identity, profileRevision: ownedProfile, providerRevision: configuration, ruleRevision: revision)
                    let total = prepared.0.eligibleProseLength
                    try await channel.send(.progress(completed: 0, total: total))
                    try await channel.waitForCapacity()
                    await waitForLocal()
                    guard check(), !Task.isCancelled else { throw CancellationError() }
                    var request = WritingDiagnosticsRequest(projectID: target.identity.key.projectID, documentID: target.identity.key.documentID,
                        text: prepared.1, languageTag: profile.languageTag ?? "ko", scope: .document, styleProfile: profile.profile)
                    request.voiceSubjects = Self.declaredVoiceSubjects(in: target)
                    try await provider.analyzeChunks(request) { chunk in
                        guard await check(), !Task.isCancelled else { throw CancellationError() }
                        let update = try await mapper.consume(chunk)
                        guard await check(), !Task.isCancelled else { throw CancellationError() }
                        if !update.findings.isEmpty { try await channel.send(.findings(update.findings)) }
                        guard await check(), !Task.isCancelled else { throw CancellationError() }
                        try await channel.send(.progress(completed: update.completed, total: total))
                        try await channel.waitForCapacity()
                        guard await check(), !Task.isCancelled else { throw CancellationError() }
                        await waitForLocal()
                        guard await check(), !Task.isCancelled else { throw CancellationError() }
                    }
                    guard check(), !Task.isCancelled else { throw CancellationError() }
                    let coverage = await mapper.finish()
                    guard check(), !Task.isCancelled else { throw CancellationError() }
                    try await channel.send(.finished(coverage))
                    await channel.finish()
                } catch is CancellationError { await channel.cancel() }
                catch {
                    guard check(), !Task.isCancelled else { await channel.cancel(); return }
                    let availability: WritingDiagnosticsAvailability
                    if let classifier = provider as? any WritingDiagnosticsFailureClassifying {
                        switch classifier.failureOutcome(error).reason {
                        case .resource: availability = .unavailableResource
                        case .unsupportedInput: availability = .unsupportedInput
                        default: availability = .unavailableProvider
                        }
                    } else { availability = .unavailableProvider }
                    try? await channel.send(.failed(availability)); await channel.finish()
                }
            } onCancel: { Task { await channel.cancel() } }
        }
        storage.start(task)
        return WritingDiagnosticsReport(storage: storage)
    }

    private var wholeSource: [WritingDiagnosticRange] { index.sourceLength == 0 ? [] : [.init(location: 0, length: index.sourceLength)] }
    private var language: String { record.languageTag ?? "ko" }
    private var policyPaused: Bool {
        foregroundBusy || markedRange != nil || pressure != .normal || lowPower || thermal == .serious || thermal == .critical
    }
    private var languageSupported: Bool { supportedLanguages.contains(String(language.lowercased().split(separator: "-").first ?? "")) }
    private func invalidateWork() {
        epoch &+= 1; workTask?.cancel(); workTask = nil; state.coverage.pending.removeAll()
        cancelReport()
    }
    private func policyChanged() { invalidateWork(); schedule() }
    private func readProfile(_ next: ProjectDocumentSnapshot, force: Bool) {
        let bytes = next.userData[WritingStyleRepository.key]
        guard force || bytes != profileBytes else { return }
        profileBytes = bytes
        switch WritingStyleRepository.read(next) {
        case .ready(let value):
            if force || !profileReadable || value != record {
                profileRevision &+= 1; record = value; cache.clear()
                state.findings.removeAll(); state.coverage.assessed.removeAll(); assessedWindows.removeAll(); state.coverage.dirty = wholeSource
                resultBudgetExhausted = false
            }
            profileReadable = true
        case .unreadable:
            profileReadable = false; state.findings.removeAll(); state.coverage.assessed.removeAll(); assessedWindows.removeAll()
            state.coverage.dirty = wholeSource; cache.clear()
        }
    }
    private func readVoiceSubjects(_ next: ProjectDocumentSnapshot, force: Bool) {
        let bytes = next.mode == .fiction && next.kind == .manuscript
            ? next.userData[WriterDocumentData.key(for: next.identity.key.documentID)] : nil
        guard force || bytes != voiceBytes else { return }
        voiceBytes = bytes
        let subjects = Self.declaredVoiceSubjects(in: next)
        guard subjects != voiceSubjects else { return }
        voiceSubjects = subjects; profileRevision &+= 1; cache.clear()
        state.findings.removeAll(); state.coverage.assessed.removeAll(); assessedWindows.removeAll()
        state.coverage.dirty = wholeSource; resultBudgetExhausted = false
    }
    /// Decode only changed author metadata, never manuscript bytes on typing.
    private static func declaredVoiceSubjects(in source: ProjectDocumentSnapshot) -> [WritingVoiceSubject] {
        guard source.mode == .fiction, source.kind == .manuscript,
              let writer = try? WriterDocumentData.decode(source.userData[WriterDocumentData.key(for: source.identity.key.documentID)],
                documentID: source.identity.key.documentID), writer.characters.count <= 128 else { return [] }
        return writer.characters.filter { $0.autoRegistered != true }.map {
            .init(id: $0.id, name: $0.name, aliases: $0.aliases.split(separator: ",").map(String.init))
        }
    }

    private func stamp(digest: String) -> WritingDiagnosticsStamp? {
        guard let boundIdentity else { return nil }
        return .init(runtime: boundIdentity, nativeRevision: nativeRevision, profileRevision: profileRevision,
                     providerRevision: engine.configurationRevision, ruleRevision: ruleRevision, windowDigest: digest)
    }
    private func rebindFindings() {
        state.findings = state.findings.compactMap { finding in
            guard let current = stamp(digest: finding.stamp.windowDigest) else { return nil }
            var value = finding; value.stamp = current; return value
        }
    }
    private func owns(_ ownedEpoch: UInt64, _ ownedStamp: WritingDiagnosticsStamp) -> Bool {
        epoch == ownedEpoch && !Task.isCancelled && !awaitingCommit && hasVerifiedNative && !policyPaused
            && currentSnapshot()?.identity == ownedStamp.runtime && snapshot?.identity == ownedStamp.runtime
            && stamp(digest: ownedStamp.windowDigest) == ownedStamp && profileReadable && languageSupported
    }
    private func schedule() {
        guard !awaitingCommit, hasVerifiedNative, profileReadable, languageSupported, !policyPaused,
              !engine.configurationRevision.isEmpty else { refreshState(); return }
        guard !state.coverage.dirty.isEmpty else { refreshState(); return }
        guard let base = stamp(digest: "") else { return }
        let ownedEpoch = epoch, clock = self.clock
        state.coverage.pending = state.coverage.dirty
        state.status = .checking; state.availability = .available
        workTask = Task(priority: .utility) { [weak self] in
            do { try await clock.sleep(for: .milliseconds(350)); try Task.checkCancellation() } catch { return }
            guard let self, self.owns(ownedEpoch, base) else { return }
            let dirty = self.state.coverage.dirty
            var failed: [WritingDiagnosticRange] = [], failure: WritingDiagnosticsAvailability?
            for range in dirty {
                for window in self.index.windows(intersecting: range) {
                    guard let ownedStamp = self.stamp(digest: window.digest), self.owns(ownedEpoch, ownedStamp) else { return }
                    let context = Self.context(of: window)
                    for segment in window.segments where segment.unsupported { self.state.coverage.unsupported.append(.init(segment.source)) }
                    self.state.coverage.unsupported = Self.merged(self.state.coverage.unsupported)
                    let key = WritingDiagnosticsCache.Key(digest: window.digest, languageTag: self.language,
                        profileRevision: ownedStamp.profileRevision, providerRevision: ownedStamp.providerRevision, ruleRevision: ownedStamp.ruleRevision)
                    let diagnostics: [WritingDiagnostic]
                    var assessed = true
                    if let hit = self.cache.value(for: key, text: window.text) { diagnostics = hit }
                    else {
                        var request = WritingDiagnosticsRequest(projectID: ownedStamp.runtime.key.projectID, documentID: ownedStamp.runtime.key.documentID,
                            text: window.text, languageTag: self.language, scope: .local, styleProfile: self.record.profile)
                        request.voiceSubjects = self.voiceSubjects
                        guard let result = await self.engine.analyze(request), self.owns(ownedEpoch, ownedStamp) else { return }
                        diagnostics = result.diagnostics
                        assessed = !result.providerOutcomes.isEmpty && result.providerOutcomes.allSatisfy { $0.status == .success }
                        if assessed { self.cache.insert(diagnostics, text: window.text, for: key) }
                        else {
                            if result.providerOutcomes.contains(where: { $0.reason == .resource }) { failure = .unavailableResource }
                            else if result.providerOutcomes.contains(where: { $0.reason == .unsupportedInput }) { failure = .unsupportedInput }
                            else { failure = .unavailableProvider }
                        }
                    }
                    guard self.owns(ownedEpoch, ownedStamp) else { return }
                    let published = self.publish(diagnostics, window: window, stamp: ownedStamp)
                    if assessed && published && self.retainAssessment(context) {
                        self.state.coverage.assessed = Self.merged(self.state.coverage.assessed + window.segments.filter(\.eligible).map { .init($0.source) })
                        self.state.coverage.dirty = Self.subtract(context.nsRange, from: self.state.coverage.dirty)
                    } else {
                        failed.append(context)
                        self.state.coverage.assessed = Self.subtract(context.nsRange, from: self.state.coverage.assessed)
                    }
                    self.state.coverage.dirty = Self.merged(self.state.coverage.dirty + failed)
                    for unassessed in failed { self.state.coverage.assessed = Self.subtract(unassessed.nsRange, from: self.state.coverage.assessed) }
                    self.state.coverage.pending = Self.subtract(context.nsRange, from: self.state.coverage.pending)
                    await Task.yield()
                    guard self.owns(ownedEpoch, ownedStamp) else { return }
                }
            }
            guard self.owns(ownedEpoch, base) else { return }
            self.state.coverage.dirty = Self.merged(failed)
            self.state.coverage.pending.removeAll()
            self.state.availability = failure ?? .available
            self.workTask = nil; self.refreshState()
        }
    }

    @discardableResult
    private func publish(_ diagnostics: [WritingDiagnostic], window: WritingAnalysisWindow, stamp: WritingDiagnosticsStamp) -> Bool {
        let context = Self.context(of: window)
        var values = Dictionary(uniqueKeysWithValues: state.findings.map { ($0.id, $0) })
        var cost = state.findings.reduce(assessedWindows.count * 256) { $0 + WritingDiagnosticsCache.findingCost($1) }, complete = true
        for diagnostic in diagnostics {
            guard let primary = index.sourceRanges(for: diagnostic.range, in: window), let first = primary.first, let last = primary.last else { continue }
            let related = diagnostic.relatedRanges.compactMap { index.sourceRanges(for: $0, in: window) }
            guard related.count == diagnostic.relatedRanges.count else { continue }
            let anchorRange = WritingDiagnosticRange(location: first.location, length: last.location + last.length - first.location)
            guard let quote = index.sourceText(in: anchorRange), let piece = index.sourcePiece(containing: first.location) else {
                complete = false; continue
            }
            let evidence = EvidenceAnchor(documentID: stamp.runtime.key.documentID, quote: quote, utf16Hint: first.location)
            if record.intentionalOccurrences.contains(where: { $0.suppresses(ruleID: diagnostic.ruleID, evidence: evidence, sourceRevision: verifiedSourceRevision) }) { continue }
            let discriminator = "\(diagnostic.providerID)|\(diagnostic.ruleID)|\(stamp.runtime.key.documentID.rawValue)|\(piece.block.id)|\(first.location - piece.range.location)|\(quote)"
            let id = SHA256.hash(data: Data(discriminator.utf8)).map { String(format: "%02x", $0) }.joined()
            let relatedEvidence = related.compactMap { index.freeze().boundedEvidence(for: $0, documentID: stamp.runtime.key.documentID) }
            guard relatedEvidence.count == related.count else { complete = false; continue }
            let finding = WritingDiagnosticsFinding(id: id, diagnostic: diagnostic, sourceRanges: primary, relatedSourceRanges: related,
                evidence: evidence, relatedEvidence: relatedEvidence, contextRange: context, stamp: stamp)
            let previousCost = values[id].map(WritingDiagnosticsCache.findingCost) ?? 0, added = WritingDiagnosticsCache.findingCost(finding)
            guard added <= findingBudgetBytes, cost - previousCost <= findingBudgetBytes - added else {
                resultBudgetExhausted = true; complete = false; continue
            }
            values[id] = finding; cost += added - previousCost
        }
        state.findings = values.values.sorted {
            $0.sourceRanges[0].location == $1.sourceRanges[0].location ? $0.id < $1.id : $0.sourceRanges[0].location < $1.sourceRanges[0].location
        }
        return complete
    }
    private func retainAssessment(_ context: WritingDiagnosticRange) -> Bool {
        if assessedWindows.contains(context) { return true }
        let cost = state.findings.reduce((assessedWindows.count + 1) * 256) { $0 + WritingDiagnosticsCache.findingCost($1) }
        guard cost <= findingBudgetBytes else { resultBudgetExhausted = true; return false }
        assessedWindows.insert(context); return true
    }

    private func refreshState() {
        state.coverage.isComplete = !awaitingCommit && state.coverage.dirty.isEmpty && state.coverage.pending.isEmpty
            && state.coverage.unsupported.isEmpty && !resultBudgetExhausted && profileReadable && languageSupported
        if policyPaused { state.status = .paused; state.availability = .pausedPolicy; state.coverage.isComplete = false }
        else if !profileReadable { state.status = .unavailable; state.availability = .unavailableProfile; state.coverage.isComplete = false }
        else if !languageSupported { state.status = .unavailable; state.availability = .unsupportedLanguage; state.coverage.isComplete = false }
        else if engine.configurationRevision.isEmpty { state.status = .unavailable; state.availability = .unavailableProvider; state.coverage.isComplete = false }
        else if workTask != nil { state.status = .checking; state.availability = .available }
        else if [.unavailableResource, .unavailableProvider, .unsupportedInput].contains(state.availability) {
            state.status = state.findings.isEmpty ? .unavailable : .partial
        } else {
            state.availability = .available
            state.status = state.coverage.isComplete ? .idle : .partial
        }
    }
    private static func context(of window: WritingAnalysisWindow) -> WritingDiagnosticRange {
        guard let first = window.segments.first, let last = window.segments.last else { return .init(location: 0, length: 0) }
        return .init(location: first.source.location, length: last.source.upperBound - first.source.location)
    }
    private static func intersects(_ range: NSRange, _ cut: NSRange) -> Bool {
        cut.length == 0 ? range.location <= cut.location && cut.location <= range.upperBound : NSIntersectionRange(range, cut).length > 0
    }
    private static func shift(_ range: WritingDiagnosticRange, after end: Int, by delta: Int) -> WritingDiagnosticRange {
        .init(location: range.location >= end ? range.location + delta : range.location, length: range.length)
    }
    private static func merged(_ ranges: [WritingDiagnosticRange]) -> [WritingDiagnosticRange] {
        var result: [WritingDiagnosticRange] = []
        for range in ranges.filter({ $0.length > 0 }).sorted(by: { $0.location < $1.location }) {
            if let last = result.last, last.nsRange.upperBound >= range.location {
                result[result.count - 1].length = max(last.nsRange.upperBound, range.nsRange.upperBound) - last.location
            } else { result.append(range) }
        }
        return result
    }
    private static func subtract(_ cut: NSRange, from ranges: [WritingDiagnosticRange]) -> [WritingDiagnosticRange] {
        var result: [WritingDiagnosticRange] = []
        for value in ranges {
            let range = value.nsRange
            guard NSIntersectionRange(range, cut).length > 0 else { result.append(value); continue }
            if range.location < cut.location { result.append(.init(location: range.location, length: cut.location - range.location)) }
            if range.upperBound > cut.upperBound { result.append(.init(location: cut.upperBound, length: range.upperBound - cut.upperBound)) }
        }
        return result
    }
    private static func rebase(_ ranges: [WritingDiagnosticRange], replacing old: NSRange, delta: Int) -> [WritingDiagnosticRange] {
        subtract(old, from: ranges).map { shift($0, after: old.upperBound, by: delta) }
    }
}
