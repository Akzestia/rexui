// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
import AppKit

protocol AnySetInserting { func inserting(_ x: Any) -> Any? }
extension Set: AnySetInserting {
    func inserting(_ x: Any) -> Any? {
        guard let e = x as? Element else { return nil }
        var s = self
        s.insert(e)
        return s
    }
}

enum RexValues {
    static func meta(of v: Any) -> UnsafeRawPointer {
        unsafeBitCast(type(of: v) as Any.Type, to: UnsafeRawPointer.self)
    }

    static func edited(_ template: Any, _ edits: [String: (UnsafeMutableRawPointer) -> Void], check: (Any) -> Bool)
        -> Any?
    {
        let m = meta(of: template)
        let labels = Mirror(reflecting: template).children.map { $0.label ?? "" }
        let offsets = structFieldOffsets(m)
        guard labels.count == offsets.count, edits.keys.allSatisfy({ labels.contains($0) }) else {
            rexLog("rex values: \(type(of: template)) has \(labels), not \(edits.keys.sorted())")
            return nil
        }
        let size = m.load(fromByteOffset: -8, as: UnsafeRawPointer.self).load(fromByteOffset: 64, as: Int.self)
        let buf = UnsafeMutableRawPointer.allocate(byteCount: max(size, 1), alignment: 16)
        func put<T>(_ x: T) { buf.initializeMemory(as: T.self, repeating: x, count: 1) }
        _openExistential(template, do: put)
        for (name, write) in edits { write(buf + offsets[labels.firstIndex(of: name)!]) }
        let out = swiftValue(at: buf, meta: m)
        destroyValue(buf, meta: m)
        guard check(out) else {
            rexLog("rex values: a \(type(of: template)) made didn't read back as written; not used")
            return nil
        }
        return out
    }

    static func string(_ s: String) -> (UnsafeMutableRawPointer) -> Void {
        { $0.assumingMemoryBound(to: String.self).pointee = s }
    }
    static func date(_ d: Date) -> (UnsafeMutableRawPointer) -> Void {
        { $0.assumingMemoryBound(to: Date.self).pointee = d }
    }

    private static var ours: Set<String> = []
    static func isOurs(_ id: String) -> Bool { ours.contains(id) }

    static func glassNotice(title: String, body: String?, tone: String, symbol: String?, dismissible: Bool) -> String? {
        guard let wm = Reads.windowModel(), let off = classFieldOffset(wm, rxs(RXN_094)),
            let template = Notices.templatePresentation()
        else { return nil }
        let tones = ["accent", "success", "standard", "warning", "error"]
        let uuid = UUID()
        var edits: [String: (UnsafeMutableRawPointer) -> Void] = [
            rxs(RXN_004): { p in
                withUnsafeBytes(of: uuid.uuid) { p.copyMemory(from: $0.baseAddress!, byteCount: 16) }
                p.storeBytes(of: 0, toByteOffset: 16, as: UInt8.self)
            },
            rxs(RXN_015): string(title),
            rxs(RXN_032): { $0.assumingMemoryBound(to: Optional<String>.self).pointee = body },
            rxs(RXN_034): { $0.storeBytes(of: UInt8(tones.firstIndex(of: tone) ?? 2), as: UInt8.self) },
            rxs(RXN_036): { $0.storeBytes(of: dismissible, as: Bool.self) },
        ]
        if Mirror(reflecting: template).children.contains(where: { $0.label == rxs(RXN_207) }) {
            edits[rxs(RXN_207)] = { $0.storeBytes(of: false, as: Bool.self) }
        }
        if let s = symbol, String(describing: field(template, rxs(RXN_035)) ?? "").hasPrefix("symbol(") {
            edits[rxs(RXN_035)] = string(s)
        }
        guard
            let p = edited(
                template, edits,
                check: { v in
                    String(describing: field(v, rxs(RXN_004)) ?? "").contains(uuid.uuidString)
                        && (field(v, rxs(RXN_015)) as? String) == title
                        && String(describing: field(v, rxs(RXN_034)) ?? "")
                            == (tones.contains(tone) ? tone : "standard")
                        && (symbol == nil || edits[rxs(RXN_035)] == nil
                            || String(describing: field(v, rxs(RXN_035)) ?? "") == "symbol(\"\(symbol!)\")")
                })
        else { return nil }
        let base = UnsafeRawPointer(Unmanaged.passUnretained(wm).toOpaque())
        guard let fn = base.load(fromByteOffset: off, as: UnsafeRawPointer?.self) else { return nil }
        let ctx = base.load(fromByteOffset: off + 8, as: UnsafeRawPointer?.self)
        let m = meta(of: p)
        let size = m.load(fromByteOffset: -8, as: UnsafeRawPointer.self).load(fromByteOffset: 64, as: Int.self)
        let buf = UnsafeMutableRawPointer.allocate(byteCount: max(size, 1), alignment: 16)
        func put<T>(_ x: T) { buf.initializeMemory(as: T.self, repeating: x, count: 1) }
        _openExistential(p, do: put)
        if let ctx { _ = swiftRetain(ctx) }
        _ = rx_call_self(fn, ctx, buf, nil)
        if let ctx { swiftRelease(ctx) }
        destroyValue(buf, meta: m)
        let id = "posted(\(uuid))"
        ours.insert(id)
        return id
    }

