// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: GPL-3.0-only
import AppKit

let rexui = RexuiBackend()

let fm = FileManager.default
let home = fm.homeDirectoryForCurrentUser.path
let support = home + "/Library/Application Support/rexui"
let stateFile = support + "/launcher.json"
let iconDir = home + "/Library/Caches/rexui/launcher"
let logFile = home + "/Library/Logs/rexui-launch.log"
let distro = ProcessInfo.processInfo.environment["REXUI_DISTRO"] ?? home + "/.config/rex/distros/main"
let configFile = distro + "/launcher.json"

func log(_ s: String) { FileHandle.standardError.write("rexui-launch: \(s)\n".data(using: .utf8)!) }

struct App {
    var id, name, subtitle: String
    var icon: String?, symbol: String?
    var path: String?
    var command: [String]?
    var rui: String?
    var relative = false
    var keys: [String] = []
    var json: [String: Any] {
        var o: [String: Any] = [
            "id": id, "kind": rui == nil ? "app" : "widget", "name": name, "subtitle": subtitle, "relative": relative,
        ]
        if let icon { o["icon"] = icon }
        if let symbol { o["symbol"] = symbol }
        return o
    }
}

var apps: [App] = []
var recent: [String] = []
var running: [Int32: (id: String, block: String)] = [:]

func loadState() {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: stateFile)),
        let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    else { return }
    recent = o["recent"] as? [String] ?? []
    for r in o["running"] as? [[String: Any]] ?? [] {
        guard let pid = (r["pid"] as? NSNumber)?.int32Value, let id = r["id"] as? String,
            let block = r["block"] as? String,
            kill(pid, 0) == 0
        else { continue }
        running[pid] = (id, block)
        watchExit(pid)
    }
}

func saveState() {
    try? fm.createDirectory(atPath: support, withIntermediateDirectories: true)
    let o: [String: Any] = ["recent": recent, "running": runningJSON()]
    if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) {
        try? d.write(to: URL(fileURLWithPath: stateFile), options: .atomic)
    }
}

var places: [String: [String: Any]] = [:]

func runningJSON(placed: Bool = false) -> [[String: Any]] {
    running.sorted { $0.key < $1.key }.map {
        let o: [String: Any] = ["pid": Int($0.key), "id": $0.value.id, "block": $0.value.block]
        return placed ? o.merging(places[$0.value.block] ?? [:]) { a, _ in a } : o
    }
}

func emit(_ o: [String: Any]) {
    rexui.emit(o)
}

func emitState() {
    let listed = Set(apps.map(\.id))
    emit([
        "state": [
            "apps": apps.map(\.json), "recent": recent.filter(listed.contains), "running": runningJSON(placed: true),
        ]
    ])
}

func fnv(_ s: String) -> String {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
    return String(h, radix: 16)
}

func iconPNG(_ path: String) -> String? {
    let mtime =
        (try? fm.attributesOfItem(atPath: path + "/Contents/Info.plist")[.modificationDate] as? Date)?
        .timeIntervalSince1970 ?? 0
    let out = "\(iconDir)/\(fnv(path + "\(mtime)")).png"
    if fm.fileExists(atPath: out) { return out }
    let image = NSWorkspace.shared.icon(forFile: path)
    let px = 64
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
    try? fm.createDirectory(atPath: iconDir, withIntermediateDirectories: true)
    return (try? png.write(to: URL(fileURLWithPath: out), options: .atomic)) != nil ? out : nil
}

func scan() {
    var config: [String: Any] = [:]
    if let d = try? Data(contentsOf: URL(fileURLWithPath: configFile)) {
        if let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            config = o
        } else {
            log("\(configFile): not a JSON object")
        }
    }
    var found: [App] = []
    let every = config["keys"] as? [String] ?? []
    for c in config["apps"] as? [[String: Any]] ?? [] {
        let path = (c["path"] as? String).map { ($0 as NSString).expandingTildeInPath }
        let bundle = path.flatMap { Bundle(path: $0) }
        guard
            let name = c["name"] as? String ?? (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
        else {
            log("an app without a name")
            continue
        }
        var a = App(id: path ?? "custom:" + name, name: name, subtitle: c["subtitle"] as? String ?? "")
        if let path {
            guard fm.fileExists(atPath: path) else {
                log("\(name): no \(path)")
                continue
            }
            a.path = path
            a.icon = iconPNG(path)
            if a.subtitle.isEmpty {
                a.subtitle = (path as NSString).deletingLastPathComponent.replacingOccurrences(of: home, with: "~")
            }
        } else if let cmd = c["command"] as? [String], !cmd.isEmpty {
            a.command = cmd.map { $0.hasPrefix("~/") ? ($0 as NSString).expandingTildeInPath : $0 }
            if a.subtitle.isEmpty { a.subtitle = cmd[0] }
        } else {
            log("\(name): no path or command")
            continue
        }
        if let i = c["icon"] as? String { a.icon = (i as NSString).expandingTildeInPath }
        a.symbol = c["symbol"] as? String ?? (a.icon == nil ? "terminal" : nil)
        a.relative = c["relative"] as? Bool ?? false
        a.keys = every + (c["keys"] as? [String] ?? [])
        found.append(a)
    }
    found.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    apps = found + widgets(config["widgets"] as? [[String: Any]] ?? [])
}

