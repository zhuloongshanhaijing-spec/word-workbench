// AutoTest v2 — full lifecycle tests via command file + library + AnkiConnect
import Foundation
import AppKit

let LibraryPath = NSHomeDirectory() + "/Library/Application Support/WordWorkbench/library-v3.json"
let AnkiURL = "http://127.0.0.1:8765"
let AppBundleID = "com.wordworkbench.dailyvocabulary"
let AppPath = ProcessInfo.processInfo.environment["WWB_APP_PATH"]
    ?? NSHomeDirectory() + "/Applications/每日录词工作台.app"
let TestDeck = "GUI复核测试"

// MARK: - App lifecycle
func launchApp() {
    for app in NSWorkspace.shared.runningApplications.filter({ $0.bundleIdentifier == AppBundleID }) {
        kill(app.processIdentifier, SIGKILL); usleep(1_000_000)
    }
    NSWorkspace.shared.open(URL(fileURLWithPath: AppPath))
    for _ in 0..<40 {
        if let attr = try? FileManager.default.attributesOfItem(atPath: LibraryPath),
           let mod = attr[.modificationDate] as? Date,
           Date().timeIntervalSince(mod) < 10 { print("App ready"); return }
        usleep(500_000)
    }
    print("WARNING: app may not be ready")
}

func waitForAppReady() -> Bool {
    for _ in 0..<30 {
        if let ack = sendCmd(["action":"debugState"], timeout: 3), ack["status"] as? String == "ok" { return true }
        usleep(500_000)
    }
    return false
}

// MARK: - Library state
struct LibraryState: Codable {
    var decks: [Deck] = []
    struct Deck: Codable { var id: String; var ankiDeckName: String; var units: [Unit] = []; var entries: [Entry] = [] }
    struct Unit: Codable { var id: String; var name: String }
    struct Entry: Codable {
        var id: String; var word: String; var imported: Bool; var groups: [Group] = []
        struct Group: Codable { var label: String; var senses: [Sense]
            struct Sense: Codable { var sourceSenseID: String?; var gloss: String; var selected: Bool; var recommendation: Rec?; struct Rec: Codable { var engine: String; var reason: String } }
        }
        var totalSenses: Int { groups.reduce(0) { $0 + $1.senses.count } }
        var selectedSenses: Int { groups.reduce(0) { $0 + $1.senses.filter(\.selected).count } }
        var selectedIDs: [String] { groups.flatMap { $0.senses.filter(\.selected).compactMap(\.sourceSenseID) } }
    }
}
func readState() -> LibraryState? { guard let d = try? Data(contentsOf: URL(fileURLWithPath: LibraryPath)) else { return nil }; return try? JSONDecoder().decode(LibraryState.self, from: d) }
// Wait until predicate is true, polling library
func waitForState(_ pred: (LibraryState) -> Bool, timeout: Int = 15) -> Bool {
    for _ in 0..<(timeout * 2) {
        if let s = readState(), pred(s) { return true }
        usleep(500_000)
    }
    return false
}

// MARK: - Command file
var cmdSeq = Int(Date().timeIntervalSince1970 * 1000)  // 时间基 seq：对任何存活实例的高 lastSeq 免疫
func sendCmd(_ cmd: [String: Any], timeout: Int = 60) -> [String: Any]? {
    cmdSeq += 1
    var fullCmd = cmd
    fullCmd["seq"] = cmdSeq
    let ackP = "/tmp/wwb-command-ack.json"
    try? FileManager.default.removeItem(atPath: ackP)
    try? JSONSerialization.data(withJSONObject: fullCmd).write(to: URL(fileURLWithPath: "/tmp/wwb-command.json"))
    for _ in 0..<(timeout * 2) { usleep(500_000); if let d = try? Data(contentsOf: URL(fileURLWithPath: ackP)), let a = try? JSONSerialization.jsonObject(with: d) as? [String: Any], a["status"] as? String == "ok" { return a } }
    return nil
}

// MARK: - Anki
func anki(_ action: String, _ params: [String: Any] = [:]) -> Any? {
    var r = URLRequest(url: URL(string: AnkiURL)!); r.httpMethod = "POST"; r.timeoutInterval = 20
    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    r.httpBody = try? JSONSerialization.data(withJSONObject: ["action":action,"version":6,"params":params])
    let sem = DispatchSemaphore(value: 0)
    var result: Any?
    URLSession(configuration: .ephemeral).dataTask(with: r) { d, resp, _ in
        defer { sem.signal() }
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let d = d, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        result = o["result"]
    }.resume()
    sem.wait()
    return result
}

