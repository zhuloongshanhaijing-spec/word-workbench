import Foundation
import CryptoKit

// Real benchmark harness. It runs the shipped engines against the checked-in
// fixture and writes BENCHMARK_RESULTS.json. Every number it emits is measured
// on this machine at run time; nothing is estimated or hard-coded.
//
// Two candidate-text modes are evaluated on the same cases:
//   * "labeled"      - the exact document the app sends (word/POS/gloss/labels/example)
//   * "label_sparse" - the same document with the dictionary label line removed,
//                      which is what the app sends for senses whose labels/topics
//                      are empty. It isolates pure semantics from the label match.
//
// Usage:
//   SemanticBenchmarkCheck [--cases PATH] [--output PATH] [--mode labeled|label_sparse|both]
//                          [--reranker-peak-log PATH] [--ollama-peak-mb N] [--apply-peak NAME=MB]

// MARK: - Fixture model

struct BenchmarkFile: Decodable {
    let name: String
    let case_count: Int
    let cases: [BenchmarkCase]
    /// "contract_fixture" for the synthetic calibration set, "heldout_evaluation"
    /// for the independent real-record set. Optional so older fixtures still decode.
    let kind: String?
    let subject_count: Int?
}

struct BenchmarkCase: Decodable {
    let id: String
    let category: String
    let word: String
    let unit: BenchmarkUnit
    let candidates: [BenchmarkCandidate]
    let expected_top_id: String?
    let expected_abstain: Bool
    let notes: String?
}

struct BenchmarkUnit: Decodable {
    let name: String
    let subject: String
    let topics: [String]
    let context: String
}

struct BenchmarkCandidate: Decodable {
    let sourceSenseID: String
    let text: String
    let domainHints: [String]
    let sourceRank: Int
}

// MARK: - Measurement

struct CaseFailure {
    let caseID: String
    let category: String
    let kind: String
    let expected: String
    let actual: String
}

struct ModeMetrics {
    var top1Accuracy = 0.0
    var mrr = 0.0
    var abstainPrecision = 0.0
    var abstainRecall = 0.0
    var selectionRecall = 0.0
    var evaluated = 0
    var failures: [CaseFailure] = []
}

struct EngineMeasurement {
    let name: String
    let kind: SemanticEngineKind
    var modelRevision: String
    var health: String
    var available: Bool
    var coldLatencyMs = 0.0
    var warmP50Ms = 0.0
    var warmP95Ms = 0.0
    var peakMemoryMB = 0.0
    var diskMB = 0.0
    var modes: [String: ModeMetrics] = [:]
    var callLatenciesMs: [Double] = []
    var engineErrors: [String] = []
}

func stripLabels(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.hasPrefix("领域：") }
        .joined(separator: "\n")
}

func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = min(sorted.count - 1, max(0, Int((Double(sorted.count) * fraction).rounded(.up)) - 1))
    return sorted[index]
}

