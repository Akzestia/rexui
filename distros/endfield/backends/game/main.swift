// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT
import Foundation

let rexui = RexuiBackend()
let home = FileManager.default.homeDirectoryForCurrentUser.path
func emit(_ obj: [String: Any]) {
    rexui.emit(obj)
}
func note(_ s: String) { FileHandle.standardError.write(("endfield-game: " + s + "\n").data(using: .utf8)!) }
func fail(_ s: String) -> Never {
    note(s)
    emit(["error": s])
    exit(1)
}

let args = CommandLine.arguments
let block = args.count > 1 ? args[1] : ""
let session = args.count > 2 ? args[2] : ""
let keys = args.count > 3 && !args[3].isEmpty ? args[3] : "qwerty"
guard block.hasPrefix("block:") else { fail("no pane to start Endfield in") }

func running(_ pattern: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-qf", pattern]
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus == 0
}
let game = "Endfield\\.exe"
if running(game) { fail("Endfield is already running") }

let crossover = home + "/Applications/CrossOver_Endfield_Patch.app"
guard FileManager.default.fileExists(atPath: crossover) else { fail("no ~/Applications/CrossOver_Endfield_Patch.app") }
let path = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
guard let embed = path.map({ $0 + "/rexui" }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
    fail("the rexui command isn't installed (just cli::install)")
}
let cx = home + "/Library/Application Support/rexui/embed/CrossOver_Endfield_Patch.app/Contents/SharedSupport/CrossOver"
let lib: String = {
    let p = Process()
    let out = Pipe()
    p.executableURL = URL(fileURLWithPath: embed)
    p.arguments = ["embed", "--library"]
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    let d = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(data: d, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}()
if lib.isEmpty || !FileManager.default.fileExists(atPath: lib) {
    fail("rexui embed's library isn't built (just apps::core)")
}
let state = home + "/Library/Application Support/rexui/embed"
let target = state + "/endfield-target.json"
let steamPid = state + "/endfield-steam.pid"
try? FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)

if let d = try? JSONSerialization.data(withJSONObject: ["block": block, "session": session]) {
    FileManager.default.createFile(atPath: target, contents: d)
}

@discardableResult func wine(_ args: [String], wait: Bool) -> Process {
    let q = Process()
    q.executableURL = URL(fileURLWithPath: cx + "/bin/wine")
    q.arguments = ["--bottle", "Steam", "--no-update"] + args
    var e = ProcessInfo.processInfo.environment
    e["DYLD_INSERT_LIBRARIES"] = lib
    e["REXUI_EMBED_WINE"] = "1"
    e["REXUI_EMBED_EXE"] = "none.exe"
    e["REX_BLOCK"] = nil
    q.environment = e
    q.standardInput = FileHandle.nullDevice
    q.standardOutput = FileHandle.nullDevice
    q.standardError = FileHandle.nullDevice
    try? q.run()
    if wait { q.waitUntilExit() }
    return q
}
let steamExe = "C:\\Program Files (x86)\\Steam\\steam.exe"
let launchArgs = ["-applaunch", "4732690", "-force-d3d11"]
let steam = "Steam\\\\steam\\.exe|Steam/steam\\.exe"

func ourSteam() -> pid_t? {
    guard let s = try? String(contentsOfFile: steamPid, encoding: .utf8) else { return nil }
    let parts = s.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    guard let pid = parts.first.flatMap({ pid_t($0) }), kill(pid, 0) == 0 else { return nil }
    let p = Process()
    let out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-o", "command=", "-p", String(pid)]
    p.standardOutput = out
    try? p.run()
    p.waitUntilExit()
    let cmd = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return cmd.contains("CrossOver_Endfield_Patch.app") ? pid : nil
}
func ourKeys() -> String {
    let s = (try? String(contentsOfFile: steamPid, encoding: .utf8)) ?? ""
    let parts = s.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    return parts.count > 1 ? parts[1] : "qwerty"
}