// MARK: - Runner
var reports = [(String,Bool,String)]()
func c(_ n: String, _ cond: Bool, _ detail: String = "") { print("[\(cond ? "PASS" : "FAIL")] \(n)"); if !cond && !detail.isEmpty { print("       \(detail)") }; reports.append((n,cond,detail)) }

@main struct AutoTest { static func main() {
    print("=== AutoTest v2 ===\n")
    
    // 0. Setup
    launchApp()
    guard waitForAppReady() else { print("FATAL: app not responsive"); exit(1) }
    print("App responsive")
    
    // Restart Anki if needed
    if anki("version") == nil {
        print("Starting Anki...")
        let root = FileManager.default.currentDirectoryPath + "/.harness-local"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "\(root)/anki-app/Anki.app/Contents/MacOS/anki")
        task.arguments = ["-b", "\(root)/anki-temp/base", "-l", "en"]
        try? task.run()
        for _ in 0..<30 { usleep(1_000_000); if anki("version") != nil { print("Anki ready"); break } }
    }
    
    // Select deck and clean duplicates
    c("selectDeck", sendCmd(["action":"selectDeck","deckName":TestDeck]) != nil)
    usleep(2_000_000)
    c("purgeDuplicates", sendCmd(["action":"purgeDuplicates"]) != nil)
    _ = waitForState({ s in
        let words = s.decks.first(where: {$0.ankiDeckName==TestDeck})?.entries.map(\.word) ?? []
        return Set(words).count == words.count
    }, timeout: 15)
    usleep(1_000_000)
    
    // PASSIVE: strain
    if let s = readState(), let d = s.decks.first(where: { $0.ankiDeckName == TestDeck }), let strain = d.entries.first(where: { $0.word == "strain" }) {
        let engines = strain.groups.flatMap { $0.senses.compactMap { $0.recommendation?.engine } }
        c("strain 26 senses", strain.totalSenses == 26, "\(strain.totalSenses)")
        c("strain conservative ≤3", strain.selectedSenses <= 3, "\(strain.selectedSenses)")
        let reasons = strain.groups.flatMap { $0.senses.compactMap { $0.recommendation?.reason } }
        c("all have reason", reasons.count == strain.totalSenses)
        c("engine detected", !engines.isEmpty, "\(Set(engines))")
        c("reason non-empty", reasons.filter({!$0.isEmpty}).count >= strain.totalSenses/2)
        c("reason no 概率", reasons.filter({($0.contains("概率")||$0.contains("百分比")) && !$0.contains("非概率")}).isEmpty)
    }
    
    // A1: Sense selection + persistence
    print("\n--- A1 ---")
    let bl = readState()?.decks.first(where: { $0.ankiDeckName == TestDeck })?.entries.count ?? 0
    let w = "catalyst"
    c("addWord \(w)", sendCmd(["action":"addWord","word":w]) != nil)
    _ = waitForState({ s in s.decks.first(where: {$0.ankiDeckName==TestDeck})?.entries.contains(where: { $0.word == w }) ?? false }, timeout: 20)
    usleep(1_500_000)  // 同词替换模式下等待 lookup 落盘
    guard let s1 = readState(), let d1 = s1.decks.first(where: { $0.ankiDeckName == TestDeck }), let enz = d1.entries.first(where: { $0.word == w }) else { exit(1) }
    c("\(w) added", d1.entries.count >= bl, "\(bl)→\(d1.entries.count)")
    let sc = enz.totalSenses; c("\(w) senses>0", sc > 0, "\(sc)")
    let sid = enz.groups.flatMap({$0.senses}).first?.sourceSenseID ?? ""
    c("first sense id", !sid.isEmpty, sid)
    
    sendCmd(["action":"selectEntry","word":w]); usleep(500000)
    sendCmd(["action":"deselectAll"])
    _ = waitForState({ s in
        let e = s.decks.first(where: {$0.ankiDeckName==TestDeck})?.entries.first(where: {$0.word==w})
        return (e?.groups.flatMap({$0.senses}).filter({$0.selected}).count ?? 1) == 0
    }, timeout: 10)
    sendCmd(["action":"selectSense","sourceSenseID":sid,"word":w])
    _ = waitForState({ s in
        let e = s.decks.first(where: {$0.ankiDeckName==TestDeck})?.entries.first(where: {$0.word==w})
        return (e?.groups.flatMap({$0.senses}).filter({$0.selected}).count ?? 0) > 0
    }, timeout: 10)
    guard let s2 = readState(), let enz2 = s2.decks.first(where: {$0.ankiDeckName==TestDeck})?.entries.last(where: {$0.word==w}) else { exit(1) }
    c("exactly 1 selected", enz2.selectedIDs.count == 1, "\(enz2.selectedIDs)")
    c("correct sense selected", enz2.selectedIDs.first == sid)
    
