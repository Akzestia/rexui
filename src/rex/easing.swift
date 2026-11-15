// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
import AppKit

private enum MMAlignment { case origin, center, trailing }
private enum MMPlacement {
    case offset(CGVector)
    case hold, still
}
private struct MMCurve { var x1 = 0.0, y1 = 0.0, x2 = 1.0, y2 = 1.0 }
private struct MMFade { var delay = 0.0, duration = 0.0, curve = MMCurve() }
private struct EaseElement<ID: Hashable> {
    var frame: CGRect
    var shown = true
    var scale: CGFloat = 1
    var under: ID? = nil
    var pair: ID? = nil
    var pairAlign = MMAlignment.origin
    var spot = MMPlacement.still
    var container: ID? = nil
    var appear = MMFade(), disappear = MMFade(), passOn = MMFade()
    var ownsAlpha = false
}
private struct MMActor {
    var layer: CALayer
    var place: (CGRect) -> Void
    var sized: Bool
    var zoomLayer: CALayer?
}
private struct MMPlan<ID: Hashable> {
    var tracks: [ID: Int]
    var rests: [ID: Int]
    var landing: Double
    var departed: Set<ID>
}
private struct MMHole<ID: Hashable> {
    var layer: CALayer
    var front: ID
    var behind: ID
    var fill: CALayer?
}
private struct MMFns<ID: Hashable> {
    var holes: (MMPlan<ID>) -> [MMHole<ID>]
    var actor: (ID) -> MMActor?
}

struct RexEasing {
    let driver: UnsafeRawPointer
    let allocate: UnsafeRawPointer
    let apply: UnsafeRawPointer

    static let shared: RexEasing? = RexDeps.on("easing") ? timed("easing") { resolve() } : nil

    private static func fail(_ what: String) -> RexEasing? {
        rexLog("easing: \(what) not found in this Rex build; easing \"rex\" is the spatial curve")
        return nil
    }