Thread.detachNewThread {
    while rexui.readLine() != nil {}
    exit(0)
}

var started: pid_t = 0
if running(steam), ourSteam() != nil, ourKeys() == keys {
    note("handing the launch to the running Steam (ours) for \(block)")
    wine([steamExe] + launchArgs, wait: false)
    emit(["phase": "game"])
} else {
    if running(steam) {
        guard FileManager.default.isExecutableFile(atPath: cx + "/bin/wine") else {
            fail("Steam is running in CrossOver: quit it first")
        }
        note(
            ourSteam() != nil
                ? "asking Steam to quit (started with other keys: \(ourKeys()))"
                : "asking Steam (not started from a pane) to quit")
        emit(["status": "Quitting Steam to start it in this pane"])
        wine([steamExe, "-shutdown"], wait: false)
        var until = Date().addingTimeInterval(15)
        while running(steam) && Date() < until { Thread.sleep(forTimeInterval: 0.5) }
        if running(steam) {
            note("Steam still there: the bottle's processes ended")
            let k = Process()
            k.executableURL = URL(fileURLWithPath: cx + "/bin/wineserver")
            k.arguments = ["-k"]
            var e = ProcessInfo.processInfo.environment
            e["DYLD_INSERT_LIBRARIES"] = nil
            e["WINEPREFIX"] = home + "/Library/Application Support/CrossOver/Bottles/Steam"
            k.environment = e
            try? k.run()
            k.waitUntilExit()
            until = Date().addingTimeInterval(10)
            while running(steam) && Date() < until { Thread.sleep(forTimeInterval: 0.5) }
        }
        if running(steam) { fail("Steam didn't quit: quit it in CrossOver, then try again") }
        Thread.sleep(forTimeInterval: 1)
    }
    var env = ProcessInfo.processInfo.environment
    env["DYLD_INSERT_LIBRARIES"] = nil
    env["REX_BLOCK"] = block
    env["REX_SESSION"] = session
    env["PATH"] = path.joined(separator: ":")
    env["REXUI_CROSSOVER"] = crossover
    env["CX_GRAPHICS_BACKEND"] = "dxmt"
    env["REXUI_EMBED_EXE"] = "Endfield.exe"
    env["REXUI_EMBED_TARGET"] = target
    env["REXUI_WINE_LAYOUT"] = keys == "qwerty" ? "com.apple.keylayout.US" : nil
    env["REXUI_WINE_KEYS"] = keys == "dvorak" ? "dvorak" : nil
    let argv = [embed, "embed", "--crossover", "Steam", steamExe] + launchArgs
    let log = home + "/Library/Logs/endfield-game.log"
    var fa: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fa)
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&fa, 1, log, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    posix_spawn_file_actions_adddup2(&fa, 1, 2)
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    let cargs = argv.map { strdup($0) } + [nil]
    let cenv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
    let rc = posix_spawn(&started, embed, &fa, &attr, cargs, cenv)
    guard rc == 0 else { fail("couldn't start rexui embed: " + String(cString: strerror(rc))) }
    try? "\(started) \(keys)".write(toFile: steamPid, atomically: true, encoding: .utf8)
    note("Steam and Endfield (pid \(started)) for \(block)")
    emit(["started": Int(started), "phase": "steam"])
}

var phase = started > 0 ? "steam" : "game"
var seen = false
let handedAt = Date()
while true {
    Thread.sleep(forTimeInterval: 0.5)
    var st: Int32 = 0
    if started > 0, waitpid(started, &st, WNOHANG) == started {
        fail(seen ? "Endfield closed before it showed" : "Steam closed before Endfield started")
    }
    let up = running(game)
    if up && !seen {
        seen = true
        if phase != "game" {
            phase = "game"
            emit(["phase": phase])
        }
    } else if !up && seen {
        fail("Endfield closed before it showed")
    } else if !up && started == 0 && Date().timeIntervalSince(handedAt) > 120 {
        fail("Steam didn't start Endfield")
    }
}
