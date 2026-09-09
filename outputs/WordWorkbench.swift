import SwiftUI
import AppKit
import CoreServices

func appleDefinition(_ word: String) -> String? {
    let text = word as CFString
    return DCSCopyTextDefinition(nil, text, CFRange(location: 0, length: CFStringGetLength(text)))?.takeRetainedValue() as String?
}

func spellingCandidates(for word: String) -> [String] {
    guard !word.isEmpty else { return [] }
    let range = NSRange(location: 0, length: (word as NSString).length)
    let guesses = NSSpellChecker.shared.guesses(forWordRange: range, in: word, language: "en_US", inSpellDocumentWithTag: 0) ?? []
    var unique: [String] = []
    for guess in guesses where !unique.contains(guess) { unique.append(guess) }
    return Array(unique.prefix(8))
}

func escapedHTML(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "\n", with: "<br>")
}

struct WordEntry: Identifiable, Codable {
    var id = UUID().uuidString
    var word: String
    var rawDefinition: String
    var cardBack: String
    var source = "Apple Dictionary · 本机启用词典"
    var included = true
    var imported = false

    init(word: String, rawDefinition: String, cardBack: String = "") {
        self.word = word; self.rawDefinition = rawDefinition; self.cardBack = cardBack
    }
    enum Keys: String, CodingKey { case id, word, rawDefinition, cardBack, source, included, imported, meaning }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        word = try c.decode(String.self, forKey: .word)
        let old = try c.decodeIfPresent(String.self, forKey: .meaning) ?? ""
        rawDefinition = try c.decodeIfPresent(String.self, forKey: .rawDefinition) ?? old
        cardBack = try c.decodeIfPresent(String.self, forKey: .cardBack) ?? old
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? source
        included = try c.decodeIfPresent(Bool.self, forKey: .included) ?? true
        imported = try c.decodeIfPresent(Bool.self, forKey: .imported) ?? false
    }
}
struct WordFolder: Identifiable, Codable { var id = UUID().uuidString; var name: String }
struct WordBook: Identifiable, Codable { var id = UUID().uuidString; var folderID: String; var name: String; var entries: [WordEntry] = [] }
struct Library: Codable { var folders: [WordFolder] = []; var books: [WordBook] = [] }
struct LookupIssue { var input: String; var candidates: [String] }
struct LocalError: LocalizedError { let message: String; var errorDescription: String? { message } }

struct AICard: Codable {
    struct Part: Codable { let partOfSpeech: String; let meanings: [String]; let collocations: [Collocation]; let examples: [Example] }
    struct Collocation: Codable { let english: String; let chinese: String }
    struct Example: Codable { let english: String; let chinese: String }
    let parts: [Part]
}
func aiSourceText(_ raw: String, fastLimit: Int? = nil) -> String {
    // Etymology and derivative lists cost tokens but are not used on the final card.
    let cutMarkers = [" DERIVATIVES ", " ORIGIN "]
    var text = raw
    for marker in cutMarkers {
        if let range = text.range(of: marker) { text = String(text[..<range.lowerBound]) }
    }
    return fastLimit.map { String(text.prefix($0)) } ?? text
}
func renderCardBack(_ card: AICard) -> String {
    card.parts.map { p in
        let meanings = p.meanings.map { "<li>\(escapedHTML($0))</li>" }.joined()
        let collocations = p.collocations.isEmpty ? "" : "<div class='label'>搭配</div><ul>" + p.collocations.map { "<li><b>\(escapedHTML($0.english))</b>：\(escapedHTML($0.chinese))</li>" }.joined() + "</ul>"
        let examples = p.examples.isEmpty ? "" : "<div class='label'>例句</div>" + p.examples.map { "<div class='example'>\(escapedHTML($0.english))<br><span>\(escapedHTML($0.chinese))</span></div>" }.joined()
        return "<section><div class='pos'>\(escapedHTML(p.partOfSpeech))</div><div class='label'>中文义项</div><ul>\(meanings)</ul>\(collocations)\(examples)</section>"
    }.joined(separator: "<hr>")
}

func validateSourcePhrases(_ card: AICard, raw: String) -> AICard {
    let normalizedRaw = raw.lowercased()
    let parts = card.parts.map { part in
        AICard.Part(
            partOfSpeech: part.partOfSpeech,
            meanings: part.meanings,
            collocations: part.collocations.filter { normalizedRaw.contains($0.english.lowercased()) },
            examples: part.examples.filter { normalizedRaw.contains($0.english.lowercased()) }
        )
    }
    return AICard(parts: parts)
}

