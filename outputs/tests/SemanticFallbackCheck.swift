import Foundation

// Fallback-chain and backward-compatibility tests.
//
//   * every failure mode falls through to the next engine, and finally to the
//     transparent dictionary-label rule, without losing a single sense;
//   * a library written before the new settings fields existed still decodes;
//   * an already-saved `selected` value survives a plain load.

struct ThrowingEngine: SemanticRankingEngine {
    let kind: SemanticEngineKind
    let error: SemanticRankingError
    func health() async -> SemanticEngineHealth { .unavailable(error.localizedDescription) }
    func rank(query: String, candidates: [SemanticCandidate]) async throws -> [SemanticScore] {
        throw error
    }
}

struct FixedEngine: SemanticRankingEngine {
    let kind: SemanticEngineKind
    let scores: [Double]
    func health() async -> SemanticEngineHealth { .available("stub") }
    func rank(query: String, candidates: [SemanticCandidate]) async throws -> [SemanticScore] {
        candidates.enumerated().map { SemanticScore(sourceSenseID: $0.element.sourceSenseID, score: scores.indices.contains($0.offset) ? scores[$0.offset] : 0) }
    }
}

/// Returns results whose IDs do not match the request, to prove the coordinator
/// validates instead of trusting the engine.
struct MismatchedEngine: SemanticRankingEngine {
    let kind: SemanticEngineKind
    func health() async -> SemanticEngineHealth { .available("stub") }
    func rank(query: String, candidates: [SemanticCandidate]) async throws -> [SemanticScore] {
        [SemanticScore(sourceSenseID: "not-a-candidate", score: 1.0)]
    }
}


enum FallbackCheckFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { if case .failed(let message) = self { return message }; return "" }
}

func fallbackExpect(_ condition: Bool, _ message: String) throws {
    if !condition { throw FallbackCheckFailure.failed(message) }
}

