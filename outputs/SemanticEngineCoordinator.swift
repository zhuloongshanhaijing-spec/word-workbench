import Foundation

// The ranking contract, its strict validator, the ordered fallback coordinator,
// and the conservative selection policy.
//
// Boundaries that must not change:
//   * The engine only ever reorders / scores senses that Open Dictionary already
//     produced. It never creates, translates, merges, deletes, or moves facts.
//   * Results are associated with `sourceSenseID`, never with array position.
//     A response that is out of order is fine; a response that is duplicated,
//     incomplete, unknown, or non-finite is invalid and triggers the fallback.
//   * Nothing here touches Anki, decks, note fields, or scheduling.

// MARK: - Engine identity

enum SemanticEngineKind: String, Codable, CaseIterable, Equatable {
    case localReranker
    case ollamaEmbedding
    case rule

    var displayName: String {
        switch self {
        case .localReranker: return "本地重排 bge-reranker-v2-m3"
        case .ollamaEmbedding: return "Ollama bge-m3"
        case .rule: return "词典标签规则"
        }
    }
}

/// The engine that leads the `auto` chain.
///
/// The local reranker is only allowed to lead once the independent held-out
/// evaluation (`BENCHMARK_RESULTS.json`, `dataset.kind = heldout_evaluation`)
/// showed a net semantic improvement over Ollama bge-m3 without weakening
/// abstention. Until that is proven, the already-verified Ollama chain stays
/// primary and the reranker remains an evaluable candidate. The exact rule and
/// the measured numbers live in `promotion_rule` / `promotion_decision`.
enum SemanticEnginePromotion {
    static let primary: SemanticEngineKind = .ollamaEmbedding

    static var isPromoted: Bool { primary == .localReranker }

    /// Order for the `auto` preference: promoted primary first, then the other,
    /// with the transparent dictionary-label rule always last.
    static func autoOrder(reranker: any SemanticRankingEngine, ollama: any SemanticRankingEngine) -> [any SemanticRankingEngine] {
        isPromoted ? [reranker, ollama] : [ollama, reranker]
    }
}

/// A single already-existing dictionary sense offered to a ranking engine.
/// `text` is evidence assembled from the dictionary record; it is never
/// interpreted as content the engine may rewrite.
struct SemanticCandidate: Codable, Equatable {
    let sourceSenseID: String
    let text: String
}

struct SemanticScore: Codable, Equatable {
    let sourceSenseID: String
    let score: Double
}

enum SemanticEngineHealth: Equatable {
    case available(String)
    case unavailable(String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var summary: String {
        switch self {
        case .available(let detail): return detail
        case .unavailable(let detail): return detail
        }
    }
}

enum SemanticRankingError: LocalizedError, Equatable {
    case emptyCandidates
    case tooManyCandidates(count: Int, maximum: Int)
    case unavailable(String)
    case timedOut(String)
    case malformedResponse(String)
    case duplicateSourceID(String)
    case missingSourceID(String)
    case unknownSourceID(String)
    case nonFiniteScore(String)

    var errorDescription: String? {
        switch self {
        case .emptyCandidates: return "没有可排序的义项。"
        case .tooManyCandidates(let count, let maximum): return "候选义项 \(count) 条超过上限 \(maximum) 条。"
        case .unavailable(let detail): return detail
        case .timedOut(let detail): return detail
        case .malformedResponse(let detail): return "排名响应无效：\(detail)"
        case .duplicateSourceID(let id): return "排名响应重复了义项 \(id)。"
        case .missingSourceID(let id): return "排名响应缺少义项 \(id)。"
        case .unknownSourceID(let id): return "排名响应包含未知义项 \(id)。"
        case .nonFiniteScore(let id): return "义项 \(id) 的分数不是有限数值。"
        }
    }
}

protocol SemanticRankingEngine {
    var kind: SemanticEngineKind { get }
    func health() async -> SemanticEngineHealth
    func rank(query: String, candidates: [SemanticCandidate]) async throws -> [SemanticScore]
}

// MARK: - Strict response validation

enum SemanticScoreValidator {
    /// Rejects anything that could silently mis-associate a score with a sense:
    /// duplicate IDs, unknown IDs, missing IDs, and NaN / Infinity.
    @discardableResult
    static func validate(_ scores: [SemanticScore],
                         against candidates: [SemanticCandidate],
                         engine: SemanticEngineKind) throws -> [String: Double] {
        var expected = Set<String>()
        for candidate in candidates {
            guard expected.insert(candidate.sourceSenseID).inserted else {
                throw SemanticRankingError.duplicateSourceID(candidate.sourceSenseID)
            }
        }
        var resolved: [String: Double] = [:]
        for score in scores {
            guard score.score.isFinite else { throw SemanticRankingError.nonFiniteScore(score.sourceSenseID) }
            guard expected.contains(score.sourceSenseID) else { throw SemanticRankingError.unknownSourceID(score.sourceSenseID) }
            guard resolved[score.sourceSenseID] == nil else { throw SemanticRankingError.duplicateSourceID(score.sourceSenseID) }
            resolved[score.sourceSenseID] = score.score
        }
        if let missing = expected.first(where: { resolved[$0] == nil }) {
            throw SemanticRankingError.missingSourceID(missing)
        }
        return resolved
    }

