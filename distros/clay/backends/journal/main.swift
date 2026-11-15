// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT
import Foundation

let rexui = RexuiBackend()

let arg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "~/Documents/Journal"
let folder = URL(fileURLWithPath: (arg as NSString).expandingTildeInPath, isDirectory: true)
let shown = folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
let fm = FileManager.default

func emit(_ obj: [String: Any]) {
    rexui.emit(obj)
}

func today() -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: Date())
}

func valid(_ day: String) -> String? {
    day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil ? day : nil
}

func file(_ day: String) -> URL { folder.appendingPathComponent(day + ".md") }

func days() -> [String] {
    let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
    return Array(
        names.filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) }.compactMap(valid).sorted(by: >).prefix(60))
}

func words(_ text: String) -> Int { text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count }

var day = today()

func state(_ text: String) {
    let saved =
        (try? fm.attributesOfItem(atPath: file(day).path)[.modificationDate] as? Date).map { $0.timeIntervalSince1970 }
        ?? 0
    emit(["state": ["folder": shown, "day": day, "words": words(text), "saved": saved, "days": days()]])
}

func open(_ d: String) {
    day = d
    let text = (try? String(contentsOf: file(d), encoding: .utf8)) ?? ""
    emit(["page": ["day": d, "text": text]])
    state(text)
}

func save(_ d: String, _ text: String) {
    let url = file(d)
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        try? fm.removeItem(at: url)
    } else {
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch {
            FileHandle.standardError.write(
                "clay-journal: \(url.path): \(error.localizedDescription)\n".data(using: .utf8)!)
        }
    }
    if d == day { state(text) }
}

open(day)
while let line = rexui.readLine() {
    guard let data = line.data(using: .utf8), let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { continue }
    if let d = msg["open"] as? String, let d = valid(d) { open(d) }
    if let s = msg["save"] as? [String: Any], let d = (s["day"] as? String).flatMap(valid),
        let text = s["text"] as? String
    {
        save(d, text)
    }
}