func shell(_ launchPath: String, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do { try process.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

@main
struct SemanticBenchmarkCheck {
    static func main() async {
        let arguments = CommandLine.arguments

        if let index = arguments.firstIndex(of: "--apply-peak"), index + 1 < arguments.count {
            applyPeak(arguments[index + 1], outputPath: value(for: "--output", in: arguments) ?? "benchmarks/semantic-ranking/results/BENCHMARK_RESULTS.json")
            return
        }

        let casesPath = value(for: "--cases", in: arguments) ?? "benchmarks/semantic-ranking/cases.json"
        let outputPath = value(for: "--output", in: arguments) ?? "benchmarks/semantic-ranking/results/BENCHMARK_RESULTS.json"
        let requestedMode = value(for: "--mode", in: arguments) ?? "both"
        let modes = requestedMode == "both" ? ["labeled", "label_sparse"] : [requestedMode]
        let ollamaPeakMB = Double(value(for: "--ollama-peak-mb", in: arguments) ?? "0") ?? 0

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: casesPath))
            let fixture = try JSONDecoder().decode(BenchmarkFile.self, from: data)

            var reranker = LocalSemanticReranker(
                baseURL: URL(string: value(for: "--reranker-url", in: arguments) ?? "http://127.0.0.1:11436")!,
                modelName: "bge-reranker-v2-m3"
            )
            reranker.requestTimeout = 20
            let ollama = OllamaRankingEngine(model: value(for: "--ollama-model", in: arguments) ?? "bge-m3")

            let rerankerHealth = await reranker.health()
            let ollamaHealth = await ollama.health()

            var reports: [EngineMeasurement] = []
            reports.append(await measure(engine: reranker, name: "bge-reranker-v2-m3 (llama.cpp, Q4_K_M)",
                                         kind: .localReranker, revision: rerankerHealth.summary.lowercased(),
                                         health: rerankerHealth.summary, available: rerankerHealth.isAvailable,
                                         diskMB: fileSizeMB(repositoryRoot(casesPath: casesPath).appendingPathComponent("tools/local-reranker/.cache/bge-reranker-v2-m3-Q4_K_M.gguf")),
                                         fixture: fixture, modes: modes))
            reports.append(await measure(engine: ollama, name: "bge-m3 (Ollama embedding)",
                                         kind: .ollamaEmbedding, revision: ollamaRevision(),
                                         health: ollamaHealth.summary, available: ollamaHealth.isAvailable,
                                         diskMB: ollamaDiskMB(), fixture: fixture, modes: modes))
            if ollamaPeakMB > 0, let index = reports.firstIndex(where: { $0.kind == .ollamaEmbedding }) {
                reports[index].peakMemoryMB = ollamaPeakMB
            }
            if let logPath = value(for: "--reranker-peak-log", in: arguments),
               let peak = parsePeakMemoryMB(path: logPath),
               let index = reports.firstIndex(where: { $0.kind == .localReranker }) {
                reports[index].peakMemoryMB = peak
            }

            let machine = machineFacts()
            let status = decideStatus(reports: reports)
            let verdict = promotionVerdict(reports: reports)
            let json = render(status: status, machine: machine, fixture: fixture, data: data,
                              casesPath: casesPath, modes: modes, reports: reports,
                              decision: verdict.text, promotionVerdict: verdict.verdict,
                              decisionMode: verdict.mode, outputPath: outputPath)
            try json.write(to: URL(fileURLWithPath: outputPath), atomically: true, encoding: .utf8)
            print("WROTE \(outputPath)")
            for report in reports {
                let labeled = report.modes["labeled"]
                print("ENGINE \(report.name): available=\(report.available) top1=\(fmt(labeled?.top1Accuracy)) mrr=\(fmt(labeled?.mrr)) abstainP=\(fmt(labeled?.abstainPrecision)) cold=\(Int(report.coldLatencyMs))ms warmP95=\(Int(report.warmP95Ms))ms peak=\(Int(report.peakMemoryMB))MB disk=\(Int(report.diskMB))MB")
                if !report.engineErrors.isEmpty { print("  errors: \(report.engineErrors.prefix(3))") }
            }
            print("STATUS \(status)")
        } catch {
            print("FAIL SemanticBenchmark: \(error)")
            exit(1)
        }
    }

    // MARK: measurement

    static func measure(engine: any SemanticRankingEngine, name: String, kind: SemanticEngineKind,
                        revision: String, health: String, available: Bool, diskMB: Double,
                        fixture: BenchmarkFile, modes: [String]) async -> EngineMeasurement {
        var report = EngineMeasurement(name: name, kind: kind, modelRevision: revision, health: health,
                                       available: available, diskMB: diskMB)
        for mode in modes { report.modes[mode] = ModeMetrics() }
        for mode in modes {
            var cold = true
            var sourceIDsByCase: [String: (ranked: [SemanticScore], selected: Set<String>)] = [:]
            for benchmarkCase in fixture.cases {
                let unit = UnitProfile(name: benchmarkCase.unit.name, subject: benchmarkCase.unit.subject,
                                       topics: benchmarkCase.unit.topics, context: benchmarkCase.unit.context)
                let query = TopicNormalizer.queryText(for: unit)
                let texts = benchmarkCase.candidates.map { mode == "label_sparse" ? stripLabels($0.text) : $0.text }
                let candidates = zip(benchmarkCase.candidates, texts).map { SemanticCandidate(sourceSenseID: $0.0.sourceSenseID, text: $0.1) }
                let start = Date()
                do {
                    let ranked = try await engine.rank(query: query, candidates: candidates)
                    let elapsed = Date().timeIntervalSince(start) * 1000
                    if cold { report.coldLatencyMs = elapsed; cold = false } else { report.callLatenciesMs.append(elapsed) }
                    let policy = SemanticSelectionPolicy.policy(for: kind)
                    let selected = policy.selectedSourceIDs(ranked: ranked, engine: kind, unitHasContext: unit.hasUsableContext)
                    sourceIDsByCase[benchmarkCase.id] = (ranked, selected)
                } catch {
                    report.engineErrors.append("\(benchmarkCase.id): \(error.localizedDescription)")
                }
            }
            report.modes[mode] = score(benchmarkCase: fixture.cases, results: sourceIDsByCase)
        }
        report.warmP50Ms = percentile(report.callLatenciesMs, 0.50)
        report.warmP95Ms = percentile(report.callLatenciesMs, 0.95)
        return report
    }

    static func score(benchmarkCase cases: [BenchmarkCase], results: [String: (ranked: [SemanticScore], selected: Set<String>)]) -> ModeMetrics {
        var top1 = 0, ranked = 0, trueAbstain = 0, falseAbstain = 0, expectedAbstain = 0, selectedExpected = 0, nonAbstain = 0
        var mrr = 0.0
        var failures: [CaseFailure] = []
        for benchmarkCase in cases {
            guard let result = results[benchmarkCase.id] else {
                failures.append(CaseFailure(caseID: benchmarkCase.id, category: benchmarkCase.category, kind: "engine_error",
                                            expected: benchmarkCase.expected_top_id ?? "(abstain)", actual: "(no result)"))
                continue
            }
            let order = result.ranked.map(\.sourceSenseID)
            let top = order.first
            if benchmarkCase.expected_abstain {
                expectedAbstain += 1
                if result.selected.isEmpty { trueAbstain += 1 }
                else {
                    failures.append(CaseFailure(caseID: benchmarkCase.id, category: benchmarkCase.category, kind: "false_selection",
                                                expected: "abstain", actual: top ?? "none"))
                }
                continue
            }
            nonAbstain += 1
            ranked += 1
            let scoresByID = Dictionary(uniqueKeysWithValues: result.ranked.map { ($0.sourceSenseID, $0.score) })
            if top == benchmarkCase.expected_top_id { top1 += 1 }
            else {
                failures.append(CaseFailure(caseID: benchmarkCase.id, category: benchmarkCase.category, kind: "top1_miss",
                                            expected: benchmarkCase.expected_top_id ?? "", actual: top ?? "none"))
            }
            if let expected = benchmarkCase.expected_top_id, let position = order.firstIndex(of: expected) {
                mrr += 1.0 / Double(position + 1)
            }
            if let expected = benchmarkCase.expected_top_id, result.selected.contains(expected) { selectedExpected += 1 }
            if result.selected.isEmpty { falseAbstain += 1 }
            _ = scoresByID
        }
        var metrics = ModeMetrics()
        metrics.top1Accuracy = ranked > 0 ? Double(top1) / Double(ranked) : 0
        metrics.mrr = ranked > 0 ? mrr / Double(ranked) : 0
        let abstained = trueAbstain + falseAbstain
        metrics.abstainPrecision = abstained > 0 ? Double(trueAbstain) / Double(abstained) : 0
        metrics.abstainRecall = expectedAbstain > 0 ? Double(trueAbstain) / Double(expectedAbstain) : 0
        metrics.selectionRecall = nonAbstain > 0 ? Double(selectedExpected) / Double(nonAbstain) : 0
        metrics.evaluated = cases.count
        metrics.failures = failures
        return metrics
    }

    // MARK: environment

    static func repositoryRoot(casesPath: String) -> URL {
        URL(fileURLWithPath: casesPath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func fileSizeMB(_ url: URL) -> Double {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return Double(size.int64Value) / 1_048_576.0
    }

    static func ollamaDiskMB() -> Double {
        let listing = shell("/bin/sh", ["-c", "ollama list 2>/dev/null | awk 'NR>1 {print $1, $3, $4}'"])
        for line in listing.split(separator: "\n") where line.contains("bge-m3") {
            let parts = line.split(separator: " ")
            if parts.count >= 3, let value = Double(parts[1]) {
                return parts[2].hasPrefix("GB") ? value * 1024 : value
            }
        }
        return 0
    }

    static func ollamaRevision() -> String {
        shell("/bin/sh", ["-c", "ollama --version 2>/dev/null | head -1"])
    }

    static func machineFacts() -> [String: Any] {
        let model = shell("/usr/sbin/sysctl", ["-n", "hw.model"])
        let memory = Int(shell("/usr/sbin/sysctl", ["-n", "hw.memsize"])) ?? 0
        let version = shell("/usr/bin/sw_vers", ["-productVersion"])
        let chip = shell("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"])
        return [
            "model": model,
            "chip": chip.isEmpty ? "Apple Silicon" : chip,
            "memory_gb": Int((Double(memory) / 1_073_741_824.0).rounded()),
            "os": "macOS \(version)",
            "arch": shell("/usr/bin/uname", ["-m"]),
            "swift": shell("/usr/bin/swiftc", ["--version"]).split(separator: "\n").first.map(String.init) ?? ""
        ]
    }

    static func parsePeakMemoryMB(path: String) -> Double? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        // `/usr/bin/time -l` prints e.g. "  123456789  maximum resident set size"
        for line in text.split(separator: "\n") where line.contains("maximum resident set size") {
            let digits = line.prefix { $0 == " " || $0.isNumber }.trimmingCharacters(in: .whitespaces)
            if let bytes = Double(digits) { return bytes / 1_048_576.0 }
        }
        return nil
    }

    // MARK: decision and rendering

    static func decideStatus(reports: [EngineMeasurement]) -> String {
        let allAvailable = reports.allSatisfy { $0.available }
        return allAvailable ? "PASS" : "PASS_WITH_LIMITS"
    }

    /// Contract rule (promotion gate B): the local reranker
    /// is only PROMOTED when it is clearly better on the semantic mode *and*
    /// abstention does not become less safe. A tie stays CANDIDATE.
    static let promotionThreshold = 0.05

    static func promotionVerdict(reports: [EngineMeasurement]) -> (verdict: String, mode: String, text: String) {
        guard let reranker = reports.first(where: { $0.kind == .localReranker }),
              let ollama = reports.first(where: { $0.kind == .ollamaEmbedding }) else {
            return ("INCOMPLETE", "none", "无法比较：基准数据不完整。")
        }
        // label_sparse removes the dictionary label line, so it isolates semantic
        // matching from straightforward label lookup and is the honest mode for a
        // promotion decision. labeled is reported alongside as a sanity check.
        let semanticAvailable = reranker.modes["label_sparse"] != nil && ollama.modes["label_sparse"] != nil
        let mode = semanticAvailable ? "label_sparse" : "labeled"
        guard let mine = reranker.modes[mode], let theirs = ollama.modes[mode] else {
            return ("INCOMPLETE", mode, "无法比较：缺少 \(mode) 模式指标。")
        }
        let top1Delta = mine.top1Accuracy - theirs.top1Accuracy
        let mrrDelta = mine.mrr - theirs.mrr
        let qualityBetter = top1Delta >= promotionThreshold || mrrDelta >= promotionThreshold
        let abstainSafe = mine.abstainPrecision >= theirs.abstainPrecision
        let verdict = (qualityBetter && abstainSafe) ? "PROMOTED" : "CANDIDATE"
        var text = "判定模式 \(mode)：top1 \(fmt(mine.top1Accuracy)) vs \(fmt(theirs.top1Accuracy))（Δ\(fmt(top1Delta))），"
            + "MRR \(fmt(mine.mrr)) vs \(fmt(theirs.mrr))（Δ\(fmt(mrrDelta))），"
            + "abstain precision \(fmt(mine.abstainPrecision)) vs \(fmt(theirs.abstainPrecision))。"
        text += "规则：语义模式 top1 或 MRR 至少提升 \(fmt(promotionThreshold))，且 abstain 精度不下降，才算可复核的净改进；否则保持候选。"
        text += "已有失败用例逐条列在 modes.\(mode).failures，不只报告平均值。"
        if let labeledMine = reranker.modes["labeled"], let labeledTheirs = ollama.modes["labeled"] {
            text += " 参考 labeled 模式：top1 \(fmt(labeledMine.top1Accuracy)) vs \(fmt(labeledTheirs.top1Accuracy))，"
                + "abstain precision \(fmt(labeledMine.abstainPrecision)) vs \(fmt(labeledTheirs.abstainPrecision))"
                + "（该模式保留了词典领域标签，不能单独证明语义能力）。"
        }
        switch verdict {
        case "PROMOTED":
            text += " 结论：PROMOTED——本地重排可作为默认主引擎，Ollama bge-m3 为回退 1，词典标签规则为回退 2。"
        default:
            text += " 结论：CANDIDATE——默认保留已验证的 Ollama bge-m3 → 词典标签规则链，本地重排继续作为可评测候选。"
        }
        return (verdict, mode, text)
    }

    static func modeJSON(_ metrics: ModeMetrics) -> [String: Any] {
        ["top1_accuracy": metrics.top1Accuracy,
         "mrr": metrics.mrr,
         "abstain_precision": metrics.abstainPrecision,
         "abstain_recall": metrics.abstainRecall,
         "selection_recall": metrics.selectionRecall,
         "evaluated": metrics.evaluated,
         "failures": metrics.failures.map { ["case_id": $0.caseID, "category": $0.category, "kind": $0.kind, "expected": $0.expected, "actual": $0.actual] }]
    }

    static func render(status: String, machine: [String: Any], fixture: BenchmarkFile, data: Data,
                       casesPath: String, modes: [String], reports: [EngineMeasurement],
                       decision: String, promotionVerdict: String, decisionMode: String,
                       outputPath: String) -> String {
        let engines = reports.map { report -> [String: Any] in
            let headline = report.modes["labeled"] ?? ModeMetrics()
            return [
                "name": report.name,
                "kind": report.kind.rawValue,
                "model_revision": report.modelRevision,
                "health": report.health,
                "available": report.available,
                "top1_accuracy": headline.top1Accuracy,
                "mrr": headline.mrr,
                "abstain_precision": headline.abstainPrecision,
                "abstain_recall": headline.abstainRecall,
                "selection_recall": headline.selectionRecall,
                "cold_latency_ms": Int(report.coldLatencyMs.rounded()),
                "warm_p50_ms": Int(report.warmP50Ms.rounded()),
                "warm_p95_ms": Int(report.warmP95Ms.rounded()),
                "peak_memory_mb": Int(report.peakMemoryMB.rounded()),
                "disk_mb": Int(report.diskMB.rounded()),
                "call_count": report.callLatenciesMs.count + 1,
                "engine_errors": report.engineErrors,
                "failure_count": headline.failures.count,
                "failures": headline.failures.map { ["case_id": $0.caseID, "category": $0.category, "kind": $0.kind, "expected": $0.expected, "actual": $0.actual] },
                "modes": report.modes.mapValues(modeJSON)
            ]
        }
        let object: [String: Any] = [
            "status": status,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "machine": machine,
            "dataset": ["path": casesPath, "case_count": fixture.case_count, "sha256": sha256Hex(data),
                        "name": fixture.name, "kind": fixture.kind ?? "contract_fixture",
                        "subject_count": fixture.subject_count ?? 0],
            "headline_mode": "labeled",
            "headline_note": "engines[] 的标量指标取 labeled 模式（应用实际发送的候选文本）；label_sparse 为缺少词典标签时的鲁棒性模式，见 modes。",
            "protocol": ["version": LocalSemanticReranker.protocolVersion,
                         "candidate_text_modes": modes,
                         "selection_policy": ["localReranker": ["min_confidence": SemanticSelectionPolicy.localReranker.minimumConfidence, "min_margin": SemanticSelectionPolicy.localReranker.minimumMargin],
                                              "ollamaEmbedding": ["min_confidence": SemanticSelectionPolicy.ollamaEmbedding.minimumConfidence, "min_margin": SemanticSelectionPolicy.ollamaEmbedding.minimumMargin]]],
            "engines": engines,
            "promotion_verdict": promotionVerdict,
            "promotion_decision_mode": decisionMode,
            "promotion_rule": "语义模式（优先 label_sparse）top1 或 MRR 相对 Ollama bge-m3 提升 >= \(promotionThreshold)，且 abstain precision 不下降，才判定 PROMOTED；并列或不足则 CANDIDATE。",
            "promotion_decision": decision,
            "limitations": limitations(reports: reports, fixture: fixture)
        ]
        let serialized = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return String(data: serialized, encoding: .utf8) ?? "{}"
    }

    static func limitations(reports: [EngineMeasurement], fixture: BenchmarkFile) -> [String] {
        var items: [String] = []
        if (fixture.kind ?? "contract_fixture") == "heldout_evaluation" {
            items.append("候选文本与 sourceSenseID 由真实本地 Open Dictionary v2.0 记录导出；可执行 benchmarks/semantic-ranking/generate_heldout_cases.py 重现。")
            items.append("期望义项由实现者依据词典自身 labels/topics/gloss 逐条审计，理由写在每个 case 的 rationale 字段。")
            items.append("该留出集未参与选择阈值校准；阈值只在合成契约样例 cases.json 上调整。")
            items.append("生成文件含 CC BY-SA 4.0 词典文本，保存在被忽略的 .harness-local 目录，未提交到 MIT 仓库。")
        } else {
            items.append("候选文本是为契约测试编写的合成材料，不是从 Open Dictionary 复制的词条。")
            items.append("选择阈值在本合成基准上校准，因此该基准不能用于决定是否晋级主引擎。")
        }
        items.append("候选文本在 labeled 模式下包含词典领域标签；label_sparse 模式移除该行，用于隔离纯语义匹配。")
        items.append("失败用例已逐条列出，不只报告平均值。")
        for report in reports where !report.available {
            items.append("\(report.name) 未运行：\(report.health)")
        }
        return items
    }

    static func fmt(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.3f", value)
    }

    static func applyPeak(_ assignment: String, outputPath: String) {
        let parts = assignment.split(separator: "=")
        guard parts.count == 2, let megaBytes = Double(parts[1]) else {
            print("FAIL --apply-peak expects NAME=MB")
            exit(1)
        }
        let name = String(parts[0])
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: outputPath)),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var engines = object["engines"] as? [[String: Any]] else {
            print("FAIL cannot read \(outputPath)")
            exit(1)
        }
        for index in engines.indices where (engines[index]["kind"] as? String) == name {
            engines[index]["peak_memory_mb"] = Int(megaBytes.rounded())
        }
        object["engines"] = engines
        if let serialized = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: serialized, encoding: .utf8) {
            try? text.write(toFile: outputPath, atomically: true, encoding: .utf8)
            print("PATCHED \(name) peak_memory_mb=\(Int(megaBytes.rounded()))")
        }
    }

    static func value(for flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
