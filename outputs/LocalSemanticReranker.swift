import Foundation

// Local cross-encoder reranker client.
//
// The model runs in a separate local runtime (llama.cpp `llama-server`, started
// on 127.0.0.1 only). This type is the whole app-facing surface of that runtime,
// so the runtime stays replaceable: the app only needs `/health` and a batch
// rerank call that echoes an explicit index per document.
//
// What it does NOT do:
//   * never generates, translates, rewrites, merges, or deletes a sense;
//   * never logs unit text, headwords, or glosses;
//   * never starts a model process inside a per-word query.

protocol RerankerTransport {
    func send(_ request: URLRequest, timeout: TimeInterval) async throws -> (data: Data, statusCode: Int)
}

struct URLSessionRerankerTransport: RerankerTransport {
    /// Ephemeral by default: local rerank traffic is never written to a disk cache.
    static let ephemeral: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    var session: URLSession = URLSessionRerankerTransport.ephemeral

    func send(_ request: URLRequest, timeout: TimeInterval) async throws -> (data: Data, statusCode: Int) {
        var request = request
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SemanticRankingError.malformedResponse("非 HTTP 响应。")
            }
            return (data, http.statusCode)
        } catch let error as SemanticRankingError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw SemanticRankingError.timedOut("本地重排请求超过 \(Int(timeout)) 秒。")
        } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .cannotFindHost {
            throw SemanticRankingError.unavailable("未检测到本地重排服务（127.0.0.1）。")
        } catch {
            throw SemanticRankingError.unavailable(error.localizedDescription)
        }
    }
}

struct LocalSemanticReranker: SemanticRankingEngine {
    /// Bumped when the app-facing request/response contract changes. The runtime
    /// reports its own build id through `/props`, which `health()` surfaces.
    static let protocolVersion = 1
    static let defaultBaseURL = URL(string: "http://127.0.0.1:11436")!
    static let defaultModelName = "bge-reranker-v2-m3"
    static let defaultMaximumCandidates = 64
    static let defaultMaximumTextCharacters = 2000

    var baseURL: URL
    var modelName: String
    /// Per the contract the primary engine may not block a lookup longer than 10s.
    var requestTimeout: TimeInterval
    var healthTimeout: TimeInterval
    var maximumCandidates: Int
    var maximumTextCharacters: Int
    var transport: RerankerTransport

    init(baseURL: URL = LocalSemanticReranker.defaultBaseURL,
         modelName: String = LocalSemanticReranker.defaultModelName,
         requestTimeout: TimeInterval = 10,
         healthTimeout: TimeInterval = 3,
         maximumCandidates: Int = LocalSemanticReranker.defaultMaximumCandidates,
         maximumTextCharacters: Int = LocalSemanticReranker.defaultMaximumTextCharacters,
         transport: RerankerTransport = URLSessionRerankerTransport()) {
        self.baseURL = baseURL
        self.modelName = modelName
        self.requestTimeout = requestTimeout
        self.healthTimeout = healthTimeout
        self.maximumCandidates = maximumCandidates
        self.maximumTextCharacters = maximumTextCharacters
        self.transport = transport
    }

    var kind: SemanticEngineKind { .localReranker }

    func health() async -> SemanticEngineHealth {
        do {
            let (healthData, healthStatus) = try await transport.send(urlRequest(path: "health"), timeout: healthTimeout)
            guard healthStatus == 200 else {
                return .unavailable("本地重排服务返回 HTTP \(healthStatus)。")
            }
            guard let object = try? JSONSerialization.jsonObject(with: healthData) as? [String: Any],
                  (object["status"] as? String) == "ok" else {
                return .unavailable("本地重排服务健康检查响应无效。")
            }
            var detail = "本地重排服务已就绪（协议 v\(Self.protocolVersion)"
            if let (propsData, propsStatus) = try? await transport.send(urlRequest(path: "props"), timeout: healthTimeout),
               propsStatus == 200,
               let props = try? JSONSerialization.jsonObject(with: propsData) as? [String: Any] {
                if let build = props["build_info"] as? String, !build.isEmpty {
                    detail += "，运行时 \(build)"
                }
                if let path = props["model_path"] as? String {
                    detail += "，模型 \((path as NSString).lastPathComponent)"
                }
            }
            return .available(detail + "）")
        } catch {
            return .unavailable("未检测到本地重排服务：\(error.localizedDescription)")
        }
    }

    func rank(query: String, candidates: [SemanticCandidate]) async throws -> [SemanticScore] {
        guard !candidates.isEmpty else { throw SemanticRankingError.emptyCandidates }
        guard candidates.count <= maximumCandidates else {
            throw SemanticRankingError.tooManyCandidates(count: candidates.count, maximum: maximumCandidates)
        }
        // Truncation only limits how much of an existing dictionary record is
        // shown to the model; it never rewrites the record.
        let documents = candidates.map { String($0.text.prefix(maximumTextCharacters)) }
        var request = urlRequest(path: "rerank")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("\(Self.protocolVersion)", forHTTPHeaderField: "X-WordWorkbench-Protocol")
        let body: [String: Any] = [
            "protocol": Self.protocolVersion,
            "model": modelName,
            "query": query,
            "documents": documents,
            "top_n": documents.count
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, statusCode) = try await transport.send(request, timeout: requestTimeout)
        guard statusCode == 200 else {
            throw SemanticRankingError.unavailable("本地重排服务返回 HTTP \(statusCode)。")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]] else {
            throw SemanticRankingError.malformedResponse("缺少 results 数组。")
        }
        var scores: [SemanticScore] = []
        for item in results {
            guard let index = (item["index"] as? NSNumber)?.intValue,
                  let raw = (item["relevance_score"] as? NSNumber)?.doubleValue else {
                throw SemanticRankingError.malformedResponse("结果项缺少 index 或 relevance_score。")
            }
            guard index >= 0, index < candidates.count else {
                throw SemanticRankingError.unknownSourceID("下标 \(index) 超出候选范围。")
            }
            guard raw.isFinite else {
                throw SemanticRankingError.nonFiniteScore(candidates[index].sourceSenseID)
            }
            scores.append(SemanticScore(sourceSenseID: candidates[index].sourceSenseID, score: raw))
        }
        try SemanticScoreValidator.validate(scores, against: candidates, engine: .localReranker)
        return SemanticScoreValidator.ranked(scores, candidates: candidates)
    }

    private func urlRequest(path: String) -> URLRequest {
        URLRequest(url: baseURL.appendingPathComponent(path))
    }
}
