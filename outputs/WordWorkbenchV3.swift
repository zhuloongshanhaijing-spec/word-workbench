import SwiftUI
import AppKit
import ApplicationServices
import ScreenCaptureKit
import UniformTypeIdentifiers

struct V3Library: Codable {
    var databasePath: String?
    var decks: [DeckBook] = []
    var semanticSettings: SemanticSettings?
    /// Restored on next launch so automated tests have a stable starting point.
    var lastDeckID: String?
    var lastUnitID: String?

    private enum CodingKeys: String, CodingKey { case databasePath, decks, semanticSettings, lastDeckID, lastUnitID }
    init(databasePath: String? = nil, decks: [DeckBook] = [], semanticSettings: SemanticSettings? = nil, lastDeckID: String? = nil, lastUnitID: String? = nil) {
        self.databasePath = databasePath; self.decks = decks; self.semanticSettings = semanticSettings
        self.lastDeckID = lastDeckID; self.lastUnitID = lastUnitID
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        databasePath = try values.decodeIfPresent(String.self, forKey: .databasePath)
        decks = try values.decodeIfPresent([DeckBook].self, forKey: .decks) ?? []
        semanticSettings = try values.decodeIfPresent(SemanticSettings.self, forKey: .semanticSettings)
        lastDeckID = try values.decodeIfPresent(String.self, forKey: .lastDeckID)
        lastUnitID = try values.decodeIfPresent(String.self, forKey: .lastUnitID)
    }
}

enum WorkspaceMode: String, CaseIterable, Identifiable {
    case capture = "录入"
    case review = "审核"
    var id: String { rawValue }
}

struct V3LookupIssue { var input: String; var candidates: [String] }
struct V3Error: LocalizedError { let message: String; var errorDescription: String? { message } }

private struct DeletedEntry {
    let deckID: String
    let index: Int
    let entry: StructuredEntry
}

@MainActor
final class V3Workbench: ObservableObject {
    @Published var library = V3Library()
    @Published var selectedDeckID: String?
    @Published var selectedUnitID: String?
    @Published var selectedEntryID: String?
    @Published var newDeckName = ""
    @Published var newUnitName = ""
    @Published var newUnitSubject = ""
    @Published var newUnitTopics = ""
    @Published var newUnitContext = ""
    @Published var input = ""
    @Published var issue: V3LookupIssue?
    @Published var status = "先选择 Open Dictionary 的 distribution.sqlite，然后新建 Deck 与 Unit。"
    @Published var busy = false
    @Published var mode: WorkspaceMode = .capture
    @Published var canUndoDelete = false
    @Published var availableDictionaryRelease: OpenDictionaryRelease?
    @Published var dictionaryUpdateProgress: Double?
    @Published var dictionaryNotice = "未检查更新"
    @Published var dictionaryChecking = false
    @Published var semanticNotice = "尚未检测 Ollama"
    @Published var semanticChecking = false
    @Published var semanticInstalling = false
    @Published var rerankerNotice = "尚未检测本地重排服务"
    @Published var rerankerChecking = false
    @Published var rerankerHealthDetail = "未检测"
    @Published var showsReRecommendConfirmation = false
    private var deletedEntry: DeletedEntry?

    private let root: URL
    private let file: URL
    private let dictionaryLifecycle: OpenDictionaryLifecycle

