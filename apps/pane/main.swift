// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
import Foundation

func resolve(_ arg: String) -> String? {
    let fm = FileManager.default
    if arg.contains("/") || arg.hasSuffix(".rui") {
        let url = URL(
            fileURLWithPath: (arg as NSString).expandingTildeInPath,
            relativeTo: URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true))
        return fm.fileExists(atPath: url.path) ? url.standardizedFileURL.path : nil
    }
    let named = (shownDistro() as NSString).appendingPathComponent("panes/\(arg).rui")
    return fm.fileExists(atPath: named) ? named : nil
}

func shownDistro() -> String {
    if let d = ProcessInfo.processInfo.environment["REXUI_DISTRO"] { return d }
    let p = Process()
    let out = Pipe()
    p.executableURL = URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/rexui"))
    p.arguments = ["current"]
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else {
        return (NSHomeDirectory() as NSString).appendingPathComponent(".config/rex/distros/main")
    }
    p.waitUntilExit()
    let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

func isAddress(_ arg: String) -> Bool {
    if arg.contains("://") || arg.hasPrefix("about:") { return true }
    if arg.hasSuffix(".rui") || arg.hasPrefix("/") || arg.hasPrefix("~") || arg.hasPrefix(".") { return false }
    let host = arg.split(separator: "/", maxSplits: 1).first.map(String.init) ?? arg
    if host.hasPrefix("localhost") { return true }
    return host.contains(".") && !host.contains(" ") && resolve(arg) == nil
}

let args = CommandLine.arguments
func usage() -> Never {
    rexPaneLine(
        "usage: rexui pane <file.rui | a widget's name: the distro's panes/<name>.rui> [args...]\n       rexui pane <url> | web [url]"
    )
    exit(2)
}
guard args.count >= 2 else { usage() }
var path: String?
var web: String?
var rest = Array(args.dropFirst(2))
if isAddress(args[1]) {
    web = args[1]
} else if let p = resolve(args[1]) {
    path = p
} else if args[1] == "web" {
    web = rest.first ?? ""
    rest = Array(rest.dropFirst())
} else {
    usage()
}
rest = rest.map { a in
    guard !a.isEmpty, !a.hasPrefix("/"), !a.hasPrefix("~"), !isAddress(a) else { return a }
    let fm = FileManager.default
    let full = URL(fileURLWithPath: a, relativeTo: URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true))
        .standardizedFileURL.path
    return fm.fileExists(atPath: full) ? full : a
}
guard let block = ProcessInfo.processInfo.environment["REX_BLOCK"] else {
    rexPaneLine("rexui pane: not in a Rex pane ($REX_BLOCK unset)")
    exit(2)
}

let name = path.map { ($0 as NSString).lastPathComponent } ?? "web.rui"
Terminal.claim(name)

final class Holder {
    let block, name: String
    let path, web: String?
    let rest: [String]
    var fd: Int32 = -1
    var reader: DispatchSourceRead?
    var pending = Data()

    init(block: String, path: String?, web: String?, rest: [String], name: String) {
        self.block = block
        self.path = path
        self.web = web
        self.rest = rest
        self.name = name
    }

    func tick() {
        if fd >= 0 { return }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let p = PaneLink.socketPath.utf8CString
        withUnsafeMutableBytes(of: &addr.sun_path) { b in
            for (i, c) in p.prefix(b.count - 1).enumerated() { b[i] = UInt8(bitPattern: c) }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else {
            close(s)
            Terminal.shown = false
            return Terminal.status("waiting for rexui… (ctrl+c quits)")
        }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        fd = s
        var msg: [String: Any] = [
            "hello": 1, "block": block, "session": ProcessInfo.processInfo.environment["REX_SESSION"] ?? "",
            "pid": Int(getpid()), "name": name, "args": rest,
        ]
        if let path { msg["rui"] = path }
        if let web { msg["web"] = web }
        var hello = try! JSONSerialization.data(withJSONObject: msg)
        hello.append(0x0A)
        _ = hello.withUnsafeBytes { write(s, $0.baseAddress, $0.count) }
        Terminal.shown = true
        Terminal.status(nil)
        let r = DispatchSource.makeReadSource(fileDescriptor: s, queue: .main)
        r.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(s, &buf, buf.count)
            if n <= 0 { return self.lost() }
            self.pending.append(contentsOf: buf[0..<n])
            while let nl = self.pending.firstIndex(of: 0x0A) {
                let line = self.pending[self.pending.startIndex..<nl]
                self.pending.removeSubrange(self.pending.startIndex...nl)
                if let m = try? JSONSerialization.jsonObject(with: line) as? [String: Any], m["quit"] != nil { exit(0) }
            }
        }
        r.resume()
        reader = r
    }

    func lost() {
        reader?.cancel()
        reader = nil
        close(fd)
        fd = -1
        pending = Data()
        Terminal.shown = false
    }
}

let holder = Holder(block: block, path: path, web: web, rest: rest, name: name)
holder.tick()
Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in holder.tick() }
RunLoop.main.run()
