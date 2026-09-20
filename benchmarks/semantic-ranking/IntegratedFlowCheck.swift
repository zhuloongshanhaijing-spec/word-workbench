import Foundation

// Integrated real-input flow check (P3).
//
// It drives the *shipped* product functions over a real Open Dictionary record
// and the real AnkiConnect endpoint:
//
//   real SQLite lookup -> SenseResolver -> SemanticRankingCoordinator (real
//   engines) -> conservative preselection + reasons -> manual re-selection ->
//   Codable save/reopen -> CardRenderer.backHTML -> AnkiConnect addNote -> read back
//
// What it proves:
//   * every dictionary sense survives capture and review, with unique identity;
//   * the ranking engine that actually answered is recorded, with a reason;
//   * manually changed selections survive an encode/decode round trip;
//   * only selected senses reach the card, and selected dictionary text is
//     byte-identical to the source record (the model never rewrites facts);
//   * the AnkiConnect request body is accepted and stored verbatim.
//
// Usage:
//   IntegratedFlowCheck <distribution.sqlite> <anki-connect-url> <receipt.json>

struct FlowFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

func flowExpect(_ condition: Bool, _ message: String) throws {
    if !condition { throw FlowFailure(message: message) }
}

// MARK: - Minimal AnkiConnect client (same wire contract as the app)

struct AnkiResult {
    var value: Any
    var requestBody: Data
}

func ankiInvoke(base: URL, action: String, params: [String: Any] = [:]) async throws -> AnkiResult {
    var request = URLRequest(url: base)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let body = try JSONSerialization.data(withJSONObject: ["action": action, "version": 6, "params": params])
    request.httpBody = body
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    let (data, response) = try await URLSession(configuration: configuration).data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200,
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw FlowFailure(message: "\(action): AnkiConnect 响应无效")
    }
    if let error = object["error"] as? String, !error.isEmpty {
        throw FlowFailure(message: "\(action): \(error)")
    }
    return AnkiResult(value: object["result"] ?? NSNull(), requestBody: body)
}

@main
struct IntegratedFlowCheck {
    static func main() async {
        do {
            try await run()
        } catch {
            fatalError("FAIL IntegratedFlow: \(error)")
        }
    }

    static func run() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else {
            throw FlowFailure(message: "usage: IntegratedFlowCheck <distribution.sqlite> <anki-url> <receipt.json>")
        }
        let databaseURL = URL(fileURLWithPath: arguments[1])
        let ankiURL = URL(string: arguments[2])!
        let receiptPath = arguments[3]

        var receipt: [String: Any] = [:]
        let unit = UnitProfile(name: "Microbiology strains",
                               subject: "生物",
                               topics: ["微生物", "菌株"],
                               context: "细菌与病毒的品系、菌株与遗传变异")

        // 1. Real dictionary lookup.
        let dictionary = try OpenDictionarySource(databaseURL: databaseURL)
        let source = try await dictionary.lookup(word: "strain")
        let sourceIDs = source.senses.map(\.sourceSenseID)
        try flowExpect(Set(sourceIDs).count == sourceIDs.count, "词典义项身份重复")
        try flowExpect(source.senses.count >= 20, "真实义项数量异常：\(source.senses.count)")
        receipt["dictionary_sense_count"] = source.senses.count
        receipt["dictionary_source"] = source.provenance.provider

        // 2. Build the review model the way the app does.
        var entry = SenseResolver.resolve(source, for: unit)
        entry.unitID = unit.id
        let resolved = entry.groups.flatMap(\.senses)
        try flowExpect(resolved.count == source.senses.count, "进入审核模型时义项丢失")
        try flowExpect(Set(resolved.compactMap(\.sourceSenseID)) == Set(sourceIDs), "审核模型身份不一致")
        try flowExpect(entry.groups.count >= 2, "词性分组缺失")

        // 3. Real engines, ordered by the promotion verdict.
        let reranker = LocalSemanticReranker()
        let ollama = OllamaRankingEngine(model: "bge-m3")
        let engines = SemanticEnginePromotion.autoOrder(reranker: reranker, ollama: ollama)
        let coordinator = SemanticRankingCoordinator(engines: engines)
        let candidates = source.senses.map { SemanticCandidate(sourceSenseID: $0.sourceSenseID, text: $0.semanticDocument(headword: source.headword)) }
        let outcome = await coordinator.rank(query: TopicNormalizer.queryText(for: unit),
                                             candidates: candidates,
                                             unitHasContext: unit.hasUsableContext)
        receipt["promoted_primary"] = SemanticEnginePromotion.primary.rawValue
        receipt["auto_chain"] = engines.map { $0.kind.rawValue }
        receipt["engine_used"] = outcome.engine.rawValue
        receipt["engine_display_name"] = outcome.engine.displayName
        receipt["used_fallback"] = outcome.usedFallback
        receipt["notices"] = outcome.notices