    init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WordWorkbench", isDirectory: true)
        file = root.appendingPathComponent("library-v3.json")
        dictionaryLifecycle = OpenDictionaryLifecycle(applicationSupportRoot: root)
        load()
        bootstrapDictionary()
        startTestCommandLoop()
    }

    // MARK: - Own-window pixel capture (no TCC consent needed for own process)
    static func captureOwnWindow() async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let win = content.windows.first(where: { $0.owningApplication?.processID == pid }) else {
            throw V3Error(message: "未找到本进程窗口")
        }
        let filter = SCContentFilter(desktopIndependentWindow: win)
        let config = SCStreamConfiguration()
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private func windowFrameOrigin() -> CGPoint {
        NSApp.windows.first { !$0.isMiniaturized }?.frame.origin ?? .zero
    }

    /// SwiftUI 的无障碍发布是惰性的：进程自查询可能不触发物化，导致
    /// C-API 遍历时窗口子树为空。一次无害的 AX 写入强制 AppKit 构建
    /// 完整无障碍树（axTree/axPress/axFocus 前调用）。
    private func axWakeUp() {
        if let content = NSApp.windows.first(where: { !$0.isMiniaturized })?.contentView {
            content.setAccessibilityLabel("工作台主窗口")
        }
    }

    // MARK: - Test harness command loop
    /// Reads /tmp/wwb-command.json every 500ms; executes actions for automated testing.
    /// No permissions needed — the app already has filesystem access.
    private func startTestCommandLoop() {
        let cmdPath = "/tmp/wwb-command.json"
        Task.detached { [weak self] in
            var lastSeq = 0
            while true {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self = self else { return }
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: cmdPath)),
                      data.count > 2,
                      let cmd = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let seq = (cmd["seq"] as? NSNumber)?.intValue ?? 0
                guard seq > lastSeq else { continue }
                lastSeq = seq
                let action = cmd["action"] as? String ?? ""
                await MainActor.run {
                    switch action {
                    case "addWord":
                        let word = cmd["word"] as? String ?? ""
                        self.input = word
                        self.lookup()
                    case "selectSense":
                        let sourceID = cmd["sourceSenseID"] as? String ?? ""
                        let filterWord = cmd["word"] as? String
                        if let di = self.deckIndex {
                            for gi in self.library.decks[di].entries.indices {
                                if let fw = filterWord, self.library.decks[di].entries[gi].word != fw { continue }
                                for gi2 in self.library.decks[di].entries[gi].groups.indices {
                                    for si in self.library.decks[di].entries[gi].groups[gi2].senses.indices {
                                        if self.library.decks[di].entries[gi].groups[gi2].senses[si].sourceSenseID == sourceID {
                                            self.library.decks[di].entries[gi].groups[gi2].senses[si].selected = true
                                        }
                                    }
                                }
                            }
                        }
                        self.save()
                    case "deselectSense":
                        if let sourceID = cmd["sourceSenseID"] as? String,
                           let di = self.deckIndex {
                            for gi in self.library.decks[di].entries.indices {
                                for gi2 in self.library.decks[di].entries[gi].groups.indices {
                                    for si in self.library.decks[di].entries[gi].groups[gi2].senses.indices {
                                        if self.library.decks[di].entries[gi].groups[gi2].senses[si].sourceSenseID == sourceID {
                                            self.library.decks[di].entries[gi].groups[gi2].senses[si].selected = false
                                        }
                                    }
                                }
                            }
                        }
                        self.save()
                    case "deselectAll":
                        if let di = self.deckIndex {
                            if let ei = self.entryIndex {
                                for gi in self.library.decks[di].entries[ei].groups.indices {
                                    for si in self.library.decks[di].entries[ei].groups[gi].senses.indices {
                                        self.setSenseSelected(group: gi, sense: si, value: false)
                                    }
                                }
                            } else {
                                for ei2 in self.library.decks[di].entries.indices {
                                    for gi in self.library.decks[di].entries[ei2].groups.indices {
                                        for si in self.library.decks[di].entries[ei2].groups[gi].senses.indices {
                                            self.setSenseSelected(group: gi, sense: si, value: false)
                                        }
                                    }
                                }
                            }
                            self.save()
                        }
                    case "goCapture":
                        self.mode = .capture
                    case "selectDeck":
                        let name = cmd["deckName"] as? String ?? ""
                        if let deck = self.library.decks.first(where: { $0.ankiDeckName == name }) {
                            self.selectDeck(deck.id)
                        }
                    case "selectEntry":
                        let word = cmd["word"] as? String ?? ""
                        if let di = self.deckIndex,
                           let ei = self.library.decks[di].entries.lastIndex(where: { $0.word == word }) {
                            self.selectedEntryID = self.library.decks[di].entries[ei].id
                        }
                    case "purgeDuplicates":
                        if let di = self.deckIndex {
                            var seen: [String: Bool] = [:]
                            var keep: [Int] = []
                            for i in (0..<self.library.decks[di].entries.count).reversed() {
                                let w = self.library.decks[di].entries[i].word
                                if seen[w] == nil { seen[w] = true; keep.append(i) }
                            }
                            self.library.decks[di].entries = keep.reversed().map { self.library.decks[di].entries[$0] }
                            self.save()
                        }
                    case "importAnki":
                        Task { await self.importAnki() }
                    case "screenshot":
                        // Own-window capture via ScreenCaptureKit: capturing our
                        // own process's window needs no TCC consent. Classic
                        // cacheDisplay/dataWithPDF fail on layer-backed SwiftUI.
                        Task { @MainActor in
                            do {
                                let image = try await Self.captureOwnWindow()
                                let rep = NSBitmapImageRep(cgImage: image)
                                if let png = rep.representation(using: .png, properties: [:]) {
                                    try? png.write(to: URL(fileURLWithPath: "/tmp/wwb-screenshot.png"))
                                }
                            } catch {
                                try? "SCK failure: \(error.localizedDescription)".data(using: .utf8)?
                                    .write(to: URL(fileURLWithPath: "/tmp/wwb-screenshot.err"))
                            }
                        }
                    case "axFocus":
                        // Focus a control via AX (equivalent to the user clicking
                        // into it) so subsequent key events hit the real target.
                        let wantRole = cmd["role"] as? String ?? ""
                        let wantLabel = cmd["label"] as? String ?? ""
                        let appEl = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
                        self.axWakeUp()
                        func attrF(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
                            var v: CFTypeRef?
                            guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
                            return v
                        }
                        var focused = 0
                        var seenF = Set<Int>()
                        func walkFocus(_ el: AXUIElement, _ depth: Int) {
                            guard depth < 14, focused < 1 else { return }
                            guard seenF.insert(Int(CFHash(el))).inserted else { return }
                            let role = attrF(el, kAXRoleAttribute) as? String ?? ""
                            let title = (attrF(el, kAXTitleAttribute) as? String)
                                ?? (attrF(el, kAXDescriptionAttribute) as? String ?? "")
                            if (wantRole.isEmpty || role == wantRole) && (wantLabel.isEmpty || title.contains(wantLabel)) {
                                if AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success { focused += 1 }
                            }
                            if let kids = attrF(el, kAXChildrenAttribute) as? [AXUIElement] {
                                for k in kids { walkFocus(k, depth + 1) }
                            }
                        }
                        walkFocus(appEl, 0)
                    case "setGloss":
                        // 测试通道：AX 对自定义 Binding 无法触发提交（仅真实键盘
                        // 输入可），模型路径由本命令确定性覆盖。
                        if let g0 = (cmd["group"] as? NSNumber)?.intValue,
                           let s0 = (cmd["sense"] as? NSNumber)?.intValue,
                           let text = cmd["text"] as? String,
                           let di = self.deckIndex, let ei = self.entryIndex,
                           self.library.decks[di].entries.indices.contains(ei),
                           self.library.decks[di].entries[ei].groups.indices.contains(g0),
                           self.library.decks[di].entries[ei].groups[g0].senses.indices.contains(s0) {
                            self.library.decks[di].entries[ei].groups[g0].senses[s0].gloss = text
                            self.save()
                        }
                    case "deleteWord":
                        if let w = cmd["word"] as? String, let di = self.deckIndex,
                           let ei = self.library.decks[di].entries.firstIndex(where: { $0.word == w }) {
                            let removed = self.library.decks[di].entries.remove(at: ei)
                            if self.selectedEntryID == removed.id { self.selectedEntryID = nil }
                            if self.library.decks[di].entries.isEmpty { self.mode = .capture }
                            self.save()
                        }
                    case "axSet":
                        // Set a value on a matched element: TextField string or
                        // CheckBox 0/1 — drives the REAL SwiftUI binding path.
                        let wantRole = cmd["role"] as? String ?? ""
                        let wantLabel = cmd["label"] as? String ?? ""
                        let wantValue = cmd["value"] as? String ?? ""
                        let idx = (cmd["index"] as? NSNumber)?.intValue ?? 0
                        let text = cmd["text"] as? String ?? ""
                        let appEl = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
                        self.axWakeUp()
                        func attrS(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
                            var v: CFTypeRef?
                            guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
                            return v
                        }
                        var matches: [AXUIElement] = []
                        var seenS = Set<Int>()
                        func walkSet(_ el: AXUIElement, _ depth: Int) {
                            guard depth < 14, matches.count < 40 else { return }
                            guard seenS.insert(Int(CFHash(el))).inserted else { return }
                            let role = attrS(el, kAXRoleAttribute) as? String ?? ""
                            let title = (attrS(el, kAXTitleAttribute) as? String)
                                ?? (attrS(el, kAXDescriptionAttribute) as? String ?? "")
                            let ph = attrS(el, kAXPlaceholderValueAttribute) as? String ?? ""
                            let cur = attrS(el, kAXValueAttribute) as? String ?? ""
                            if (wantRole.isEmpty || role == wantRole)
                                && (wantLabel.isEmpty || title.contains(wantLabel) || ph.contains(wantLabel))
                                && (wantValue.isEmpty || cur.contains(wantValue)) {
                                matches.append(el)
                            }
                            if let kids = attrS(el, kAXChildrenAttribute) as? [AXUIElement] {
                                for k in kids { walkSet(k, depth + 1) }
                            }
                        }
                        walkSet(appEl, 0)
                        guard idx < matches.count else { break }
                        let target = matches[idx]
                        if (attrS(target, kAXRoleAttribute) as? String) == "AXCheckBox" {
                            let on = (text == "1")
                            _ = AXUIElementSetAttributeValue(target, kAXValueAttribute as CFString, on ? kCFBooleanTrue : kCFBooleanFalse)
                        } else {
                            _ = AXUIElementSetAttributeValue(target, kAXValueAttribute as CFString, text as CFString)
                        }
                    case "setInput":
                        if let t = cmd["text"] as? String { self.input = t }
                    case "sendKey":
                        // Dispatch a key event through the app's REAL responder
                        // chain (window -> focus view -> onExitCommand) without
                        // needing system-level Accessibility permission.
                        if let code = (cmd["keyCode"] as? NSNumber)?.intValue {
                            NSApp.activate(ignoringOtherApps: true)
                            let winNum = NSApp.keyWindow?.windowNumber
                                ?? NSApp.mainWindow?.windowNumber
                                ?? NSApp.windows.first { !$0.isMiniaturized }?.windowNumber ?? 0
                            let esc = String(UnicodeScalar(0x1B))
                            let defaultChars: [UInt16: String] = [6: "z", 0: "a", 36: "\r", 53: esc]
                            let chars = (cmd["characters"] as? String)
                                ?? defaultChars[UInt16(code)] ?? ""
                            var mods: NSEvent.ModifierFlags = []
                            for m in (cmd["mods"] as? [String]) ?? [] {
                                switch m {
                                case "command": mods.insert(.command)
                                case "shift": mods.insert(.shift)
                                case "option": mods.insert(.option)
                                case "control": mods.insert(.control)
                                default: break
                                }
                            }
                            let make: (Bool) -> NSEvent? = { down in
                                NSEvent.keyEvent(
                                    with: down ? .keyDown : .keyUp,
                                    location: .zero, modifierFlags: mods,
                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: winNum,
                                    context: nil, characters: chars,
                                    charactersIgnoringModifiers: chars,
                                    isARepeat: false, keyCode: UInt16(code))
                            }
                            if let down = make(true) { NSApp.sendEvent(down) }
                            if let up = make(false) { NSApp.sendEvent(up) }
                        }
                    case "cancelOp":
                        // Semantic Escape: deliver cancelOperation: to the real
                        // first responder chain — the exact contract onExitCommand
                        // is wired to. Hardware-level Esc translation is standard
                        // AppKit behavior upstream of this point.
                        NSApp.activate(ignoringOtherApps: true)
                        _ = NSApp.sendAction(Selector(("cancelOperation:")), to: nil, from: nil)
                    case "goReview":
                        guard self.deck?.entries.isEmpty == false else { break }
                        self.mode = .review
                    case "axPress":
                        // Semantic click: find an AX element by role/label/value
                        // and perform its press action — fires the REAL SwiftUI
                        // handler, no Accessibility permission needed for self.
                        let wantRole = cmd["role"] as? String ?? ""
                        let wantLabel = cmd["label"] as? String ?? ""
                        let wantValue = cmd["value"] as? String ?? ""
                        let appEl = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
                        self.axWakeUp()
                        func attrX(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
                            var v: CFTypeRef?
                            guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
                            return v
                        }
                        var pressed = 0
                        var seenP = Set<Int>()
                        func walkPress(_ el: AXUIElement, _ depth: Int) {
                            guard depth < 14, pressed < 3 else { return }
                            guard seenP.insert(Int(CFHash(el))).inserted else { return }
                            let role = attrX(el, kAXRoleAttribute) as? String ?? ""
                            let title = attrX(el, kAXTitleAttribute) as? String
                                ?? (attrX(el, kAXDescriptionAttribute) as? String ?? "")
                            let valueStr = attrX(el, kAXValueAttribute) as? String ?? ""
                            let matches = (wantRole.isEmpty || role == wantRole)
                                && (wantLabel.isEmpty || title.contains(wantLabel) || valueStr.contains(wantLabel))
                                && (wantValue.isEmpty || valueStr.contains(wantValue))
                            let exact = (cmd["exact"] as? Bool) ?? false
                            let hit = exact
                                ? (wantRole.isEmpty || role == wantRole) && (wantLabel.isEmpty || title == wantLabel || valueStr == wantLabel) && (wantValue.isEmpty || valueStr == wantValue)
                                : matches
                            if hit, !wantRole.isEmpty || !wantLabel.isEmpty || !wantValue.isEmpty {
                                if AXUIElementPerformAction(el, kAXPressAction as CFString) == .success { pressed += 1 }
                            }
                            if let kids = attrX(el, kAXChildrenAttribute) as? [AXUIElement] {
                                for k in kids { walkPress(k, depth + 1) }
                            }
                        }
                        walkPress(appEl, 0)
                    case "axTree":
                        // Semantic "screenshot" via the system AX API pointed at
                        // our OWN process: same tree System Events sees, but
                        // self-introspection needs no Accessibility TCC grant.
                        let appEl = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
                        self.axWakeUp()
                        var nodes: [[String: Any]] = []
                        func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
                            var v: CFTypeRef?
                            guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
                            return v
                        }
                        var seen = Set<Int>()  // AX 树可能自引用（AXApplication 循环），按元素身份去重
                        func dumpAX(_ el: AXUIElement, _ depth: Int) {
                            guard depth < 14, nodes.count < 1200 else { return }
                            guard seen.insert(Int(CFHash(el))).inserted else { return }
                            let role = attr(el, kAXRoleAttribute) as? String ?? ""
                            // SwiftUI exposes .accessibilityLabel via AXDescription,
                            // not AXTitle — read both plus value.
                            let title = (attr(el, kAXTitleAttribute) as? String)
                                ?? (attr(el, kAXDescriptionAttribute) as? String ?? "")
                            let value: Any
                            if let s = attr(el, kAXValueAttribute) as? String { value = s }
                            else if let n = attr(el, kAXValueAttribute) as? NSNumber { value = n }
                            else { value = "" }
                            var node: [String: Any] = ["role": role, "depth": depth]
                            if !title.isEmpty { node["label"] = title }
                            if let v = value as? String, !v.isEmpty { node["value"] = v }
                            if let n = value as? NSNumber { node["value"] = n }
                            if let posV = attr(el, kAXPositionAttribute), let sizeV = attr(el, kAXSizeAttribute) {
                                var p = CGPoint.zero, s = CGSize.zero
                                if AXValueGetValue(posV as! AXValue, .cgPoint, &p),
                                   AXValueGetValue(sizeV as! AXValue, .cgSize, &s) {
                                    node["frame"] = ["x": p.x, "y": p.y, "w": s.width, "h": s.height]
                                }
                            }
                            nodes.append(node)
                            if let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] {
                                for k in kids { dumpAX(k, depth + 1) }
                            }
                            // 某些状态下 app 的 children 不含窗口；显式从
                            // kAXWindowsAttribute 补充（seen 集合防重复）。
                            if depth == 0, let wins = attr(el, kAXWindowsAttribute) as? [AXUIElement] {
                                for w in wins { dumpAX(w, 1) }
                            }
                        }
                        dumpAX(appEl, 0)
                        var meta: [String: Any] = ["nodeCount": nodes.count]
                        meta["nsWindows"] = NSApp.windows.map { [
                            "title": $0.title,
                            "class": String(describing: type(of: $0)),
                            "visible": $0.isVisible,
                            "mini": $0.isMiniaturized
                        ] }
                        var cf: CFTypeRef?
                        let r1 = AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &cf)
                        meta["windowsResult"] = "\(r1.rawValue)" + (cf != nil ? " count=\((cf as? [AXUIElement])?.count ?? -1)" : " nil")
                        // 备用获取路径：systemWide → focusedApplication（自 pid 代理可能损坏）
                        NSApp.activate(ignoringOtherApps: true)
                        let sw = AXUIElementCreateSystemWide()
                        var faRef: CFTypeRef?
                        let rf = AXUIElementCopyAttributeValue(sw, kAXFocusedApplicationAttribute as CFString, &faRef)
                        meta["focusedAppResult"] = "\(rf.rawValue)"
                        if let far = faRef {
                            let fa = far as! AXUIElement
                            var wRef: CFTypeRef?
                            let rfw = AXUIElementCopyAttributeValue(fa, kAXWindowsAttribute as CFString, &wRef)
                            meta["faWindows"] = "\(rfw.rawValue)" + (wRef != nil ? " count=\((wRef as? [Any])?.count ?? -1)" : " nil")
                            if let wlist = wRef as? [Any], let wfirst = wlist.first {
                                let w2 = wfirst as! AXUIElement
                                var roleRef2: CFTypeRef?
                                AXUIElementCopyAttributeValue(w2, kAXRoleAttribute as CFString, &roleRef2)
                                meta["faWinRole"] = (roleRef2 as? String) ?? "nil"
                            }
                        }
                        if let cfv = cf as? [Any], let first = cfv.first {
                            let w = first as! AXUIElement  // CF 下转型按编译器保证必然成功
                            var kidsRef: CFTypeRef?
                            let rw = AXUIElementCopyAttributeValue(w, kAXChildrenAttribute as CFString, &kidsRef)
                            meta["winChildren"] = "\(rw.rawValue)" + (kidsRef != nil ? " count=\((kidsRef as? [Any])?.count ?? -1)" : " nil")
                            var roleRef: CFTypeRef?
                            AXUIElementCopyAttributeValue(w, kAXRoleAttribute as CFString, &roleRef)
                            meta["winRole"] = (roleRef as? String) ?? "nil"
                        }
                        let r2 = AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &cf)
                        meta["focusedResult"] = "\(r2.rawValue)" + (cf != nil ? " yes" : " nil")
                        if let data = try? JSONSerialization.data(withJSONObject: ["nodes": nodes, "meta": meta], options: [.prettyPrinted]) {
                            try? data.write(to: URL(fileURLWithPath: "/tmp/wwb-axtree.json"))
                        }
                    case "debugState":
                        var info: [String: Any] = ["status":"ok","action":"debugState","deck":self.deck?.ankiDeckName ?? "","entryCount":self.deck?.entries.count ?? 0,"entryIndex":(self.entryIndex ?? -1) as Int,"selectedEntryID":self.selectedEntryID ?? "","mode":self.mode.rawValue,"busy":self.busy,"keyWindow":NSApp.keyWindow != nil,"uiStatus":self.status,"hasIssue":self.issue != nil,"canUndoDelete":self.canUndoDelete,"newUnitName":self.newUnitName,"newDeckName":self.newDeckName,"unitName":self.unit?.name ?? ""]
                        if let di = self.deckIndex {
                            info["deckEntryCount"] = self.library.decks[di].entries.count
                            info["allWords"] = self.library.decks[di].entries.map { $0.word }
                            if let ei = self.entryIndex {
                                let entry = self.library.decks[di].entries[ei]
                                info["currentWord"] = entry.word
                                info["currentSenseIDs"] = entry.groups.flatMap { $0.senses }.compactMap { $0.sourceSenseID }
                                info["currentSelectedCount"] = entry.groups.flatMap { $0.senses }.filter { $0.selected }.count
                            }
                        }
                        try? JSONSerialization.data(withJSONObject: info).write(to: URL(fileURLWithPath: "/tmp/wwb-command-ack.json"))
                    default: break
                    }
                    if action != "debugState" {
                        try? JSONEncoder().encode(["status":"ok","action":action]).write(to: URL(fileURLWithPath: "/tmp/wwb-command-ack.json"))
                    }
                }
            }
        }
    }

    var deckIndex: Int? { library.decks.firstIndex { $0.id == selectedDeckID } }
    var unitIndex: Int? { guard let d = deckIndex else { return nil }; return library.decks[d].units.firstIndex { $0.id == selectedUnitID } }
    var entryIndex: Int? { guard let d = deckIndex else { return nil }; return library.decks[d].entries.firstIndex { $0.id == selectedEntryID } }
    var deck: DeckBook? { deckIndex.map { library.decks[$0] } }
    var unit: UnitProfile? { guard let d = deckIndex, let u = unitIndex else { return nil }; return library.decks[d].units[u] }
    var entry: StructuredEntry? { guard let d = deckIndex, let e = entryIndex else { return nil }; return library.decks[d].entries[e] }
    var selectedEntries: [(Int, StructuredEntry)] {
        guard let d = deckIndex else { return [] }
        return library.decks[d].entries.enumerated().filter { $0.element.hasSelectedSense }
    }
    var isDictionaryReady: Bool {
        guard let path = library.databasePath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }
    var pendingCount: Int { deck?.entries.filter { !$0.imported && $0.hasSelectedSense }.count ?? 0 }
    var importedCount: Int { deck?.entries.filter(\.imported).count ?? 0 }
    var dictionaryVersionText: String {
        if let release = availableDictionaryRelease { return "发现 \(release.tagName)" }
        return dictionaryNotice
    }
    var semanticModelName: String {
        get { semanticSettings.ollamaModel }
        set { updateSemanticSettings { $0.ollamaModel = newValue.trimmingCharacters(in: .whitespacesAndNewlines) } }
    }

    var semanticSettings: SemanticSettings { library.semanticSettings ?? SemanticSettings() }

    private func updateSemanticSettings(_ transform: (inout SemanticSettings) -> Void) {
        var settings = library.semanticSettings ?? SemanticSettings()
        transform(&settings)
        library.semanticSettings = settings
        save()
    }

    var preferredSemanticEngine: String {
        get { semanticSettings.preferredEngine }
        set { updateSemanticSettings { $0.preferredEngine = newValue } }
    }

    var rerankerBaseURL: String {
        get { semanticSettings.rerankerBaseURL }
        set { updateSemanticSettings { $0.rerankerBaseURL = newValue.trimmingCharacters(in: .whitespacesAndNewlines) } }
    }

    /// Ordered fallback chain. The primary engine is first; every later engine is
    /// tried only after the previous one fails validation, times out, or is absent.
    /// `auto` follows the engine that the independent held-out evaluation proved
    /// should lead, not a hard-coded winner.
    func semanticEngines() -> [any SemanticRankingEngine] {
        let settings = semanticSettings
        let reranker = LocalSemanticReranker(baseURL: URL(string: settings.rerankerBaseURL) ?? LocalSemanticReranker.defaultBaseURL,
                                             modelName: settings.rerankerModel)
        let ollama = OllamaRankingEngine(model: settings.ollamaModel)
        switch settings.preferredEngine {
        case "localReranker": return [reranker, ollama]
        case "ollamaEmbedding": return [ollama, reranker]
        case "rule": return []
        default: return SemanticEnginePromotion.autoOrder(reranker: reranker, ollama: ollama)
        }
    }

    func semanticCandidates(for source: SourceEntry) -> [SemanticCandidate] {
        source.senses.map { SemanticCandidate(sourceSenseID: $0.sourceSenseID, text: $0.semanticDocument(headword: source.headword)) }
    }

    func selectDeck(_ id: String) {
        guard let index = library.decks.firstIndex(where: { $0.id == id }) else { return }
        selectedDeckID = id
        selectedUnitID = library.decks[index].units.first?.id
        selectedEntryID = library.decks[index].entries.last?.id
        issue = nil
    }

    func selectEntry(_ id: String) {
        selectedEntryID = id
        mode = .review
    }

    func load() {
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                library = try JSONDecoder().decode(V3Library.self, from: Data(contentsOf: file))
            }
            selectedDeckID = library.lastDeckID.flatMap { id in library.decks.contains(where: { $0.id == id }) ? id : nil } ?? library.decks.first?.id
            selectedUnitID = library.lastUnitID.flatMap { id in library.decks.first(where: { $0.id == selectedDeckID })?.units.contains(where: { $0.id == id }) ?? false ? id : nil } ?? library.decks.first?.units.first?.id
            // Test hook: pre-select deck by name via env var
            if let testDeck = ProcessInfo.processInfo.environment["WWB_TEST_DECK_NAME"] {
                if let deck = library.decks.first(where: { $0.ankiDeckName == testDeck }) {
                    selectedDeckID = deck.id
                    selectedUnitID = deck.units.first?.id
                }
            }
            if isDictionaryReady {
                status = library.decks.isEmpty ? "本地词库已连接。新建一本词书后即可开始录入。" : "准备就绪：输入单词并按 Return，或继续审核本轮词汇。"
            }
        } catch { status = "v3 词库读取失败：\(error.localizedDescription)。旧版数据未被改动。" }
    }

    /// Makes a bundled release usable without a file picker, then performs a
    /// lightweight metadata-only update check. It never downloads a 200MB+
    /// dictionary package without an explicit user action.
    func bootstrapDictionary() {
        Task {
            do {
                if let installed = try await dictionaryLifecycle.installBundledDatabaseIfNeeded() {
                    if library.databasePath != installed.path {
                        library.databasePath = installed.path
                        save()
                        status = "已启用应用内置 Open Dictionary。"
                    }
                }
            } catch {
                dictionaryNotice = "内置词库安装失败：\(error.localizedDescription)"
            }
            await checkDictionaryUpdate()
        }
    }

    func checkDictionaryUpdate() async {
        guard !dictionaryChecking else { return }
        dictionaryChecking = true
        defer { dictionaryChecking = false }
        do {
            let release = try await dictionaryLifecycle.checkLatestRelease()
            if await dictionaryLifecycle.isUpdateAvailable(release) {
                availableDictionaryRelease = release
                if let asset = release.sqliteAsset {
                    dictionaryNotice = "可更新至 \(release.tagName)（\(ByteCountFormatter.string(fromByteCount: asset.size, countStyle: .file))）"
                }
            } else {
                availableDictionaryRelease = nil
                dictionaryNotice = "Open Dictionary 已是最新版本（\(release.tagName)）"
            }
        } catch {
            dictionaryNotice = "无法检查更新；当前本地词库仍可离线使用。"
        }
    }

    func installDictionaryUpdate() {
        guard let release = availableDictionaryRelease, !busy else { return }
        busy = true
        dictionaryUpdateProgress = 0
        status = "正在下载并校验 Open Dictionary；完成前不会替换现有词库。"
        Task {
            do {
                let url = try await dictionaryLifecycle.install(release)
                library.databasePath = url.path
                availableDictionaryRelease = nil
                dictionaryUpdateProgress = nil
                dictionaryNotice = "已更新至 \(release.tagName)"
                status = "Open Dictionary 已安全更新至 \(release.tagName)。"
                save()
            } catch {
                dictionaryUpdateProgress = nil
                status = "词库更新未完成：\(error.localizedDescription)"
            }
            busy = false
        }
    }

    func save() {
        library.lastDeckID = selectedDeckID; library.lastUnitID = selectedUnitID
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(library).write(to: file, options: .atomic)
        } catch { status = "保存失败：\(error.localizedDescription)" }
    }

    func chooseDatabase() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        // `.database` is a broad macOS type and does not consistently include
        // SQLite files in NSOpenPanel. Use the filename extension supplied by
        // the Open Dictionary release so the real distribution.sqlite is selectable.
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite")!]
        panel.message = "选择从 Open Dictionary Release 解压得到的 distribution.sqlite"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try OpenDictionarySource(databaseURL: url)
            library.databasePath = url.path; save()
            status = "已选择本地 Open Dictionary：\(url.lastPathComponent)。"
        } catch { status = error.localizedDescription }
    }

    func openDictionaryRelease() {
        NSWorkspace.shared.open(URL(string: "https://github.com/ahpxex/open-dictionary/releases/latest")!)
        status = "浏览器已打开 Open Dictionary Release。下载 distribution.sqlite.gz，解压后回到这里选择 distribution.sqlite。"
    }

    func source() throws -> OpenDictionarySource {
        guard let path = library.databasePath, !path.isEmpty else { throw V3Error(message: "请先选择 Open Dictionary 的 distribution.sqlite。") }
        return try OpenDictionarySource(databaseURL: URL(fileURLWithPath: path))
    }

    func addDeck() {
        let name = newDeckName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let item = DeckBook(ankiDeckName: name)
        library.decks.append(item); selectedDeckID = item.id; selectedUnitID = nil; selectedEntryID = nil; newDeckName = ""; save()
    }

    func addUnit() {
        guard let d = deckIndex else { status = "请先新建 Deck。"; return }
        let name = newUnitName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { status = "请输入 Unit 名称。"; return }
        let topics = newUnitTopics.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let item = UnitProfile(name: name, subject: newUnitSubject.trimmingCharacters(in: .whitespacesAndNewlines), topics: topics, context: newUnitContext.trimmingCharacters(in: .whitespacesAndNewlines))
        library.decks[d].units.append(item); selectedUnitID = item.id
        newUnitName = ""; newUnitSubject = ""; newUnitTopics = ""; newUnitContext = ""; save()
    }

    func beginEditingUnit() {
        guard let unit else { return }
        newUnitName = unit.name
        newUnitSubject = unit.subject
        newUnitTopics = unit.topics.joined(separator: ", ")
        newUnitContext = unit.context
    }

    func saveUnitEdits() {
        guard let d = deckIndex, let u = unitIndex else { return }
        let name = newUnitName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { status = "Unit 名称不能为空。"; return }
        library.decks[d].units[u].name = name
        library.decks[d].units[u].subject = newUnitSubject.trimmingCharacters(in: .whitespacesAndNewlines)
        library.decks[d].units[u].topics = newUnitTopics.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        library.decks[d].units[u].context = newUnitContext.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
        status = "已保存 Unit 主题；点击“重新推荐本 Unit”即可更新已有词条。"
    }

    func lookup(_ requested: String? = nil) {
        let word = (requested ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let d = deckIndex, let unit else { status = "请先选择 Deck 和 Unit。"; return }
        guard !word.isEmpty else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let result = try await source().lookup(word: word)
                var item = SenseResolver.resolve(result, for: unit)
                // Ranking can never block capture: the coordinator bounds each
                // engine and falls through to the transparent label rule.
                let coordinator = SemanticRankingCoordinator(engines: semanticEngines())
                let outcome = await coordinator.rank(query: TopicNormalizer.queryText(for: unit),
                                                     candidates: semanticCandidates(for: result),
                                                     unitHasContext: unit.hasUsableContext)
                RecommendationPolicy.apply(outcome, to: &item, unitTerms: TopicNormalizer.terms(for: unit))
                semanticNotice = outcome.notices.joined(separator: " ")
                item.unitID = unit.id
                // 同一 Unit 内重复查询同一单词：替换旧词条而不是追加，避免
                // 词块区出现重复词条；保留已导入标记。
                if let existing = library.decks[d].entries.firstIndex(where: {
                    $0.unitID == unit.id && $0.word.caseInsensitiveCompare(word) == .orderedSame
                }) {
                    item.imported = library.decks[d].entries[existing].imported
                    library.decks[d].entries[existing] = item
                } else {
                    library.decks[d].entries.append(item)
                }
                selectedEntryID = item.id; mode = .review
                input = ""; issue = nil
                let selectedCount = item.groups.flatMap({$0.senses}).filter({$0.selected}).count
                status = selectedCount > 0
                    ? "已取得 \(item.groups.count) 个词性组；\(selectedCount) 个高相关义项已默认勾选。请审核后导入 Anki。"
                    : "已取得 \(item.groups.count) 个词性组。未发现高相关义项——请手动勾选合适的义项后导入 Anki。"
                save()
            } catch OpenDictionaryAdapterError.notFound {
                let candidates = spellingCandidates(word: word)
                issue = V3LookupIssue(input: word, candidates: candidates); status = "Open Dictionary 未收录该词。可选择拼写候选或暂不录入。"
            } catch { status = error.localizedDescription }
        }
    }

    func checkSemanticModel() {
        guard !semanticChecking else { return }
        semanticChecking = true
        Task {
            defer { semanticChecking = false }
            do {
                let models = try await OllamaSemanticRecommender().installedModels()
                semanticNotice = models.contains(where: { $0.name == semanticModelName || $0.name.hasPrefix("\(semanticModelName):") }) ? "Ollama 已就绪：\(semanticModelName)" : "Ollama 已连接，但未下载 \(semanticModelName)"
            } catch { semanticNotice = "未连接 Ollama：请启动 Ollama 后重试" }
        }
    }

    func installSemanticModel() {
        guard !semanticInstalling else { return }
        semanticInstalling = true
        semanticNotice = "正在由 Ollama 下载 \(semanticModelName)…"
        Task {
            defer { semanticInstalling = false }
            do {
                try await OllamaSemanticRecommender().install(model: semanticModelName)
                semanticNotice = "已下载并验证：\(semanticModelName)"
            } catch { semanticNotice = error.localizedDescription }
        }
    }

    /// Detection only. The app never downloads the reranker runtime or weights on
    /// its own; `tools/local-reranker/download-model.sh` is the explicit step.
    func checkReranker() {
        guard !rerankerChecking else { return }
        rerankerChecking = true
        rerankerNotice = "正在检测本地重排服务…"
        Task {
            defer { rerankerChecking = false }
            let settings = semanticSettings
            let reranker = LocalSemanticReranker(baseURL: URL(string: settings.rerankerBaseURL) ?? LocalSemanticReranker.defaultBaseURL,
                                                 modelName: settings.rerankerModel)
            let health = await reranker.health()
            rerankerHealthDetail = health.summary
            rerankerNotice = health.isAvailable
                ? health.summary
                : "\(health.summary) 可在项目目录运行 zsh tools/local-reranker/start.sh 启动；未启动时自动回退 Ollama 或词典标签规则。"
        }
    }

    var enginePreferenceLabel: String {
        switch preferredSemanticEngine {
        case "localReranker": return "仅本地重排（失败回退 Ollama）"
        case "ollamaEmbedding": return "仅 Ollama bge-m3（失败回退本地重排）"
        case "rule": return "只用词典标签规则"
        default: return autoEngineLabel
        }
    }

    /// Label for the auto/automatic option in the engine picker, regardless of current selection.
    var autoEngineLabel: String {
        SemanticEnginePromotion.isPromoted
            ? "自动：本地重排 → Ollama → 词典标签（留出集已证明净改进）"
            : "自动：Ollama bge-m3 → 本地重排 → 词典标签（本地重排仍为候选）"
    }

    var engineChainSummary: String {
        switch preferredSemanticEngine {
        case "rule": return "词典标签规则"
        case "ollamaEmbedding": return "Ollama bge-m3 → 本地重排 → 词典标签规则"
        case "localReranker": return "本地重排 bge-reranker-v2-m3 → Ollama bge-m3 → 词典标签规则"
        default: return SemanticEnginePromotion.isPromoted
            ? "本地重排 bge-reranker-v2-m3 → Ollama bge-m3 → 词典标签规则"
            : "Ollama bge-m3 → 本地重排 bge-reranker-v2-m3 → 词典标签规则"
        }
    }

    func reRecommendCurrentUnit() {
        guard let d = deckIndex, let currentUnit = unit else { return }
        let targets = library.decks[d].entries.indices.filter { library.decks[d].entries[$0].unitID == currentUnit.id }
        guard !targets.isEmpty else { status = "当前 Unit 还没有可重新推荐的词。"; return }
        busy = true
        Task {
            defer { busy = false }
            let coordinator = SemanticRankingCoordinator(engines: semanticEngines())
            let unitTerms = TopicNormalizer.terms(for: currentUnit)
            let query = TopicNormalizer.queryText(for: currentUnit)
            var engineCounts: [String: Int] = [:]
            for index in targets {
                var entry = library.decks[d].entries[index]
                // Existing entries retain only the structured fields, so rebuild the
                // transparent rule baseline first, then rerank the same saved evidence.
                var sourceSenses: [SourceSense] = []
                for group in entry.groups {
                    for sense in group.senses {
                        sourceSenses.append(SourceSense(sourceSenseID: sense.sourceSenseID ?? sense.id,
                                                        partOfSpeech: group.label,
                                                        gloss: sense.gloss,
                                                        examples: sense.example.map { [$0] } ?? [],
                                                        explicitPhrases: sense.collocations,
                                                        domainHints: sense.recommendation?.domainHints ?? [],
                                                        sourceRank: sense.recommendation?.sourceRank ?? 100))
                    }
                }
                for groupIndex in entry.groups.indices {
                    for senseIndex in entry.groups[groupIndex].senses.indices {
                        let sense = entry.groups[groupIndex].senses[senseIndex]
                        let sourceSense = SourceSense(sourceSenseID: sense.sourceSenseID ?? sense.id, partOfSpeech: entry.groups[groupIndex].label, gloss: sense.gloss, examples: sense.example.map { [$0] } ?? [], explicitPhrases: sense.collocations, domainHints: sense.recommendation?.domainHints ?? [], sourceRank: sense.recommendation?.sourceRank ?? 100)
                        let rule = RecommendationPolicy.ruleRecommendation(sourceSense, unitTerms: unitTerms)
                        entry.groups[groupIndex].senses[senseIndex].recommendation = rule
                        entry.groups[groupIndex].senses[senseIndex].selected = rule.suggested
                    }
                }
                let entryCandidates = sourceSenses.map { SemanticCandidate(sourceSenseID: $0.sourceSenseID, text: $0.semanticDocument(headword: entry.word)) }
                let outcome = await coordinator.rank(query: query, candidates: entryCandidates, unitHasContext: currentUnit.hasUsableContext)
                RecommendationPolicy.apply(outcome, to: &entry, unitTerms: unitTerms)
                engineCounts[outcome.engine.rawValue, default: 0] += 1
                library.decks[d].entries[index] = entry
            }
            let summary = engineCounts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value) 词" }.joined(separator: "，")
            semanticNotice = "重新推荐完成：\(summary)。"
            status = "已按当前 Unit 重新推荐 \(targets.count) 个词；请复核自动勾选项。"
            save()
        }
    }

    /// Re-recommending recomputes default selections, so it must be an explicit,
    /// confirmed action — never something a plain open or refresh can trigger.
    func requestReRecommendation() {
        showsReRecommendConfirmation = true
    }

    func spellingCandidates(word: String) -> [String] {
        let range = NSRange(location: 0, length: (word as NSString).length)
        return Array((NSSpellChecker.shared.guesses(forWordRange: range, in: word, language: "en_US", inSpellDocumentWithTag: 0) ?? []).prefix(8))
    }

    func deleteEntry() {
        guard let d = deckIndex, let e = entryIndex else { return }
        let wasImported = library.decks[d].entries[e].imported
        let removed = library.decks[d].entries.remove(at: e)
        deletedEntry = DeletedEntry(deckID: library.decks[d].id, index: e, entry: removed)
        canUndoDelete = true
        selectedEntryID = library.decks[d].entries.last?.id; save()
        status = wasImported ? "已从工作台移除；为保护复习进度，Anki 内原卡未删除。" : "已删除未导入词条。"
        if library.decks[d].entries.isEmpty { mode = .capture }
    }

    func undoDelete() {
        guard let deletedEntry,
              let deckIndex = library.decks.firstIndex(where: { $0.id == deletedEntry.deckID }) else { return }
        let index = min(deletedEntry.index, library.decks[deckIndex].entries.count)
        library.decks[deckIndex].entries.insert(deletedEntry.entry, at: index)
        selectedDeckID = deletedEntry.deckID
        selectedEntryID = deletedEntry.entry.id
        self.deletedEntry = nil
        canUndoDelete = false
        status = "已恢复 (deletedEntry.entry.word)。"
        save()
    }

    func setSenseSelected(group: Int, sense: Int, value: Bool) {
        guard let d = deckIndex, let e = entryIndex else { return }
        library.decks[d].entries[e].groups[group].senses[sense].selected = value; save()
    }

    func setGloss(group: Int, sense: Int, value: String) {
        guard let d = deckIndex, let e = entryIndex else { return }
        library.decks[d].entries[e].groups[group].senses[sense].gloss = value; save()
    }

    func removePhrase(group: Int, sense: Int, phrase: Int) {
        guard let d = deckIndex, let e = entryIndex else { return }
        library.decks[d].entries[e].groups[group].senses[sense].collocations.remove(at: phrase); save()
    }

    func connectAnki() async throws {
        if (try? await anki("version")) != nil { return }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Anki.app"), configuration: .init()) { _, _ in }
        for _ in 0..<12 { try? await Task.sleep(for: .seconds(1)); if (try? await anki("version")) != nil { return } }
        throw V3Error(message: "无法连接 AnkiConnect。请启动 Anki 并启用 AnkiConnect 后重试。")
    }

    func anki(_ action: String, _ params: [String: Any] = [:]) async throws -> Any {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8765")!)
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["action": action, "version": 6, "params": params])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw V3Error(message: "AnkiConnect 返回无效响应。") }
        if let error = object["error"] as? String, !error.isEmpty { throw V3Error(message: error) }
        return object["result"] ?? NSNull()
    }

    func importAnki() async {
        guard let d = deckIndex, !selectedEntries.isEmpty else { status = "没有可导入的已选义项。"; return }
        busy = true; defer { busy = false }
        let deckName = library.decks[d].ankiDeckName.replacingOccurrences(of: "::", with: "：")
        do {
            try await connectAnki(); _ = try await anki("createDeck", ["deck": deckName])
            let models = try await anki("modelNames") as? [String] ?? []
            if !models.contains("WordWorkbench v3") {
                _ = try await anki("createModel", ["modelName": "WordWorkbench v3", "inOrderFields": ["ID", "Word", "Definition", "Attribution"], "css": ".card{font-family:-apple-system,Arial;font-size:22px;text-align:left;line-height:1.6;padding:24px}.word{font-size:34px;font-weight:bold}.pos{font-weight:700;margin-top:12px}.label{color:#667085;font-size:14px;margin-top:8px}.example{margin:8px 0}.example span{color:#667085}.source{font-size:12px;opacity:.6;margin-top:24px}", "cardTemplates": [["Name": "英文 → 中文", "Front": "<div class='word'>{{Word}}</div>", "Back": "{{FrontSide}}<hr id=answer>{{Definition}}<div class='source'>{{Attribution}}</div>"]]])
            }
            let queue = selectedEntries
            for (number, pair) in queue.enumerated() {
                let (_, item) = pair
                let unitName = library.decks[d].units.first(where: { $0.id == item.unitID })?.name ?? "unassigned"
                let fields = ["ID": item.id, "Word": CardRenderer.escapedHTML(item.word), "Definition": CardRenderer.backHTML(for: item), "Attribution": "Open Dictionary / Wiktionary contributors · CC BY-SA 4.0"]
                let ids = try await anki("findNotes", ["query": "\"note:WordWorkbench v3\" ID:\(item.id)"]) as? [Int64] ?? []
                if ids.count > 1 { throw V3Error(message: "\(item.word) 匹配多条笔记，已停止。") }
                if let id = ids.first {
                    _ = try await anki("updateNoteFields", ["note": ["id": id, "fields": fields]])
                    let cards = try await anki("findCards", ["query": "nid:\(id)"]) as? [Int64] ?? []
                    if !cards.isEmpty { _ = try await anki("changeDeck", ["deck": deckName, "cards": cards]) }
                } else {
                    _ = try await anki("addNote", ["note": ["deckName": deckName, "modelName": "WordWorkbench v3", "fields": fields, "options": ["allowDuplicate": false], "tags": ["wordworkbench", "unit::\(unitName)", "source::open-dictionary"]]])
                }
                // Use id-based lookup to survive array mutations during await
                if let idx = library.decks[d].entries.firstIndex(where: { $0.id == item.id }) {
                    library.decks[d].entries[idx].imported = true
                }
                status = "已写入 \(number + 1)/\(queue.count)：\(item.word)"; save()
            }
            status = "完成：\(queue.count) 条写入 Anki Deck「\(deckName)」。Anki 负责跨 Unit 的统一复习。"
        } catch { status = "导入中止：\(error.localizedDescription)。已成功条目可安全重试。"; save() }
    }
}

