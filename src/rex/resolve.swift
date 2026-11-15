// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
import Foundation

struct Rex {
    let image: RexImage
    let stack: UnsafeRawPointer
    let stackWitnesses: UnsafeMutablePointer<UnsafeRawPointer?>
    let bodySlot: Int
    static let shared: Rex? = RexDeps.on("tabs") ? timed("tabs") { resolve() } : nil

    private static func fail(_ what: String) -> Rex? {
        rexLog("tabs: \(what) not found in this Rex build; live tab previews are off")
        return nil
    }

    private static func failed(_ image: RexImage, _ what: String) -> Rex? {
        RexCache.fail(image, "tabs", what)
        return fail(what)
    }

    private static func resolve() -> Rex? {
        guard let image = RexImage.find() else { return nil }
        guard let pv = image.metadata(rxs(RXN_145), kind: 17, qualified: rxs(RXN_158)) else {
            return fail(rxs(RXN_158))
        }
        let names = image.descriptor(of: pv).fieldNames
        let offsets = structFieldOffsets(pv)
        guard names.count == offsets.count else { return fail("\(rxs(RXN_145))'s fields") }
        let fields = Dictionary(zip(names, offsets), uniquingKeysWith: { a, _ in a })
        for f in [rxs(RXN_042), rxs(RXN_136), rxs(RXN_044)] where fields[f] == nil {
            return fail("\(rxs(RXN_145)).\(f)")
        }
        guard let viewProto = Lib.view, let bodyReq = Lib.viewBody else {
            return fail("SwiftUI.View")
        }
        let cached = RexCache.entry(image, "tabs")
        let pvDesc = image.descriptor(of: pv).address
        func isStacks(_ cd: UnsafeRawPointer) -> Bool {
            relIndirect(cd) == UnsafeRawPointer(viewProto)
                && (cd.load(fromByteOffset: 12, as: UInt32.self) >> 3) & 7 == 0 && rel(cd + 4) == pvDesc
        }
        var keep: [String: Int] = [:]
        let wt: UnsafeRawPointer
        if let cd = image.word(cached?["stack.conformance"]), isStacks(cd), let t = swift_getWitnessTable(cd, pv, nil) {
            wt = t
            keep["stack.conformance"] = cached?["stack.conformance"]
        } else {
            guard let t = swift_conformsToProtocol(pv, viewProto) else {
                return fail("\(rxs(RXN_145))'s View conformance")
            }
            wt = t
            let cd = t.load(as: UnsafeRawPointer.self)
            if image.word(image.offset(cd)) == cd, isStacks(cd) { keep["stack.conformance"] = image.offset(cd) }
        }
        let proto = UnsafeRawPointer(viewProto)
        let inSig = Int(proto.load(fromByteOffset: 12, as: UInt32.self))
        let nReq = Int(proto.load(fromByteOffset: 16, as: UInt32.self))
        let reqs = proto + 24 + 12 * inSig
        let idx = (UnsafeRawPointer(bodyReq) - reqs) / 8
        guard (UnsafeRawPointer(bodyReq) - reqs) % 8 == 0, idx >= 0, idx < nReq else {
            return fail("View.body's requirement")
        }
        let witnesses = UnsafeMutablePointer<UnsafeRawPointer?>(
            mutating: wt.assumingMemoryBound(to: UnsafeRawPointer?.self))
        guard let body = witnesses[idx + 1], image.contains(body) else {
            return fail(
                "\(rxs(RXN_145)).body (witness \(idx + 1): \(String(describing: witnesses[idx + 1])), outside Rex's code)"
            )
        }

        RexCache.store(image, "tabs", keep)
        return Rex(image: image, stack: pv, stackWitnesses: witnesses, bodySlot: idx + 1)
    }

    func describe() -> String { "\(rxs(RXN_145)) body slot \(bodySlot)" }
}

let swift_getWitnessTable = unsafeBitCast(
    Lib.core("swift_getWitnessTable")!,
    to: (@convention(c) (UnsafeRawPointer, UnsafeRawPointer, UnsafeRawPointer?) -> UnsafeRawPointer?).self)
let swift_conformsToProtocol = unsafeBitCast(
    Lib.core("swift_conformsToProtocol")!,
    to: (@convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> UnsafeRawPointer?).self)

func structFieldOffsets(_ meta: UnsafeRawPointer) -> [Int] {
    let desc = meta.load(fromByteOffset: 8, as: UnsafeRawPointer.self)
    let n = Int(desc.load(fromByteOffset: 20, as: UInt32.self))
    let vec = Int(desc.load(fromByteOffset: 24, as: UInt32.self))
    return (0..<n).map { Int(meta.load(fromByteOffset: vec * 8 + $0 * 4, as: UInt32.self)) }
}
