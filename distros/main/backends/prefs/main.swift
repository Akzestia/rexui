// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

let rexui = RexuiBackend()

let name = CommandLine.arguments.dropFirst().first ?? "default"
guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else {
    FileHandle.standardError.write("rexui-prefs: a name, not a path\n".data(using: .utf8)!)
    exit(2)
}
let dir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/rexui/prefs", isDirectory: true)
let file = dir.appendingPathComponent(name + ".json")

var prefs: [String: Any] = [:]
func load() -> [String: Any] {
    guard let data = try? Data(contentsOf: file),
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return obj
}
prefs = load()

func emit() {
    rexui.emit(["state": prefs])
}

func save() {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if let data = try? JSONSerialization.data(withJSONObject: prefs, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: file, options: .atomic)
    }
}

func keep(_ key: String, _ from: String) -> String? {
    guard !key.contains("/"), !key.isEmpty else { return nil }
    let src = URL(fileURLWithPath: (from as NSString).expandingTildeInPath)
    let ext = src.pathExtension.isEmpty ? "" : "." + src.pathExtension.lowercased()
    let id = UUID().uuidString.prefix(8).lowercased()
    let dst = dir.appendingPathComponent("\(name)-\(key)-\(id)\(ext)")
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: src, to: dst)
    } catch {
        FileHandle.standardError.write(
            "rexui-prefs: keeping \(from): \(error.localizedDescription)\n".data(using: .utf8)!)
        return nil
    }
    if let old = prefs[key] as? String, old != dst.path,
        URL(fileURLWithPath: old).deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL,
        URL(fileURLWithPath: old).lastPathComponent.hasPrefix("\(name)-\(key)-")
    {
        try? FileManager.default.removeItem(atPath: old)
    }
    return dst.path
}

let q = DispatchQueue(label: "rexui-prefs")
func same(_ a: [String: Any], _ b: [String: Any]) -> Bool { NSDictionary(dictionary: a).isEqual(to: b) }
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let fd = open(dir.path, O_EVTONLY)
let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: q)
watch.setEventHandler {
    let now = load()
    if !same(now, prefs) {
        prefs = now
        emit()
    }
}
if fd >= 0 { watch.resume() }

q.sync { emit() }
while let line = rexui.readLine() {
    q.sync {
        guard let data = line.data(using: .utf8),
            let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        var changed = false
        for (k, v) in msg["set"] as? [String: Any] ?? [:] {
            if v is NSNull {
                changed = prefs.removeValue(forKey: k) != nil || changed
            } else if !same([k: v], prefs[k].map { [k: $0] } ?? [:]) {
                prefs[k] = v
                changed = true
            }
        }
        for (k, v) in msg["keep"] as? [String: Any] ?? [:] {
            guard let from = v as? String, let copy = keep(k, from) else { continue }
            prefs[k] = copy
            changed = true
        }
        guard changed else { return }
        save()
        emit()
    }
}