struct V3ContentView: View {
    @StateObject private var model = V3Workbench()
    @State private var showingSettings = false
    @State private var showingNewDeck = false
    @State private var showingNewUnit = false
    @State private var showingEditUnit = false

    var body: some View {
        NavigationSplitView {
            AppSidebar(model: model, showingNewDeck: $showingNewDeck, showingSettings: $showingSettings)
        } detail: {
            if model.deck == nil {
                WelcomeState(model: model, showingNewDeck: $showingNewDeck, showingSettings: $showingSettings)
            } else if model.unit == nil {
                UnitEmptyState(model: model, showingNewUnit: $showingNewUnit)
            } else {
                WorkspaceView(model: model, showingNewUnit: $showingNewUnit, showingEditUnit: $showingEditUnit)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 980, minHeight: 660)
        .toolbar {
            ToolbarItem(placement: .navigation) { Label("每日录词工作台", systemImage: "rectangle.stack.fill").font(.headline) }
            ToolbarItem(placement: .primaryAction) {
                Button { showingNewDeck = true } label: { Label("新建词书", systemImage: "plus") }
                    .keyboardShortcut("n", modifiers: [.command])
                    .accessibilityLabel("新建词书")
            }
            ToolbarItem(placement: .automatic) {
                Button { showingSettings = true } label: { Label("设置", systemImage: "gearshape") }
                    .accessibilityLabel("打开设置")
            }
        }
        .sheet(isPresented: $showingSettings) { SetupSheet(model: model) }
        .sheet(isPresented: $showingNewDeck) { NewDeckSheet(model: model, isPresented: $showingNewDeck) }
        .sheet(isPresented: $showingNewUnit) { NewUnitSheet(model: model, isPresented: $showingNewUnit) }
        .sheet(isPresented: $showingEditUnit) { EditUnitSheet(model: model, isPresented: $showingEditUnit) }
    }
}

struct AppSidebar: View {
    @ObservedObject var model: V3Workbench
    @Binding var showingNewDeck: Bool
    @Binding var showingSettings: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("词书").font(.headline).padding(.top, 8)
            if model.library.decks.isEmpty {
                Text("还没有词书").foregroundStyle(.secondary).font(.callout)
            } else {
                List {
                    ForEach(model.library.decks) { deck in
                        Button { model.selectDeck(deck.id) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: deck.id == model.selectedDeckID ? "book.closed.fill" : "book.closed")
                                    .foregroundStyle(deck.id == model.selectedDeckID ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(deck.ankiDeckName).lineLimit(1)
                                    Text("\(deck.entries.count) 词 · \(deck.units.count) Units").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).padding(.vertical, 4)
                    }
                }.listStyle(.sidebar)
            }
            Button { showingNewDeck = true } label: { Label("新建词书", systemImage: "plus") }.buttonStyle(.bordered)
            Spacer()
            Divider()
            Button { showingSettings = true } label: {
                HStack { Image(systemName: model.isDictionaryReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(model.isDictionaryReady ? .green : .orange); Text(model.isDictionaryReady ? "本地词库已连接" : "需要连接词库") ; Spacer() }
            }.buttonStyle(.plain).font(.callout)
        }.padding(.horizontal, 14).padding(.bottom, 14).frame(minWidth: 240)
    }
}

