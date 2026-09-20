import Foundation
import CoreGraphics
import AppKit

// UI driver: the "hands and eyes" for autonomous GUI verification.
//
// Subcommands:
//   windows                          — list on-screen windows (id, owner, bounds)
//   capture <windowID> <out.png>     — capture ONE window's rendered pixels only
//   key <virtualKeyCode>             — post a real key down+up (53 = Escape)
//   text <string>                    — type a unicode string via keyboard events
//   click <x> <y>                    — post a real left click at global coords
//   move <x> <y>                     — post a mouse move (for hover states)
//
// Window coordinates from CGWindowList are already in the global top-left
// display space, the same space CGEvent uses, so click math is direct.

@main struct UIDriver {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else { print("usage: ui-driver windows|capture|key|text|click|move"); exit(64) }
        let src = CGEventSource(stateID: .combinedSessionState)
        switch args[1] {
        case "windows":
            listWindows()
        case "capture":
            // CGWindowListCreateImage is unavailable on this macOS; delegate to
            // the system screencapture binary, which supports per-window shots.
            guard args.count == 4, let id = UInt32(args[2]) else { print("usage: capture <windowID> <out.png>"); exit(64) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-l\(id)", "-x", args[3]]
            try? p.run(); p.waitUntilExit()
            print(p.terminationStatus == 0 ? "ok -> \(args[3])" : "screencapture failed (\(p.terminationStatus))")
            exit(Int32(p.terminationStatus))
        case "key":
            guard args.count == 3, let code = CGKeyCode(args[2]) else { print("usage: key <virtualKeyCode>"); exit(64) }
            postKey(code: code, source: src)
        case "text":
            guard args.count == 3 else { print("usage: text <string>"); exit(64) }
            typeText(args[2], source: src)
        case "click":
            guard args.count == 4, let x = Double(args[2]), let y = Double(args[3]) else { print("usage: click <x> <y>"); exit(64) }
            postMouse(.leftMouseDown, x: x, y: y, source: src)
            usleep(60_000)
            postMouse(.leftMouseUp, x: x, y: y, source: src)
        case "move":
            guard args.count == 4, let x = Double(args[2]), let y = Double(args[3]) else { print("usage: move <x> <y>"); exit(64) }
            postMouse(.mouseMoved, x: x, y: y, source: src)
        default:
            print("unknown subcommand: \(args[1])"); exit(64)
        }
    }

    // MARK: - Eyes

    static func listWindows() {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            print("[]"); exit(1)
        }
        var out: [[String: Any]] = []
        for w in list {
            guard let id = w[kCGWindowNumber as String] as? Int,
                  let bounds = w[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
                  let wd = bounds["Width"] as? Double, let ht = bounds["Height"] as? Double else { continue }
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }  // normal windows only
            out.append(["id": id, "owner": owner, "x": x, "y": y, "w": wd, "h": ht])
        }
        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted]),
           let s = String(data: data, encoding: .utf8) { print(s) }
    }

    // MARK: - Hands

    static func postKey(code: CGKeyCode, source: CGEventSource?) {
        for type in [CGEventType.keyDown, .keyUp] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: type == .keyDown) else { continue }
            e.post(tap: .cghidEventTap)
            usleep(40_000)
        }
        print("key \(code) posted")
    }

    static func typeText(_ text: String, source: CGEventSource?) {
        // Max 20 chars per event (CGEvent unicode limit is 20 UTF-16 units).
        let units = Array(text.unicodeScalars.flatMap { $0.isASCII ? [$0] : $0.properties.numericType != nil ? [] : [] })
        _ = units  // scalar path unused; use utf16 chunks below
        let utf16 = Array(text.utf16)
        var index = 0
        while index < utf16.count {
            let chunk = Array(utf16[index..<min(index + 20, utf16.count)])
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            down?.post(tap: .cghidEventTap)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            up?.post(tap: .cghidEventTap)
            index += 20
            usleep(30_000)
        }
        print("typed \(text.count) chars")
    }

    static func postMouse(_ type: CGEventType, x: Double, y: Double, source: CGEventSource?) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left) else { return }
        e.post(tap: .cghidEventTap)
        if type != .mouseMoved { print("\(type == .leftMouseDown ? "click" : "release") at (\(x),\(y))") }
    }
}