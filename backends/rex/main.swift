// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
import AppKit
import Foundation

let rexui = RexuiBackend()

let domain = "com.superlogical.rex" as CFString
let home = FileManager.default.homeDirectoryForCurrentUser
let confURL = URL(
    fileURLWithPath: (ProcessInfo.processInfo.environment["REXUI_DISTRO"] ?? home.path + "/.config/rex/distros/main")
        + "/rui-config.lua")
let initURL = home.appendingPathComponent(".config/rex/init.lua")

func emit(_ state: [String: Any]) {
    rexui.emit(["state": state])
}

func log(_ s: String) { FileHandle.standardError.write(("rexui-rex: " + s + "\n").data(using: .utf8)!) }

func cliPath() -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    var path = ""
    if proc_pidpath(getppid(), &buf, UInt32(buf.count)) > 0 { path = String(cString: buf) }
    if let r = path.range(of: ".app/Contents/MacOS/") {
        let app = String(path[..<r.lowerBound]) + ".app"
        let cli = app + "/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex"
        if FileManager.default.isExecutableFile(atPath: cli) { return cli }
    }
    return "/Applications/Rex Beta.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex"
}
let cli = cliPath()

@discardableResult
func rex(_ args: [String]) -> (Int32, Data) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cli)
    p.arguments = args
    let out = Pipe()
    let err = Pipe()
    p.standardOutput = out
    p.standardError = err
    do { try p.run() } catch {
        log("can't run rex: \(error)")
        return (-1, Data())
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let e = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    if p.terminationStatus != 0, let s = String(data: e, encoding: .utf8), !s.isEmpty {
        log("rex \(args.joined(separator: " ")): \(s)")
    }
    return (p.terminationStatus, data)
}

var client: String?
func findClient() {
    let (_, data) = rex(["client", "ls", "--json"])
    guard let all = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let clients = all["clients"] as? [[String: Any]]
    else { return }
    for c in clients {
        if let p = c["principal"] as? [String: Any], (p["pid"] as? Int).map({ Int32($0) }) == getppid(),
            let info = c["info"] as? [String: Any], info["kind"] as? String == "app"
        {
            client = c["client_id"] as? String
            emit(["client": client ?? "", "version": "\(info["name"] ?? "Rex") \(info["version"] ?? "")"])
            break
        }
    }
}

func actions() {
    var out: [[String: Any]] = []
    var seen = Set<String>()
    for args in [client.map { ["-C", $0, "actions", "--json"] }, ["actions", "--json"]].compactMap({ $0 }) {
        let (_, data) = rex(args)
        let obj = try? JSONSerialization.jsonObject(with: data)
        let list = (obj as? [[String: Any]]) ?? ((obj as? [String: Any])?["actions"] as? [[String: Any]]) ?? []
        for a in list {
            guard let name = a["name"] as? String, !seen.contains(name) else { continue }
            seen.insert(name)
            var args: [String] = []
            var about: [String: Any] = [:]
            if let as_ = a["args"] as? [[String: Any]] {
                args = as_.compactMap { x in
                    (x["name"] as? String).map { $0 + ((x["optional"] as? Bool) == true ? "?" : "") }
                }
            } else if let as_ = a["args"] as? [String] {
                args = as_
            } else if let schema = a["args"] as? [String: Any], let props = schema["properties"] as? [String: Any] {
                let required = Set((schema["required"] as? [String]) ?? [])
                args = props.keys.sorted().map { required.contains($0) ? $0 : $0 + "?" }
                for (k, v) in props {
                    guard let p = v as? [String: Any] else { continue }
                    var d: [String: Any] = [:]
                    if let e = p["enum"] as? [Any] { d["choices"] = e.map { "\($0)" } }
                    if let t = p["type"] as? String { d["type"] = t }
                    if let t = p["description"] as? String { d["about"] = t }
                    about[k] = d
                }
            }
            out.append([
                "name": name, "title": (a["title"] as? String) ?? name, "args": args, "about": about,
                "category": (a["category"] as? String) ?? "", "keywords": (a["keywords"] as? String) ?? "",
            ])
        }
    }
    emit(["actions": out])
}

