// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT
import Foundation

let rexui = RexuiBackend()

func emit(_ obj: [String: Any]) {
    rexui.emit(obj)
}
func fail(_ s: String) {
    FileHandle.standardError.write(("endfield-missions: " + s + "\n").data(using: .utf8)!)
    emit(["error": s])
}

let given =
    CommandLine.arguments.count > 1 && !CommandLine.arguments[1].isEmpty
    ? CommandLine.arguments[1] : "~/Documents/Missions"
let folder = (given as NSString).expandingTildeInPath
let file = folder + "/missions.md"

struct Mission {
    var kind: String
    var text: String
    var urgent: Bool
    var done: Bool
    var doneOn: String
}
let kinds = ["daily", "weekly", "once"]
let titles = ["daily": "Daily", "weekly": "Weekly", "once": "Once"]

var cal = Calendar(identifier: .gregorian)
cal.locale = Locale(identifier: "en_US_POSIX")
let fmt: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()
func today() -> String { fmt.string(from: Date()) }
func monday() -> String {
    let d = Date()
    let wd = cal.component(.weekday, from: d)
    return fmt.string(from: cal.date(byAdding: .day, value: -((wd + 5) % 7), to: d)!)
}

var missions: [Mission] = []
var allDone: [String] = []
var lastText = ""

func parse(_ s: String) {
    var out: [Mission] = []
    var days: [String] = []
    var kind = "once"
    let item = try! NSRegularExpression(
        pattern: #"^\s*[-*] \[( |x|X)\] (!!! )?(.*?)(?: \(done (\d{4}-\d{2}-\d{2})\))?\s*$"#)
    for raw in s.components(separatedBy: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("## ") {
            let t = line.dropFirst(3).lowercased()
            kind = t.hasPrefix("daily") ? "daily" : t.hasPrefix("weekly") ? "weekly" : "once"
        } else if line.hasPrefix("<!-- all dailies done:") {
            days = line.replacingOccurrences(of: "<!-- all dailies done:", with: "").replacingOccurrences(
                of: "-->", with: ""
            )
            .split(separator: " ").map(String.init).filter { $0.count == 10 }
        } else if let m = item.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
            func g(_ i: Int) -> String { Range(m.range(at: i), in: raw).map { String(raw[$0]) } ?? "" }
            out.append(
                Mission(kind: kind, text: g(3), urgent: !g(2).isEmpty, done: g(1).lowercased() == "x", doneOn: g(4)))
        }
    }
    missions = out
    allDone = days
}

func render() -> String {
    var s = "# Missions\n"
    for k in kinds {
        s += "\n## \(titles[k]!)\n"
        for m in missions where m.kind == k {
            s +=
                "- [\(m.done ? "x" : " ")] \(m.urgent ? "!!! " : "")\(m.text)\(m.done && !m.doneOn.isEmpty ? " (done \(m.doneOn))" : "")\n"
        }
    }
    if !allDone.isEmpty { s += "\n<!-- all dailies done: \(allDone.suffix(60).joined(separator: " ")) -->\n" }
    return s
}

func doneNow(_ m: Mission) -> Bool {
    guard m.done else { return false }
    if m.kind == "daily" { return m.doneOn == today() }
    if m.kind == "weekly" { return m.doneOn >= monday() }
    return true
}

func streak() -> Int {
    let set = Set(allDone)
    var d = Date()
    var n = 0
    if !set.contains(fmt.string(from: d)) { d = cal.date(byAdding: .day, value: -1, to: d)! }
    while set.contains(fmt.string(from: d)) {
        n += 1
        d = cal.date(byAdding: .day, value: -1, to: d)!
    }
    return n
}

func ids() -> [String] {
    var count: [String: Int] = [:]
    return missions.map { m in
        let i = count[m.kind, default: 0]
        count[m.kind] = i + 1
        return String(m.kind.prefix(1)) + String(i)
    }
}

func publish() {
    let idList = ids()
    let list: [[String: Any]] = missions.enumerated().map { i, m in
        ["id": idList[i], "kind": m.kind, "text": m.text, "urgent": m.urgent, "done": doneNow(m), "doneOn": m.doneOn]
    }
    emit([
        "state": [
            "missions": list, "day": today(), "week": monday(), "streak": streak(),
            "folder": given.hasPrefix("~")
                ? given
                : (folder.hasPrefix(NSHomeDirectory()) ? "~" + folder.dropFirst(NSHomeDirectory().count) : folder),
        ]
    ])
}

func read() {
    let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
    if text == lastText && !missions.isEmpty { return }
    lastText = text
    parse(text)
    publish()
}

func write() {
    do {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let text = render()
        try text.write(toFile: file, atomically: true, encoding: .utf8)
        lastText = text
    } catch { fail("can't write \(file): \(error.localizedDescription)") }
    publish()
}

func index(_ id: String) -> Int? { ids().firstIndex(of: id) }

func handle(_ line: String) {
    guard let d = line.data(using: .utf8), let msg = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
        return
    }
    read()
    if let a = msg["add"] as? [String: Any] {
        let text = ((a["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(
            of: "\n", with: " ")
        guard !text.isEmpty else { return }
        let kind = kinds.contains(a["kind"] as? String ?? "") ? a["kind"] as! String : "daily"
        missions.append(
            Mission(kind: kind, text: text, urgent: (a["urgent"] as? Bool) ?? false, done: false, doneOn: ""))
    } else if let a = msg["done"] as? [String: Any], let i = index(a["id"] as? String ?? "") {
        missions[i].done = true
        missions[i].doneOn = today()
        let dailies = missions.filter { $0.kind == "daily" }
        if !dailies.isEmpty && dailies.allSatisfy(doneNow) && !allDone.contains(today()) { allDone.append(today()) }
    } else if let a = msg["undo"] as? [String: Any], let i = index(a["id"] as? String ?? "") {
        missions[i].done = false
        missions[i].doneOn = ""
        if missions[i].kind == "daily" { allDone.removeAll { $0 == today() } }
    } else if let a = msg["remove"] as? [String: Any], let i = index(a["id"] as? String ?? "") {
        missions.remove(at: i)
    } else if let a = msg["edit"] as? [String: Any], let i = index(a["id"] as? String ?? ""),
        let t = a["text"] as? String,
        !t.trimmingCharacters(in: .whitespaces).isEmpty
    {
        missions[i].text = t.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
    } else if let a = msg["urgent"] as? [String: Any], let i = index(a["id"] as? String ?? "") {
        missions[i].urgent = (a["on"] as? Bool) ?? !missions[i].urgent
    } else {
        return
    }
    write()
}

var source: DispatchSourceFileSystemObject?
func watch() {
    guard source == nil else { return }
    let fd = open(folder, O_EVTONLY)
    guard fd >= 0 else { return }
    let s = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
    s.setEventHandler {
        if s.data.contains(.delete) || s.data.contains(.rename) {
            s.cancel()
            source = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { read() }
    }
    s.setCancelHandler { close(fd) }
    s.resume()
    source = s
}
var shownDay = today()
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now() + 5, repeating: 5)
timer.setEventHandler {
    watch()
    if today() != shownDay {
        shownDay = today()
        publish()
    } else {
        read()
    }
}
timer.resume()

Thread.detachNewThread {
    while let line = rexui.readLine() { DispatchQueue.main.async { handle(line) } }
    exit(0)
}
DispatchQueue.main.async {
    read()
    watch()
}
dispatchMain()