        // 4. Apply ranking + conservative preselection, and require a real reason.
        RecommendationPolicy.apply(outcome, to: &entry, unitTerms: TopicNormalizer.terms(for: unit))
        let afterRanking = entry.groups.flatMap(\.senses)
        try flowExpect(afterRanking.count == source.senses.count, "排序后义项数量变化")
        try flowExpect(afterRanking.allSatisfy { ($0.recommendation?.reason.isEmpty == false) }, "存在没有理由的义项")
        try flowExpect(afterRanking.contains { $0.recommendation?.engine != nil }, "没有记录引擎来源")
        try flowExpect(outcome.engine != .rule || outcome.ranked.isEmpty, "规则回退不应伪造分数")

        // 4b. Empty-Unit context must not preselect anything (conservative default).
        let emptyUnit = UnitProfile(name: "", subject: "", topics: [], context: "")
        try flowExpect(!emptyUnit.hasUsableContext, "空 Unit 被判定为可用语境")
        let emptyPolicy = SemanticSelectionPolicy.policy(for: outcome.engine)
        try flowExpect(emptyPolicy.selectedSourceIDs(ranked: outcome.ranked, engine: outcome.engine, unitHasContext: emptyUnit.hasUsableContext).isEmpty,
                       "空 Unit 仍然默认勾选了义项")

        // 5. The user manually re-selects: keep only the biology sense.
        let biology = try source.senses.first { $0.gloss.contains("菌株") }.unwrap(orThrow: "缺少菌株义项")
        let biologyID = biology.sourceSenseID
        let deselectedGlosses: [String] = entry.groups.flatMap(\.senses)
            .filter { $0.sourceSenseID != biologyID }
            .map(\.gloss)
            .filter { !$0.isEmpty }
        for groupIndex in entry.groups.indices {
            for senseIndex in entry.groups[groupIndex].senses.indices {
                let wanted = entry.groups[groupIndex].senses[senseIndex].sourceSenseID == biologyID
                if entry.groups[groupIndex].senses[senseIndex].selected != wanted {
                    ReviewAction.toggleSense(&entry,
                                             groupID: entry.groups[groupIndex].id,
                                             senseID: entry.groups[groupIndex].senses[senseIndex].id)
                }
            }
        }
        let selected = entry.groups.flatMap(\.senses).filter(\.selected)
        try flowExpect(selected.count == 1 && selected.first?.sourceSenseID == biologyID, "人工改选未生效")
        receipt["manually_selected_ids"] = selected.compactMap(\.sourceSenseID)

        // 6. Save and reopen: the manual choice must survive.
        let saved = try JSONEncoder().encode(entry)
        let reopened = try JSONDecoder().decode(StructuredEntry.self, from: saved)
        let reopenedSelected = reopened.groups.flatMap(\.senses).filter(\.selected)
        try flowExpect(reopenedSelected.count == 1, "重开后勾选数量变化")
        try flowExpect(reopenedSelected.first?.sourceSenseID == biologyID, "重开后人工勾选被重置")
        try flowExpect(reopened.groups.flatMap(\.senses).count == source.senses.count, "重开后义项丢失")
        entry = reopened
        receipt["save_reopen_selected_ids"] = reopenedSelected.compactMap(\.sourceSenseID)

        // 7. Card back contains only selected facts, verbatim.
        let definition = CardRenderer.backHTML(for: entry)
        try flowExpect(definition.contains(CardRenderer.escapedHTML(biology.gloss)), "卡片缺少选中义项原文")
        if let example = biology.examples.first {
            try flowExpect(definition.contains(CardRenderer.escapedHTML(example.english)), "卡片缺少原例句")
            try flowExpect(definition.contains(CardRenderer.escapedHTML(example.chinese)), "卡片缺少例句译文")
        }
        for gloss in deselectedGlosses {
            try flowExpect(!definition.contains(CardRenderer.escapedHTML(gloss)), "未选义项进入了卡片：\(gloss)")
        }
        receipt["card_html_bytes"] = definition.utf8.count
        receipt["deselected_gloss_count"] = deselectedGlosses.count