    private static func receipts(for blocks: Set<String>) -> [(String, String, Date)] {
        guard let pa = RexApp.object(rxs(RXN_001)), let src = field(pa, rxs(RXN_134)),
            let adapters = field(src, rxs(RXN_002)),
            let sessions = field(adapters, rxs(RXN_135))
        else { return [] }
        var out: [(String, String, Date)] = []
        for entry in Mirror(reflecting: sessions).children {
            guard let hs = field(entry.value, rxs(RXN_003)), let s = unwrap(field(hs, rxs(RXN_136))),
                let states = field(s, rxs(RXN_010))
            else { continue }
            for kv in Mirror(reflecting: states).children {
                let block = Activity.raw(field(kv.value, "key"))
                guard blocks.contains(block), let st = field(kv.value, rxs(RXN_003)),
                    let meta = unwrap(field(st, rxs(RXN_011))),
                    let tm = field(meta, rxs(RXN_003))
                else { continue }
                if let recs = field(tm, rxs(RXN_020)) {
                    for r in Mirror(reflecting: recs).children {
                        if let id = field(r.value, rxs(RXN_004)) as? String,
                            let d = field(r.value, rxs(RXN_021)) as? Date
                        {
                            out.append((block, id, d))
                        }
                    }
                }
                if let f = unwrap(field(tm, rxs(RXN_095))), let id = field(f, rxs(RXN_096)) as? String,
                    let d = field(f, rxs(RXN_097)) as? Date
                {
                    out.append((block, id, d))
                }
            }
        }
        return out
    }

    static func markSeen(_ blocks: [String]) -> Int {
        guard let pa = RexApp.object(rxs(RXN_001)), let off = classFieldOffset(pa, rxs(RXN_098)),
            let seen = field(pa, rxs(RXN_098))
        else { return 0 }
        let ledger = field(pa, rxs(RXN_099)).map { $0 as AnyObject }
        let ledgerSet = ledger.flatMap { field($0, rxs(RXN_100)) }
        guard
            let template = Mirror(reflecting: seen).children.first?.value
                ?? ledgerSet.flatMap({ Mirror(reflecting: $0).children.first?.value })
        else {
            rexLog("activity: no seen receipt of Rex's to make others from yet")
            return 0
        }
        var set: Any = seen
        var lset: Any? = ledgerSet
        var added = 0
        for (block, record, at) in receipts(for: Set(blocks)) {
            guard
                let r = edited(
                    template, [rxs(RXN_101): string(block), rxs(RXN_096): string(record), rxs(RXN_021): date(at)],
                    check: { v in
                        Activity.raw(field(v, rxs(RXN_101))) == block && (field(v, rxs(RXN_096)) as? String) == record
                            && (field(v, rxs(RXN_021)) as? Date) == at
                    })
            else { return added }
            if let n = (set as? AnySetInserting)?.inserting(r) {
                set = n
                added += 1
            }
            if let l = lset, let n = (l as? AnySetInserting)?.inserting(r) { lset = n }
        }
        guard added > 0 else { return 0 }
        assign(set, at: UnsafeMutableRawPointer(Unmanaged.passUnretained(pa).toOpaque()) + off)
        if let ledger, let l = lset, let loff = classFieldOffset(ledger, rxs(RXN_100)) {
            assign(l, at: UnsafeMutableRawPointer(Unmanaged.passUnretained(ledger).toOpaque()) + loff)
        }
        return added
    }

    private static var models: [Weak] = []
    private static var walkedAt = -1e9
    final class Weak {
        weak var o: AnyObject?
        init(_ o: AnyObject) { self.o = o }
    }

    static func findState() -> [String: Any]? {
        func open() -> AnyObject? { models.compactMap { $0.o }.first { unwrap(field($0, rxs(RXN_102))) != nil } }
        var m = open()
        let now = CACurrentMediaTime()
        if m == nil, now - walkedAt > 1 {
            walkedAt = now
            for n in [rxs(RXN_154), rxs(RXN_155)] where NSClassFromString(n) != nil {
                models = heapObjects(n).map { Weak($0) }
                if !models.isEmpty { break }
            }
            m = open()
        }
        guard let model = m else { return nil }
        let snap = unwrap(field(model, rxs(RXN_103)))
        let count = snap.flatMap { field($0, rxs(RXN_104)) as? Int } ?? 0
        let sel = snap.flatMap { unwrap(field($0, rxs(RXN_142))) as? Int }.map { $0 + 1 } ?? 0
        return [
            "text": (field(model, rxs(RXN_105)) as? String) ?? "", "count": count, "selected": sel,
            "failure": (unwrap(field(model, rxs(RXN_106))) as? String) ?? "",
        ]
    }
}

@_cdecl("rex_glass_notice") public func rexGlassNotice(
    _ title: UnsafePointer<CChar>, _ body: UnsafePointer<CChar>?, _ tone: UnsafePointer<CChar>,
    _ symbol: UnsafePointer<CChar>?, _ dismissible: Bool
) -> UnsafeMutableRawPointer? {
    guard RexDeps.on("notices") else { return nil }
    return RexValues.glassNotice(
        title: String(cString: title), body: body.map { String(cString: $0) }, tone: String(cString: tone),
        symbol: symbol.map { String(cString: $0) }, dismissible: dismissible
    ).map { Unmanaged.passRetained($0 as NSString).toOpaque() }
}
@_cdecl("rex_notice_is_ours") public func rexNoticeIsOurs(_ id: UnsafePointer<CChar>) -> Bool {
    RexValues.isOurs(String(cString: id))
}
@_cdecl("rex_mark_seen") public func rexMarkSeen(_ blocks: UnsafeRawPointer) -> Int {
    guard RexDeps.on("seen") else { return 0 }
    return RexValues.markSeen(Unmanaged<NSArray>.fromOpaque(blocks).takeUnretainedValue() as? [String] ?? [])
}
@_cdecl("rex_find_state") public func rexFindState() -> UnsafeMutableRawPointer? {
    guard RexDeps.on("find") else { return nil }
    return RexValues.findState().map { Unmanaged.passRetained($0 as NSDictionary).toOpaque() }
}