@MainActor final class Workbench: ObservableObject {
    @Published var library = Library()
    @Published var selectedFolderID: String?
    @Published var selectedBookID: String?
    @Published var selectedEntryID: String?
    @Published var input = ""
    @Published var issue: LookupIssue?
    @Published var folderName = ""
    @Published var bookName = ""
    @Published var status = "先新建或打开一个 Anki Deck，再输入英文词并按回车。"
    @Published var busy = false
    @Published var fastMode = false
    @Published var batchCurrent = ""
    @Published var batchCompleted = 0
    @Published var batchTotal = 0
    @Published var batchElapsed = 0
    @Published var batchFailures: [String] = []
    @Published var loadFailed = false
    let root: URL
    let file: URL

    init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WordWorkbench", isDirectory: true)
        file = root.appendingPathComponent("library-v2.json")
        load()
    }
    func load() {
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                library = try JSONDecoder().decode(Library.self, from: Data(contentsOf: file))
            } else { try migrate() }
            selectedFolderID = library.folders.first?.id
            selectedBookID = booksHere.first?.id
        } catch { loadFailed = true; status = "词库读取失败，已禁止覆盖：\(error.localizedDescription)" }
    }
    func migrate() throws {
        let old = root.appendingPathComponent("words.json")
        guard FileManager.default.fileExists(atPath: old.path) else { return }
        let entries = try JSONDecoder().decode([WordEntry].self, from: Data(contentsOf: old))
        let folder = WordFolder(name: "未分类")
        library = Library(folders: [folder], books: [WordBook(folderID: folder.id, name: "旧词", entries: entries)])
        save(); status = "已把旧版词条迁移到“未分类 / 旧词”。"
    }
    func save() {
        guard !loadFailed else { return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(library)
            if FileManager.default.fileExists(atPath: file.path) {
                let previous = try Data(contentsOf: file)
                _ = try JSONDecoder().decode(Library.self, from: previous)
                if previous != data { try previous.write(to: root.appendingPathComponent("library-v2.backup.json"), options: .atomic) }
            }
            try data.write(to: file, options: .atomic)
        } catch { status = "保存失败：\(error.localizedDescription)" }
    }
    var folderIndex: Int? { library.folders.firstIndex { $0.id == selectedFolderID } }
    var booksHere: [WordBook] { library.books.filter { $0.folderID == selectedFolderID } }
    var bookIndex: Int? { library.books.firstIndex { $0.id == selectedBookID } }
    var entryIndex: Int? { guard let b = bookIndex else { return nil }; return library.books[b].entries.firstIndex { $0.id == selectedEntryID } }
    var book: WordBook? { bookIndex.map { library.books[$0] } }
    var ready: [(Int, WordEntry)] { guard let b = bookIndex else { return [] }; return library.books[b].entries.enumerated().filter { $0.element.included && !$0.element.cardBack.isEmpty } }

    func addFolder() {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines); guard !name.isEmpty else { return }
        let folder = WordFolder(name: name); library.folders.append(folder); selectedFolderID = folder.id; folderName = ""; save()
    }
    func addBook() {
        let name = bookName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let folder = selectedFolderID, !name.isEmpty else { status = "请先新建一个 Anki Deck。"; return }
        let new = WordBook(folderID: folder, name: name); library.books.append(new); selectedBookID = new.id; selectedEntryID = nil; bookName = ""; save()
    }
    func addDeck() {
        if selectedFolderID == nil {
            let folder = WordFolder(name: "本机牌组")
            library.folders.append(folder); selectedFolderID = folder.id
        }
        addBook()
    }
    func renameFolder(_ value: String) { guard let i = folderIndex else { return }; library.folders[i].name = value; save() }
    func renameBook(_ value: String) { guard let i = bookIndex else { return }; library.books[i].name = value; save() }

    func lookup(_ selected: String? = nil) {
        let word = (selected ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let b = bookIndex else { status = "请先新建或打开一个 Anki Deck。"; return }
        guard !word.isEmpty else { return }
        if let raw = appleDefinition(word) {
            let entry = WordEntry(word: word, rawDefinition: raw)
            library.books[b].entries.append(entry); selectedEntryID = entry.id; input = ""; issue = nil
            status = "已取得原始词典内容。可用 AI 整理中文卡背，或手动编辑。"; save()
        } else {
            let verifiedSystemCandidates = spellingCandidates(for: word).filter { appleDefinition($0) != nil }
            input = word; issue = LookupIssue(input: word, candidates: verifiedSystemCandidates)
            status = "本机词典未找到该词，正在用本地模型补充并核验拼写候选…"
            let initial = issue!.candidates
            Task { await enrichCandidates(for: word, initial: initial) }
        }
    }
    func enrichCandidates(for word: String, initial: [String]) async {
        do {
            let candidates = try await ollamaSpellingCandidates(for: word)
            // A model suggestion is displayed only after Apple Dictionary confirms it is a real entry.
            let verified = candidates.filter { appleDefinition($0) != nil }
            guard issue?.input == word else { return }
            var combined = initial
            for candidate in verified where !combined.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) { combined.append(candidate) }
            issue = LookupIssue(input: word, candidates: Array(combined.prefix(8)))
            status = combined.isEmpty ? "本机词典未找到该词，也没有已核验候选。可修改输入或手工添加。" : "未找到该词。红色字母表示与已核验候选不一致的位置。"
        } catch {
            guard issue?.input == word else { return }
            status = initial.isEmpty ? "本机词典未找到该词；拼写候选服务不可用。可修改输入或手工添加。" : "本地模型不可用，以下为 macOS 拼写建议。"
        }
    }
    func addManual() {
        guard let b = bookIndex else { return }
        let word = input.trimmingCharacters(in: .whitespacesAndNewlines); guard !word.isEmpty else { return }
        let entry = WordEntry(word: word, rawDefinition: "")
        library.books[b].entries.append(entry); selectedEntryID = entry.id; input = ""; issue = nil; status = "已添加手工词条。填写卡背后即可导入。"; save()
    }
    func rerunLookup() {
        guard let b = bookIndex, let e = entryIndex else { return }
        let word = library.books[b].entries[e].word
        guard let raw = appleDefinition(word) else { input = word; issue = LookupIssue(input: word, candidates: spellingCandidates(for: word)); status = "重新查询未找到该词。请修正拼写。"; return }
        library.books[b].entries[e].rawDefinition = raw; status = "原始资料已更新；现有卡背没有被覆盖。"; save()
    }
    func deleteEntry() {
        guard let b = bookIndex, let e = entryIndex else { return }
        let entry = library.books[b].entries.remove(at: e); selectedEntryID = library.books[b].entries.first?.id; save()
        status = entry.imported ? "已从本地 Deck 列表移除；Anki 中已导入的卡仍保留，防止误删复习记录。" : "已删除未导入词条。"
    }
    func generate() async {
        guard let b = bookIndex, let e = entryIndex else { return }
        let raw = library.books[b].entries[e].rawDefinition; guard !raw.isEmpty else { status = "没有原始词典资料，不能交给 AI 整理。"; return }
        busy = true; defer { busy = false }
        do {
            status = "qwen3:8b 正在本机整理中文义项、搭配和例句…"
            let result = validateSourcePhrases(try await ollama(raw: aiSourceText(raw, fastLimit: fastMode ? 9_000 : nil), word: library.books[b].entries[e].word), raw: raw)
            library.books[b].entries[e].cardBack = renderCardBack(result); status = "AI 候选卡背已生成。请浏览、修改后再导入。"; save()
        } catch { status = "AI 整理失败：\(error.localizedDescription)。原文仍在，可手动填写卡背。" }
    }
    func generateAll() async {
        guard let b = bookIndex else { return }
        let targets = library.books[b].entries.enumerated().filter { $0.element.included && !$0.element.rawDefinition.isEmpty && $0.element.cardBack.isEmpty }
        guard !targets.isEmpty else { status = "当前 Deck 没有待整理词。已生成卡背的词不会被批量覆盖。"; return }
        busy = true; batchCompleted = 0; batchTotal = targets.count; batchFailures = []; batchElapsed = 0
        let started = Date()
        let clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.batchElapsed = Int(Date().timeIntervalSince(started)) }
            }
        }
        defer { busy = false; clock.cancel(); batchCurrent = "" }
        var completed = 0
        for (index, entry) in targets {
            if Task.isCancelled { status = "已停止批量整理；已完成 \(completed)/\(targets.count) 条，结果已保存。"; return }
            do {
                batchCurrent = entry.word
                status = "正在整理 \(completed + 1)/\(targets.count)：\(entry.word)（单词最长等待 55 秒）"
                let card = validateSourcePhrases(try await ollama(raw: aiSourceText(entry.rawDefinition, fastLimit: fastMode ? 9_000 : nil), word: entry.word), raw: entry.rawDefinition)
                library.books[b].entries[index].cardBack = renderCardBack(card)
                completed += 1; batchCompleted = completed; save()
            } catch is CancellationError { status = "已停止批量整理；已完成 \(completed)/\(targets.count) 条，结果已保存。"; return }
            catch { batchFailures.append(entry.word); status = "\(entry.word) 整理失败，已跳过；其余词继续处理。" }
        }
        status = "批量整理完成：\(completed)/\(targets.count) 条，失败 \(batchFailures.count) 条。请浏览卡背后导入 Anki。"
    }
    func stopBatch() { status = "正在停止当前请求…"; batchTask?.cancel() }
    private var batchTask: Task<Void, Never>?
    func startBatch() { guard !busy else { return }; batchTask = Task { await generateAll() } }
    func ollama(raw: String, word: String) async throws -> AICard {
        let prompt = """
        You format one flashcard for a Chinese high-school English learner. Use only the supplied Apple Dictionary text. Do not invent meanings, collocations, or examples. Return JSON only:
        {"parts":[{"partOfSpeech":"noun or verb","meanings":["concise Chinese meaning"],"collocations":[{"english":"phrase from source","chinese":"Chinese translation"}],"examples":[{"english":"sentence from source","chinese":"Chinese translation"}]}]}
        Group by part of speech. Keep collocations/examples empty if absent. Word: \(word)
        Apple Dictionary text:
        \(raw)
        """
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/generate")!)
        request.httpMethod = "POST"; request.timeoutInterval = 55; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let model = fastMode ? "qwen2.5:3b" : "qwen3:8b"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "prompt": prompt, "stream": false, "format": "json", "think": false, "options": ["temperature": 0.1, "num_predict": 700]])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = body["response"] as? String else { throw LocalError(message: "Ollama 返回无效响应。") }
        let card = try JSONDecoder().decode(AICard.self, from: Data(text.utf8))
        guard !card.parts.isEmpty, card.parts.allSatisfy({ !$0.partOfSpeech.isEmpty && !$0.meanings.isEmpty }) else { throw LocalError(message: "Ollama 返回的词卡结构不完整。") }
        return card
    }
    func ollamaSpellingCandidates(for word: String) async throws -> [String] {
        let prompt = "Return JSON only: {\"candidates\":[\"correct English word\"]}. The learner typed this possibly misspelled English word: \(word). Suggest at most five likely intended English headwords. Do not explain."
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/generate")!)
        request.httpMethod = "POST"; request.timeoutInterval = 60; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": "qwen3:8b", "prompt": prompt, "stream": false, "format": "json", "options": ["temperature": 0]])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = body["response"] as? String,
              let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let candidates = object["candidates"] as? [String] else { throw LocalError(message: "拼写候选返回无效。") }
        return Array(candidates.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.prefix(5))
    }
    func deckName() -> String {
        func clean(_ text: String) -> String { text.replacingOccurrences(of: "::", with: "：").trimmingCharacters(in: .whitespacesAndNewlines) }
        return clean(library.books[bookIndex!].name)
    }
    func connectAnki() async throws {
        if (try? await anki("version")) != nil { return }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Anki.app"), configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        for _ in 0..<12 {
            try? await Task.sleep(for: .seconds(1))
            if (try? await anki("version")) != nil { return }
        }
        throw LocalError(message: "无法连接 AnkiConnect。已尝试打开 Anki；请等待 Anki 完全启动，并在 Tools → Add-ons 中确认 AnkiConnect 已启用后重试。")
    }
    func anki(_ action: String, _ params: [String: Any] = [:]) async throws -> Any {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8765")!)
        request.httpMethod = "POST"; request.timeoutInterval = 20; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["action": action, "version": 6, "params": params])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LocalError(message: "AnkiConnect 返回无效响应。") }
        if let error = object["error"] as? String, !error.isEmpty { throw LocalError(message: error) }
        return object["result"] ?? NSNull()
    }
    func importAnki() async {
        guard let b = bookIndex, !ready.isEmpty else { status = "没有已勾选且已整理卡背的词。"; return }
        busy = true; defer { busy = false }; let deck = deckName()
        do {
            status = "正在连接本机 Anki…"
            try await connectAnki(); _ = try await anki("createDeck", ["deck": deck])
            let models = try await anki("modelNames") as? [String] ?? []
            if !models.contains("WordWorkbench v1") {
                _ = try await anki("createModel", ["modelName": "WordWorkbench v1", "inOrderFields": ["ID", "Word", "Definition", "Source"], "css": ".card{font-family:-apple-system,Arial;font-size:22px;text-align:left;line-height:1.6;padding:24px}.word{font-size:34px;font-weight:bold}.pos{font-weight:700;margin-top:12px}.label{color:#667085;font-size:14px;margin-top:8px}.example{margin:8px 0}.example span{color:#667085}.source{font-size:12px;opacity:.6;margin-top:24px}", "cardTemplates": [["Name": "英文 → 中文", "Front": "<div class='word'>{{Word}}</div>", "Back": "{{FrontSide}}<hr id=answer>{{Definition}}<div class='source'>{{Source}}</div>"]]])
            }
            var completed = 0
            for (index, entry) in ready {
                let fields = ["ID": entry.id, "Word": escapedHTML(entry.word), "Definition": entry.cardBack, "Source": escapedHTML(entry.source)]
                let ids = try await anki("findNotes", ["query": "\"note:WordWorkbench v1\" ID:\(entry.id)"]) as? [Int64] ?? []
                if ids.count > 1 { throw LocalError(message: "\(entry.word) 匹配多条笔记，已停止。") }
                if let id = ids.first {
                    _ = try await anki("updateNoteFields", ["note": ["id": id, "fields": fields]])
                    let cards = try await anki("findCards", ["query": "nid:\(id)"]) as? [Int64] ?? []
                    if !cards.isEmpty { _ = try await anki("changeDeck", ["deck": deck, "cards": cards]) }
                } else {
                    _ = try await anki("addNote", ["note": ["deckName": deck, "modelName": "WordWorkbench v1", "fields": fields, "options": ["allowDuplicate": false], "tags": ["deck::\(library.books[b].name)"]]])
                }
                library.books[b].entries[index].imported = true; completed += 1; status = "已写入 \(completed)/\(ready.count)：\(entry.word)"
            }
            save(); status = "完成：\(completed) 条写入 Anki Deck「\(deck)」。该 Deck 独立拥有复习进度。"
        } catch { status = "导入中止：\(error.localizedDescription)。已成功条目可安全重试。"; save() }
    }
}