    private static func resolve() -> RexEasing? {
        guard let image = RexImage.find() else { return nil }
        let intMeta = unsafeBitCast(Int.self as Any.Type, to: UnsafeRawPointer.self)
        guard let hashable = Lib.core("$sSHMp"),
            let wt = swift_conformsToProtocol(intMeta, hashable)
        else { return fail("Int: Hashable") }
        func instantiate(_ d: RexImage.TypeDescriptor, _ qualified: String) -> UnsafeRawPointer? {
            guard let acc = d.accessor, image.contains(acc) else { return nil }
            let meta = unsafeBitCast(
                acc, to: (@convention(c) (Int, UnsafeRawPointer, UnsafeRawPointer) -> UnsafeRawPointer).self)(
                    0, intMeta, wt)
            return _typeName(unsafeBitCast(meta, to: Any.Type.self), qualified: true).hasSuffix(qualified) ? meta : nil
        }
        let drivers = image.types(named: rxs(RXN_159), kind: 16, generic: true)
        guard drivers.count == 1, let driver = instantiate(drivers[0], rxs(RXN_160)) else {
            return fail(rxs(RXN_159))
        }
        let elements = image.types(named: rxs(RXN_146), kind: 17, generic: true).filter {
            guard let p = $0.parent, p.kind == 18 else { return false }
            return p.name == rxs(RXN_161)
        }
        let actors = image.types(named: rxs(RXN_147), kind: 17, generic: true).filter {
            $0.parent?.address == drivers[0].address
        }
        guard elements.count == 1, actors.count == 1,
            let element = instantiate(elements[0], rxs(RXN_162)),
            let actor = instantiate(actors[0], rxs(RXN_163))
        else { return fail("\(rxs(RXN_161)).Element or \(rxs(RXN_159)).Actor") }
        func size(_ m: UnsafeRawPointer) -> Int {
            m.load(fromByteOffset: -8, as: UnsafeRawPointer.self).load(fromByteOffset: 64, as: Int.self)
        }
        let ours: [Int] = [
            \EaseElement<Int>.frame, \.shown, \.scale, \.under, \.pair, \.pairAlign, \.spot, \.container,
            \.appear, \.disappear, \.passOn, \.ownsAlpha,
        ].map { MemoryLayout<EaseElement<Int>>.offset(of: $0)! }
        guard size(element) == MemoryLayout<EaseElement<Int>>.size, structFieldOffsets(element) == ours,
            size(actor) == MemoryLayout<MMActor>.size, structFieldOffsets(actor) == [0, 8, 24, 32]
        else {
            return fail("\(rxs(RXN_161)).Element and \(rxs(RXN_159)).Actor as rexui knows them (their layout changed)")
        }

        let inits = vtableInits(drivers[0])
        guard inits.count == 1, image.contains(inits[0]) else { return fail("\(rxs(RXN_159))'s init (\(inits.count))") }
        guard
            let g = (2..<64).first(where: {
                driver.load(fromByteOffset: $0 * 8, as: UnsafeRawPointer?.self) == intMeta
                    && driver.load(fromByteOffset: $0 * 8 + 8, as: UnsafeRawPointer?.self) == wt
            })
        else {
            return fail("\(rxs(RXN_159))'s generic arguments")
        }
        var near: [UnsafeRawPointer] = []
        if let c = RexCache.entry(image, "easing"), let f = image.at(c["apply"]), abs(f - inits[0]) < 0x40000,
            takesSix(image, f, generics: g * 8)
        {
            near = [f]
        } else if let why = RexCache.failure(image, "easing") {
            return fail("\(why) (as an earlier launch of this build found)")
        } else {
            near = image.functions(from: inits[0] - 0x40000, to: inits[0] + 0x40000).filter {
                takesSix(image, $0, generics: g * 8)
            }
            guard near.count == 1 else {
                RexCache.fail(image, "easing", "\(rxs(RXN_159)).apply (\(near.count) matches)")
                return fail("\(rxs(RXN_159)).apply (\(near.count) matches)")
            }
            RexCache.store(image, "easing", ["apply": image.offset(near[0])])
        }
        let mm = RexEasing(driver: driver, allocate: inits[0], apply: near[0])
        if let d = mm.make() {
            let s = mm.spring(d)
            rexLog(
                String(
                    format:
                        "easing: Rex's driver found (init 0x%lx, apply 0x%lx; spring mass %g stiffness %g damping %g)",
                    Int(bitPattern: inits[0]) - image.slide, Int(bitPattern: near[0]) - image.slide, s.0, s.1, s.2))
        }
        return mm
    }

    private static func takesSix(_ image: RexImage, _ f: UnsafeRawPointer, generics: Int) -> Bool {
        var isa: UInt32?
        var loaded = Set<Int>()
        var live = Set<UInt32>()
        var defined = Set<UInt32>()
        func read(_ r: UInt32) { if r <= 5, !defined.contains(r) { live.insert(r) } }
        for i in 0..<40 {
            let x = image.insn(f + 4 * i)
            if x & 0xfc00_0000 == 0x9400_0000 { break }
            if x & 0xffff_ffe0 == 0xf940_0280 { isa = x & 31 }
            if let m = isa, (x >> 5) & 31 == m {
                if x & 0xffc0_0000 == 0xf940_0000 { loaded.insert(Int((x >> 10) & 0xfff) * 8) }
                if x & 0xffc0_0000 == 0x3dc0_0000 {
                    let o = Int((x >> 10) & 0xfff) * 16
                    loaded.formUnion([o, o + 8])
                }
            }
            if x & 0xffc0_0000 == 0xa900_0000 {
                read(x & 31)
                read((x >> 10) & 31)
            }
            if x & 0xffc0_0000 == 0xf900_0000 { read(x & 31) }
            if x & 0x7fe0_ffe0 == 0x2a00_03e0 {
                read((x >> 16) & 31)
                defined.insert(x & 31)
            }
        }
        return loaded.contains(generics) && loaded.contains(generics + 8) && live.isSuperset(of: 0...5)
    }