struct WelcomeState: View {
    @ObservedObject var model: V3Workbench
    @Binding var showingNewDeck: Bool
    @Binding var showingSettings: Bool
    var body: some View {
        ContentUnavailableView {
            Label("从今天的单词开始", systemImage: "rectangle.stack.badge.plus")
        } description: {
            Text(model.isDictionaryReady ? "新建一本词书，再按 Unit 录入当天的课程词。" : "先在设置中连接 Open Dictionary 本地词库，再新建第一本词书。")
        } actions: {
            if model.isDictionaryReady { Button("新建第一本词书") { showingNewDeck = true }.buttonStyle(.borderedProminent) }
            else { Button("连接本地词库") { showingSettings = true }.buttonStyle(.borderedProminent) }
        }
    }
}

struct UnitEmptyState: View {
    @ObservedObject var model: V3Workbench
    @Binding var showingNewUnit: Bool
    var body: some View {
        ContentUnavailableView {
            Label("为这本词书建立第一个 Unit", systemImage: "bookmark")
        } description: { Text("Unit 只帮助按课程语境推荐义项；导入 Anki 后仍会在同一个 Deck 中统一复习。") }
        actions: { Button("新建 Unit") { showingNewUnit = true }.buttonStyle(.borderedProminent) }
    }
}

