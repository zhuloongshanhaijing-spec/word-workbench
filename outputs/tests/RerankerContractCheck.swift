import Foundation

// Contract tests for the ranking protocol. These run fully offline against a
// stub transport, so they prove the ID-alignment and validation rules without
// needing the model, Ollama, or the network.

final class StubRerankerTransport: RerankerTransport {
    private let handler: (URLRequest) -> (Data, Int)
    private(set) var requests: [URLRequest] = []

    init(_ handler: @escaping (URLRequest) -> (Data, Int)) {
        self.handler = handler
    }

    func send(_ request: URLRequest, timeout: TimeInterval) async throws -> (data: Data, statusCode: Int) {
        requests.append(request)
        return handler(request)
    }
}

enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { if case .failed(let message) = self { return message }; return "" }
}

func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure.failed(message) }
}

struct RerankResult: Encodable {
    let index: Int
    let relevance_score: Double
}

func rerankBody(_ results: [RerankResult]) -> Data {
    let payload: [String: Any] = ["model": "bge-reranker-v2-m3",
                                  "results": results.map { ["index": $0.index, "relevance_score": $0.relevance_score] }]
    return try! JSONSerialization.data(withJSONObject: payload)
}

func expectRankingError(_ label: String, _ body: () async throws -> Void, matching: (SemanticRankingError) -> Bool) async throws {
    do {
        try await body()
        throw CheckFailure.failed("\(label)：预期抛出 SemanticRankingError，但成功返回。")
    } catch let error as SemanticRankingError {
        try expect(matching(error), "\(label)：错误类型不符 -> \(error)")
    }
}

@main
struct RerankerContractCheck {
    static func candidates(_ ids: [String]) -> [SemanticCandidate] {
        ids.map { SemanticCandidate(sourceSenseID: $0, text: "单词：x\n义项：\($0)") }
    }

    static func engine(_ handler: @escaping (URLRequest) -> (Data, Int)) -> LocalSemanticReranker {
        LocalSemanticReranker(transport: StubRerankerTransport(handler))
    }

    static func main() async {
        do {
            try await run()
            print("PASS RerankerContract: id alignment, strict validation, timeout, selection policy, fact immutability")
        } catch {
            fatalError("FAIL RerankerContract: \(error)")
        }
    }

