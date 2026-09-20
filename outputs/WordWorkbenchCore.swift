import Foundation

// v3 domain model. This file deliberately contains no UI, Anki, network, or API key.
// It is the contract shared by the future SwiftUI review screen and dictionary adapters.

struct UnitProfile: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var subject: String
    var topics: [String]
    /// Optional free-text course context, e.g. “cell membrane transport”.
    /// It is used only for local relevance scoring, never exported to Anki.
    var context: String = ""
    var preference: String = "course-terms-first"

    init(id: String = UUID().uuidString, name: String, subject: String, topics: [String], context: String = "", preference: String = "course-terms-first") {
        self.id = id; self.name = name; self.subject = subject; self.topics = topics
        self.context = context; self.preference = preference
    }

    private enum CodingKeys: String, CodingKey { case id, name, subject, topics, context, preference }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try values.decode(String.self, forKey: .name)
        subject = try values.decodeIfPresent(String.self, forKey: .subject) ?? ""
        topics = try values.decodeIfPresent([String].self, forKey: .topics) ?? []
        context = try values.decodeIfPresent(String.self, forKey: .context) ?? ""
        preference = try values.decodeIfPresent(String.self, forKey: .preference) ?? "course-terms-first"
    }

    /// A unit with no subject, topic, or free-text context gives the ranking
    /// engine nothing to be relevant to, so nothing may be preselected.
    var hasUsableContext: Bool {
        !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || topics.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// Local semantic engine preferences. Lives in the shared core so it is covered
/// by the offline decoding tests. Every field has a tolerant decoder: a library
/// written by an earlier build (which only had `modelName`) still loads.
struct SemanticSettings: Codable, Equatable {
    /// "auto" | "localReranker" | "ollamaEmbedding" | "rule"
    var preferredEngine: String = "auto"
    var ollamaModel: String = "bge-m3"
    var rerankerBaseURL: String = "http://127.0.0.1:11436"
    var rerankerModel: String = "bge-reranker-v2-m3"

    init(preferredEngine: String = "auto",
         ollamaModel: String = "bge-m3",
         rerankerBaseURL: String = "http://127.0.0.1:11436",
         rerankerModel: String = "bge-reranker-v2-m3") {
        self.preferredEngine = preferredEngine
        self.ollamaModel = ollamaModel
        self.rerankerBaseURL = rerankerBaseURL
        self.rerankerModel = rerankerModel
    }

    private enum CodingKeys: String, CodingKey {
        case preferredEngine, ollamaModel, rerankerBaseURL, rerankerModel
        /// Legacy key from builds that only knew about Ollama.
        case modelName
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        preferredEngine = try values.decodeIfPresent(String.self, forKey: .preferredEngine) ?? "auto"
        if let model = try values.decodeIfPresent(String.self, forKey: .ollamaModel), !model.isEmpty {
            ollamaModel = model
        } else if let legacy = try values.decodeIfPresent(String.self, forKey: .modelName), !legacy.isEmpty {
            ollamaModel = legacy
        } else {
            ollamaModel = "bge-m3"
        }
        rerankerBaseURL = try values.decodeIfPresent(String.self, forKey: .rerankerBaseURL) ?? "http://127.0.0.1:11436"
        rerankerModel = try values.decodeIfPresent(String.self, forKey: .rerankerModel) ?? "bge-reranker-v2-m3"
    }

    /// Writes only the current keys. `modelName` exists purely so that a library
    /// written by an older build still decodes.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(preferredEngine, forKey: .preferredEngine)
        try container.encode(ollamaModel, forKey: .ollamaModel)
        try container.encode(rerankerBaseURL, forKey: .rerankerBaseURL)
        try container.encode(rerankerModel, forKey: .rerankerModel)
    }
}

struct DeckBook: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var ankiDeckName: String
    var units: [UnitProfile] = []
    var entries: [StructuredEntry] = []
}

struct SourceProvenance: Codable, Equatable {
    // Retained for retry, compliance, and repair. It is never rendered into an Anki card.
    var provider: String
    var sourceID: String?
    var retrievalDate: Date
}

struct ExamplePair: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var english: String
    var chinese: String
}