func dockInfo(_ path: String) -> (title: String?, icon: String?) {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
        let open = text.range(of: #"\bDock\s*\{"#, options: .regularExpression)
    else { return (nil, nil) }
    var head = text[open.upperBound...]
    if let child = head.range(of: #"\b[A-Z]\w*\s*\{"#, options: .regularExpression) { head = head[..<child.lowerBound] }
    func prop(_ name: String) -> String? {
        guard let r = head.range(of: #"\b\#(name)\s*:\s*"([^"\n]*)""#, options: .regularExpression) else { return nil }
        let m = head[r]
        guard let q = m.firstIndex(of: "\"") else { return nil }
        return String(m[m.index(after: q)..<m.index(before: m.endIndex)])
    }
    return (prop("title"), prop("icon"))
}

func widgets(_ listed: [[String: Any]]) -> [App] {
    var byPath: [String: [String: Any]] = [:]
    var order: [String] = []
    let dir = distro + "/panes"
    for f in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() where f.hasSuffix(".rui") {
        order.append(dir + "/" + f)
    }
    for c in listed {
        guard let p = (c["path"] as? String).map({ ($0 as NSString).expandingTildeInPath }) else {
            log("a widget without a path")
            continue
        }
        if byPath[p] == nil && !order.contains(p) { order.append(p) }
        byPath[p] = c
    }
    var found: [App] = []
    for path in order {
        guard fm.fileExists(atPath: path) else {
            log("widget \(path): no such file")
            continue
        }
        let c = byPath[path] ?? [:]
        let dock = dockInfo(path)
        let file = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let name = c["name"] as? String ?? dock.title ?? file.prefix(1).uppercased() + file.dropFirst()
        var a = App(
            id: "widget:" + path, name: name,
            subtitle: c["subtitle"] as? String ?? (path as NSString).abbreviatingWithTildeInPath)
        a.rui = path
        if let i = c["icon"] as? String { a.icon = (i as NSString).expandingTildeInPath }
        a.symbol = c["symbol"] as? String ?? dock.icon ?? (a.icon == nil ? "square.grid.2x2" : nil)
        found.append(a)
    }
    return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

func toolPath(_ name: String) -> String? {
    let path =
        (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) + [
            home + "/.local/bin"
        ]
    return path.map { $0 + "/" + name }.first { fm.isExecutableFile(atPath: $0) }
}

func watchExit(_ pid: pid_t) {
    let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
    src.setEventHandler {
        var status: Int32 = 0
        waitpid(pid, &status, WNOHANG)
        running[pid] = nil
        saveState()
        emitState()
        src.cancel()
    }
    src.resume()
    exits[pid] = src
}
var exits: [pid_t: DispatchSourceProcess] = [:]

func stop(_ pid: pid_t) {
    kill(pid, SIGTERM)
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        if running[pid] != nil, kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }
}

func rexCLI() -> String? {
    let helper = "/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex"
    return [home + "/Applications/Rex UI.app", "/Applications/Rex Beta.app", "/Applications/Rex.app"].map {
        $0 + helper
    }
    .first { fm.isExecutableFile(atPath: $0) }
}

func survey(_ asked: Set<String>) -> (blocks: Set<String>, places: [String: [String: Any]])? {
    guard let cli = rexCLI() else { return nil }
    func call(_ args: [String]) -> [String: Any]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["DYLD_INSERT_LIBRARIES"] = nil
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? try? JSONSerialization.jsonObject(with: data) as? [String: Any] : nil
    }
    func ids(_ v: Any, into out: inout Set<String>) {
        if let d = v as? [String: Any] {
            if let b = d["block_id"] as? String { out.insert(b) }
            for x in d.values { ids(x, into: &out) }
        } else if let a = v as? [Any] {
            for x in a { ids(x, into: &out) }
        }
    }
    guard let sessions = call(["session", "ls", "--json"])?["sessions"] as? [[String: Any]] else { return nil }
    var blocks = Set<String>()
    var places: [String: [String: Any]] = [:]
    for s in sessions {
        guard let id = s["session_id"] as? String,
            let list = call(["block", "ls", "-s", id, "--json"])?["blocks"] as? [[String: Any]]
        else { return nil }
        var here = Set<String>()
        for b in list { if let b = b["block_id"] as? String { here.insert(b) } }
        blocks.formUnion(here)
        guard !here.isDisjoint(with: asked), let o = call(["session", "inspect", id, "--json"]) else { continue }
        let session = o["session"] as? [String: Any] ?? o
        for (k, w) in (session["windows"] as? [[String: Any]] ?? []).enumerated() {
            var inTab = Set<String>()
            ids(w["layers"] ?? [], into: &inTab)
            let label = w["label"] as? String ?? ""
            let own = label.range(of: #"^Window [0-9a-f]{8}$"#, options: .regularExpression) == nil ? label : ""
            for b in inTab.intersection(asked) {
                places[b] = ["sessionId": id, "session": s["label"] as? String ?? "", "tab": k + 1, "tabLabel": own]
            }
        }
    }
    return (blocks, places)
}

func locate() {
    let asked = Set(running.values.map(\.block))
    guard !asked.isEmpty else { return }
    DispatchQueue.global(qos: .utility).async {
        guard let found = survey(asked)?.places else { return }
        DispatchQueue.main.async { place(found) }
    }
}

func place(_ found: [String: [String: Any]]) {
    guard !NSDictionary(dictionary: found).isEqual(to: places) else { return }
    places = found
    emitState()
}

func reapClosedPanes() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { reapClosedPanes() }
    guard !running.isEmpty else { return }
    let watched = running
    DispatchQueue.global(qos: .utility).async {
        guard let (blocks, found) = survey(Set(watched.values.map(\.block))) else { return }
        DispatchQueue.main.async {
            place(found)
            for (pid, r) in watched where running[pid] != nil && !blocks.contains(r.block) {
                log("\(r.id) (pid \(pid)): its pane \(r.block) is closed: quit")
                stop(pid)
            }
        }
    }
}

func focusedBlock(_ session: String) -> String? {
    guard !session.isEmpty, let cli = rexCLI() else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cli)
    p.arguments = ["session", "inspect", session, "--json"]
    var env = ProcessInfo.processInfo.environment
    env["DYLD_INSERT_LIBRARIES"] = nil
    p.environment = env
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let s = o["session"] as? [String: Any] ?? o
    guard let active = s["active_window_id"] as? String,
        let w = (s["windows"] as? [[String: Any]])?.first(where: { $0["window_id"] as? String == active })
    else { return nil }
    return w["focused_block_id"] as? String
}

func launch(_ id: String, block given: String, session: String) {
    guard let app = apps.first(where: { $0.id == id }) else { return emit(["error": "no app \(id)"]) }
    let block = given.hasPrefix("block:") ? given : focusedBlock(session) ?? ""
    guard block.hasPrefix("block:") else { return emit(["error": "no pane to show \(app.name) in"]) }
    guard let embed = toolPath("rexui") else {
        return emit(["error": "the rexui command isn't installed (just cli::install)"])
    }
    for (pid, r) in running where r.block == block { stop(pid) }
    var args = [embed, app.rui == nil ? "embed" : "pane"]
    if let rui = app.rui {
        args.append(rui)
    } else {
        if app.relative { args.append("--relative") }
        args += app.path.map { [$0] } ?? app.command ?? []
    }
    var env = ProcessInfo.processInfo.environment
    env["DYLD_INSERT_LIBRARIES"] = nil
    env["REX_BLOCK"] = block
    env["REX_SESSION"] = session
    env["REXUI_PANE_KEYS"] = app.keys.isEmpty ? nil : app.keys.joined(separator: ",")
    env["PATH"] = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"].joined(
        separator: ":")
    var fa: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fa)
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&fa, 1, logFile, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    posix_spawn_file_actions_adddup2(&fa, 1, 2)
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    let cargs = args.map { strdup($0) } + [nil]
    let cenv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, embed, &fa, &attr, cargs, cenv)
    cargs.forEach { free($0) }
    cenv.forEach { free($0) }
    posix_spawn_file_actions_destroy(&fa)
    posix_spawnattr_destroy(&attr)
    guard rc == 0 else { return emit(["error": "couldn't start \(app.name): \(String(cString: strerror(rc)))"]) }
    log("\(app.name) (pid \(pid)) in \(block)")
    running[pid] = (id, block)
    watchExit(pid)
    recent = [id] + recent.filter { $0 != id }.prefix(7)
    saveState()
    emitState()
    locate()
}

loadState()
scan()
emitState()
locate()
reapClosedPanes()

DispatchQueue.global().async {
    while let line = rexui.readLine() {
        guard let d = line.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { continue }
        DispatchQueue.main.async {
            if o["refresh"] != nil {
                scan()
                emitState()
                locate()
            }
            if let l = o["launch"] as? [String: Any], let id = l["id"] as? String {
                launch(id, block: l["block"] as? String ?? "", session: l["session"] as? String ?? "")
            }
            if let q = o["quit"] as? [String: Any], let id = q["id"] as? String {
                for (pid, r) in running where r.id == id { stop(pid) }
            }
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { exit(0) }
}
dispatchMain()