    static func run() async throws {
        // 1. Shuffled response is aligned by explicit index, not array order.
        let ids = ["sense-a", "sense-b", "sense-c"]
        let shuffled = engine { _ in
            (rerankBody([RerankResult(index: 2, relevance_score: 3.0),
                         RerankResult(index: 0, relevance_score: -1.0),
                         RerankResult(index: 1, relevance_score: 0.5)]), 200)
        }
        let ranked = try await shuffled.rank(query: "unit", candidates: candidates(ids))
        try expect(ranked.map(\.sourceSenseID) == ["sense-c", "sense-b", "sense-a"], "乱序响应未按 index 对齐：\(ranked)")
        try expect(ranked.map(\.score) == [3.0, 0.5, -1.0], "乱序响应未按分数降序：\(ranked)")

        // 2. Duplicate index / duplicate ID -> invalid.
        let duplicated = engine { _ in
            (rerankBody([RerankResult(index: 0, relevance_score: 1.0),
                         RerankResult(index: 0, relevance_score: 2.0),
                         RerankResult(index: 1, relevance_score: 0.0)]), 200)
        }
        try await expectRankingError("重复 ID") { _ = try await duplicated.rank(query: "q", candidates: candidates(ids)) } matching: {
            if case .duplicateSourceID = $0 { return true }; return false
        }

        // 3. Missing index -> invalid.
        let missing = engine { _ in
            (rerankBody([RerankResult(index: 0, relevance_score: 1.0),
                         RerankResult(index: 1, relevance_score: 0.5)]), 200)
        }
        try await expectRankingError("缺失 ID") { _ = try await missing.rank(query: "q", candidates: candidates(ids)) } matching: {
            if case .missingSourceID = $0 { return true }; return false
        }

        // 4. Unknown / out-of-range index -> invalid.
        let unknown = engine { _ in
            (rerankBody([RerankResult(index: 0, relevance_score: 1.0),
                         RerankResult(index: 1, relevance_score: 0.5),
                         RerankResult(index: 9, relevance_score: 0.1)]), 200)
        }
        try await expectRankingError("未知 ID") { _ = try await unknown.rank(query: "q", candidates: candidates(ids)) } matching: {
            if case .unknownSourceID = $0 { return true }; return false
        }

        // 5. Non-finite score over the wire -> invalid (never silently ranked).
        let nonFinite = engine { _ in
            (Data(#"{"results":[{"index":0,"relevance_score":1e999},{"index":1,"relevance_score":0.5}]}"#.utf8), 200)
        }
        try await expectRankingError("非有限分数") { _ = try await nonFinite.rank(query: "q", candidates: candidates(["a", "b"])) } matching: {
            switch $0 { case .nonFiniteScore, .malformedResponse: return true; default: return false }
        }

        // 6. Non-finite detected directly by the validator (NaN and Infinity).
        do {
            _ = try SemanticScoreValidator.validate([SemanticScore(sourceSenseID: "a", score: .nan)], against: candidates(["a"]), engine: .localReranker)
            throw CheckFailure.failed("validator 未拒绝 NaN。")
        } catch let error as SemanticRankingError {
            if case .nonFiniteScore = error {} else { throw CheckFailure.failed("validator 对 NaN 抛出 \(error)") }
        }
        do {
            _ = try SemanticScoreValidator.validate([SemanticScore(sourceSenseID: "a", score: .infinity)], against: candidates(["a"]), engine: .localReranker)
            throw CheckFailure.failed("validator 未拒绝 Infinity。")
        } catch let error as SemanticRankingError {
            if case .nonFiniteScore = error {} else { throw CheckFailure.failed("validator 对 Infinity 抛出 \(error)") }
        }
        do {
            _ = try SemanticScoreValidator.validate([SemanticScore(sourceSenseID: "ghost", score: 1)], against: candidates(["a"]), engine: .localReranker)
            throw CheckFailure.failed("validator 未拒绝未知 ID。")
        } catch let error as SemanticRankingError {
            if case .unknownSourceID = error {} else { throw CheckFailure.failed("validator 对未知 ID 抛出 \(error)") }
        }

        do {
            _ = try SemanticScoreValidator.validate(
                [SemanticScore(sourceSenseID: "a", score: 1), SemanticScore(sourceSenseID: "a", score: 0)],
                against: candidates(["a", "a"]),
                engine: .localReranker
            )
            throw CheckFailure.failed("validator 未拒绝请求中的重复 sourceSenseID。")
        } catch let error as SemanticRankingError {
            if case .duplicateSourceID = error {} else { throw CheckFailure.failed("validator 对重复候选 ID 抛出 \(error)") }
        }

        // 7. Transport failures -> typed errors that trigger fallback.
        let serverError = engine { _ in (Data(), 500) }
        try await expectRankingError("HTTP 500") { _ = try await serverError.rank(query: "q", candidates: candidates(["a"])) } matching: {
            if case .unavailable = $0 { return true }; return false
        }
        let garbage = engine { _ in (Data("not json".utf8), 200) }
        try await expectRankingError("畸形响应") { _ = try await garbage.rank(query: "q", candidates: candidates(["a"])) } matching: {
            if case .malformedResponse = $0 { return true }; return false
        }

        // 8. Input limits.
        try await expectRankingError("候选上限") {
            let small = LocalSemanticReranker(maximumCandidates: 2, transport: StubRerankerTransport { _ in (rerankBody([]), 200) })
            _ = try await small.rank(query: "q", candidates: candidates(["a", "b", "c"]))
        } matching: { if case .tooManyCandidates = $0 { return true }; return false }

        // 9. health() reports both states.
        let healthy = engine { request in
            if request.url?.path.hasSuffix("health") == true { return (Data(#"{"status":"ok"}"#.utf8), 200) }
            return (Data(#"{"build_info":"b10970-test","model_path":"/tmp/model.gguf"}"#.utf8), 200)
        }
        let health = await healthy.health()
        try expect(health.isAvailable, "健康服务被判定为不可用：\(health.summary)")
        try expect(health.summary.contains("b10970-test"), "健康信息缺少运行时版本：\(health.summary)")
        let unhealthy = engine { _ in (Data(), 503) }
        let badHealth = await unhealthy.health()
        try expect(!badHealth.isAvailable, "503 服务被判定为可用。")

        // 10. Timeout helper returns promptly and falls back to the next engine.
        struct SlowEngine: SemanticRankingEngine {
            var kind: SemanticEngineKind { .localReranker }
            func health() async -> SemanticEngineHealth { .available("slow") }
            func rank(query: String, candidates: [SemanticCandidate]) async throws -> [SemanticScore] {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return candidates.map { SemanticScore(sourceSenseID: $0.sourceSenseID, score: 1) }
            }
        }
        struct FastEngine: SemanticRankingEngine {
            var kind: SemanticEngineKind { .rule }
            func health() async -> SemanticEngineHealth { .available("fast") }
            func rank(query: String, candidates: [SemanticCandidate]) async throws -> [SemanticScore] {
                candidates.enumerated().map { SemanticScore(sourceSenseID: $0.element.sourceSenseID, score: Double(10 - $0.offset)) }
            }
        }
        let timeoutCoordinator = SemanticRankingCoordinator(engines: [SlowEngine(), FastEngine()], primaryTimeout: 0.2, fallbackTimeout: 1)
        let started = Date()
        let outcome = await timeoutCoordinator.rank(query: "q", candidates: candidates(["a", "b"]), unitHasContext: true)
        let elapsed = Date().timeIntervalSince(started)
        try expect(outcome.usedFallback, "超时后未回退。notices=\(outcome.notices)")
        try expect(elapsed < 3, "超时回退耗时过长：\(elapsed)s")
        try expect(outcome.ranked.first?.sourceSenseID == "a", "回退引擎结果不正确：\(outcome.ranked)")

        // 11. Selection policy is conservative.
        let high = [SemanticScore(sourceSenseID: "a", score: 4.0), SemanticScore(sourceSenseID: "b", score: -4.0)]
        try expect(SemanticSelectionPolicy.localReranker.selectedSourceIDs(ranked: high, engine: .localReranker, unitHasContext: true) == ["a"], "高置信度未预选。")
        let flat = [SemanticScore(sourceSenseID: "a", score: 0.2), SemanticScore(sourceSenseID: "b", score: 0.19)]
        try expect(SemanticSelectionPolicy.localReranker.selectedSourceIDs(ranked: flat, engine: .localReranker, unitHasContext: true).isEmpty, "差距过小仍然预选。")
        let low = [SemanticScore(sourceSenseID: "a", score: -3.0)]
        try expect(SemanticSelectionPolicy.localReranker.selectedSourceIDs(ranked: low, engine: .localReranker, unitHasContext: true).isEmpty, "绝对置信不足仍然预选。")
        try expect(SemanticSelectionPolicy.localReranker.selectedSourceIDs(ranked: high, engine: .localReranker, unitHasContext: false).isEmpty, "无 Unit 语境仍然预选。")

        // 12. Applying an outcome reorders and reselects, but never mutates facts.
        var entry = StructuredEntry(
            unitID: "u",
            word: "membrane",
            groups: [PartOfSpeechGroup(label: "noun", senses: [
                ReviewedSense(sourceSenseID: "music", gloss: "唱片的薄膜", example: ExamplePair(english: "The membrane vibrated.", chinese: "薄膜振动。"), collocations: [PhrasePair(english: "speaker membrane", chinese: "扬声器振膜")], selected: false, recommendation: SenseRecommendation(score: 0.1, suggested: false, reason: "r", engine: .rule, domainHints: ["music"], sourceRank: 10)),
                ReviewedSense(sourceSenseID: "bio", gloss: "细胞膜", example: ExamplePair(english: "The cell membrane is selective.", chinese: "细胞膜具有选择透过性。"), collocations: [], selected: false, recommendation: SenseRecommendation(score: 0.1, suggested: false, reason: "r", engine: .rule, domainHints: ["biology"], sourceRank: 10))
            ])]
        )
        let appliedOutcome = SemanticRankingOutcome(
            engine: .localReranker,
            ranked: [SemanticScore(sourceSenseID: "bio", score: 2.2), SemanticScore(sourceSenseID: "music", score: -6.0)],
            selectedSourceIDs: ["bio"],
            unitHasContext: true,
            notices: [],
            usedFallback: false
        )
        RecommendationPolicy.apply(appliedOutcome, to: &entry, unitTerms: ["biology"])
        let senses = entry.groups[0].senses
        try expect(senses.first?.sourceSenseID == "bio", "重排未把生物学义项排到第一。")
        try expect(senses.first?.selected == true, "高置信义项未默认勾选。")
        try expect(senses.last?.selected == false, "低置信义项被默认勾选。")
        try expect(senses.last?.recommendation?.engine == .localReranker, "引擎来源未记录。")
        try expect(senses.first?.gloss == "细胞膜", "模型改写了释义！")
        try expect(senses.last?.example?.english == "The membrane vibrated.", "模型改写了例句！")
        try expect(senses.last?.collocations.first?.english == "speaker membrane", "模型改写了搭配！")
        try expect(senses.last?.recommendation?.reason.contains("生物学") != true, "理由编造了不存在的标签。")
        try expect(senses.first?.recommendation?.reason.contains("biology") == true, "理由未说明真实使用的标签。")
    }
}