        // 8. Write it through the real AnkiConnect endpoint, exactly like the app.
        let deckName = "WordWorkbench Harness Flow"
        let modelName = "WordWorkbench v3"
        _ = try await ankiInvoke(base: ankiURL, action: "createDeck", params: ["deck": deckName])
        let models = try await ankiInvoke(base: ankiURL, action: "modelNames").value as? [String] ?? []
        if !models.contains(modelName) {
            _ = try await ankiInvoke(base: ankiURL, action: "createModel", params: [
                "modelName": modelName,
                "inOrderFields": ["ID", "Word", "Definition", "Attribution"],
                "css": ".card{font-family:-apple-system,Arial;font-size:22px;text-align:left;line-height:1.6;padding:24px}.word{font-size:34px;font-weight:bold}.pos{font-weight:700;margin-top:12px}.label{color:#667085;font-size:14px;margin-top:8px}.example{margin:8px 0}.example span{color:#667085}.source{font-size:12px;opacity:.6;margin-top:24px}",
                "cardTemplates": [["Name": "英文 → 中文", "Front": "<div class='word'>{{Word}}</div>", "Back": "{{FrontSide}}<hr id=answer>{{Definition}}<div class='source'>{{Attribution}}</div>"]]
            ])
        }
        let fields: [String: String] = [
            "ID": entry.id,
            "Word": CardRenderer.escapedHTML(entry.word),
            "Definition": definition,
            "Attribution": "Open Dictionary / Wiktionary contributors · CC BY-SA 4.0"
        ]
        let existing = try await ankiInvoke(base: ankiURL, action: "findNotes",
                                            params: ["query": "\"note:\(modelName)\" ID:\(entry.id)"]).value as? [Int64] ?? []
        try flowExpect(existing.count <= 1, "ID 匹配到多条笔记")
        let noteID: Int64
        if let found = existing.first {
            _ = try await ankiInvoke(base: ankiURL, action: "updateNoteFields", params: ["note": ["id": found, "fields": fields]])
            noteID = found
        } else {
            let added = try await ankiInvoke(base: ankiURL, action: "addNote", params: ["note": [
                "deckName": deckName, "modelName": modelName, "fields": fields,
                "options": ["allowDuplicate": false],
                "tags": ["wordworkbench", "unit::\(unit.name)", "source::open-dictionary", "harness::flow"]
            ]]).value as? Int64
            noteID = try added.unwrap(orThrow: "addNote 未返回 note id")
        }
        let info = try await ankiInvoke(base: ankiURL, action: "notesInfo", params: ["notes": [noteID]]).value as? [[String: Any]] ?? []
        let stored = try info.first.unwrap(orThrow: "notesInfo 未返回笔记")
        let storedFields = stored["fields"] as? [String: Any] ?? [:]
        let storedDefinition = (storedFields["Definition"] as? [String: Any])?["value"] as? String ?? ""
        let storedWord = (storedFields["Word"] as? [String: Any])?["value"] as? String ?? ""
        try flowExpect(storedDefinition == definition, "Anki 中存储的 Definition 与渲染结果不一致")
        try flowExpect(storedWord == CardRenderer.escapedHTML(entry.word), "Anki 中存储的 Word 被改写")
        for gloss in deselectedGlosses {
            try flowExpect(!storedDefinition.contains(CardRenderer.escapedHTML(gloss)), "未选义项被写入 Anki：\(gloss)")
        }
        receipt["anki_note_id"] = noteID
        receipt["anki_deck"] = deckName
        receipt["anki_stored_definition_matches"] = true
        receipt["anki_tags"] = stored["tags"] as? [String] ?? []
        receipt["anki_cards"] = stored["cards"] as? [Int64] ?? []
        receipt["anki_listener"] = ankiURL.absoluteString
        receipt["status"] = "PASS"

        let serialized = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        try serialized.write(to: URL(fileURLWithPath: receiptPath))
        print("PASS IntegratedFlow: engine=\(outcome.engine.rawValue) senses=\(source.senses.count) note=\(noteID) card_bytes=\(definition.utf8.count)")
    }
}

extension Optional {
    func unwrap(orThrow message: String) throws -> Wrapped {
        guard let value = self else { throw FlowFailure(message: message) }
        return value
    }
}