    print("Restarting..."); launchApp(); _ = waitForAppReady()
    sendCmd(["action":"selectDeck","deckName":TestDeck]); usleep(1_000_000)
    sendCmd(["action":"selectEntry","word":w]); usleep(500000)
    guard let s3 = readState(), let enz3 = s3.decks.first(where: {$0.ankiDeckName==TestDeck})?.entries.first(where: {$0.word==w}) else { exit(1) }
    c("selection survived restart", enz3.selectedIDs == [sid], "\(enz3.selectedIDs)")
    c("sense count unchanged", enz3.totalSenses == sc, "\(enz3.totalSenses)")
    
    // Clean up duplicate from test word (purgeDuplicates ran before addWord, so the test word is now duplicated)
    _ = sendCmd(["action":"purgeDuplicates"])
    usleep(1_000_000)
    
    // A2: Anki import
    print("\n--- A2 ---")
    if anki("version") == nil { c("AnkiConnect", false, "skip import") }
    else {
        c("AnkiConnect available", true)
        c("importAnki ack", sendCmd(["action":"importAnki"], timeout: 90) != nil)
        for _ in 0..<30 { usleep(1_000_000) }
        if let notes = anki("findNotes", ["query":"\"note:WordWorkbench v3\" ID:\(enz2.id)"]) as? [Int64], let nid = notes.first {
            c("note in Anki", true, "id=\(nid)")
            if let infos = anki("notesInfo", ["notes":[nid]]) as? [[String:Any]], let info = infos.first, let fields = info["fields"] as? [String:Any] {
                let def = (fields["Definition"] as? [String:Any])?["value"] as? String ?? ""
                c("card has definition", !def.isEmpty, "\(def.count) bytes")
                let selGloss = enz2.groups.flatMap({$0.senses}).first(where: {$0.sourceSenseID==sid})?.gloss ?? ""
                c("selected gloss in card", def.contains(selGloss) || selGloss.isEmpty, selGloss.prefix(30).description)
                let unsel = enz2.groups.flatMap({$0.senses}).filter({$0.sourceSenseID != sid}).map({$0.gloss}).filter({!$0.isEmpty})
                let leaked = unsel.filter({def.contains($0)})
                c("unselected NOT leaked", leaked.isEmpty, "leaked: \(leaked.prefix(3))")
            }
        } else { c("note in Anki", false, "not found") }
    }
    
    // A3: Edge cases
    print("\n--- A3 ---")
    c("empty word ack", sendCmd(["action":"addWord","word":""]) != nil)
    c("fake word ack", sendCmd(["action":"addWord","word":"xyznonexistent999"]) != nil)
    if let fs = readState(), let fd = fs.decks.first(where: {$0.ankiDeckName==TestDeck}) {
        let words = fd.entries.map({$0.word}); let dupes = Dictionary(grouping: words, by: {$0}).filter({$0.value.count>1})
        c("no duplicate words", dupes.isEmpty, "\(dupes.keys)")
        c("all entries have senses", fd.entries.allSatisfy({$0.totalSenses>0}))
    }
    
    // Cleanup
    try? FileManager.default.removeItem(atPath: "/tmp/wwb-command.json")
    try? FileManager.default.removeItem(atPath: "/tmp/wwb-command-ack.json")
    
    let p = reports.filter({$0.1}).count; let f = reports.filter({!$0.1}).count
    print("\n=== \(p)/\(reports.count) passed, \(f) failed ===")
    for r in reports { print("  [\(r.1 ? "✓" : "✗")] \(r.0)\(r.2.isEmpty ? "" : " — \(r.2)")") }
    let rpt: [String:Any] = ["timestamp":ISO8601DateFormatter().string(from:Date()),"passed":p,"total":reports.count,"failed":f]
    try? JSONSerialization.data(withJSONObject: rpt, options:.prettyPrinted).write(to: URL(fileURLWithPath:"/tmp/wwb-autotest-report.json"))
    print("\nReport: /tmp/wwb-autotest-report.json")
    exit(f > 0 ? 1 : 0)
}}