struct PhrasePair: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var english: String
    var chinese: String
}

struct ReviewedSense: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    // Kept for retry/repair only; it is never rendered in the review screen or card.
    var sourceSenseID: String?
    var gloss: String
    var example: ExamplePair?
    var collocations: [PhrasePair] = []
    /// New entries begin unchecked unless a recommendation is sufficiently strong.
    var selected = false
    var needsRepair = false
    /// Internal evidence only; it is never written into the Anki card.
    var recommendation: SenseRecommendation?

    init(id: String = UUID().uuidString, sourceSenseID: String? = nil, gloss: String, example: ExamplePair? = nil, collocations: [PhrasePair] = [], selected: Bool = false, needsRepair: Bool = false, recommendation: SenseRecommendation? = nil) {
        self.id = id; self.sourceSenseID = sourceSenseID; self.gloss = gloss; self.example = example
        self.collocations = collocations; self.selected = selected; self.needsRepair = needsRepair; self.recommendation = recommendation
    }

    private enum CodingKeys: String, CodingKey { case id, sourceSenseID, gloss, example, collocations, selected, needsRepair, recommendation }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        sourceSenseID = try values.decodeIfPresent(String.self, forKey: .sourceSenseID)
        gloss = try values.decode(String.self, forKey: .gloss)
        example = try values.decodeIfPresent(ExamplePair.self, forKey: .example)
        collocations = try values.decodeIfPresent([PhrasePair].self, forKey: .collocations) ?? []
        // Preserve the user's previous choices when opening old local libraries.
        selected = try values.decodeIfPresent(Bool.self, forKey: .selected) ?? true
        needsRepair = try values.decodeIfPresent(Bool.self, forKey: .needsRepair) ?? false
        recommendation = try values.decodeIfPresent(SenseRecommendation.self, forKey: .recommendation)
    }
}

struct SenseRecommendation: Codable, Equatable {
    /// `rule` and `ollamaEmbedding` are the legacy values and must keep decoding.
    /// `localReranker` is additive; an old library never contains it.
    enum Engine: String, Codable { case rule, ollamaEmbedding, localReranker }
    var score: Double
    var suggested: Bool
    var reason: String
    var engine: Engine
    var domainHints: [String]
    var sourceRank: Int
}

struct PartOfSpeechGroup: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var label: String
    var senses: [ReviewedSense]
    var needsRepair = false
}

struct StructuredEntry: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var unitID: String
    var word: String
    var groups: [PartOfSpeechGroup] = []
    var provenance: [SourceProvenance] = []
    var imported = false

    var hasSelectedSense: Bool {
        groups.contains { $0.senses.contains { $0.selected } }
    }
}

enum ReviewAction {
    static func toggleSense(_ entry: inout StructuredEntry, groupID: String, senseID: String) {
        guard let group = entry.groups.firstIndex(where: { $0.id == groupID }),
              let sense = entry.groups[group].senses.firstIndex(where: { $0.id == senseID }) else { return }
        entry.groups[group].senses[sense].selected.toggle()
    }

    static func removeCollocation(_ entry: inout StructuredEntry, groupID: String, senseID: String, phraseID: String) {
        guard let group = entry.groups.firstIndex(where: { $0.id == groupID }),
              let sense = entry.groups[group].senses.firstIndex(where: { $0.id == senseID }) else { return }
        entry.groups[group].senses[sense].collocations.removeAll { $0.id == phraseID }
    }

    static func flagForRepair(_ entry: inout StructuredEntry, groupID: String) {
        guard let group = entry.groups.firstIndex(where: { $0.id == groupID }) else { return }
        entry.groups[group].needsRepair = true
    }
}

