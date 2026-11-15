// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
import AppKit

enum Panes {
    private static var broken = false

    private static var kinds: [ObjectIdentifier: UInt8] = [:]
    private static func kind(_ v: NSView) -> UInt8 {
        let c = ObjectIdentifier(type(of: v))
        if let k = kinds[c] { return k }
        let n = NSStringFromClass(type(of: v))
        let k: UInt8 = n.contains("AppKitPlatformViewHost") && n.contains(rxs(RXN_156)) ? 2 : 0
        kinds[c] = k
        return k
    }

    private static func bridgeHosts(_ v: NSView, _ out: inout [NSView], _ depth: Int = 0) {
        let k = kind(v)
        if depth > 16 { return }
        if k == 2 {
            out.append(v)
            return
        }
        for s in v.subviews { bridgeHosts(s, &out, depth + 1) }
    }

    private static func fail(_ what: String) -> [String: NSView]? {
        if !broken { rexLog("pane drag: \(what) not found (a Rex update?): off") }
        broken = true
        return nil
    }

    private struct Last {
        weak var host: NSView?
        weak var ctl: AnyObject?
        var storage: UInt, count: Int, at: Double
        var out: [String: NSView]
    }
    private static var last: [ObjectIdentifier: Last] = [:]
    private static var offsets: [ObjectIdentifier: Int] = [:]
    private static var toldUncached = false

    private static func word(_ o: AnyObject, _ off: Int) -> UInt {
        UnsafeRawPointer(Unmanaged.passUnretained(o).toOpaque()).load(fromByteOffset: off, as: UInt.self)
    }

    private static func hostsStorage(_ ctl: AnyObject) -> (UInt, Int)? {
        let k = ObjectIdentifier(type(of: ctl))
        if offsets[k] == nil { offsets[k] = classFieldOffset(ctl, rxs(RXN_040)) ?? -1 }
        guard let off = offsets[k], off > 0 else { return nil }
        let storage = word(ctl, off)
        guard storage > 0x1_0000_0000 else { return nil }
        return (storage, UnsafeRawPointer(bitPattern: storage)!.load(fromByteOffset: 16, as: Int.self))
    }

    private static func sweep() {
        if last.values.contains(where: { $0.host?.window == nil }) {
            last = last.filter { $0.value.host?.window != nil }
        }
    }

    private static func panes(of host: NSView) -> [String: NSView]? {
        let k = ObjectIdentifier(host)
        let now = ProcessInfo.processInfo.systemUptime
        if let l = last[k], l.host === host, let ctl = l.ctl, now - l.at < 2, let (st, n) = hostsStorage(ctl),
            st == l.storage, n == l.count, l.out.values.allSatisfy({ $0.isDescendant(of: host) })
        {
            return l.out
        }
        guard let out = read(host) else {
            last[k] = nil
            return nil
        }
        var why = "no controller"
        if let layout = field(host, "coreRepresentedViewProvider"), let lazy = field(layout, rxs(RXN_041)),
            let c = unwrap(lazy), Mirror(reflecting: c).displayStyle == .class
        {
            let ctl = c as AnyObject
            if let (st, n) = hostsStorage(ctl) {
                if n == out.count {
                    last[k] = Last(host: host, ctl: ctl, storage: st, count: n, at: now, out: out)
                    why = ""
                } else {
                    why = "\(rxs(RXN_040)) count \(n), read \(out.count)"
                }
            } else {
                why = "\(rxs(RXN_040)) offset \(offsets[ObjectIdentifier(type(of: ctl))] ?? -2) in \(type(of: ctl))"
            }
        }
        if !why.isEmpty && !toldUncached {
            toldUncached = true
            rexLog("panes: reads not cached (\(why)): by reflection each time")
        }
        return out
    }

    private static func read(_ host: NSView) -> [String: NSView]? {
        guard let layout = field(host, "coreRepresentedViewProvider") else {
            return fail("coreRepresentedViewProvider")
        }
        guard let lazy = field(layout, rxs(RXN_041)) else { return fail("the layout view's controller") }
        guard let ctl = unwrap(lazy) else { return [:] }
        guard Mirror(reflecting: ctl).displayStyle == .class, let hosts = field(ctl, rxs(RXN_040)) else {
            return fail("\(rxs(RXN_040))")
        }
        var out: [String: NSView] = [:]
        for kv in Mirror(reflecting: hosts).children {
            let pair = Array(Mirror(reflecting: kv.value).children)
            guard pair.count == 2, let id = field(pair[0].value, rxs(RXN_000)) as? String else {
                return fail("\(rxs(RXN_144)).rawValue")
            }
            guard let v = pair[1].value as? NSView else { return fail("a pane host view") }
            out[id] = v
        }
        return out
    }

    private static func hosts(_ c: NSView) -> [NSView] {
        var all: [NSView] = []
        bridgeHosts(c, &all)
        return all.sorted { $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height }
    }

    static func tiled(_ c: NSView) -> [String: NSView]? {
        if broken { return nil }
        sweep()
        guard let h = hosts(c).first else { return [:] }
        return panes(of: h)
    }

    static func all(_ c: NSView) -> [String: (view: NSView, floating: Bool)]? {
        if broken { return nil }
        sweep()
        var out: [String: (view: NSView, floating: Bool)] = [:]
        for (i, h) in hosts(c).enumerated() {
            guard let d = panes(of: h) else { return nil }
            for (id, v) in d { out[id] = (v, i > 0) }
        }
        return out
    }

    static func floating(_ c: NSView, _ id: String) -> (pane: NSView, layer: NSView)? {
        if broken { return nil }
        let all = hosts(c)
        guard let tiledHost = all.first else { return nil }
        for h in all.dropFirst() {
            guard let p = panes(of: h)?[id] else { continue }
            var top = h
            while let s = top.superview, s !== c, !tiledHost.isDescendant(of: s) { top = s }
            return (p, top)
        }
        return nil
    }
}

@_cdecl("rex_panes") public func rexPanes(_ content: UnsafeRawPointer) -> UnsafeMutableRawPointer? {
    guard RexDeps.on("pane-views"), let d = Panes.tiled(Unmanaged<NSView>.fromOpaque(content).takeUnretainedValue())
    else { return nil }
    return Unmanaged.passRetained(d as NSDictionary).toOpaque()
}

@_cdecl("rex_floating_pane") public func rexFloatingPane(
    _ content: UnsafeRawPointer, _ id: UnsafePointer<CChar>,
    _ pane: UnsafeMutablePointer<UnsafeRawPointer?>,
    _ layer: UnsafeMutablePointer<UnsafeRawPointer?>
) -> Bool {
    guard RexDeps.on("pane-views"),
        let f = Panes.floating(Unmanaged<NSView>.fromOpaque(content).takeUnretainedValue(), String(cString: id))
    else { return false }
    pane.pointee = UnsafeRawPointer(Unmanaged.passUnretained(f.pane).toOpaque())
    layer.pointee = UnsafeRawPointer(Unmanaged.passUnretained(f.layer).toOpaque())
    return true
}

@_cdecl("rex_all_panes") public func rexAllPanes(_ content: UnsafeRawPointer) -> UnsafeMutableRawPointer? {
    guard RexDeps.on("pane-views"), let d = Panes.all(Unmanaged<NSView>.fromOpaque(content).takeUnretainedValue())
    else { return nil }
    let out = NSMutableDictionary()
    for (id, p) in d { out[id] = ["view": p.view, "floating": p.floating] as NSDictionary }
    return Unmanaged.passRetained(out).toOpaque()
}

@_cdecl("rex_slide_busy") public func rexSlideBusy() -> Bool { Slide.busy }
