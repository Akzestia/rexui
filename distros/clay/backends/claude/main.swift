// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT
import Foundation

let rexui = RexuiBackend()
let home = NSHomeDirectory()
let fm = FileManager.default

func emit(_ obj: [String: Any]) {
    rexui.emit(obj)
}
func log(_ s: String) { FileHandle.standardError.write(("clay-claude: " + s + "\n").data(using: .utf8)!) }

let configDir: String = {
    let a = CommandLine.arguments.count > 1 ? CommandLine.arguments[1].trimmingCharacters(in: .whitespaces) : ""
    return (((a.isEmpty ? "~/.claude" : a) as NSString).expandingTildeInPath as NSString).standardizingPath
}()
let defaultDir = configDir == home + "/.claude"

func configFiles() -> [String] {
    defaultDir ? [home + "/.claude.json", configDir + "/.claude.json"] : [configDir + "/.claude.json"]
}

func claudeEnv(_ env: [String: String]) -> [String: String] {
    var e = env
    e.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
    if defaultDir { e.removeValue(forKey: "CLAUDE_CONFIG_DIR") } else { e["CLAUDE_CONFIG_DIR"] = configDir }
    return e
}

let iso: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
let isoPlain = ISO8601DateFormatter()
func seconds(_ s: Any?) -> Int {
    guard let s = s as? String, let d = iso.date(from: s) ?? isoPlain.date(from: s) else { return 0 }
    return Int(d.timeIntervalSince1970)
}

var mtimes: [String: Date] = [:]
var cached: [String: (at: Double, u: [String: Any])] = [:]
var lastUsage: [String: Any]? = nil

func limit(_ u: [String: Any], _ group: String, _ legacy: String) -> [String: Any]? {
    let limits = u["limits"] as? [[String: Any]] ?? []
    var percent = 0.0
    var resets = 0
    var severity = ""
    if let l = limits.first(where: { ($0["group"] as? String) == group }) {
        percent = l["percent"] as? Double ?? 0
        resets = seconds(l["resets_at"])
        severity = l["severity"] as? String ?? ""
    } else if let l = u[legacy] as? [String: Any] {
        percent = l["utilization"] as? Double ?? 0
        resets = seconds(l["resets_at"])
        severity = percent >= 90 ? "critical" : percent >= 70 ? "warning" : "normal"
    } else {
        return nil
    }
    if resets > 0 && Double(resets) < Date().timeIntervalSince1970 {
        percent = 0
        severity = "normal"
        resets = 0
    }
    return ["percent": percent, "resets": resets, "severity": severity]
}

func readUsage() {
    for f in configFiles() {
        let m = (try? fm.attributesOfItem(atPath: f))?[.modificationDate] as? Date
        if m == mtimes[f] { continue }
        mtimes[f] = m
        cached[f] = nil
        guard let data = fm.contents(atPath: f),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let cache = obj["cachedUsageUtilization"] as? [String: Any],
            let u = cache["utilization"] as? [String: Any]
        else { continue }
        cached[f] = ((cache["fetchedAtMs"] as? Double) ?? 0, u)
    }
    var usage: [String: Any] = [:]
    if let c = cached.values.max(by: { $0.at < $1.at }) {
        usage["fetched"] = Int(c.at / 1000)
        if let s = limit(c.u, "session", "five_hour") { usage["session"] = s }
        if let w = limit(c.u, "weekly", "seven_day") { usage["weekly"] = w }
    }
    if let last = lastUsage, NSDictionary(dictionary: last).isEqual(to: usage) { return }
    lastUsage = usage
    emit(["state": ["usage": usage]])
}

let rexCLI: String? = [
    home + "/Applications/Rex UI.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex",
    "/Applications/Rex Beta.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex",
    "/Applications/Rex.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex",
].first { fm.isExecutableFile(atPath: $0) }

let claudePath: String =
    [home + "/.local/bin/claude", home + "/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    .first { fm.isExecutableFile(atPath: $0) } ?? "claude"

func rex(_ args: [String]) -> (ok: Bool, out: String) {
    guard let cli = rexCLI else { return (false, "Rex's rex command isn't there") }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cli)
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    env.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
    p.environment = env
    let out = Pipe()
    let err = Pipe()
    p.standardOutput = out
    p.standardError = err
    do { try p.run() } catch { return (false, "\(error)") }
    let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    return p.terminationStatus == 0 ? (true, o) : (false, e.isEmpty ? o : e)
}