struct WorkspaceView: View {
    @ObservedObject var model: V3Workbench
    @Binding var showingNewUnit: Bool
    @Binding var showingEditUnit: Bool
    var body: some View {
        if let deck = model.deck, let unit = model.unit {
            VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(deck.ankiDeckName).font(.title2.bold())
                        HStack(spacing: 5) {
                            Text(unit.name).font(.callout.weight(.semibold))
                            if !unit.subject.isEmpty { Text("· \(unit.subject)").foregroundStyle(.secondary) }
                            if !unit.topics.isEmpty { Text("· \(unit.topics.joined(separator: ", "))").foregroundStyle(.secondary).lineLimit(1) }
                            if !unit.context.isEmpty { Text("· \(unit.context)").foregroundStyle(.secondary).lineLimit(1) }
                        }
                    }
                    Spacer()
                    Picker("Unit", selection: $model.selectedUnitID) {
                        ForEach(deck.units) { Text($0.name).tag(Optional($0.id)) }
                    }.labelsHidden().frame(width: 150)
                    Picker("工作模式", selection: $model.mode) {
                        ForEach(WorkspaceMode.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).frame(width: 150)
                    Button { model.beginEditingUnit(); showingEditUnit = true } label: { Label("编辑 Unit", systemImage: "pencil") }.buttonStyle(.bordered)
                    Button { showingNewUnit = true } label: { Label("Unit", systemImage: "plus") }.buttonStyle(.bordered)
                }
                HStack(spacing: 8) {
                    MetricPill(value: "\(model.pendingCount)", label: "待导入", tint: .orange)
                    MetricPill(value: "\(model.importedCount)", label: "已导入", tint: .green)
                    Spacer()
                    Button("重新推荐本 Unit") { model.requestReRecommendation() }.buttonStyle(.bordered).disabled(model.busy)
                    if model.busy { ProgressView().controlSize(.small); Text("正在处理").font(.caption).foregroundStyle(.secondary) }
                }
            }.padding(.horizontal, 24).padding(.vertical, 18)
            Divider()
            Group {
                switch model.mode {
                case .capture: CaptureWorkspace(model: model)
                case .review: ReviewWorkspace(model: model)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 10) {
                Image(systemName: model.status.hasPrefix("导入中止") ? "exclamationmark.triangle.fill" : "info.circle.fill").foregroundStyle(model.status.hasPrefix("导入中止") ? .orange : .secondary)
                Text(model.status).font(.callout).lineLimit(2).textSelection(.enabled)
                Spacer()
                if model.canUndoDelete { Button("撤销删除") { model.undoDelete() }.keyboardShortcut("z", modifiers: [.command]) }
                Button { Task { await model.importAnki() } } label: { Label("导入 Anki", systemImage: "arrow.up.doc") }.buttonStyle(.borderedProminent).disabled(model.busy || model.pendingCount == 0)
            }.padding(.horizontal, 24).padding(.vertical, 12)
            }
            .confirmationDialog("重新推荐本 Unit？", isPresented: $model.showsReRecommendConfirmation, titleVisibility: .visible) {
                Button("重算默认勾选") { model.reRecommendCurrentUnit() }
                Button("取消", role: .cancel) { }
            } message: {
                Text("这会按当前 Unit 语境重新计算本 Unit 内所有词条的默认勾选，覆盖你手动修改过的勾选。已导入 Anki 的卡片不会被改写，Anki 复习进度不受影响。")
            }
            // Escape 在审核工作区任意位置（左侧列表、中间义项、右侧预览）都返回录入模式。
            // onExitCommand 只在 SwiftUI 焦点链内生效；keyboardShortcut(.cancelAction)
            // 是窗口级键等效，无焦点时同样生效——两者叠加保证任意情况可用。
            .onExitCommand { if model.mode == .review { model.mode = .capture } }
            // 窗口级键等效兜底：无文本焦点时（点列表/背景后）Escape 也能返回录入。
            // 经真实事件分发验证（2026-09-18）；与 onExitCommand 双保险。
            .background(
                Button("") { if model.mode == .review { model.mode = .capture } }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0).frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            )
        } else {
            EmptyView()
        }
    }
}

