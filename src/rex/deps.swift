// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
import Foundation
import MachO
import ObjectiveC

enum RexDeps {
    struct Feature {
        let id: String
        let without: String
        var entries: [[[String]]] = []
    }

    static func list() -> ([Feature], String?) {
        var size: UInt = 0
        guard
            let p = getsectiondata(
                UnsafeRawPointer(#dsohandle).assumingMemoryBound(to: mach_header_64.self), "__TEXT", "__rexui_deps",
                &size)
        else { return ([], "no list in this dylib") }
        let text = String(decoding: UnsafeRawBufferPointer(start: p, count: Int(size)), as: UTF8.self)
        var out: [Feature] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if raw.hasPrefix("feature ") {
                let head = line.dropFirst(8)
                let id =
                    head.split(separator: ":", maxSplits: 1).first.map {
                        String($0).trimmingCharacters(in: .whitespaces)
                    } ?? ""
                guard !id.isEmpty else { continue }
                out.append(
                    Feature(
                        id: id, without: line.range(of: " | without: ").map { String(line[$0.upperBound...]) } ?? ""))
                continue
            }
            let w = line.split(separator: " ").map(String.init)
            guard !out.isEmpty, let k = w.first else { continue }
            if k == "|", w.count > 1, !out[out.count - 1].entries.isEmpty {
                out[out.count - 1].entries[out[out.count - 1].entries.count - 1].append(Array(w.dropFirst()))
            } else {
                out[out.count - 1].entries.append([w])
            }
        }
        return (out, out.isEmpty ? "the list in this dylib has no feature" : nil)
    }

    private static var offIDs: Set<String>?

    static func on(_ id: String) -> Bool {
        guard Thread.isMainThread else { return true }
        if offIDs == nil {
            offIDs = []
            if let image = RexImage.find(), let ok = RexCache.entry(image, "deps") {
                offIDs = Set(ok.filter { $0.value == 0 }.map(\.key))
            }
        }
        return offIDs!.isEmpty || !offIDs!.contains(id)
    }

    static func report() {
        guard let image = RexImage.find() else { return }
        DispatchQueue.global(qos: .utility).async {
            let (features, why) = list()
            DispatchQueue.main.async { report(image, features, why) }
        }
    }

    private static func report(_ image: RexImage, _ features: [Feature], _ why: String?) {
        guard !features.isEmpty else { return rexLog("rex deps: \(why ?? "no list in this dylib")") }
        if let ok = RexCache.entry(image, "deps") {
            let off = features.filter { ok[$0.id] == 0 }
            for f in off {
                rexLog(
                    "rex deps: \(f.id) off: \(RexCache.failure(image, "deps.\(f.id)") ?? "?")\(f.without.isEmpty ? "" : "; " + f.without)"
                )
            }
            rexLog(
                "rex deps: \(features.count - off.count) of \(features.count) features have what they use (as checked before for this build)"
            )
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let index = SwiftIndex(image)
            var result: [(Feature, String?)] = []
            for f in features {
                var why: String?
                for alts in f.entries {
                    var first: String?
                    for e in alts {
                        let w = check(e, image, index)
                        if w == nil {
                            first = nil
                            break
                        }
                        if first == nil { first = w }
                    }
                    if let w = first { why = (why.map { $0 + "; " } ?? "") + w }
                }
                result.append((f, why))
            }
            let ms = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6
            DispatchQueue.main.async {
                var ok: [String: Int] = [:]
                for (f, why) in result {
                    ok[f.id] = why == nil ? 1 : 0
                    if let why {
                        RexCache.fail(image, "deps.\(f.id)", why)
                        rexLog("rex deps: \(f.id) off: \(why)\(f.without.isEmpty ? "" : "; " + f.without)")
                    }
                }
                RexCache.store(image, "deps", ok)
                offIDs = Set(ok.filter { $0.value == 0 }.map(\.key))
                let off = result.filter { $0.1 != nil }.count
                rexLog(
                    String(
                        format:
                            "rex deps: %d of %d features have what they use (checked in %.1f ms, in the background)",
                        result.count - off, result.count, ms))
            }
        }
    }