func diffText(_ input: String, _ candidate: String) -> Text {
    let a = Array(input), b = Array(candidate); let m = a.count, n = b.count
    var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
    if m > 0 && n > 0 { for i in stride(from: m - 1, through: 0, by: -1) { for j in stride(from: n - 1, through: 0, by: -1) { dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1]) } } }
    var matched = Set<Int>(); var i = 0, j = 0
    while i < m && j < n { if a[i] == b[j] { matched.insert(i); i += 1; j += 1 } else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 } else { j += 1 } }
    return a.enumerated().reduce(Text("")) { $0 + Text(String($1.element)).foregroundColor(matched.contains($1.offset) ? .primary : .red) }
}

struct ContentView: View {
    @StateObject private var model = Workbench()
    var body: some View {
        HSplitView {
            VStack(alignment: .leading) {
                Text("Anki Deck").font(.headline).padding(.horizontal)
                List(selection: $model.selectedBookID) { ForEach(model.library.books) { Text("\($0.name)（\($0.entries.count)）").tag($0.id) } }
                HStack { TextField("新 Deck 名称", text: $model.bookName); Button("新建") { model.addDeck() } }.padding()
                Text("此列表直接对应 Anki Deck；不再提供额外单词夹或单词书分类。").font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }.frame(minWidth: 250)
            BookView(model: model)
        }
    }
}