    private static func vtableInits(_ d: RexImage.TypeDescriptor) -> [UnsafeRawPointer] {
        let ks = d.flags >> 16
        guard d.kind == 16, ks & 0x8000 != 0 else { return [] }
        var p = d.address + 44
        if d.isGeneric {
            let params = Int(p.load(fromByteOffset: 8, as: UInt16.self))
            let reqs = Int(p.load(fromByteOffset: 10, as: UInt16.self))
            p += 16 + ((params + 3) & ~3) + 12 * reqs
        }
        if ks & 0x2000 != 0 { p += 4 }
        switch ks & 3 {
        case 1: p += 12
        case 2: p += 4
        default: break
        }
        let n = Int(p.load(fromByteOffset: 4, as: UInt32.self))
        return (0..<n).compactMap { i in
            let e = p + 8 + 8 * i
            return e.load(as: UInt32.self) & 0xf == 1 ? rel(e + 4) : nil
        }
    }

    func make() -> AnyObject? {
        guard let d = rx_call_self(allocate, driver, nil, nil) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(d).takeRetainedValue()
    }

    func spring(_ d: AnyObject) -> (Double, Double, Double) {
        let p = UnsafeRawPointer(Unmanaged.passUnretained(d).toOpaque())
        return (
            p.load(fromByteOffset: 0x10, as: Double.self), p.load(fromByteOffset: 0x18, as: Double.self),
            p.load(fromByteOffset: 0x20, as: Double.self)
        )
    }

    func apply(_ d: AnyObject, _ frame: CGRect, layer: CALayer, animated: Bool, place: @escaping (CGRect) -> Void) {
        let elements: [Int: EaseElement<Int>] = [1: EaseElement(frame: frame)]
        let fns = MMFns<Int>(
            holes: { _ in [] }, actor: { _ in MMActor(layer: layer, place: place, sized: true, zoomLayer: nil) })
        withExtendedLifetime((elements, fns, d)) {
            var f = fns
            let closures = withUnsafeBytes(of: &f) { Array($0.bindMemory(to: UInt.self)) }
            var frame = [UInt](repeating: 0, count: 12)
            frame[0] = UInt(bitPattern: apply)
            frame[1] = UInt(bitPattern: Unmanaged.passUnretained(d).toOpaque())
            frame[2] = unsafeBitCast(elements, to: UInt.self)
            frame[3] = animated ? 1 : 0
            frame[4...7] = closures[0...3]
            frame.withUnsafeMutableBytes { rx_call_self6($0.baseAddress!) }
            for i in 8...10 { swift_bridgeObjectRelease(frame[i]) }
        }
    }
}

private let swift_bridgeObjectRelease = unsafeBitCast(
    Lib.core("swift_bridgeObjectRelease")!,
    to: (@convention(c) (UInt) -> Void).self)

private final class Mover: NSObject {
    var driver: AnyObject
    var last = CGRect.null
    init(_ d: AnyObject) { driver = d }
}
private var moverKey = 0

@_cdecl("rex_easing_move") public func rexEasingMove(_ l: UnsafeRawPointer, _ frame: CGRect, _ animated: Bool) -> Bool {
    let layer = Unmanaged<CALayer>.fromOpaque(l).takeUnretainedValue()
    guard let mm = RexEasing.shared else { return false }
    var mover = objc_getAssociatedObject(layer, &moverKey) as? Mover
    var animate = animated
    if mover == nil || mover!.last != layer.frame {
        guard let d = mm.make() else { return false }
        if let m = mover {
            m.driver = d
        } else {
            mover = Mover(d)
            objc_setAssociatedObject(layer, &moverKey, mover, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        animate = false
    }
    let m = mover!
    mm.apply(m.driver, frame, layer: layer, animated: animate) { [weak layer] r in layer?.frame = r }
    m.last = layer.frame
    return true
}

@_cdecl("rex_easing_spring") public func rexEasingSpring(_ out: UnsafeMutablePointer<Double>) -> Bool {
    guard let mm = RexEasing.shared, let d = mm.make() else { return false }
    (out[0], out[1], out[2]) = mm.spring(d)
    return true
}
