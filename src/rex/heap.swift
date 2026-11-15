// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
import Foundation
import ObjectiveC

private struct Search {
    var isas: (UInt, UInt, UInt, UInt, UInt, UInt, UInt, UInt) = (0, 0, 0, 0, 0, 0, 0, 0)
    var count = 0
    var found: UnsafeMutablePointer<(UInt, UInt)>
    var capacity: Int
}

private let reader:
    @convention(c) (task_t, vm_address_t, vm_size_t, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> kern_return_t =
        { _, address, _, local in
            local?.pointee = UnsafeMutableRawPointer(bitPattern: UInt(address))
            return KERN_SUCCESS
        }

private let recorder:
    @convention(c) (task_t, UnsafeMutableRawPointer?, UInt32, UnsafeMutablePointer<vm_range_t>?, UInt32) -> Void = {
        _, ctx, _, ranges, count in
        guard let ranges, let s = ctx?.assumingMemoryBound(to: Search.self) else { return }
        var i = 0
        while i < Int(count) {
            let r = ranges[i]
            i += 1
            if r.size < 16 { continue }
            let isa = UnsafeRawPointer(bitPattern: UInt(r.address))!.load(as: UInt.self) & 0x0000_7fff_ffff_fff8
            if isa == 0 { continue }
            let t = s.pointee.isas
            if isa == t.0 || isa == t.1 || isa == t.2 || isa == t.3 || isa == t.4 || isa == t.5 || isa == t.6
                || isa == t.7,
                s.pointee.count < s.pointee.capacity
            {
                s.pointee.found[s.pointee.count] = (isa, UInt(r.address))
                s.pointee.count += 1
            }
        }
    }

func heapInstances(_ names: [String]) -> [String: [UInt]] {
    var byIsa: [UInt: String] = [:]
    for n in names.prefix(8) {
        if let c = NSClassFromString(n) { byIsa[unsafeBitCast(c, to: UInt.self)] = n }
    }
    let isas = Array(byIsa.keys) + Array(repeating: UInt(0), count: 8)
    let s = UnsafeMutablePointer<Search>.allocate(capacity: 1)
    s.initialize(
        to: Search(
            isas: (isas[0], isas[1], isas[2], isas[3], isas[4], isas[5], isas[6], isas[7]),
            found: .allocate(capacity: 4096), capacity: 4096))
    defer {
        s.pointee.found.deallocate()
        s.deallocate()
    }
    var zones: UnsafeMutablePointer<vm_address_t>?
    var nz: UInt32 = 0
    guard malloc_get_all_zones(mach_task_self_, nil, &zones, &nz) == KERN_SUCCESS, let zones else { return [:] }
    let task = mach_task_self_
    let type = UInt32(MALLOC_PTR_IN_USE_RANGE_TYPE)
    let rd = reader
    let rc = recorder
    for z in 0..<Int(nz) {
        guard let zone = UnsafeMutablePointer<malloc_zone_t>(bitPattern: UInt(zones[z])),
            let intro = zone.pointee.introspect, let en = intro.pointee.enumerator
        else { continue }
        intro.pointee.force_lock(zone)
        _ = en(task, s, type, zones[z], rd, rc)
        intro.pointee.force_unlock(zone)
    }
    var res: [String: [UInt]] = [:]
    for i in 0..<s.pointee.count { res[byIsa[s.pointee.found[i].0]!, default: []].append(s.pointee.found[i].1) }
    return res
}

private let swift_tryRetain = unsafeBitCast(
    dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_tryRetain")!,
    to: (@convention(c) (UnsafeRawPointer) -> UnsafeRawPointer?).self)

private let tryRetainSel = NSSelectorFromString("_tryRetain")

private func cfn<T>(_ name: String, _: T.Type) -> T {
    unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)!, to: T.self)
}
private let rawSuperclass = cfn("class_getSuperclass", (@convention(c) (UnsafeRawPointer) -> UnsafeRawPointer?).self)
private let rawInstanceSize = cfn("class_getInstanceSize", (@convention(c) (UnsafeRawPointer) -> Int).self)
private let rawImp = cfn(
    "class_getMethodImplementation", (@convention(c) (UnsafeRawPointer, Selector) -> UnsafeRawPointer?).self)
private let nsObjectClass = UnsafeRawPointer(Unmanaged.passUnretained(NSObject.self as AnyObject).toOpaque())

func object(_ p: UInt, _ className: String) -> AnyObject? {
    guard let raw = UnsafeRawPointer(bitPattern: p), let expected = NSClassFromString(className) else { return nil }
    let size = malloc_size(raw)
    let isa = raw.load(as: UInt.self)
    guard size >= 16, isa & 0x0000_7fff_ffff_fff8 == unsafeBitCast(expected, to: UInt.self),
        let cls = UnsafeRawPointer(bitPattern: isa & 0x0000_7fff_ffff_fff8)
    else { return nil }
    let want = rawInstanceSize(cls)
    guard want >= 16, size >= want, size <= max(want * 2, want + 64) else { return nil }
    var objc = isa & ~UInt(0x0000_7fff_ffff_fff8) != 0
    var c: UnsafeRawPointer? = cls
    while let k = c, !objc {
        objc = k == nsObjectClass
        c = rawSuperclass(k)
    }
    if objc {
        guard let imp = rawImp(cls, tryRetainSel) else { return nil }
        let f = unsafeBitCast(imp, to: (@convention(c) (UnsafeRawPointer, Selector) -> Bool).self)
        guard f(raw, tryRetainSel) else { return nil }
    } else {
        let rc = raw.load(fromByteOffset: 8, as: UInt.self)
        if rc >> 62 == 3 {
            guard let side = UnsafeRawPointer(bitPattern: rc << 3), malloc_size(side) >= 16,
                side.load(as: UInt.self) == p
            else { return nil }
        } else {
            guard rc & 1 == 1, rc & 0xffff_fffe != 0 else { return nil }
        }
        guard swift_tryRetain(raw) != nil else { return nil }
    }
    return Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue()
}

func heapObjects(_ className: String) -> [AnyObject] {
    (heapInstances([className])[className] ?? []).compactMap { object($0, className) }
}
