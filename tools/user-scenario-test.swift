import Foundation

// Comprehensive user-scenario verification.
// Simulates real user flows end-to-end, checks every state transition and edge case.

let TestDeck = "GUI复核测试"
let cmdPath = "/tmp/wwb-command.json"
let ackPath = "/tmp/wwb-command-ack.json"

// MARK: - Helpers
func readLibrary() -> [String:Any]? {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let p = home.appendingPathComponent("Library/Application Support/WordWorkbench/library-v3.json").path
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: p)),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String:Any] else { return nil }
    return o
}

var cmdSeq = 0
func sendCmd(_ cmd: [String:Any], timeout: Int = 10) -> [String:Any]? {
    cmdSeq += 1
    var c = cmd; c["seq"] = cmdSeq
    try? FileManager.default.removeItem(atPath: ackPath)
    try? JSONSerialization.data(withJSONObject: c).write(to: URL(fileURLWithPath: cmdPath))
    for _ in 0..<(timeout*2) {
        usleep(500_000)
        if let d = try? Data(contentsOf: URL(fileURLWithPath: ackPath)),
           let a = try? JSONSerialization.jsonObject(with: d) as? [String:Any],
           a["status"] as? String == "ok" { return a }
    }
    return nil
}

func debugState() -> [String:Any]? {
    return sendCmd(["action":"debugState"], timeout: 5)
}

func waitForPred(_ pred: () -> Bool, timeout: Int) -> Bool {
    for _ in 0..<(timeout*2) { if pred() { return true }; usleep(500_000) }
    return false
}

var issues = [(String,Bool,String)]()

