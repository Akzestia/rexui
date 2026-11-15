// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
import AppKit

enum Activity {
    static func raw(_ v: Any?) -> String {
        guard let v = unwrap(v) else { return "" }
        if let s = v as? String { return s }
        if let s = field(v, rxs(RXN_000)) as? String { return s }
        return ""
    }

    private static func text(_ v: Any?) -> String? {
        guard let s = unwrap(v) as? String, !s.isEmpty else { return nil }
        return s
    }

    private static func caseName(_ v: Any?) -> String {
        guard let v = unwrap(v) else { return "" }
        let s = String(describing: v)
        if s.hasPrefix("unknown(\""), s.hasSuffix("\")") { return String(s.dropFirst(9).dropLast(2)) }
        return s
    }

    static func snapshot() -> [[String: Any]] {
        guard let pa = RexApp.object(rxs(RXN_001)), let src = field(pa, rxs(RXN_134)),
            let adapters = field(src, rxs(RXN_002)),
            let sessions = field(adapters, rxs(RXN_135))
        else { return [] }
        var out: [[String: Any]] = []
        for entry in Mirror(reflecting: sessions).children {
            guard let hs = field(entry.value, rxs(RXN_003)), let s = unwrap(field(hs, rxs(RXN_136))) else { continue }
            let sf = fields(s)
            let sid = raw(sf[rxs(RXN_004)].flatMap { field($0, rxs(RXN_137)) })
            let label = (sf[rxs(RXN_005)] as? String) ?? ""
            var tabOf: [String: String] = [:]
            var tabLabel: [String: String] = [:]
            if let windows = sf[rxs(RXN_006)] {
                for w in Mirror(reflecting: windows).children {
                    let wf = fields(w.value)
                    let wid = raw(wf[rxs(RXN_004)])
                    if let st = wf[rxs(RXN_007)], let l = unwrap(field(st, rxs(RXN_008))) as? String {
                        tabLabel[wid] = l
                    }
                    if let ids = wf[rxs(RXN_009)] {
                        for b in Mirror(reflecting: ids).children { tabOf[raw(b.value)] = wid }
                    }
                }
            }
            guard let states = sf[rxs(RXN_010)] else { continue }
            for kv in Mirror(reflecting: states).children {
                let kvf = fields(kv.value)
                let block = raw(kvf["key"])
                guard !block.isEmpty, let state = kvf[rxs(RXN_003)], let meta = unwrap(field(state, rxs(RXN_011))),
                    let tm = field(meta, rxs(RXN_003)), "\(type(of: tm))".hasSuffix(rxs(RXN_012))
                else { continue }
                let tf = fields(tm)
                var e: [String: Any] = [
                    "block": block, "session": sid, "sessionLabel": label, "tab": tabOf[block] ?? "",
                    "tabLabel": tabLabel[tabOf[block] ?? ""] ?? "",
                ]
                if let p = unwrap(tf[rxs(RXN_013)]), let n = text(field(p, rxs(RXN_014))) { e["process"] = n }
                if let t = text(tf[rxs(RXN_015)]) { e["title"] = t }
                if let d = text(tf[rxs(RXN_016)]) { e["cwd"] = d }
                if let x = unwrap(tf[rxs(RXN_017)]), let code = field(x, rxs(RXN_018)) as? Int { e["lastExit"] = code }
                if let pr = unwrap(tf[rxs(RXN_019)]) {
                    let pf = fields(pr)
                    e["progressState"] = caseName(pf[rxs(RXN_138)])
                    if let v = unwrap(pf[rxs(RXN_019)]) as? UInt8 { e["progress"] = Double(v) / 100 }
                }
                var newest: Any?
                var at = Date.distantPast
                if let recs = tf[rxs(RXN_020)] {
                    for r in Mirror(reflecting: recs).children {
                        if let d = field(r.value, rxs(RXN_021)) as? Date, d >= at {
                            at = d
                            newest = r.value
                        }
                    }
                }
                if let r = newest {
                    let rf = fields(r)
                    e["status"] = caseName(rf[rxs(RXN_138)])
                    if let w = unwrap(rf[rxs(RXN_022)]) { e["waitReason"] = caseName(w) }
                    if let v = unwrap(rf[rxs(RXN_019)]) as? UInt8 { e["progress"] = Double(v) / 100 }
                    if let a = text(rf[rxs(RXN_023)]) ?? text(rf[rxs(RXN_024)]) { e["app"] = a }
                    if let t = text(rf[rxs(RXN_015)]) { e["statusTitle"] = t }
                    if let m = text(rf[rxs(RXN_025)]) { e["message"] = m }
                    e["updatedAt"] = floor(at.timeIntervalSince1970 * 1000)
                } else {
                    e["status"] = "idle"
                }
                out.append(e)
            }
        }
        return out
    }
}

@_cdecl("rex_activity") public func rexActivity() -> UnsafeMutableRawPointer? {
    guard RexDeps.on("activity"), RexApp.delegate != nil else { return nil }
    return Unmanaged.passRetained(Activity.snapshot() as NSArray).toOpaque()
}