struct MetricPill: View {
    let value: String; let label: String; let tint: Color
    var body: some View { HStack(spacing: 5) { Text(value).font(.caption.bold()); Text(label).font(.caption) }.padding(.horizontal, 9).padding(.vertical, 5).background(tint.opacity(0.12)).foregroundStyle(tint).clipShape(Capsule()) }
}

struct CaptureWorkspace: View {
    @ObservedObject var model: V3Workbench
    @FocusState private var fieldFocused: Bool
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("录入今天的单词").font(.title3.bold())
                    Text("输入英文词后按 Return。程序会用本地词典和 Ollama 语义相关性推荐义项；你再统一审核。") .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        TextField("例如 membrane", text: $model.input).textFieldStyle(.roundedBorder).font(.title3).focused($fieldFocused).onSubmit { model.lookup() }.disabled(model.busy)
                        Button("加入") { model.lookup() }.buttonStyle(.borderedProminent).disabled(model.busy || model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.frame(maxWidth: 640)
                }.padding(20).background(Color.accentColor.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 14))
                if let issue = model.issue { SpellingRecovery(model: model, issue: issue) }
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("本轮收集").font(.headline); Text("\(model.deck?.entries.count ?? 0) 个词").foregroundStyle(.secondary); Spacer(); if !(model.deck?.entries.isEmpty ?? true) { Button("开始审核") { model.mode = .review }.buttonStyle(.bordered) } }
                    if let entries = model.deck?.entries, !entries.isEmpty {
                        FlowLayout(spacing: 8) { ForEach(entries) { item in Button { model.selectEntry(item.id) } label: { HStack(spacing: 5) { Image(systemName: item.imported ? "checkmark.circle.fill" : "circle").foregroundStyle(item.imported ? .green : .secondary); Text(item.word) }.padding(.horizontal, 10).padding(.vertical, 7).background(Color.secondary.opacity(0.08)).clipShape(Capsule()) }.buttonStyle(.plain) } }
                    } else { Text("还没有词。先从课程词书中输入今天准备背的词。") .foregroundStyle(.secondary).padding(.vertical, 18) }
                }
            }.padding(24)
        }.onAppear { fieldFocused = true }
    }
}

