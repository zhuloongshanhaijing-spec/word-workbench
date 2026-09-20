import Foundation

enum OllamaSemanticError: LocalizedError {
    case unavailable(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .invalidResponse: return "Ollama 返回的向量格式无效。"
        }
    }
}

struct OllamaModelTag: Decodable, Identifiable, Equatable {
    let name: String
    var id: String { name }
}

private struct OllamaTagsResponse: Decodable { let models: [OllamaModelTag] }
private struct OllamaEmbedResponse: Decodable { let embeddings: [[Double]] }

/// Local-only bridge to Ollama's embedding API. It never sends course content
/// outside localhost and never asks a generative model to write card content.
struct OllamaSemanticRecommender {
    static let defaultModel = "bge-m3"
    private let endpoint = URL(string: "http://127.0.0.1:11434")!
    /// Ephemeral: no disk cache for local model traffic, and nothing about the
    /// unit or the dictionary record is written anywhere.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    func installedModels() async throws -> [OllamaModelTag] {
        let (data, response) = try await Self.session.data(from: endpoint.appending(path: "api/tags"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw OllamaSemanticError.unavailable("无法连接 Ollama。请打开 Ollama 后重试。") }
        return try JSONDecoder().decode(OllamaTagsResponse.self, from: data).models
    }

    func install(model: String) async throws {
        var request = URLRequest(url: endpoint.appending(path: "api/pull"))
        request.httpMethod = "POST"
        request.timeoutInterval = 7_200
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": model, "stream": false])
        let (_, response) = try await Self.session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw OllamaSemanticError.unavailable("Ollama 未能下载 \(model)。请检查网络、磁盘空间和 Ollama 是否已启动。") }
    }

    func semanticScores(query: String, candidates: [String], model: String) async throws -> [Double] {
        guard !candidates.isEmpty else { return [] }
        var request = URLRequest(url: endpoint.appending(path: "api/embed"))
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "input": [query] + candidates, "truncate": true])
        let (data, response) = try await Self.session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw OllamaSemanticError.unavailable("Ollama 模型“\(model)”不可用。请先在设置中下载或选择已安装模型。") }
        let vectors = try JSONDecoder().decode(OllamaEmbedResponse.self, from: data).embeddings
        guard let queryVector = vectors.first, vectors.count == candidates.count + 1 else { throw OllamaSemanticError.invalidResponse }
        return vectors.dropFirst().map { cosine(queryVector, $0) }
    }

    func candidateTexts(source: SourceEntry) -> [String] {
        source.senses.map { $0.semanticDocument(headword: source.headword) }
    }

    private func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, left = 0.0, right = 0.0
        for index in a.indices { dot += a[index] * b[index]; left += a[index] * a[index]; right += b[index] * b[index] }
        guard left > 0, right > 0 else { return 0 }
        return dot / (sqrt(left) * sqrt(right))
    }
}

/// Fallback 1 of the ranking chain. It is an embedding similarity engine, not a
/// cross-encoder: scores are cosine similarities, and the coordinator maps them
/// monotonically into 0...1 without ever calling them a probability.
struct OllamaRankingEngine: SemanticRankingEngine {
    var model: String
    var recommender: OllamaSemanticRecommender = OllamaSemanticRecommender()

    init(model: String = OllamaSemanticRecommender.defaultModel) {
        self.model = model
    }

    var kind: SemanticEngineKind { .ollamaEmbedding }

    func health() async -> SemanticEngineHealth {
        do {
            let models = try await recommender.installedModels()
            let installed = models.contains { $0.name == model || $0.name.hasPrefix("\(model):") }
            return installed ? .available("Ollama 已就绪：\(model)") : .unavailable("Ollama 已连接，但未下载 \(model)。")
        } catch {
            return .unavailable("未连接 Ollama：\(error.localizedDescription)")
        }
    }

    func rank(query: String, candidates: [SemanticCandidate]) async throws -> [SemanticScore] {
        guard !candidates.isEmpty else { throw SemanticRankingError.emptyCandidates }
        // Ollama returns one embedding per input in request order, so the mapping
        // is positional by construction on both sides; the count check below is
        // the guard against a silently short response.
        let similarities = try await recommender.semanticScores(query: query, candidates: candidates.map(\.text), model: model)
        guard similarities.count == candidates.count else {
            throw SemanticRankingError.malformedResponse("Ollama 返回 \(similarities.count) 个向量，期望 \(candidates.count) 个。")
        }
        var scores: [SemanticScore] = []
        for (candidate, similarity) in zip(candidates, similarities) {
            guard similarity.isFinite else { throw SemanticRankingError.nonFiniteScore(candidate.sourceSenseID) }
            scores.append(SemanticScore(sourceSenseID: candidate.sourceSenseID, score: similarity))
        }
        try SemanticScoreValidator.validate(scores, against: candidates, engine: .ollamaEmbedding)
        return SemanticScoreValidator.ranked(scores, candidates: candidates)
    }
}
