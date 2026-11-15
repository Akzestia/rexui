// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
import AppKit

enum RexApp {
    private static weak var cached: AnyObject?

    static var delegate: AnyObject? {
        if let d = cached { return d }
        guard let sd = NSApp.delegate, let d = unwrap(field(sd, "appDelegate")), type(of: d) is AnyClass else {
            return nil
        }
        cached = d as AnyObject
        return cached
    }

    static func object(_ name: String) -> AnyObject? {
        guard let d = delegate, let v = unwrap(field(d, name)), type(of: v) is AnyClass else { return nil }
        return v as AnyObject
    }
}

enum Notices {
    private static weak var center: AnyObject?
    private static var missing = false

    static func glassCenter() -> AnyObject? {
        if let c = center { return c }
        guard !missing else { return nil }
        guard let relay = RexApp.object(rxs(RXN_139)), let off = classFieldOffset(relay, rxs(RXN_026)) else {
            missing = true
            rexLog("notices: Rex's notice center not found (its field in the event relay); glass notices not seen")
            return nil
        }
        let base = UnsafeRawPointer(Unmanaged.passUnretained(relay).toOpaque())
        guard let fn = base.load(fromByteOffset: off, as: UnsafeRawPointer?.self) else { return nil }
        let ctx = base.load(fromByteOffset: off + 8, as: UnsafeRawPointer?.self)
        guard let r = rx_call_self(fn, ctx, nil, nil) else { return nil }
        let c = Unmanaged<AnyObject>.fromOpaque(r).takeRetainedValue()
        guard NSStringFromClass(type(of: c)).hasSuffix(rxs(RXN_027)) else {
            missing = true
            rexLog("notices: \(rxs(RXN_026)) gave a \(type(of: c)); glass notices not seen")
            return nil
        }
        center = c
        return c
    }

    static func centerPresentation(_ c: AnyObject) -> Any? {
        if let p = field(c, rxs(RXN_031)) { return p }
        guard let lc = field(c, rxs(RXN_202)) else { return nil }
        for state in [rxs(RXN_203), rxs(RXN_204), rxs(RXN_205)] {
            guard let payload = field(lc, state) else { continue }
            let posted: Any? =
                field(payload, rxs(RXN_206)) != nil ? payload : Mirror(reflecting: payload).children.first?.value
            return posted.flatMap { field($0, rxs(RXN_206)) }
        }
        return nil
    }

    static func templatePresentation() -> Any? {
        if let c = glassCenter(), let p = centerPresentation(c) { return p }
        return hostInputs().flatMap { field($0, rxs(RXN_031)) }
    }

    private static func text(_ v: Any?) -> String? {
        guard let v = unwrap(v) else { return nil }
        if let s = v as? String { return s.isEmpty ? nil : s }
        return String(describing: v)
    }

    private static weak var hostView: NSView?
    private static weak var inputs: AnyObject?

    static func host() -> NSView? {
        if let h = hostView, h.window != nil { return h }
        for w in NSApp.windows {
            guard let c = w.contentView, let chrome = chromeView(c.superview ?? c, 0),
                let h = unwrap(field(chrome, rxs(RXN_028))) as? NSView
            else { continue }
            hostView = h
            inputs = nil
            return h
        }
        return nil
    }

    private static func chromeView(_ v: NSView, _ depth: Int) -> NSView? {
        if NSStringFromClass(type(of: v)).hasSuffix(rxs(RXN_029)) { return v }
        guard depth < 8 else { return nil }
        for s in v.subviews { if let c = chromeView(s, depth + 1) { return c } }
        return nil
    }

