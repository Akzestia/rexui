// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
import AppKit

enum Tabs {
    static func start() {
        guard let rex = Rex.shared else { return }
        let ok = rex_body_hook(rex.stack, rex.stackWitnesses, Int32(rex.bodySlot))
        rexLog("tabs: \(rex.describe())\(ok ? "" : " (hook already installed)")")
    }

    static func windows(_ captured: Any) -> [AnyObject] {
        guard let hub = field(captured, rxs(RXN_136)), let session = field(hub, rxs(RXN_136)),
            let ws = field(session, rxs(RXN_006))
        else { return [] }
        return Mirror(reflecting: ws).children.map { $0.value as AnyObject }
    }

    static func id(_ window: AnyObject) -> String? { field(window, rxs(RXN_004)).map { "\($0)" } }

    static func hubs(_ captured: Any) -> [AnyObject] {
        if let wm = field(captured, rxs(RXN_042)), let cache = field(wm, rxs(RXN_045)),
            let all = field(cache, rxs(RXN_135))
        {
            let hubs = Mirror(reflecting: all).children.compactMap {
                field($0.value, rxs(RXN_003)).map { $0 as AnyObject }
            }
            if !hubs.isEmpty { return hubs }
        }
        return field(captured, rxs(RXN_136)).map { [$0 as AnyObject] } ?? []
    }

    static func otherSessionTabs(_ captured: Any) -> [String] {
        guard let current = session(captured) else { return [] }
        var selected: [String: String] = [:]
        if let wm = field(captured, rxs(RXN_042)), let sel = field(wm, rxs(RXN_046)) {
            for c in Mirror(reflecting: sel).children {
                if let k = field(c.value, "key"), let v = field(c.value, rxs(RXN_003)) { selected["\(k)"] = "\(v)" }
            }
        }
        return hubs(captured).compactMap { hub -> String? in
            guard let s = field(hub, rxs(RXN_136)).map({ $0 as AnyObject }), s !== current else { return nil }
            if (field(s, rxs(RXN_005)) as? String)?.hasPrefix("rexui-") == true { return nil }
            return field(s, rxs(RXN_004)).flatMap { selected["\($0)"] }
                ?? unwrap(field(s, rxs(RXN_047))).map { "\($0)" }
        }
    }

    static func session(_ captured: Any) -> AnyObject? {
        field(captured, rxs(RXN_136)).flatMap { field($0, rxs(RXN_136)) }.map { $0 as AnyObject }
    }
    static func sessionKey(_ s: AnyObject) -> String {
        field(s, rxs(RXN_004)).map { "\($0)" } ?? "\(ObjectIdentifier(s))"
    }

    static func shown(_ captured: Any) -> String? {
        unwrap(field(captured, rxs(RXN_044))).flatMap { field($0, rxs(RXN_048)) }.map { "\($0)" }
    }
}

protocol AnyOptional { static var empty: Any { get } }
extension Optional: AnyOptional { static var empty: Any { Optional<Wrapped>.none as Any } }

func field(_ v: Any, _ name: String) -> Any? { Mirror(reflecting: v).children.first { $0.label == name }?.value }

func fields(_ v: Any) -> [String: Any] {
    var out: [String: Any] = [:]
    for c in Mirror(reflecting: v).children { if let l = c.label, out[l] == nil { out[l] = c.value } }
    return out
}

func unwrap(_ v: Any?) -> Any? {
    guard let v else { return nil }
    let m = Mirror(reflecting: v)
    if m.displayStyle == .optional { return m.children.first.map { unwrap($0.value) } ?? nil }
    return v
}

func swiftValue(at p: UnsafeRawPointer, meta: UnsafeRawPointer) -> Any {
    func load<T>(_: T.Type) -> Any { p.assumingMemoryBound(to: T.self).pointee }
    return _openExistential(unsafeBitCast(meta, to: Any.Type.self), do: load)
}

func assign(_ v: Any, at p: UnsafeMutableRawPointer) {
    func put<T>(_ x: T) { p.assumingMemoryBound(to: T.self).pointee = x }
    _openExistential(v, do: put)
}

private func witnesses(_ meta: UnsafeRawPointer) -> UnsafeRawPointer {
    meta.load(fromByteOffset: -8, as: UnsafeRawPointer.self)
}
func destroyValue(_ p: UnsafeMutableRawPointer, meta: UnsafeRawPointer) {
    unsafeBitCast(
        witnesses(meta).load(fromByteOffset: 8, as: UnsafeRawPointer.self),
        to: (@convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer) -> Void).self)(p, meta)
    p.deallocate()
}

private let runtime = UnsafeMutableRawPointer(bitPattern: -2)
let swiftAllocObject = unsafeBitCast(
    dlsym(runtime, "swift_allocObject")!, to: (@convention(c) (UnsafeRawPointer, Int, Int) -> UnsafeRawPointer).self)
let swiftRelease = unsafeBitCast(dlsym(runtime, "swift_release")!, to: (@convention(c) (UnsafeRawPointer) -> Void).self)
let swiftRetain = unsafeBitCast(
    dlsym(runtime, "swift_retain")!, to: (@convention(c) (UnsafeRawPointer) -> UnsafeRawPointer).self)
let swiftWeakLoadStrong = unsafeBitCast(
    dlsym(runtime, "swift_weakLoadStrong")!, to: (@convention(c) (UnsafeMutableRawPointer) -> UnsafeRawPointer?).self)
let swiftWeakAssign = unsafeBitCast(
    dlsym(runtime, "swift_weakAssign")!,
    to: (@convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer?) -> UnsafeMutableRawPointer).self)

func classFieldOffset(_ object: AnyObject, _ name: String) -> Int? {
    var m: UnsafeRawPointer? = object_getClass(object).map { unsafeBitCast($0, to: UnsafeRawPointer.self) }
    while let meta = m, meta.load(fromByteOffset: 32, as: UInt.self) & 3 != 0 {
        let desc = meta.load(fromByteOffset: 64, as: UnsafeRawPointer.self)
        let names = RexImage.TypeDescriptor(address: desc).fieldNames
        let n = Int(desc.load(fromByteOffset: 36, as: UInt32.self))
        let vec = Int(desc.load(fromByteOffset: 40, as: UInt32.self))
        if names.count == n, let i = names.firstIndex(of: name) {
            return meta.load(fromByteOffset: vec * 8 + i * 8, as: Int.self)
        }
        m = meta.load(fromByteOffset: 8, as: UnsafeRawPointer?.self)
    }
    return nil
}

func rexLog(_ s: String) { rex_log(s) }

@_cdecl("rex_tabs_start") public func rexTabsStart() { Tabs.start() }

@_cdecl("rex_tab_count") public func rexTabCount() -> Int {
    guard let rex = Rex.shared, let src = rex_body_capture() else { return 0 }
    return Tabs.windows(swiftValue(at: src, meta: rex.stack)).count
}