struct BookView: View {
    @ObservedObject var model: Workbench
    var body: some View {
        if let book = model.book {
            VStack(alignment: .leading, spacing: 12) {
                HStack { if let b = model.bookIndex { TextField("Deck 名称", text: Binding(get: { model.library.books[b].name }, set: model.renameBook)).font(.title3.bold()).textFieldStyle(.roundedBorder) }; Spacer(); Text("\(book.entries.count) 个词") }
                HStack { TextField("输入英文单词，按回车查询", text: $model.input).textFieldStyle(.roundedBorder).onSubmit { model.lookup() }.disabled(model.busy); Button("查询") { model.lookup() }.disabled(model.busy) }
                if let issue = model.issue {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("未找到 \(issue.input)。红色字母表示与候选拼写不一致的位置。").foregroundStyle(.red)
                        if issue.candidates.isEmpty { Text("没有本机拼写候选。可修改上方输入或手工添加。").foregroundStyle(.secondary) }
                        ForEach(issue.candidates, id: \.self) { candidate in Button { model.lookup(candidate) } label: { HStack { diffText(issue.input, candidate); Text(" → \(candidate)").foregroundStyle(.blue) } } }
                        Button("仍然添加为空白手工词条") { model.addManual() }
                    }.padding(10).background(Color.orange.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                HSplitView {
                    List(selection: $model.selectedEntryID) { ForEach(book.entries) { entry in HStack { Image(systemName: entry.included ? "checkmark.square" : "square"); Text(entry.word); Spacer(); if entry.cardBack.isEmpty { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) } }.tag(entry.id) } }.frame(minWidth: 190)
                    EntryEditor(model: model)
                }.frame(minHeight: 350)
                if model.busy && !model.batchCurrent.isEmpty {
                    HStack {
                        ProgressView(value: Double(model.batchCompleted), total: Double(model.batchTotal)).frame(width: 170)
                        Text("\(model.batchCompleted)/\(model.batchTotal) · \(model.batchCurrent) · 已用 \(model.batchElapsed)s · 失败 \(model.batchFailures.count)").font(.caption).monospacedDigit()
                        Button("停止批量整理", role: .destructive) { model.stopBatch() }
                    }
                }
                HStack {
                    Text(model.status).font(.callout).textSelection(.enabled)
                    Spacer()
                    Toggle("快速模式（qwen2.5:3b，原文最多 9,000 字符）", isOn: $model.fastMode).toggleStyle(.checkbox).disabled(model.busy)
                    Button("批量 AI 整理待处理词") { model.startBatch() }.disabled(model.busy)
                    Button("确认并导入 Anki") { Task { await model.importAnki() } }.disabled(model.busy)
                }
            }.padding(20)
        } else { Text("从左侧新建或打开一个 Anki Deck。每个 Deck 的卡和复习进度彼此独立。").multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
    }
}

struct EntryEditor: View {
    @ObservedObject var model: Workbench
    var body: some View {
        if let b = model.bookIndex, let e = model.entryIndex {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("包含在本轮导入中", isOn: $model.library.books[b].entries[e].included)
                HStack { TextField("英文词", text: $model.library.books[b].entries[e].word).font(.title3).textFieldStyle(.roundedBorder); Button("重新查询") { model.rerunLookup() }; Button("删除词条", role: .destructive) { model.deleteEntry() } }
                HStack { Button("用 qwen3:8b 整理中文卡背") { Task { await model.generate() } }.disabled(model.busy); Text("AI 只依据下方原始资料生成候选，不会覆盖原文。").font(.caption).foregroundStyle(.secondary) }
                Text("最终卡背（可直接编辑）").font(.headline)
                TextEditor(text: $model.library.books[b].entries[e].cardBack).font(.system(size: 16)).border(Color.secondary.opacity(0.25)).frame(minHeight: 170)
                DisclosureGroup("Apple Dictionary 原始资料（保留供核对）") { TextEditor(text: $model.library.books[b].entries[e].rawDefinition).font(.system(size: 13)).frame(minHeight: 120).border(Color.secondary.opacity(0.2)) }
                TextField("来源", text: $model.library.books[b].entries[e].source).textFieldStyle(.roundedBorder)
            }.padding(12).frame(minWidth: 500)
        } else { Text("选择一个词条查看原文和卡背。").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
    }
}

@main struct WordWorkbenchApp: App { var body: some Scene { Window("每日录词工作台", id: "main") { ContentView() } } }