    private static func hostInputs() -> AnyObject? {
        if let i = inputs { return i }
        guard let h = host() else { return nil }
        var m: Mirror? = Mirror(reflecting: h)
        var root: Any?
        while let mm = m, root == nil {
            root = mm.children.first { $0.label == "_rootView" }?.value
            m = mm.superclassMirror
        }
        var v: Any? = root.flatMap { field($0, "storage") }.flatMap { field($0, "view") }
        for _ in 0..<4 where v != nil {
            if let i = field(v!, rxs(RXN_030)), type(of: i) is AnyClass {
                inputs = i as AnyObject
                return inputs
            }
            v = field(v!, "content")
        }
        return nil
    }

    static var hostWanted: (() -> Bool)?

    static func presentation() -> [String: Any]? {
        var source: Any?
        if let i = hostInputs() {
            guard hostWanted?() ?? !(host()?.isHidden ?? true) else { return nil }
            source = field(i, rxs(RXN_031))
        } else if let c = glassCenter() {
            source = centerPresentation(c)
        }
        guard let p = source else { return nil }
        var id = ""
        var out: [String: Any] = [:]
        for ch in Mirror(reflecting: p).children {
            switch ch.label {
            case rxs(RXN_004): id = String(describing: ch.value)
            case rxs(RXN_015): out["title"] = text(ch.value) ?? ""
            case rxs(RXN_032): out["body"] = text(ch.value) ?? ""
            case rxs(RXN_140): if let s = text(ch.value) { out["scrolling"] = s }
            case rxs(RXN_033): if let f = unwrap(ch.value) as? Double { out["progress"] = f }
            case rxs(RXN_207): out["transient"] = (ch.value as? Bool) ?? false
            case rxs(RXN_034): out["tone"] = String(describing: ch.value)
            case rxs(RXN_035): out["indicator"] = String(describing: ch.value)
            case rxs(RXN_036): out["dismissible"] = (ch.value as? Bool) ?? false
            case rxs(RXN_037):
                out["actions"] = Mirror(reflecting: ch.value).children.compactMap {
                    text(field($0.value, rxs(RXN_015)))
                }
            default: break
            }
        }
        guard id != "empty", !id.isEmpty else { return nil }
        out["id"] = id
        return out
    }
}

extension Notices {
    private static weak var remote: AnyObject?
    private static var looks = 0, lookedAt = CACurrentMediaTime()
    static func remoteNotice() -> String? {
        let now = CACurrentMediaTime()
        if remote == nil, looks < 5, now - lookedAt > (looks == 0 ? 5 : 60) {
            looks += 1
            lookedAt = now
            for n in [rxs(RXN_148), rxs(RXN_149)]
            where NSClassFromString(n) != nil {
                remote = heapObjects(n).first
                if remote != nil { break }
            }
            if remote == nil, looks == 5 {
                rexLog(
                    "notices: Rex's remote action notices not found (remote action messages are seen only as they show)"
                )
            }
        }
        guard let r = remote, let cur = unwrap(field(r, rxs(RXN_038))), let text = field(cur, rxs(RXN_039)) as? String,
            !text.isEmpty
        else { return nil }
        return text
    }
}

@_cdecl("rex_remote_notice") public func rexRemoteNotice() -> UnsafeMutableRawPointer? {
    guard RexDeps.on("notices") else { return nil }
    return Notices.remoteNotice().map { Unmanaged.passRetained($0 as NSString).toOpaque() }
}

@_cdecl("rex_notice_host") public func rexNoticeHost() -> UnsafeRawPointer? {
    guard RexDeps.on("notices") else { return nil }
    return Notices.host().map { UnsafeRawPointer(Unmanaged.passUnretained($0).toOpaque()) }
}

@_cdecl("rex_notice_set_wanted") public func rexNoticeSetWanted(_ fn: (@convention(c) () -> Bool)?) {
    Notices.hostWanted = fn.map { f in { f() } }
}

@_cdecl("rex_notice_presentation") public func rexNoticePresentation() -> UnsafeMutableRawPointer? {
    guard RexDeps.on("notices"), let p = Notices.presentation() else { return nil }
    return Unmanaged.passRetained(p as NSDictionary).toOpaque()
}