func run(_ name: String, _ args: [String: Any]) {
    var a = client.map { ["-C", $0] } ?? []
    a += ["do", name]
    for (k, v) in args.sorted(by: { $0.key < $1.key }) { a.append("\(k)=\(v)") }
    DispatchQueue.global().async { rex(a) }
}

func plain(_ v: Any) -> Any? {
    switch v {
    case let d as Data:
        return try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
    case let d as Date:
        return ISO8601DateFormatter().string(from: d)
    case let a as [Any]:
        return a.compactMap(plain)
    case let m as [String: Any]:
        return m.compactMapValues(plain)
    default:
        return v
    }
}

var lastDefaults = Data()
func readDefaults(force: Bool = false) {
    CFPreferencesAppSynchronize(domain)
    let keys = (CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]) ?? []
    var out: [String: Any] = [:]
    for k in keys where k.hasPrefix("Workspace.") || k.hasPrefix("rex.") || k.hasPrefix("SU") {
        if k == "Workspace.lastFocusedSession" || k == "Workspace.openWindows" || k == "Workspace.sessionOrder" {
            continue
        }
        if let v = CFPreferencesCopyAppValue(k as CFString, domain), let p = plain(v) { out[k] = p }
    }
    let data = (try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])) ?? Data()
    if data == lastDefaults && !force { return }
    lastDefaults = data
    emit(["defaults": out])
}

func set(_ values: [String: Any]) {
    for (k, v) in values {
        guard k.hasPrefix("Workspace.") || k.hasPrefix("rex.") || k.hasPrefix("SU") else { continue }
        if v is NSNull {
            CFPreferencesSetAppValue(k as CFString, nil, domain)
        } else if k == "Workspace.customThemes", JSONSerialization.isValidJSONObject(v),
            let d = try? JSONSerialization.data(withJSONObject: v)
        {
            CFPreferencesSetAppValue(k as CFString, d as CFData, domain)
        } else {
            CFPreferencesSetAppValue(k as CFString, v as CFPropertyList, domain)
        }
    }
    CFPreferencesAppSynchronize(domain)
    readDefaults()
}

func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