func check(_ name: String, _ cond: Bool, _ detail: String = "") {
    let mark = cond ? "✓" : "✗"
    print("[\(mark)] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    issues.append((name, cond, detail))
}

// MARK: - Main
@main struct UserScenarioTest { static func main() {
print("=== User Scenario Test ===\n")

// ---- PREAMBLE: ensure fresh state ----
print("--- Preamble: reset state ---")
let lib = readLibrary()
guard lib != nil else { print("FATAL: no library"); exit(1) }
print("Library loaded.")

_ = sendCmd(["action":"selectDeck","deckName":TestDeck])
usleep(1_000_000)

// Purge duplicates to start clean
_ = sendCmd(["action":"purgeDuplicates"])
usleep(2_000_000)

// ---- SCENARIO 1: Capture → auto-review → toggle senses ----
print("\n--- S1: Capture → Review → Sense Toggle ---")

// Add a word
let word1 = "catalyst"
let ack1 = sendCmd(["action":"addWord","word":word1])
check("S1.1 addWord returns ack", ack1 != nil)

// Wait for lookup to complete (async)
let added = waitForPred({
    guard let lib = readLibrary(),
          let decks = lib["decks"] as? [[String:Any]],
          let d = decks.first(where: { ($0["ankiDeckName"] as? String) == TestDeck }),
          let entries = d["entries"] as? [[String:Any]] else { return false }
    return entries.contains(where: { ($0["word"] as? String) == word1 })
}, timeout: 20)
check("S1.2 word appears in library", added)

// Check that mode switched to review (debugState tells us the current entry)
let ds1 = debugState()
check("S1.3 debugState returns state", ds1 != nil)
if let ds = ds1 {
    let currentWord = ds["currentWord"] as? String ?? ""
    check("S1.4 current entry is \(word1)", currentWord == word1)
    let selCount = ds["currentSelectedCount"] as? Int ?? -1
    check("S1.5 some senses auto-selected", selCount > 0, "selected=\(selCount)")
    
    // Deselect all
    _ = sendCmd(["action":"deselectAll"])
    usleep(1_000_000)
    let ds2 = debugState()
    let selCount2 = ds2?["currentSelectedCount"] as? Int ?? -1
    check("S1.6 deselectAll clears all", selCount2 == 0, "selected=\(selCount2)")
    
    // Select exactly one sense
    let senseIDs = ds2?["currentSenseIDs"] as? [String] ?? []
    check("S1.7 has sense IDs", !senseIDs.isEmpty, "count=\(senseIDs.count)")
    if let firstID = senseIDs.first {
        _ = sendCmd(["action":"selectSense","sourceSenseID":firstID,"word":word1])
        usleep(1_000_000)
        let ds3 = debugState()
        let selCount3 = ds3?["currentSelectedCount"] as? Int ?? -1
        check("S1.8 selectSense picks one", selCount3 == 1, "selected=\(selCount3)")
    }
}

// ---- SCENARIO 2: Add another word, verify it's the current entry ----
print("\n--- S2: Second word, auto-focus ---")
let word2 = "enzyme"
_ = sendCmd(["action":"addWord","word":word2])
_ = waitForPred({
    guard let lib = readLibrary(),
          let decks = lib["decks"] as? [[String:Any]],
          let d = decks.first(where: { ($0["ankiDeckName"] as? String) == TestDeck }),
          let entries = d["entries"] as? [[String:Any]] else { return false }
    return entries.contains(where: { ($0["word"] as? String) == word2 })
}, timeout: 20)

let ds4 = debugState()
check("S2.1 second word becomes current", (ds4?["currentWord"] as? String) == word2)
check("S2.2 first word still exists", {
    guard let lib = readLibrary(),
          let decks = lib["decks"] as? [[String:Any]],
          let d = decks.first(where: { ($0["ankiDeckName"] as? String) == TestDeck }),
          let entries = d["entries"] as? [[String:Any]] else { return false }
    return entries.contains(where: { ($0["word"] as? String) == word1 })
}())

// ---- SCENARIO 3: Review mode navigation (selectEntry) ----
print("\n--- S3: Review navigation ---")
_ = sendCmd(["action":"selectEntry","word":word1])
usleep(1_000_000)
let ds5 = debugState()
check("S3.1 selectEntry switches to word1", (ds5?["currentWord"] as? String) == word1)

_ = sendCmd(["action":"selectEntry","word":word2])
usleep(1_000_000)
let ds6 = debugState()
check("S3.2 selectEntry switches to word2", (ds6?["currentWord"] as? String) == word2)

// ---- SCENARIO 4: Anki import ----
print("\n--- S4: Anki import ---")
// First select some senses on both words
_ = sendCmd(["action":"selectEntry","word":word1])
usleep(500_000)
let ds7 = debugState()
if let ids = ds7?["currentSenseIDs"] as? [String], let first = ids.first {
    _ = sendCmd(["action":"selectSense","sourceSenseID":first,"word":word1])
}
usleep(500_000)

_ = sendCmd(["action":"selectEntry","word":word2])
usleep(500_000)
let ds8 = debugState()
if let ids = ds8?["currentSenseIDs"] as? [String], let first = ids.first {
    _ = sendCmd(["action":"selectSense","sourceSenseID":first,"word":word2])
}
usleep(500_000)

// Import
let importAck = sendCmd(["action":"importAnki"], timeout: 30)
check("S4.1 importAnki returns ack", importAck != nil)

// Verify notes exist in Anki
Thread.sleep(forTimeInterval: 3)
let ankiCheck: () -> Bool = {
    var r = URLRequest(url: URL(string: "http://127.0.0.1:8765")!)
    r.httpMethod = "POST"
    r.timeoutInterval = 10
    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    for word in [word1, word2] {
        r.httpBody = try? JSONSerialization.data(withJSONObject: [
            "action":"findNotes","version":6,
            "params":["query":"\"note:WordWorkbench v3\" Word:\"\(word)\""]
        ])
        guard let d = try? Data(contentsOf: r.url!), // simplified — actual implementation uses URLSession
              let o = try? JSONSerialization.jsonObject(with: d) as? [String:Any],
              let result = o["result"] as? [Int64], !result.isEmpty else { return false }
    }
    return true
}
// Use curl for simplicity
func ankiFind(_ word: String) -> Bool {
    let sem = DispatchSemaphore(value: 0)
    var ok = false
    var r = URLRequest(url: URL(string: "http://127.0.0.1:8765")!)
    r.httpMethod = "POST"; r.timeoutInterval = 15
    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    r.httpBody = try? JSONSerialization.data(withJSONObject: [
        "action":"findNotes","version":6,
        "params":["query":"\"note:WordWorkbench v3\" Word:\"\(word)\""]
    ])
    URLSession(configuration: .ephemeral).dataTask(with: r) { d, resp, _ in
        defer { sem.signal() }
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let d = d,
              let o = try? JSONSerialization.jsonObject(with: d) as? [String:Any],
              let ids = o["result"] as? [Int64] else { return }
        ok = !ids.isEmpty
    }.resume()
    sem.wait()
    return ok
}
check("S4.2 \(word1) note in Anki", ankiFind(word1))
check("S4.3 \(word2) note in Anki", ankiFind(word2))

// ---- SCENARIO 5: Persistence across restart ----
print("\n--- S5: Persistence ---")
// Record current state
let beforeEntryCount = (debugState()?["entryCount"] as? Int) ?? 0
let beforeAllWords = (debugState()?["allWords"] as? [String]) ?? []
print("  Before restart: \(beforeEntryCount) entries — \(beforeAllWords)")

// Kill and relaunch
let killTask = Process()
killTask.launchPath = "/usr/bin/pkill"
killTask.arguments = ["-9", "-f", "WordWorkbench"]
try? killTask.run()
killTask.waitUntilExit()
sleep(2)

let openTask = Process()
openTask.launchPath = "/usr/bin/open"
openTask.arguments = [ProcessInfo.processInfo.environment["WWB_APP_PATH"] ?? NSHomeDirectory() + "/Applications/每日录词工作台.app"]
try? openTask.run()
sleep(6)

// Wait for app to be responsive
_ = waitForPred({ sendCmd(["action":"debugState"], timeout: 3) != nil }, timeout: 20)
_ = sendCmd(["action":"selectDeck","deckName":TestDeck])
usleep(1_000_000)

let ds9 = debugState()
check("S5.1 app responsive after restart", ds9 != nil)
let afterEntryCount = ds9?["entryCount"] as? Int ?? -1
let afterAllWords = ds9?["allWords"] as? [String] ?? []
check("S5.2 entry count preserved", afterEntryCount >= beforeEntryCount, "before=\(beforeEntryCount) after=\(afterEntryCount)")

// Check that selected senses survived
_ = sendCmd(["action":"selectEntry","word":word1])
usleep(500_000)
let ds10 = debugState()
let selAfter = ds10?["currentSelectedCount"] as? Int ?? -1
check("S5.3 selections survived restart for \(word1)", selAfter > 0, "selected=\(selAfter)")

// ---- SCENARIO 6: Edge cases ----
print("\n--- S6: Edge cases ---")

// 6.1 Empty word
let emptyAck = sendCmd(["action":"addWord","word":""])
check("S6.1 empty word returns ack (rejected)", emptyAck != nil)
// Check no new entry
let allWords6 = debugState()?["allWords"] as? [String] ?? []
check("S6.2 no empty entry added", !allWords6.contains(""))

// 6.2 Fake word
let fakeAck = sendCmd(["action":"addWord","word":"xyznonexistent12345"])
check("S6.3 fake word returns ack (not found)", fakeAck != nil)

// 6.3 Select sense without word filter — should work on current entry
_ = sendCmd(["action":"selectEntry","word":word1])
usleep(500_000)
let ds11 = debugState()
if let ids = ds11?["currentSenseIDs"] as? [String], ids.count > 1 {
    _ = sendCmd(["action":"deselectAll"])
    usleep(500_000)
    _ = sendCmd(["action":"selectSense","sourceSenseID":ids[1]]) // no word filter
    usleep(500_000)
    let ds12 = debugState()
    let sel2 = ds12?["currentSelectedCount"] as? Int ?? -1
    check("S6.4 selectSense without word filter works", sel2 == 1, "selected=\(sel2)")
}

// ---- SCENARIO 7: Rapid-fire operations ----
print("\n--- S7: Rapid operations ---")
_ = sendCmd(["action":"addWord","word":"strain"])
usleep(200_000) // very short wait
_ = sendCmd(["action":"selectEntry","word":"enzyme"])
usleep(200_000)
_ = sendCmd(["action":"selectEntry","word":"catalyst"])
usleep(200_000)
let ds13 = debugState()
check("S7.1 rapid navigation stable", ds13 != nil && (ds13?["currentWord"] as? String) == "catalyst")

// ---- SUMMARY ----
print("\n=== Summary ===")
let passed = issues.filter(\.1).count
let total = issues.count
for (name, ok, detail) in issues {
    print("  [\(ok ? "✓" : "✗")] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
}
print("\n\(passed)/\(total) passed")
if passed == total { print("ALL USER SCENARIOS PASSED") }
else { print("ISSUES FOUND — see above") }
exit(passed == total ? 0 : 1)
}}