struct SpellingRecovery: View {
    @ObservedObject var model: V3Workbench
    let issue: V3LookupIssue
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("本地词库未收录“\(issue.input)”", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("红色字符与原输入不一致。选择建议后仍会重新查询本地词库。") .font(.caption).foregroundStyle(.secondary)
            HStack { TextField("修改拼写后重新查询", text: $model.input).textFieldStyle(.roundedBorder); Button("重新查询") { model.lookup() } }
            ForEach(issue.candidates, id: \.self) { candidate in Button { model.lookup(candidate) } label: { HStack { Text("建议") .foregroundStyle(.secondary); DifferenceMarkedWord(input: issue.input, candidate: candidate); Spacer(); Image(systemName: "arrow.right") } }.buttonStyle(.plain).padding(.vertical, 3).accessibilityLabel("建议拼写：\(candidate)") }
        }.padding(16).background(Color.orange.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct FlowLayout<Content: View>: View {
    let spacing: CGFloat; @ViewBuilder let content: Content
    init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) { self.spacing = spacing; self.content = content() }
    var body: some View { LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: spacing)], alignment: .leading, spacing: spacing) { content } }
}

struct ReviewWorkspace: View {
    @ObservedObject var model: V3Workbench
    var body: some View {
        HSplitView {
            List {
                Section("本轮单词") {
                    ForEach(model.deck?.entries ?? []) { item in
                        ReviewWordRow(item: item, selected: item.id == model.selectedEntryID) { model.selectedEntryID = item.id }
                    }
                }
            }.frame(minWidth: 190, idealWidth: 220)
            HSplitView {
                V3EntryReview(model: model).frame(minWidth: 360)
                AnkiCardPreview(entry: model.entry).frame(minWidth: 260, idealWidth: 310)
            }
        }
    }
}

struct ReviewWordRow: View {
    let item: StructuredEntry
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: item.hasSelectedSense ? "checkmark.square.fill" : "square")
                    .foregroundStyle(item.hasSelectedSense ? Color.accentColor : Color.secondary)
                Text(item.word)
                Spacer()
                if item.imported { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).listRowBackground(selected ? Color.accentColor.opacity(0.10) : Color.clear)
        .accessibilityLabel(item.word)
        .accessibilityAddTraits(item.hasSelectedSense ? .isSelected : [])
    }
}

struct AnkiCardPreview: View {
    let entry: StructuredEntry?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Label("Anki 卡片预览", systemImage: "rectangle.on.rectangle"); Spacer() }.font(.headline)
            if let entry {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(entry.word).font(.system(size: 30, weight: .bold))
                        Divider()
                        ForEach(entry.groups) { group in
                            let selected = group.senses.filter(\.selected)
                            if !selected.isEmpty {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(group.label).font(.headline)
                                    Text("中文义项").font(.caption).foregroundStyle(.secondary)
                                    ForEach(selected) { sense in
                                        Text("• \(sense.gloss)").textSelection(.enabled)
                                        if let example = sense.example { VStack(alignment: .leading, spacing: 2) { Text(example.english).font(.callout); Text(example.chinese).font(.callout).foregroundStyle(.secondary) }.padding(.leading, 8) }
                                    }
                                }
                                Divider()
                            }
                        }
                        Text("Open Dictionary / Wiktionary contributors · CC BY-SA 4.0").font(.caption2).foregroundStyle(.tertiary)
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 12))
                }
            } else { ContentUnavailableView("选择一个词条", systemImage: "rectangle.on.rectangle", description: Text("预览会同步显示最终将写入 Anki 的内容。")) }
        }.padding(16).background(Color.secondary.opacity(0.06))
    }
}