func luaString(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

func luaUnescape(_ s: Substring) -> String {
    var out = ""
    var escaped = false
    for c in s {
        if escaped {
            out.append(c)
            escaped = false
        } else if c == "\\" {
            escaped = true
        } else {
            out.append(c)
        }
    }
    return out
}

func bindings(_ s: String) -> [[String: String]] {
    let str = #""((?:[^"\\]|\\.)*)""#
    let re = try! NSRegularExpression(
        pattern: #"^\s*rex\.bind\(\s*"# + str + #"\s*,\s*"# + str, options: [.anchorsMatchLines])
    return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { m in
        ["key": luaUnescape(s[Range(m.range(at: 1), in: s)!]), "action": luaUnescape(s[Range(m.range(at: 2), in: s)!])]
    }
}

var lastConf = ""
var lastInit = ""
var ownInit: String?
func readFiles(force: Bool = false) {
    let c = text(confURL)
    let i = text(initURL)
    if c != lastConf || force {
        lastConf = c
        emit(["confText": c])
    }
    if i != lastInit || force {
        if !force && i != ownInit { reloadInit() }
        lastInit = i
        emit(["bindings": bindings(i), "initText": i])
    }
}

func write(_ url: URL, _ s: String) {
    if url == initURL { ownInit = s }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    do { try s.write(to: url, atomically: true, encoding: .utf8) } catch { log("writing \(url.path): \(error)") }
}

func luaValue(_ v: Any) -> String {
    if let n = v as? NSNumber {
        return CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
    }
    let s = "\(v)".trimmingCharacters(in: .whitespaces)
    let number = #"-?\d+(\.\d+)?"#
    if s == "true" || s == "false" || s.range(of: "^\(number)$", options: .regularExpression) != nil { return s }
    if s.range(of: "^\(number)(\\s*,\\s*\(number))+$", options: .regularExpression) != nil {
        return "{ " + s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
            + " }"
    }
    return luaString(s)
}

func setConf(_ values: [String: Any]) {
    var lines = text(confURL).components(separatedBy: "\n")
    if !lines.contains(where: { $0.hasPrefix("return") }) { lines = ["return {", "}", ""] }
    for (k, v) in values.sorted(by: { $0.key < $1.key }) {
        let name = k.replacingOccurrences(of: "-", with: "_")
        let en = NSRegularExpression.escapedPattern(for: name)
        let ek = NSRegularExpression.escapedPattern(for: k)
        let mine = try! NSRegularExpression(pattern: #"^(\s*)(\#(en)|\["\#(ek)"\])\s*=(.*?)(\s--[^"]*)?$"#)
        let at = lines.firstIndex { mine.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
        if v is NSNull {
            if let at { lines.remove(at: at) }
            continue
        }
        if let at {
            let l = lines[at]
            let m = mine.firstMatch(in: l, range: NSRange(l.startIndex..., in: l))!
            let indent = String(l[Range(m.range(at: 1), in: l)!])
            let comment = Range(m.range(at: 4), in: l).map { String(l[$0]) } ?? ""
            lines[at] = "\(indent)\(name) = \(luaValue(v)),\(comment)"
        } else {
            let close = lines.lastIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("}") } ?? lines.count
            lines.insert("    \(name) = \(luaValue(v)),", at: close)
        }
    }
    write(confURL, lines.joined(separator: "\n"))
    readFiles()
}

func reloadInit() { run("client.config.reload", [:]) }

func bind(_ key: String, _ action: String?) {
    var lines = text(initURL).components(separatedBy: "\n")
    let quoted = luaString(key)
    let mine = { (l: String) -> Bool in
        let t = l.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("rex.bind(") && t.dropFirst(9).trimmingCharacters(in: .whitespaces).hasPrefix(quoted)
    }
    if let action {
        let line = "rex.bind(\(quoted), \(luaString(action)))"
        if let at = lines.firstIndex(where: mine) {
            lines[at] = line
        } else {
            if lines.last == "" { lines.insert(line, at: lines.count - 1) } else { lines.append(line) }
        }
    } else {
        lines.removeAll(where: mine)
    }
    write(initURL, lines.joined(separator: "\n"))
    readFiles()
    reloadInit()
}

func fonts() {
    var families = Set<String>()
    for name in NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? [] {
        if let f = NSFont(name: name, size: 12), let fam = f.familyName, !fam.hasPrefix(".") { families.insert(fam) }
    }
    emit(["fonts": families.sorted(), "paths": ["conf": confURL.path, "init": initURL.path]])
}

func everything() {
    readDefaults(force: true)
    readFiles(force: true)
    fonts()
    findClient()
    actions()
}

let queue = DispatchQueue(label: "rexui-rex")
queue.sync { everything() }
let timer = DispatchSource.makeTimerSource(queue: queue)
timer.schedule(deadline: .now() + 1, repeating: 1)
var looked = 0
timer.setEventHandler {
    readDefaults()
    readFiles()
    if client == nil && looked < 60 {
        looked += 1
        findClient()
        if client != nil {
            log("Rex's client found after \(looked) s")
            actions()
        }
    }
}
timer.resume()

while let line = rexui.readLine() {
    guard let data = line.data(using: .utf8),
        let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { continue }
    queue.sync {
        if let s = msg["set"] as? [String: Any] { set(s) }
        if let c = msg["conf"] as? [String: Any] { setConf(c) }
        if let b = msg["bind"] as? [String: Any], let k = b["key"] as? String, let a = b["action"] as? String {
            bind(k, a)
        }
        if let k = msg["unbind"] as? String { bind(k, nil) }
        if let w = msg["write"] as? [String: Any], let f = w["file"] as? String, let t = w["text"] as? String {
            if f == "conf" {
                write(confURL, t)
            } else if f == "init" {
                write(initURL, t)
                reloadInit()
            }
            readFiles()
        }
        if let r = msg["run"] as? String { run(r, msg["args"] as? [String: Any] ?? [:]) }
        if let r = msg["refresh"] {
            if (r as? String) == "defaults" { readDefaults() } else { everything() }
        }
    }
}