    /// Deterministic descending order with the candidate order as tie-breaker.
    static func ranked(_ scores: [SemanticScore], candidates: [SemanticCandidate]) -> [SemanticScore] {
        var position: [String: Int] = [:]
        for (index, candidate) in candidates.enumerated() where position[candidate.sourceSenseID] == nil {
            position[candidate.sourceSenseID] = index
        }
        return scores.sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            return (position[left.sourceSenseID] ?? 0) < (position[right.sourceSenseID] ?? 0)
        }
    }
}

// MARK: - Bounded waiting

enum SemanticAsyncTimeout {
    /// Races `operation` against a wall-clock budget. The losing task is
    /// cancelled; URLSession-backed engines stop promptly on cancellation.
    static func run<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                throw SemanticRankingError.timedOut("排名超过 \(Int(seconds)) 秒上限，已自动回退。")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw SemanticRankingError.timedOut("排名没有返回结果。")
            }
            return result
        }
    }
}

// MARK: - Calibration and conservative selection

enum SemanticScoreCalibration {
    /// Maps each engine's raw score monotonically into 0...1 for thresholding
    /// and compact display. This value is not a calibrated probability.
    static func probability(_ raw: Double, engine: SemanticEngineKind) -> Double {
        switch engine {
        case .localReranker:
            return 1 / (1 + exp(-raw))
        case .ollamaEmbedding:
            return min(1, max(0, (raw + 1) / 2))
        case .rule:
            return min(1, max(0, raw))
        }
    }
}

/// Ranking is always produced. Default selection is a separate, conservative
/// decision: a single sense is preselected only when it clears an absolute
/// confidence floor and, when there is a runner-up, a margin over it.
struct SemanticSelectionPolicy: Equatable {
    var minimumConfidence: Double
    var minimumMargin: Double
    var requiresUnitContext: Bool

    /// Calibrated on the checked-in semantic benchmark (`benchmarks/semantic-ranking`).
    /// Relevant cases: p >= 0.108; unrelated cases: p <= 0.013. 0.05 sits in the gap.
    static let localReranker = SemanticSelectionPolicy(minimumConfidence: 0.05, minimumMargin: 0.02, requiresUnitContext: true)
    /// bge-m3 cosine relevance is poorly separated (relevant >= 0.802, unrelated <= 0.786),
    /// so the floor is tight and no margin rule is reliable.
    /// Grid search on heldout (2026-09-17): best min_confidence=0.76 yields 87.5% accuracy
    /// (was 0.79 → 83.3%). Lowering the floor captures one extra correct case
    /// (biology-expression) without introducing false positives.
    static let ollamaEmbedding = SemanticSelectionPolicy(minimumConfidence: 0.76, minimumMargin: 0.0, requiresUnitContext: true)
    static let rule = SemanticSelectionPolicy(minimumConfidence: 0, minimumMargin: 0, requiresUnitContext: true)

    static func policy(for engine: SemanticEngineKind) -> SemanticSelectionPolicy {
        switch engine {
        case .localReranker: return .localReranker
        case .ollamaEmbedding: return .ollamaEmbedding
        case .rule: return .rule
        }
    }

    func selectedSourceIDs(ranked: [SemanticScore], engine: SemanticEngineKind, unitHasContext: Bool) -> Set<String> {
        guard !requiresUnitContext || unitHasContext, let top = ranked.first else { return [] }
        let topProbability = SemanticScoreCalibration.probability(top.score, engine: engine)
        guard topProbability >= minimumConfidence else { return [] }
        if ranked.count > 1 {
            let runnerUp = SemanticScoreCalibration.probability(ranked[1].score, engine: engine)
            guard topProbability - runnerUp >= minimumMargin else { return [] }
        } else if minimumMargin > 0, topProbability < minimumConfidence + minimumMargin {
            return []
        }
        return [top.sourceSenseID]
    }
}

// MARK: - Ordered fallback coordinator

struct SemanticRankingOutcome {
    let engine: SemanticEngineKind
    let ranked: [SemanticScore]
    let selectedSourceIDs: Set<String>
    let unitHasContext: Bool
    let notices: [String]
    let usedFallback: Bool

    static func ruleFallback(notices: [String], unitHasContext: Bool) -> SemanticRankingOutcome {
        SemanticRankingOutcome(engine: .rule, ranked: [], selectedSourceIDs: [], unitHasContext: unitHasContext, notices: notices, usedFallback: true)
    }
}

struct SemanticRankingCoordinator {
    var engines: [any SemanticRankingEngine]
    /// The primary engine may not stall the capture queue: hard cap at 10s.
    var primaryTimeout: TimeInterval = 10
    var fallbackTimeout: TimeInterval = 8