@main
struct SemanticFallbackCheck {
    static func main() async {
        do {
            try await run()
            print("PASS SemanticFallback: ordered fallback, validation fallback, legacy decode, saved choices preserved")
        } catch {
            fatalError("FAIL SemanticFallback: \(error)")
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    static func run() async throws {
        let candidates = [
            SemanticCandidate(sourceSenseID: "bio", text: "单词：membrane\n义项：细胞膜\n领域：biology"),
            SemanticCandidate(sourceSenseID: "music", text: "单词：membrane\n义项：唱片的薄膜\n领域：music")
        ]

        // 1. Every required primary failure mode falls through to Ollama.
        let primaryFailures: [(String, SemanticRankingError)] = [
            ("timeout", .timedOut("主服务超时")),
            ("connection_refused", .unavailable("127.0.0.1 拒绝连接")),
            ("http_error", .unavailable("HTTP 500")),
            ("malformed_json", .malformedResponse("不是合法 JSON"))
        ]
        for (label, failure) in primaryFailures {
            let coordinator = SemanticRankingCoordinator(engines: [
                ThrowingEngine(kind: .localReranker, error: failure),
                FixedEngine(kind: .ollamaEmbedding, scores: [0.2, -0.4])
            ])
            let outcome = await coordinator.rank(query: "生物 细胞膜", candidates: candidates, unitHasContext: true)
            try fallbackExpect(outcome.engine == .ollamaEmbedding, "\(label)：未回退到 Ollama：\(outcome.engine)")
            try fallbackExpect(outcome.usedFallback, "\(label)：回退标志缺失。")
            try fallbackExpect(outcome.ranked.count == candidates.count, "\(label)：回退后义项数量变化。")
            try fallbackExpect(outcome.ranked.first?.sourceSenseID == "bio", "\(label)：回退结果排序错误：\(outcome.ranked)")
            try fallbackExpect(outcome.notices.contains { $0.contains("本地重排") }, "\(label)：未记录主引擎失败原因：\(outcome.notices)")
        }

        // 2. Primary answers with unknown IDs -> validated -> fallback.
        let mismatched = SemanticRankingCoordinator(engines: [
            MismatchedEngine(kind: .localReranker),
            FixedEngine(kind: .ollamaEmbedding, scores: [0.9, 0.1])
        ])
        let recovered = await mismatched.rank(query: "生物", candidates: candidates, unitHasContext: true)
        try fallbackExpect(recovered.engine == .ollamaEmbedding, "未知 ID 未触发回退：\(recovered.engine)")
        try fallbackExpect(recovered.ranked.count == candidates.count, "回退后候选数量错误。")

        // 3. Every engine fails -> rule outcome with no score, senses still intact.
        let allFail = SemanticRankingCoordinator(engines: [
            ThrowingEngine(kind: .localReranker, error: .unavailable("服务未启动")),
            ThrowingEngine(kind: .ollamaEmbedding, error: .unavailable("Ollama 未启动"))
        ])
        let ruleOutcome = await allFail.rank(query: "生物", candidates: candidates, unitHasContext: true)
        try fallbackExpect(ruleOutcome.engine == .rule, "全部失败后未退回规则：\(ruleOutcome.engine)")
        try fallbackExpect(ruleOutcome.ranked.isEmpty, "规则回退不应伪造分数。")
        try fallbackExpect(ruleOutcome.notices.contains { $0.contains("标签规则") }, "未说明已退回标签规则：\(ruleOutcome.notices)")

        var entry = StructuredEntry(
            unitID: "u", word: "membrane",
            groups: [PartOfSpeechGroup(label: "noun", senses: [
                ReviewedSense(sourceSenseID: "bio", gloss: "细胞膜", selected: true,
                              recommendation: SenseRecommendation(score: 0.8, suggested: true, reason: "匹配词典领域标签：biology", engine: .rule, domainHints: ["biology"], sourceRank: 10)),
                ReviewedSense(sourceSenseID: "music", gloss: "唱片的薄膜", selected: false,
                              recommendation: SenseRecommendation(score: 0.12, suggested: false, reason: "未发现与本 Unit 对应的词典领域标签", engine: .rule, domainHints: ["music"], sourceRank: 10))
            ])]
        )
        let snapshot = entry
        RecommendationPolicy.apply(ruleOutcome, to: &entry, unitTerms: ["biology"])
        try fallbackExpect(entry == snapshot, "规则回退改动了已有推荐或勾选。")
        try fallbackExpect(entry.groups[0].senses.count == 2, "规则回退丢失了义项。")

        // 4. A saved choice is not reset by loading a legacy library blob.
        let legacySenseJSON = #"{"id":"s1","gloss":"细胞膜","selected":false}"#
        let legacySense = try decode(ReviewedSense.self, legacySenseJSON)
        try fallbackExpect(legacySense.selected == false, "旧库中已保存的 false 被重置。")
        let missingSelectedJSON = #"{"id":"s2","gloss":"细胞膜"}"#
        let missingSelected = try decode(ReviewedSense.self, missingSelectedJSON)
        try fallbackExpect(missingSelected.selected == true, "缺少 selected 的旧数据未按旧行为默认保留。")

        for legacy in ["rule", "ollamaEmbedding", "localReranker"] {
            let json = #"{"score":0.5,"suggested":true,"reason":"r","engine":"\#(legacy)","domainHints":["biology"],"sourceRank":10}"#
            let recommendation = try decode(SenseRecommendation.self, json)
            try fallbackExpect(recommendation.engine.rawValue == legacy, "旧引擎值 \(legacy) 无法解码。")
        }

        // 5. Old semantic settings (only `modelName`) still decode with defaults.
        let legacySettings = try decode(SemanticSettings.self, #"{"modelName":"bge-m3"}"#)
        try fallbackExpect(legacySettings.ollamaModel == "bge-m3", "旧 modelName 未迁移：\(legacySettings.ollamaModel)")
        try fallbackExpect(legacySettings.preferredEngine == "auto", "缺失的新字段没有默认值。")
        try fallbackExpect(legacySettings.rerankerBaseURL == "http://127.0.0.1:11436", "重排地址默认值错误。")
        let emptySettings = try decode(SemanticSettings.self, "{}")
        try fallbackExpect(emptySettings == SemanticSettings(), "空设置对象未得到全默认值。")

        // 6. Round-trip through the current encoder loses nothing.
        let custom = SemanticSettings(preferredEngine: "localReranker", ollamaModel: "qwen3:8b", rerankerBaseURL: "http://127.0.0.1:11500", rerankerModel: "bge-reranker-v2-m3")
        let roundTripped = try JSONDecoder().decode(SemanticSettings.self, from: JSONEncoder().encode(custom))
        try fallbackExpect(roundTripped == custom, "设置编解码往返不一致。")
        let encoded = String(data: try JSONEncoder().encode(custom), encoding: .utf8) ?? ""
        try fallbackExpect(!encoded.contains("modelName"), "不应再写出旧字段 modelName：\(encoded)")

        // 7. Engine kinds stay decodable by raw value for stored settings.
        try fallbackExpect(SemanticEngineKind(rawValue: "localReranker") == .localReranker, "引擎类型枚举不兼容。")
        try fallbackExpect(SenseRecommendation.Engine(rawValue: "ollamaEmbedding") == .ollamaEmbedding, "旧引擎枚举不兼容。")
    }
}