    private static func check(_ e: [String], _ image: RexImage, _ index: SwiftIndex) -> String? {
        guard let k = e.first else { return nil }
        let a = Array(e.dropFirst())
        switch k {
        case "objc":
            let names = a.filter { $0 != "|" }
            return names.contains { NSClassFromString($0) != nil } ? nil : "no class \(names.joined(separator: " or "))"
        case "method":
            guard a.count == 2, let c = NSClassFromString(a[0]) else { return "no class \(a.first ?? "")" }
            return class_getInstanceMethod(c, NSSelectorFromString(a[1])) != nil ? nil : "\(a[0]) has no \(a[1])"
        case "ivar":
            guard a.count == 2, let c = NSClassFromString(a[0]) else { return "no class \(a.first ?? "")" }
            return class_getInstanceVariable(c, a[1]) != nil ? nil : "\(a[0]) has no ivar \(a[1])"
        case "subclass":
            return index.find(SwiftIndex.swiftName(a.first ?? ""), kind: 16).1
        case "type":
            guard a.count == 2 else { return nil }
            return index.find(a[0], kind: ["class": 16, "struct": 17, "enum": 18][a[1]]).1
        case "vtable":
            let (t, err) = index.find(a.first ?? "", kind: 16)
            guard let t else { return err }
            let n = t.vtable.filter { $0.kind == 1 && $0.impl.map(image.contains) == true }.count
            return n == 1 ? nil : "\(a[0]) has \(n) vtable initializers"
        case "read":
            return index.chain(a)
        case "resource":
            guard let path = a.first, let res = Bundle.main.resourceURL else { return nil }
            return FileManager.default.fileExists(atPath: res.appendingPathComponent(path).path)
                ? nil : "no file \(path)"
        default:
            return nil
        }
    }
}

private struct SwiftIndex {
    let image: RexImage
    var byLast: [String: [(name: String, d: RexImage.TypeDescriptor)]] = [:]
    var byAddress: [UnsafeRawPointer: String] = [:]

    init(_ image: RexImage) {
        self.image = image
        guard let s = RexImage.section(image.header, "__TEXT", "__swift5_types"), let base = s.baseAddress else {
            return
        }
        var names: [UnsafeRawPointer: String] = [:]
        for off in stride(from: 0, to: s.count, by: 4) {
            let rel32 = base.load(fromByteOffset: off, as: Int32.self)
            guard rel32 & 3 == 0, rel32 != 0 else { continue }
            let d = RexImage.TypeDescriptor(address: base + off + Int(rel32))
            let n = SwiftIndex.name(d.address, image, &names, 0)
            byAddress[d.address] = n
            byLast[String(n.split(separator: ".").last ?? ""), default: []].append((n, d))
        }
    }

    static func name(_ d: UnsafeRawPointer, _ image: RexImage, _ memo: inout [UnsafeRawPointer: String], _ depth: Int)
        -> String
    {
        if let n = memo[d] { return n }
        guard depth < 16 else { return "" }
        let flags = d.load(as: UInt32.self)
        let kind = flags & 0x1f
        let parent = relIndirect(d + 4)
        var n: String
        switch kind {
        case 0, 3, 16, 17, 18:
            let own = rel(d + 8).map { String(cString: $0.assumingMemoryBound(to: CChar.self)) } ?? "?"
            let up = parent.map { name($0, image, &memo, depth + 1) } ?? ""
            n = up.isEmpty ? own : up + "." + own
        case 1:
            n = ""
            if let m = rel(d + 8) {
                let b = m.load(as: UInt8.self)
                if b == 1, let t = rel(m + 1) {
                    n = name(t, image, &memo, depth + 1)
                } else if b == 2, let slot = rel(m + 1), let t = slot.load(as: UnsafeRawPointer?.self) {
                    n = name(t, image, &memo, depth + 1)
                } else {
                    n = plainIdentifiers(m)
                }
            }
        default:
            n = parent.map { name($0, image, &memo, depth + 1) } ?? ""
        }
        memo[d] = n
        return n
    }

    static func plainIdentifiers(_ m: UnsafeRawPointer) -> String {
        var out: [String] = []
        var p = m
        for _ in 0..<16 {
            var b = p.load(as: UInt8.self)
            while b != 0, !(48...57).contains(b), b >= 0x20 {
                p += 1
                b = p.load(as: UInt8.self)
            }
            guard (48...57).contains(b) else { break }
            var len = 0
            while (48...57).contains(p.load(as: UInt8.self)) {
                len = len * 10 + Int(p.load(as: UInt8.self) - 48)
                p += 1
            }
            out.append(String(decoding: UnsafeRawBufferPointer(start: p, count: len), as: UTF8.self))
            p += len
        }
        return out.joined(separator: ".")
    }