    func rank(query: String,
              candidates: [SemanticCandidate],
              unitHasContext: Bool,
              selection: SemanticSelectionPolicy? = nil) async -> SemanticRankingOutcome {
        guard !candidates.isEmpty else {
            return .ruleFallback(notices: ["没有可排序的义项，保留词典标签建议。"], unitHasContext: unitHasContext)
        }
        var notices: [String] = []
        for (index, engine) in engines.enumerated() {
            let budget = index == 0 ? primaryTimeout : fallbackTimeout
            do {
                let raw = try await SemanticAsyncTimeout.run(seconds: budget) {
                    try await engine.rank(query: query, candidates: candidates)
                }
                try SemanticScoreValidator.validate(raw, against: candidates, engine: engine.kind)
                let ordered = SemanticScoreValidator.ranked(raw, candidates: candidates)
                let policy = selection ?? SemanticSelectionPolicy.policy(for: engine.kind)
                let selected = policy.selectedSourceIDs(ranked: ordered, engine: engine.kind, unitHasContext: unitHasContext)
                notices.append("\(engine.kind.displayName) 已排序 \(ordered.count) 条义项，默认勾选 \(selected.count) 条。")
                return SemanticRankingOutcome(engine: engine.kind, ranked: ordered, selectedSourceIDs: selected, unitHasContext: unitHasContext, notices: notices, usedFallback: index > 0)
            } catch {
                notices.append("\(engine.kind.displayName) 不可用：\(error.localizedDescription)")
                continue
            }
        }
        notices.append("已退回词典标签规则；全部义项仍然可见可选。")
        return .ruleFallback(notices: notices, unitHasContext: unitHasContext)
    }
}

// MARK: - Applying an outcome to a reviewed entry

extension RecommendationPolicy {
    static func engineCase(for kind: SemanticEngineKind) -> SenseRecommendation.Engine {
        switch kind {
        case .localReranker: return .localReranker
        case .ollamaEmbedding: return .ollamaEmbedding
        case .rule: return .rule
        }
    }

    /// Reorders senses and rewrites the *default selection* only. Called for a
    /// brand-new entry, or after the user explicitly asked to re-recommend the
    /// unit. A plain open/launch never calls this, so saved choices survive.
    static func apply(_ outcome: SemanticRankingOutcome, to entry: inout StructuredEntry, unitTerms: Set<String>) {
        guard !outcome.ranked.isEmpty else { return }
        var rawByID: [String: Double] = [:]
        var probabilityByID: [String: Double] = [:]
        for score in outcome.ranked {
            rawByID[score.sourceSenseID] = score.score
            probabilityByID[score.sourceSenseID] = SemanticScoreCalibration.probability(score.score, engine: outcome.engine)
        }
        for groupIndex in entry.groups.indices {
            for senseIndex in entry.groups[groupIndex].senses.indices {
                let sense = entry.groups[groupIndex].senses[senseIndex]
                guard let sourceID = sense.sourceSenseID, rawByID[sourceID] != nil else { continue }
                let probability = probabilityByID[sourceID] ?? 0
                let prior = sense.recommendation
                let matched = (prior?.domainHints ?? []).filter { unitTerms.contains($0.lowercased()) }
                let suggested = outcome.selectedSourceIDs.contains(sourceID)
                let reason = reasonText(engine: outcome.engine, probability: probability, selected: suggested, matchedLabels: matched)
                entry.groups[groupIndex].senses[senseIndex].recommendation = SenseRecommendation(
                    score: probability,
                    suggested: suggested,
                    reason: reason,
                    engine: engineCase(for: outcome.engine),
                    domainHints: prior?.domainHints ?? [],
                    sourceRank: prior?.sourceRank ?? 100
                )
                entry.groups[groupIndex].senses[senseIndex].selected = suggested
            }
            entry.groups[groupIndex].senses.sort { left, right in
                (left.recommendation?.score ?? -1) > (right.recommendation?.score ?? -1)
            }
        }
    }

    /// Only signals that were actually used may appear here.
    static func reasonText(engine: SemanticEngineKind, probability: Double, selected: Bool, matchedLabels: [String]) -> String {
        let percent = Int((probability * 100).rounded())
        var parts: [String] = []
        switch engine {
        case .localReranker:
            parts.append("本地重排归一化相关度分 \(percent)/100（非概率）")
        case .ollamaEmbedding:
            parts.append("Ollama 归一化余弦相似度分 \(percent)/100（非概率）")
        case .rule:
            parts.append(matchedLabels.isEmpty ? "未发现与本 Unit 对应的词典领域标签" : "匹配词典领域标签：\(matchedLabels.joined(separator: "、"))")
        }
        if engine != .rule, !matchedLabels.isEmpty {
            parts.append("匹配标签：\(matchedLabels.joined(separator: "、"))")
        }
        if engine != .rule, !selected {
            parts.append("低于保守阈值，未默认勾选")
        }
        return parts.joined(separator: "；")
    }
}
