// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
import AppKit

enum RexWindow {
    static func windowModel() -> AnyObject? {
        guard let rex = Rex.shared, let src = rex_body_capture(),
            let wm = field(swiftValue(at: src, meta: rex.stack), rxs(RXN_042)), type(of: wm) is AnyClass
        else { return nil }
        return wm as AnyObject
    }

    static let presenters = [
        "commandPalette": rxs(RXN_119), "sessionPicker": rxs(RXN_120), "themePicker": rxs(RXN_121),
        "activity": rxs(RXN_122), "shortcuts": rxs(RXN_123), "sessions": rxs(RXN_124),
        "goToDirectory": rxs(RXN_125), "movePaneToTab": rxs(RXN_126),
        "switchHost": rxs(RXN_127), "removeHost": rxs(RXN_128), "restartServer": rxs(RXN_129),
    ]

    static func call(_ name: String) -> Bool {
        guard let fieldName = presenters[name], let wm = windowModel(), let off = classFieldOffset(wm, fieldName) else {
            return false
        }
        let base = UnsafeRawPointer(Unmanaged.passUnretained(wm).toOpaque())
        guard var fn = base.load(fromByteOffset: off, as: UnsafeRawPointer?.self) else { return false }
        let held = base.load(fromByteOffset: off + 8, as: UnsafeRawPointer?.self)
        var ctx = held
        if let held { _ = swiftRetain(held) }
        defer { if let held { swiftRelease(held) } }
        if fn == Wraps.gateTrampoline, let g = ctx {
            let gate = Unmanaged<ClosureGate>.fromOpaque(g).takeUnretainedValue()
            fn = gate.fn
            ctx = gate.ctx
        }
        _ = rx_call_self(fn, ctx, nil, nil)
        return true
    }

    static func pendingKeys() -> [String: Any] {
        guard let ac = RexApp.object(rxs(RXN_130)), let path = field(ac, rxs(RXN_131)) else { return [:] }
        let modes =
            field(path, rxs(RXN_132)).map {
                Mirror(reflecting: $0).children.compactMap { field($0.value, rxs(RXN_014)) as? String }
            } ?? []
        var keys: [String] = []
        if let pk = unwrap(field(path, rxs(RXN_067))), let list = field(pk, rxs(RXN_067)) {
            keys = Mirror(reflecting: list).children.map {
                Activity.raw($0.value).isEmpty ? String(describing: $0.value) : Activity.raw($0.value)
            }
        }
        return ["modes": modes, "keys": keys]
    }
}

@_cdecl("rex_present") public func rexPresent(_ name: UnsafePointer<CChar>) -> Bool {
    RexDeps.on("present") && RexWindow.call(String(cString: name))
}

@_cdecl("rex_pending_keys") public func rexPendingKeys() -> UnsafeMutableRawPointer? {
    guard RexDeps.on("keys-pending") else { return nil }
    return Unmanaged.passRetained(RexWindow.pendingKeys() as NSDictionary).toOpaque()
}

final class ClosureWrap {
    let fn: UnsafeRawPointer
    let ctx: UnsafeRawPointer?
    let note: @convention(c) (UnsafeRawPointer) -> Void
    init(fn: UnsafeRawPointer, ctx: UnsafeRawPointer?, note: @convention(c) (UnsafeRawPointer) -> Void) {
        self.fn = fn
        self.ctx = ctx
        self.note = note
    }
    deinit { if let ctx { swiftRelease(ctx) } }
}

final class ClosureGate {
    let fn: UnsafeRawPointer
    let ctx: UnsafeRawPointer?
    let note: @convention(c) (UnsafeRawPointer) -> Bool
    init(fn: UnsafeRawPointer, ctx: UnsafeRawPointer?, note: @convention(c) (UnsafeRawPointer) -> Bool) {
        self.fn = fn
        self.ctx = ctx
        self.note = note
    }
    deinit { if let ctx { swiftRelease(ctx) } }
}

enum Wraps {
    private static weak var model: AnyObject?
    private static var focus: ClosureWrap?
    private static var activity: ClosureGate?
    private static var offsets: [String: Int] = [:]
    static let trampoline = unsafeBitCast(rx_wrap_trampoline as @convention(c) () -> Void, to: UnsafeRawPointer.self)
    static let gateTrampoline = unsafeBitCast(
        rx_gate_trampoline as @convention(c) () -> Void, to: UnsafeRawPointer.self)

    private static func slot(_ name: String) -> UnsafeMutableRawPointer? {
        if model == nil {
            model = RexWindow.windowModel()
            offsets = [:]
        }
        guard let wm = model else { return nil }
        if offsets[name] == nil { offsets[name] = classFieldOffset(wm, name) }
        guard let off = offsets[name] else { return nil }
        return UnsafeMutableRawPointer(Unmanaged.passUnretained(wm).toOpaque()) + off
    }

    static func activityPopover() {
        guard let p = slot(rxs(RXN_122)), let fn = p.load(as: UnsafeRawPointer?.self), fn != gateTrampoline else {
            return
        }
        let ctx = p.load(fromByteOffset: 8, as: UnsafeRawPointer?.self)
        let g = ClosureGate(fn: fn, ctx: ctx, note: { _ in rex_activity_asked() })
        p.storeBytes(
            of: UnsafeRawPointer(Unmanaged.passRetained(g).toOpaque()), toByteOffset: 8, as: UnsafeRawPointer.self)
        p.storeBytes(of: gateTrampoline, as: UnsafeRawPointer.self)
        if activity == nil { rexLog("activity: Rex's \(rxs(RXN_122)) gated (activity.delegate)") }
        activity = g
    }

    static func focusFailure() {
        guard let p = slot(rxs(RXN_133)), let fn = p.load(as: UnsafeRawPointer?.self), fn != trampoline else { return }
        let ctx = p.load(fromByteOffset: 8, as: UnsafeRawPointer?.self)
        let w = ClosureWrap(fn: fn, ctx: ctx, note: { _ in rex_focus_edge() })
        p.storeBytes(
            of: UnsafeRawPointer(Unmanaged.passRetained(w).toOpaque()), toByteOffset: 8, as: UnsafeRawPointer.self)
        p.storeBytes(of: trampoline, as: UnsafeRawPointer.self)
        if focus == nil { rexLog("keys: Rex's \(rxs(RXN_133)) wrapped (onFocusEdge)") }
        focus = w
    }
}

@_cdecl("rex_wrap_closures") public func rexWrapClosures() {
    if RexDeps.on("focus-edge") { Wraps.focusFailure() }
    Wraps.activityPopover()
}