enum CardRenderer {
    static func escapedHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func backHTML(for entry: StructuredEntry) -> String {
        entry.groups.compactMap { group -> String? in
            let senses = group.senses.filter(\.selected)
            guard !senses.isEmpty else { return nil }
            let senseHTML = senses.map { sense -> String in
                let gloss = "<li>\(escapedHTML(sense.gloss))"
                let phrases = sense.collocations.isEmpty ? "" : "<div class='label'>搭配</div><ul>" + sense.collocations.map { "<li><b>\(escapedHTML($0.english))</b>：\(escapedHTML($0.chinese))</li>" }.joined() + "</ul>"
                let example: String
                if let item = sense.example {
                    example = "<div class='label'>例句</div><div class='example'>\(escapedHTML(item.english))<br><span>\(escapedHTML(item.chinese))</span></div>"
                } else { example = "" }
                return gloss + phrases + example + "</li>"
            }.joined()
            return "<section><div class='pos'>\(escapedHTML(group.label))</div><div class='label'>中文义项</div><ul>\(senseHTML)</ul></section>"
        }.joined(separator: "<hr>")
    }
}

struct SourceSense: Codable, Equatable {
    var sourceSenseID: String
    var partOfSpeech: String
    var gloss: String
    var examples: [ExamplePair]
    var explicitPhrases: [PhrasePair]
    var domainHints: [String]
    var sourceRank: Int = 100
}

extension SourceSense {
    /// The single canonical text used as ranking evidence for a sense. It is
    /// assembled purely from fields Open Dictionary already returned; the
    /// engine may score it but never rewrite it.
    func semanticDocument(headword: String) -> String {
        let example = examples.first.map { "例句：\($0.english) \($0.chinese)" } ?? ""
        return [
            "单词：\(headword)",
            "词性：\(partOfSpeech)",
            "义项：\(gloss)",
            "领域：\(domainHints.joined(separator: "，"))",
            example
        ].filter { !$0.hasSuffix("：") }.joined(separator: "\n")
    }
}

struct SourceEntry: Codable, Equatable {
    var headword: String
    var senses: [SourceSense]
    var provenance: SourceProvenance
}

protocol DictionarySource {
    var providerName: String { get }
    func lookup(word: String) async throws -> SourceEntry
}

enum DictionarySourceError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): return message }
    }
}

struct DisabledLicensedSource: DictionarySource {
    let providerName: String
    // Network implementations stay disabled until the user has written permission and credentials.
    func lookup(word: String) async throws -> SourceEntry {
        throw DictionarySourceError.unavailable("\(providerName) 尚未启用：需要用户的书面许可与本机凭据。")
    }
}

enum SenseResolver {
    static func resolve(_ source: SourceEntry, for unit: UnitProfile) -> StructuredEntry {
        let loweredTopics = TopicNormalizer.terms(for: unit)
        let groups = Dictionary(grouping: source.senses, by: \.partOfSpeech).map { pos, senses in
            let ordered = senses.sorted { left, right in
                let leftMatch = !loweredTopics.isDisjoint(with: Set(left.domainHints.map { $0.lowercased() }))
                let rightMatch = !loweredTopics.isDisjoint(with: Set(right.domainHints.map { $0.lowercased() }))
                if leftMatch != rightMatch { return leftMatch }
                if left.sourceRank != right.sourceRank { return left.sourceRank < right.sourceRank }
                return left.sourceSenseID < right.sourceSenseID
            }
            return PartOfSpeechGroup(label: pos, senses: ordered.map { sourceSense in
                let recommendation = RecommendationPolicy.ruleRecommendation(sourceSense, unitTerms: loweredTopics)
                return ReviewedSense(sourceSenseID: sourceSense.sourceSenseID, gloss: sourceSense.gloss, example: sourceSense.examples.first, collocations: sourceSense.explicitPhrases, selected: recommendation.suggested, recommendation: recommendation)
            })
        }.sorted { $0.label < $1.label }
        return StructuredEntry(unitID: unit.id, word: source.headword, groups: groups, provenance: [source.provenance])
    }
}

enum TopicNormalizer {
    /// A small transparent bridge for common Chinese school subjects. The embedding
    /// model handles broader semantic matching; this only strengthens the offline fallback.
    private static let aliases: [String: [String]] = [
        "生物": ["biology", "microbiology", "anatomy", "genetics", "ecology"],
        "化学": ["chemistry", "biochemistry", "organic chemistry"],
        "物理": ["physics", "mechanics", "thermodynamics"],
        "数学": ["mathematics", "algebra", "geometry", "statistics"],
        "环境": ["environment", "ecology", "climate"],
        "人文": ["humanities", "history", "society", "culture"],
        "情绪": ["emotion", "psychology", "feeling"]
    ]