    static func swiftName(_ n: String) -> String {
        guard n.hasPrefix("_Tt") else { return n }
        var s = Substring(n.dropFirst(3))
        var ext = false
        var toks: [String] = []
        while let c = s.first, c.isUppercase {
            if c == "E" { ext = true }
            s = s.dropFirst()
        }
        while !s.isEmpty {
            while let c = s.first, c.isUppercase { s = s.dropFirst() }
            let digits = s.prefix { $0.isNumber }
            guard let len = Int(digits) else { break }
            s = s.dropFirst(digits.count)
            toks.append(String(s.prefix(len)))
            s = s.dropFirst(len)
        }
        if ext, !toks.isEmpty { toks.removeFirst() }
        return toks.joined(separator: ".")
    }

    func find(_ name: String, kind: UInt32? = nil) -> (RexImage.TypeDescriptor?, String?) {
        let last = String(name.split(separator: ".").last ?? "")
        let hits = (byLast[last] ?? []).filter {
            ($0.name == name || $0.name.hasSuffix("." + name)) && (kind == nil || $0.d.kind == kind)
        }
        if hits.count == 1 { return (hits[0].d, nil) }
        if let exact = hits.first(where: { $0.name == name }), hits.filter({ $0.name == name }).count == 1 {
            return (exact.d, nil)
        }
        return (nil, hits.isEmpty ? "no type \(name)" : "\(name) is \(hits.count) types")
    }

    func fields(_ d: RexImage.TypeDescriptor) -> [String: (refs: [UnsafeRawPointer], dict: Bool, keyIsRex: Bool)] {
        guard let fd = rel(d.address + 16) else { return [:] }
        let size = Int(fd.load(fromByteOffset: 10, as: UInt16.self))
        let n = Int(fd.load(fromByteOffset: 12, as: UInt32.self))
        var out: [String: (refs: [UnsafeRawPointer], dict: Bool, keyIsRex: Bool)] = [:]
        for i in 0..<min(n, 4096) {
            let r = fd + 16 + i * size
            guard let np = rel(r + 8) else { continue }
            let name = String(cString: np.assumingMemoryBound(to: CChar.self))
            var refs: [UnsafeRawPointer] = []
            var dict = false
            var keyIsRex = false
            if let m = rel(r + 4) {
                dict =
                    m.load(as: UInt8.self) == 0x53 && m.load(fromByteOffset: 1, as: UInt8.self) == 0x44
                    && m.load(fromByteOffset: 2, as: UInt8.self) == 0x79
                var p = m
                for j in 0..<512 {
                    let b = p.load(as: UInt8.self)
                    if b == 0 { break }
                    if (1...0x17).contains(b) {
                        var t: UnsafeRawPointer?
                        if b == 1 { t = rel(p + 1) } else if b == 2 { t = rel(p + 1)?.load(as: UnsafeRawPointer?.self) }
                        if let t, byAddress[t] != nil {
                            if refs.isEmpty, dict, j == 3 { keyIsRex = true }
                            refs.append(t)
                        }
                        p += 5
                    } else if (0x18...0x1f).contains(b) {
                        p += 9
                    } else {
                        p += 1
                    }
                }
            }
            out[name] = (refs, dict, keyIsRex)
        }
        return out
    }

    func chain(_ a: [String]) -> String? {
        guard let root = a.first else { return nil }
        var (t, err) = find(root)
        guard var cur = t else { return err }
        var pending: (key: UnsafeRawPointer?, value: UnsafeRawPointer?)?
        let steps = Array(a.dropFirst())
        for (i, step) in steps.enumerated() {
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let name = parts[0]
            if let pd = pending, name == "key" || name == "value" {
                pending = nil
                guard let d = name == "key" ? pd.key : pd.value else {
                    return "\(byAddress[cur.address] ?? "?")'s \(name) isn't Rex's"
                }
                cur = RexImage.TypeDescriptor(address: d)
                continue
            }
            let fs = fields(cur)
            guard let f = fs[name] else { return "\(byAddress[cur.address] ?? "?") has no field \(name)" }
            if parts.count == 2 {
                (t, err) = find(parts[1])
                guard let nt = t else { return "\(name) as \(parts[1]): \(err ?? "")" }
                cur = nt
                continue
            }
            if i == steps.count - 1 { break }
            let next = steps[i + 1].split(separator: ":").first.map(String.init) ?? ""
            if f.dict, next == "key" || next == "value" {
                pending = (f.keyIsRex ? f.refs.first : nil, f.refs.last)
                continue
            }
            let uniq = f.refs.reduce(into: [UnsafeRawPointer]()) { if !$0.contains($1) { $0.append($1) } }
            guard uniq.count == 1 else { return "\(byAddress[cur.address] ?? "?").\(name): not one type" }
            cur = RexImage.TypeDescriptor(address: uniq[0])
        }
        return nil
    }
}