func ask(_ a: [String: Any]) {
    let text = (a["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let cwd = (((a["cwd"] as? String) ?? "~") as NSString).expandingTildeInPath
    let command =
        (defaultDir ? [] : ["/usr/bin/env", "CLAUDE_CONFIG_DIR=" + configDir])
        + (text.isEmpty ? [claudePath] : [claudePath, text])
    if (a["new"] as? String) == "session" {
        let r = rex(["session", "new", "claude", "--json", "--cwd", cwd, "--"] + command)
        guard r.ok else {
            log("session new: \(r.out)")
            emit(["error": r.out.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)])
            return
        }
        let id = find("session_id", in: json(r.out)) ?? find("id", in: json(r.out)) ?? ""
        if !id.isEmpty { emit(["opened": ["session": id]]) } else { log("session new: no id in \(r.out)") }
    } else {
        let session = a["session"] as? String ?? ""
        var args = ["run", "--json", "--label", "claude", "--cwd", cwd]
        if !session.isEmpty { args += ["-s", session] }
        let r = rex(args + ["--"] + command)
        if !r.ok {
            log("run: \(r.out)")
            emit(["error": r.out.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)])
            return
        }
        guard let window = find("window_id", in: json(r.out)) else {
            log("run: no window in \(r.out)")
            return
        }
        let ls = rex([
            "window", "ls", "--json", "-s", session.isEmpty ? (find("session_id", in: json(r.out)) ?? "") : session,
        ])
        let windows = (json(ls.out) as? [String: Any])?["windows"] as? [[String: Any]] ?? []
        if let i = windows.firstIndex(where: { ($0["window_id"] as? String) == window }) {
            emit(["opened": ["tab": i + 1, "session": session]])
        } else {
            log("run: \(window) not among the session's windows")
        }
    }
}

func json(_ s: String) -> Any? { try? JSONSerialization.jsonObject(with: Data(s.utf8)) }
func find(_ key: String, in o: Any?) -> String? {
    if let d = o as? [String: Any] {
        if let v = d[key] as? String { return v }
        for v in d.values { if let f = find(key, in: v) { return f } }
    } else if let a = o as? [Any] {
        for v in a { if let f = find(key, in: v) { return f } }
    }
    return nil
}

let askDir = home + "/Library/Application Support/rexui/clay-ask"
var conversation: String? = nil
var answering: Process? = nil
let answerLock = NSLock()

func inline(_ a: [String: Any]) {
    let id = a["id"] as? Int ?? 0
    var text = (a["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if (a["clipboard"] as? Bool) == true {
        let p = Process()
        let out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pbpaste")
        p.standardOutput = out
        try? p.run()
        let clip = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        text = text + "\n\n" + clip.trimmingCharacters(in: .whitespacesAndNewlines)
        emit(["asked": ["id": id, "text": text]])
    }
    guard !text.isEmpty else {
        emit(["done": ["id": id, "error": ""]])
        return
    }
    try? fm.createDirectory(atPath: askDir, withIntermediateDirectories: true)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: claudePath.hasPrefix("/") ? claudePath : "/usr/bin/env")
    var args = [
        "-p", text, "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--tools", "",
        "--append-system-prompt",
        "You're answering in a small panel beside the user's terminal. Be brief and direct. Plain text: no Markdown headings or tables; short code is fine.",
    ]
    if let c = conversation { args += ["--resume", c] }
    p.arguments = claudePath.hasPrefix("/") ? args : ["claude"] + args
    p.currentDirectoryURL = URL(fileURLWithPath: askDir)
    p.environment = claudeEnv(ProcessInfo.processInfo.environment)
    let out = Pipe()
    let err = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch {
        emit(["done": ["id": id, "error": "\(error)"]])
        return
    }
    answerLock.lock()
    answering = p
    answerLock.unlock()
    emit(["state": ["thinking": true]])
    var failure = ""
    let reader = out.fileHandleForReading
    var buffer = Data()
    while true {
        let chunk = reader.availableData
        if chunk.isEmpty { break }
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0a) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            switch o["type"] as? String {
            case "stream_event":
                if let e = o["event"] as? [String: Any], let d = e["delta"] as? [String: Any],
                    d["type"] as? String == "text_delta", let t = d["text"] as? String
                {
                    emit(["delta": ["id": id, "text": t]])
                }
            case "result":
                if let sid = o["session_id"] as? String { conversation = sid }
                if (o["is_error"] as? Bool) == true {
                    failure = (o["result"] as? String) ?? (o["subtype"] as? String) ?? "failed"
                }
            default: break
            }
        }
    }
    p.waitUntilExit()
    answerLock.lock()
    answering = nil
    answerLock.unlock()
    if failure.isEmpty && p.terminationStatus != 0 && p.terminationReason != .uncaughtSignal {
        failure =
            String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "claude exited with \(p.terminationStatus)"
    }
    if !failure.isEmpty { log("inline: \(failure)") }
    emit(["done": ["id": id, "error": failure]])
    emit(["state": ["thinking": false]])
}

readUsage()
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now() + 10, repeating: 10)
timer.setEventHandler { readUsage() }
timer.resume()

DispatchQueue.global().async {
    while let line = rexui.readLine() {
        guard let msg = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
        if let a = msg["ask"] as? [String: Any] { ask(a) }
        if let a = msg["inline"] as? [String: Any] { DispatchQueue.global().async { inline(a) } }
        if msg["stop"] != nil {
            answerLock.lock()
            answering?.terminate()
            answerLock.unlock()
        }
        if msg["reset"] != nil { conversation = nil }
    }
    exit(0)
}
dispatchMain()
