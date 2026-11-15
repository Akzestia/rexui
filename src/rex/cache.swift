// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
import Foundation
import MachO

enum RexCache {
    private static var found: [String: [String: Int]] = [:]
    private static var failed: [String: String] = [:]
    private static var loaded = false
    private static var path: String?
    private static var ids: (rex: String, rexui: String)?

    static func uuid(_ header: UnsafePointer<mach_header_64>) -> String? {
        var cmd = UnsafeRawPointer(header) + MemoryLayout<mach_header_64>.size
        for _ in 0..<header.pointee.ncmds {
            let lc = cmd.load(as: load_command.self)
            if lc.cmd == LC_UUID {
                let u = cmd.load(as: uuid_command.self).uuid
                return UUID(uuid: u).uuidString
            }
            cmd += Int(lc.cmdsize)
        }
        return nil
    }

    private static let reading = DispatchGroup()

    static func prefetch() {
        reading.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            if let image = RexImage.find() { read(image) }
            _ = (Lib.view, Lib.viewBody)
            reading.leave()
        }
        Reads.prefetchPalettes()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { RexDeps.report() }
    }

    private static func load(_ image: RexImage) {
        reading.wait()
        read(image)
    }

    private static func read(_ image: RexImage) {
        guard !loaded else { return }
        loaded = true
        guard let rex = uuid(image.header),
            let rexui = uuid(UnsafeRawPointer(#dsohandle).assumingMemoryBound(to: mach_header_64.self)),
            let home = getenv("HOME")
        else { return }
        ids = (rex, rexui)
        path = String(cString: home) + "/Library/Caches/rexui/rex-\(rex).txt"
        guard let fp = fopen(path, "r") else { return }
        defer { fclose(fp) }
        var bytes = [UInt8](repeating: 0, count: 16384)
        let n = fread(&bytes, 1, bytes.count, fp)
        guard n > 0, n < bytes.count else { return }
        var f: [String: [String: Int]] = [:]
        var x: [String: String] = [:]
        var sawRex = false
        var sawRexui = false
        for line in String(decoding: bytes[0..<n], as: UTF8.self).split(separator: "\n") {
            let w = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
            switch (w.first, w.count) {
            case ("rex", 2): sawRex = w[1] == rex
            case ("rexui", 2): sawRexui = w[1] == rexui
            case ("found", 4): if let v = Int(w[3]) { f[String(w[1]), default: [:]][String(w[2])] = v }
            case ("failed", 3...): x[String(w[1])] = w[2...].joined(separator: " ")
            default: break
            }
        }
        guard sawRex, sawRexui else { return }
        found = f
        failed = x
    }

    static func entry(_ image: RexImage, _ key: String) -> [String: Int]? {
        load(image)
        return found[key]
    }

    static func failure(_ image: RexImage, _ key: String) -> String? {
        load(image)
        return failed[key]
    }

    static func store(_ image: RexImage, _ key: String, _ value: [String: Int]) {
        load(image)
        guard found[key] != value || failed[key] != nil else { return }
        found[key] = value
        failed[key] = nil
        write()
    }

    static func fail(_ image: RexImage, _ key: String, _ why: String) {
        load(image)
        guard failed[key] != why else { return }
        found[key] = nil
        failed[key] = why
        write()
    }

    private static func write() {
        guard let path, let ids else { return }
        var out = "rex \(ids.rex)\nrexui \(ids.rexui)\n"
        for (k, v) in found.sorted(by: { $0.key < $1.key }) {
            for (n, o) in v.sorted(by: { $0.key < $1.key }) { out += "found \(k) \(n) \(o)\n" }
        }
        for (k, why) in failed.sorted(by: { $0.key < $1.key }) {
            out += "failed \(k) \(why.replacingOccurrences(of: "\n", with: " "))\n"
        }
        let u = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(out.utf8).write(to: u, options: .atomic)
    }
}

@_cdecl("rex_cache_prefetch") public func rexCachePrefetch() { RexCache.prefetch() }

extension RexImage {
    func offset(_ p: UnsafeRawPointer) -> Int { p - UnsafeRawPointer(header) }
    func at(_ off: Int?) -> UnsafeRawPointer? {
        guard let off, off > 0 else { return nil }
        let p = UnsafeRawPointer(header) + off
        return contains(p) && off & 3 == 0 ? p : nil
    }

    func word(_ off: Int?) -> UnsafeRawPointer? {
        guard let off, off > 0, off & 3 == 0, off < mappedSize else { return nil }
        return UnsafeRawPointer(header) + off
    }

    var mappedSize: Int {
        var cmd = UnsafeRawPointer(header) + MemoryLayout<mach_header_64>.size
        var text = 0
        var end = 0
        for _ in 0..<header.pointee.ncmds {
            let lc = cmd.load(as: load_command.self)
            if lc.cmd == LC_SEGMENT_64 {
                let seg = cmd.load(as: segment_command_64.self)
                let name = withUnsafeBytes(of: seg.segname) {
                    String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
                }
                if name == "__TEXT" { text = Int(seg.vmaddr) }
                if name != "__PAGEZERO", name != "__LINKEDIT" { end = max(end, Int(seg.vmaddr + seg.vmsize)) }
            }
            cmd += Int(lc.cmdsize)
        }
        return end - text
    }
}