    static func terms(for unit: UnitProfile) -> Set<String> {
        var result = Set(([unit.subject] + unit.topics).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
        for term in Array(result) { result.formUnion(aliases[term] ?? []) }
        return result
    }

    static func queryText(for unit: UnitProfile) -> String {
        (["课程学科：\(unit.subject)", "主题：\(unit.topics.joined(separator: "，"))", unit.context.isEmpty ? "" : "单元说明：\(unit.context)"])
            .filter { !$0.hasSuffix("：") }.joined(separator: "\n")
    }
}

enum RecommendationPolicy {
    static func ruleRecommendation(_ sense: SourceSense, unitTerms: Set<String>) -> SenseRecommendation {
        let matched = sense.domainHints.filter { unitTerms.contains($0.lowercased()) }
        let rankScore = sourceRankScore(sense.sourceRank)
        let score = matched.isEmpty ? 0.12 + rankScore * 0.12 : 0.60 + rankScore * 0.18
        return SenseRecommendation(score: score, suggested: !matched.isEmpty, reason: matched.isEmpty ? "未发现与本 Unit 对应的词典领域标签" : "匹配词典领域标签：\(matched.joined(separator: "、"))", engine: .rule, domainHints: sense.domainHints, sourceRank: sense.sourceRank)
    }

    static func applyEmbeddingScores(_ scoresBySourceID: [String: Double], to entry: inout StructuredEntry) {
        for groupIndex in entry.groups.indices {
            for senseIndex in entry.groups[groupIndex].senses.indices {
                let sense = entry.groups[groupIndex].senses[senseIndex]
                guard let sourceSenseID = sense.sourceSenseID, let score = scoresBySourceID[sourceSenseID] else { continue }
                let prior = sense.recommendation
                // Cosine ranges from -1 to 1; map it into a readable 0...1 relevance component.
                let semantic = min(1, max(0, (score + 1) / 2))
                let labelScore = (prior?.reason.hasPrefix("匹配") == true) ? 1.0 : 0.0
                let rankScore = sourceRankScore(prior?.sourceRank ?? 100)
                let combined = 0.65 * semantic + 0.25 * labelScore + 0.10 * rankScore
                let suggested = combined >= 0.64
                let reason = "语义相关度 \(Int((semantic * 100).rounded()))%" + (labelScore > 0 ? "；\(prior?.reason ?? "")" : "")
                entry.groups[groupIndex].senses[senseIndex].recommendation = SenseRecommendation(score: combined, suggested: suggested, reason: reason, engine: .ollamaEmbedding, domainHints: prior?.domainHints ?? [], sourceRank: prior?.sourceRank ?? 100)
                entry.groups[groupIndex].senses[senseIndex].selected = suggested
            }
        }
        entry.groups = entry.groups.map { group in
            var sorted = group
            sorted.senses.sort { ($0.recommendation?.score ?? 0) > ($1.recommendation?.score ?? 0) }
            return sorted
        }
    }

    static func sourceRankScore(_ rank: Int) -> Double {
        switch rank { case ..<15: return 1; case ..<25: return 0.6; default: return 0.25 }
    }
}

enum FormatterPolicy {
    static func prompt(entry: StructuredEntry, unit: UnitProfile) -> String {
        """
        Return JSON only. You are formatting already verified dictionary records for a Chinese learner.
        Unit: \(unit.name); subject: \(unit.subject); topics: \(unit.topics.joined(separator: ", ")).
        Keep every input group and sense ID. You may improve concise Chinese wording and rank senses for this unit.
        Do not invent, delete, merge, or move English facts. Bind examples only to their existing sense.
        A collocation may be output only when it came from explicitPhrases; an empty list is correct.
        Mark a group needsRepair only if its part of speech is internally inconsistent.
        Input: \(String(data: (try? JSONEncoder().encode(entry)) ?? Data(), encoding: .utf8) ?? "{}")
        """
    }
}
