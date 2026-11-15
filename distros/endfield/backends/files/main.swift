// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT
import Foundation

let rexui = RexuiBackend()
let home = NSHomeDirectory()
let folders =
    CommandLine.arguments.count > 1
    ? Array(CommandLine.arguments.dropFirst()).map { ($0 as NSString).expandingTildeInPath }
    : ["Downloads", "Pictures", "Movies"].map { home + "/" + $0 }
let images: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"]
let videos: Set<String> = ["mp4", "mov", "m4v", "webm", "mkv"]
let fm = FileManager.default
var last: [[String: String]] = []

func scan() {
    var found: [(path: String, name: String, kind: String, date: Date)] = []
    for f in folders {
        guard let names = try? fm.contentsOfDirectory(atPath: f) else { continue }
        for n in names where !n.hasPrefix(".") {
            let ext = (n as NSString).pathExtension.lowercased()
            let kind = images.contains(ext) ? "image" : videos.contains(ext) ? "video" : ""
            if kind.isEmpty { continue }
            let p = f + "/" + n
            let d = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date ?? .distantPast
            found.append((p, n, kind, d))
        }
    }
    let media = found.sorted { $0.date > $1.date }.prefix(16).map {
        ["path": $0.path, "name": $0.name, "kind": $0.kind]
    }
    if media == last { return }
    last = Array(media)
    rexui.emit(["state": ["media": media]])
}

scan()
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now() + 20, repeating: 20)
timer.setEventHandler { scan() }
timer.resume()
DispatchQueue.global().async {
    while rexui.readLine() != nil {}
    exit(0)
}
dispatchMain()