struct SetupSheet: View {
    @ObservedObject var model: V3Workbench
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("设置").font(.title2.bold()); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
            GroupBox("本地词库") {
                VStack(alignment: .leading, spacing: 10) {
                    Label(model.isDictionaryReady ? "Open Dictionary 已连接" : "尚未选择 SQLite 词库", systemImage: model.isDictionaryReady ? "checkmark.circle.fill" : "exclamationmark.circle") .foregroundStyle(model.isDictionaryReady ? .green : .orange)
                    Text(model.dictionaryVersionText).font(.callout).foregroundStyle(.secondary)
                    if let release = model.availableDictionaryRelease, let asset = release.sqliteAsset {
                        Text("更新会下载 \(ByteCountFormatter.string(fromByteCount: asset.size, countStyle: .file))，校验 SHA-256 后替换本机词库。现有词库在校验失败时不会被覆盖。") .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("下载并安装 \(release.tagName)") { model.installDictionaryUpdate() }.buttonStyle(.borderedProminent).disabled(model.busy)
                            Button("查看 Release") { NSWorkspace.shared.open(release.htmlURL) }
                        }
                    } else {
                        HStack { Button("检查更新") { Task { await model.checkDictionaryUpdate() } }.disabled(model.dictionaryChecking); if model.dictionaryChecking { ProgressView().controlSize(.small) } }
                    }
                    if model.dictionaryUpdateProgress != nil {
                        ProgressView("正在下载、校验并验证词库…").font(.caption)
                    }
                    Text("词库只在本机读取。Open Dictionary 是 Wiktionary 衍生数据，适用 CC BY-SA 4.0；本应用代码适用 MIT。") .font(.caption).foregroundStyle(.secondary)
                    HStack { Button("选择已有 SQLite") { model.chooseDatabase() }; Button("打开官方 Release") { model.openDictionaryRelease() } }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
            GroupBox("义项排序引擎") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("主引擎", selection: Binding(get: { model.preferredSemanticEngine }, set: { model.preferredSemanticEngine = $0 })) {
                        Text(model.autoEngineLabel).tag("auto")
                        Text("仅本地重排（失败回退 Ollama）").tag("localReranker")
                        Text("仅 Ollama bge-m3（失败回退本地重排）").tag("ollamaEmbedding")
                        Text("只用词典标签规则").tag("rule")
                    }
                    Text("当前顺序：\(model.engineChainSummary)").font(.caption).foregroundStyle(.secondary)
                    Text("引擎只返回相关性分数和是否默认勾选的建议；不会生成、翻译、改写、合并或删除词典义项。任何失败都会自动回退，查词不中断。").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
            GroupBox("主引擎：本地重排 bge-reranker-v2-m3（可选）") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("模型由本机 llama.cpp 运行时托管，只监听 \(model.rerankerBaseURL)，不记录词条、义项或 Unit 内容。模型权重约 418 MiB（Q4_K_M，Apache-2.0）；运行时约 27 MB（MIT）。").font(.caption).foregroundStyle(.secondary)
                    TextField("本地重排服务地址", text: Binding(get: { model.rerankerBaseURL }, set: { model.rerankerBaseURL = $0 })).textFieldStyle(.roundedBorder)
                    Text(model.rerankerNotice).font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("检测本地重排服务") { model.checkReranker() }.disabled(model.rerankerChecking)
                        if model.rerankerChecking { ProgressView().controlSize(.small) }
                    }
                    Text("安装需手动执行（不在 App 启动时静默下载）：\n  zsh tools/local-reranker/install-runtime.sh\n  zsh tools/local-reranker/download-model.sh\n启动 / 停止 / 移除：\n  zsh tools/local-reranker/start.sh · stop.sh · uninstall.sh")
                        .font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
            GroupBox("回退 1：Ollama bge-m3（可选）") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("只把 Unit 主题与候选义项发送到本机 127.0.0.1；模型只返回相关性分数，不生成释义、例句或搭配。").font(.caption).foregroundStyle(.secondary)
                    TextField("Ollama 模型名称", text: Binding(get: { model.semanticModelName }, set: { model.semanticModelName = $0 })).textFieldStyle(.roundedBorder)
                    Text(model.semanticNotice).font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("检测 Ollama") { model.checkSemanticModel() }.disabled(model.semanticChecking || model.semanticInstalling)
                        Button(model.semanticInstalling ? "正在下载…" : "下载推荐模型（约 1.2GB）") { model.installSemanticModel() }
                            .buttonStyle(.borderedProminent).disabled(model.semanticInstalling)
                        if model.semanticChecking || model.semanticInstalling { ProgressView().controlSize(.small) }
                    }
                    Text("默认模型 bge-m3；也可填入已由 Ollama 管理的其他多语言 embedding 模型。不可用时会继续回退到词典标签规则。").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
            GroupBox("Anki") { VStack(alignment: .leading, spacing: 6) { Text("导入时将自动检测 AnkiConnect。AnkiWeb 和 AnkiDroid 同步继续由 Anki 本身负责。") .font(.callout).foregroundStyle(.secondary) } .frame(maxWidth: .infinity, alignment: .leading).padding(4) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(24).frame(width: 620, height: 700)
    }
}

struct NewDeckSheet: View {
    @ObservedObject var model: V3Workbench
    @Binding var isPresented: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建词书").font(.title2.bold())
            Text("一本文词书对应一个 Anki Deck；不同词书不会混合复习进度。") .foregroundStyle(.secondary)
            TextField("例如 Biology Vocabulary", text: $model.newDeckName).textFieldStyle(.roundedBorder).onSubmit { create() }
            HStack { Spacer(); Button("取消") { isPresented = false }; Button("新建") { create() }.buttonStyle(.borderedProminent).disabled(model.newDeckName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 430)
    }
    private func create() { model.addDeck(); isPresented = false }
}

struct NewUnitSheet: View {
    @ObservedObject var model: V3Workbench
    @Binding var isPresented: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("新建 Unit").font(.title2.bold())
            Text("用于按课程语境推荐义项；不会创建 Anki 子 Deck。中文输入也可以，Ollama 会做跨语言相关性匹配。") .foregroundStyle(.secondary)
            TextField("Unit 名称，例如 Chapter 3", text: $model.newUnitName).textFieldStyle(.roundedBorder)
            TextField("学科，例如 生物 / biology", text: $model.newUnitSubject).textFieldStyle(.roundedBorder)
            TextField("主题，逗号分隔，例如 细胞膜, 代谢", text: $model.newUnitTopics).textFieldStyle(.roundedBorder)
            TextField("可选说明，例如 细胞膜的组成和跨膜运输", text: $model.newUnitContext).textFieldStyle(.roundedBorder).onSubmit { create() }
            HStack { Spacer(); Button("取消") { isPresented = false }; Button("新建") { create() }.buttonStyle(.borderedProminent).disabled(model.newUnitName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 520)
    }
    private func create() { model.addUnit(); isPresented = false }
}

struct EditUnitSheet: View {
    @ObservedObject var model: V3Workbench
    @Binding var isPresented: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("编辑 Unit 语境").font(.title2.bold())
            Text("保存后不会改变 Anki Deck 或既有复习进度。若要更新已有词条的建议，保存后点击“重新推荐本 Unit”。").foregroundStyle(.secondary)
            TextField("Unit 名称", text: $model.newUnitName).textFieldStyle(.roundedBorder)
            TextField("学科，例如 生物 / biology", text: $model.newUnitSubject).textFieldStyle(.roundedBorder)
            TextField("主题，逗号分隔，例如 细胞膜, 代谢", text: $model.newUnitTopics).textFieldStyle(.roundedBorder)
            TextField("可选说明，例如 细胞膜的组成和跨膜运输", text: $model.newUnitContext).textFieldStyle(.roundedBorder).onSubmit { save() }
            HStack { Spacer(); Button("取消") { isPresented = false }; Button("保存") { save() }.buttonStyle(.borderedProminent).disabled(model.newUnitName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 540)
    }
    private func save() { model.saveUnitEdits(); isPresented = false }
}

/// Small, deterministic visual aid for spelling recovery. It compares each
/// character against the same position; the editable input remains the source
/// of truth and every selected candidate is still verified by the dictionary.
struct DifferenceMarkedWord: View {
    let input: String
    let candidate: String

    var body: some View {
        let left = Array(input.lowercased())
        let right = Array(candidate)
        HStack(spacing: 0) {
            ForEach(right.indices, id: \.self) { index in
                let letter = right[index]
                let differs = index >= left.count || String(left[index]) != String(letter).lowercased()
                Text(String(letter)).foregroundStyle(differs ? Color.red : Color.primary)
            }
        }
    }
}

struct V3EntryReview: View {
    @ObservedObject var model: V3Workbench
    var body: some View {
        guard let item = model.entry else { return AnyView(Text("选择一个词条，审核“词性 → 中文义项 → 专属例句”。").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)) }
        return AnyView(ScrollView { VStack(alignment: .leading, spacing: 12) {
            HStack { Text(item.word).font(.title.bold()); Spacer(); Button("删除词条", role: .destructive, action: model.deleteEntry) }
            Text("推荐只帮助排序和默认勾选；词典内容没有被 AI 改写。请保留你需要的义项。\(model.semanticNotice)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            ForEach(item.groups.indices, id: \.self) { g in
                let group = item.groups[g]
                GroupBox(group.label) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(group.senses.indices, id: \.self) { s in
                            let sense = group.senses[s]
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Toggle(isOn: Binding(get: { sense.selected }, set: { model.setSenseSelected(group: g, sense: s, value: $0) })) { Text("显示此义项") }.toggleStyle(.checkbox)
                                    Spacer()
                                    if let recommendation = sense.recommendation {
                                        Text(recommendation.suggested ? "推荐" : "未推荐")
                                            .font(.caption.bold())
                                            .foregroundStyle(recommendation.suggested ? .green : .secondary)
                                            .padding(.horizontal, 7).padding(.vertical, 3)
                                            .background((recommendation.suggested ? Color.green : Color.secondary).opacity(0.12)).clipShape(Capsule())
                                    }
                                }
                                if let recommendation = sense.recommendation {
                                    Text("\(recommendation.reason) · 来源：\(semanticEngineLabel(recommendation.engine))").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                TextField("中文义项", text: Binding(get: { sense.gloss }, set: { model.setGloss(group: g, sense: s, value: $0) })).textFieldStyle(.roundedBorder).disabled(!sense.selected)
                                if let example = sense.example { VStack(alignment: .leading, spacing: 2) { Text("例句").font(.caption.bold()); Text(example.english); Text(example.chinese).foregroundStyle(.secondary) }.padding(8).background(Color.secondary.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 6)) }
                                if !sense.collocations.isEmpty { Text("搭配").font(.caption.bold()); ForEach(sense.collocations.indices, id: \.self) { p in HStack { Text("\(sense.collocations[p].english)：\(sense.collocations[p].chinese)"); Button("删除") { model.removePhrase(group: g, sense: s, phrase: p) }.buttonStyle(.borderless) } } }
                            }.padding(8).background(sense.selected ? Color.accentColor.opacity(0.07) : Color.secondary.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }.padding(12) })
    }
}

/// Human-readable provenance for a stored recommendation. Old libraries that
/// only knew `rule` / `ollamaEmbedding` still render correctly.
func semanticEngineLabel(_ engine: SenseRecommendation.Engine) -> String {
    switch engine {
    case .localReranker: return "本地重排 bge-reranker-v2-m3"
    case .ollamaEmbedding: return "Ollama bge-m3"
    case .rule: return "词典标签规则"
    }
}

#if !WORDWORKBENCH_NO_APP_ENTRY
@main
struct WordWorkbenchV3App: App { var body: some Scene { Window("每日录词工作台", id: "main") { V3ContentView() } } }
#endif
