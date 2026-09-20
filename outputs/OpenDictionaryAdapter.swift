import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// Adapter for the published Open Dictionary distribution_entry_v5 shape.
// It deliberately decodes a local fixture/package only: downloading, checksum
// verification, and user consent are separate UI work, so no data is silently fetched.

enum OpenDictionaryAdapterError: LocalizedError {
    case invalidPackage(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidPackage(let message): return "Open Dictionary 数据无效：\(message)"
        case .notFound(let word): return "Open Dictionary 未收录：\(word)"
        }
    }
}

struct OpenDictionarySource: DictionarySource {
    let providerName = "Open Dictionary（Wiktionary 衍生，CC BY-SA 4.0）"
    private let entries: [String: OpenDictionaryDistributionEntry]
    private let databaseURL: URL?

    init(jsonLines: String) throws {
        var parsed: [String: OpenDictionaryDistributionEntry] = [:]
        for (lineNumber, rawLine) in jsonLines.split(whereSeparator: \.isNewline).enumerated() {
            guard !rawLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            do {
                let entry = try JSONDecoder().decode(OpenDictionaryDistributionEntry.self, from: Data(rawLine.utf8))
                parsed[entry.headword.lowercased()] = entry
            } catch {
                throw OpenDictionaryAdapterError.invalidPackage("第 \(lineNumber + 1) 行无法解析（\(error.localizedDescription)）")
            }
        }
        guard !parsed.isEmpty else { throw OpenDictionaryAdapterError.invalidPackage("没有词条") }
        entries = parsed
        databaseURL = nil
    }

    init(fixtureData: Data) throws {
        let entry = try JSONDecoder().decode(OpenDictionaryDistributionEntry.self, from: fixtureData)
        entries = [entry.headword.lowercased(): entry]
        databaseURL = nil
    }

    /// Opens the user-installed, read-only distribution.sqlite package.
    /// The package itself is not bundled in this MIT repository.
    init(databaseURL: URL) throws {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw OpenDictionaryAdapterError.invalidPackage("找不到 distribution.sqlite")
        }
        entries = [:]
        self.databaseURL = databaseURL
    }

    func lookup(word: String) async throws -> SourceEntry {
        let entry: OpenDictionaryDistributionEntry
        if let databaseURL {
            entry = try readEntry(from: databaseURL, word: word)
        } else if let fixtureEntry = entries[word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] {
            entry = fixtureEntry
        } else {
            throw OpenDictionaryAdapterError.notFound(word)
        }
        let senses = entry.posGroups.flatMap { group in
            group.meanings.map { meaning in
                SourceSense(
                    // The distribution contract scopes sense_id to a pos group,
                    // identified by (pos, etymology_id). Preserve that identity
                    // so real multi-etymology entries cannot collide.
                    sourceSenseID: group.sourceSenseID(for: meaning.senseID),
                    partOfSpeech: group.pos,
                    gloss: meaning.shortGloss?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? meaning.shortGloss! : meaning.learnerExplanation,
                    examples: (meaning.examples ?? []).map { ExamplePair(english: $0.text, chinese: $0.translation) },
                    explicitPhrases: [],
                    // Labels/topics come from the local distribution.  They are
                    // evidence for unit-aware ordering, never material invented
                    // by the formatter.
                    domainHints: meaning.labels + meaning.topics,
                    sourceRank: meaning.priority.rank
                )
            }
        }
        guard !senses.isEmpty else { throw OpenDictionaryAdapterError.invalidPackage("\(entry.headword) 没有可导入义项") }
        return SourceEntry(
            headword: entry.headword,
            senses: senses,
            provenance: SourceProvenance(provider: providerName, sourceID: entry.headword, retrievalDate: Date())
        )
    }

    private func readEntry(from databaseURL: URL, word: String) throws -> OpenDictionaryDistributionEntry {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            throw OpenDictionaryAdapterError.invalidPackage("无法以只读方式打开 SQLite")
        }
        defer { sqlite3_close(database) }

        let query = "SELECT document_json FROM entries WHERE normalized_headword = ? LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw OpenDictionaryAdapterError.invalidPackage("SQLite schema 不符合 distribution_entry_v5")
        }
        defer { sqlite3_finalize(statement) }
        let normalized = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        sqlite3_bind_text(statement, 1, normalized, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0) else {
            throw OpenDictionaryAdapterError.notFound(word)
        }
        return try JSONDecoder().decode(OpenDictionaryDistributionEntry.self, from: Data(String(cString: raw).utf8))
    }
}

private struct OpenDictionaryDistributionEntry: Decodable {
    let headword: String
    let posGroups: [OpenDictionaryPOSGroup]

    enum CodingKeys: String, CodingKey {
        case headword
        case posGroups = "pos_groups"
    }
}

private struct OpenDictionaryPOSGroup: Decodable {
    let pos: String
    let etymologyID: String?
    let meanings: [OpenDictionaryMeaning]

    enum CodingKeys: String, CodingKey {
        case pos, meanings
        case etymologyID = "etymology_id"
    }

    func sourceSenseID(for senseID: String) -> String {
        guard let etymologyID, !etymologyID.isEmpty else { return senseID }
        return "od:\(pos)|\(etymologyID)|\(senseID)"
    }
}

private struct OpenDictionaryMeaning: Decodable {
    let senseID: String
    let shortGloss: String?
    let learnerExplanation: String
    let examples: [OpenDictionaryExample]?
    let priority: OpenDictionaryPriority
    let labels: [String]
    let topics: [String]

    enum CodingKeys: String, CodingKey {
        case senseID = "sense_id"
        case shortGloss = "short_gloss"
        case learnerExplanation = "learner_explanation"
        case examples, priority, labels, topics
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        senseID = try values.decode(String.self, forKey: .senseID)
        shortGloss = try values.decodeIfPresent(String.self, forKey: .shortGloss)
        learnerExplanation = try values.decodeIfPresent(String.self, forKey: .learnerExplanation) ?? ""
        examples = try values.decodeIfPresent([OpenDictionaryExample].self, forKey: .examples)
        priority = try values.decode(OpenDictionaryPriority.self, forKey: .priority)
        labels = try values.decodeIfPresent([String].self, forKey: .labels) ?? []
        topics = try values.decodeIfPresent([String].self, forKey: .topics) ?? []
    }
}

private enum OpenDictionaryPriority: String, Decodable {
    case core, common, rare

    var rank: Int {
        switch self {
        case .core: return 10
        case .common: return 20
        case .rare: return 30
        }
    }
}

private struct OpenDictionaryExample: Decodable {
    let text: String
    let translation: String
}
