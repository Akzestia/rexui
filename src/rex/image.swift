// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
import Foundation
import MachO

struct RexImage {
    let header: UnsafePointer<mach_header_64>
    let slide: Int
    let text: UnsafeRawBufferPointer

    static func find() -> RexImage? {
        for i in 0..<_dyld_image_count() {
            guard let n = _dyld_get_image_name(i), String(cString: n).hasSuffix("/MacOS/Rex"),
                let h = _dyld_get_image_header(i), h.pointee.magic == MH_MAGIC_64
            else { continue }
            let mh = UnsafeRawPointer(h).assumingMemoryBound(to: mach_header_64.self)
            guard let text = RexImage.section(mh, "__TEXT", "__text") else { return nil }
            return RexImage(header: mh, slide: _dyld_get_image_vmaddr_slide(i), text: text)
        }
        return nil
    }

    static func section(_ h: UnsafePointer<mach_header_64>, _ seg: String, _ sect: String) -> UnsafeRawBufferPointer? {
        var size: UInt = 0
        guard let p = getsectiondata(h, seg, sect, &size), size > 0 else { return nil }
        return UnsafeRawBufferPointer(start: p, count: Int(size))
    }

    func contains(_ p: UnsafeRawPointer) -> Bool {
        guard let b = text.baseAddress else { return false }
        return p >= b && p < b + text.count
    }

    struct TypeDescriptor {
        let address: UnsafeRawPointer
        var flags: UInt32 { address.load(as: UInt32.self) }
        var kind: UInt32 { flags & 0x1f }
        var isGeneric: Bool { flags & 0x80 != 0 }
        var name: String { String(cString: rel(address + 8)!.assumingMemoryBound(to: CChar.self)) }
        var parent: TypeDescriptor? { relIndirect(address + 4).map(TypeDescriptor.init) }
        var accessor: UnsafeRawPointer? { rel(address + 12) }
        var fieldNames: [String] {
            guard let fd = rel(address + 16) else { return [] }
            let size = Int(fd.load(fromByteOffset: 10, as: UInt16.self))
            let n = Int(fd.load(fromByteOffset: 12, as: UInt32.self))
            return (0..<n).compactMap { i in
                rel(fd + 16 + i * size + 8).map { String(cString: $0.assumingMemoryBound(to: CChar.self)) }
            }
        }
        var vtable: [(kind: UInt32, impl: UnsafeRawPointer?)] {
            let ks = flags >> 16
            guard kind == 16, ks & 0x8000 != 0 else { return [] }
            var p = address + 44
            if isGeneric {
                let np = Int(p.load(fromByteOffset: 8, as: UInt16.self))
                let nr = Int(p.load(fromByteOffset: 10, as: UInt16.self))
                p += 16 + ((np + 3) & ~3) + 12 * nr
            }
            if ks & 0x2000 != 0 { p += 4 }
            switch ks & 3 {
            case 1: p += 12
            case 2: p += 4
            default: break
            }
            let n = Int(p.load(fromByteOffset: 4, as: UInt32.self))
            guard n < 4096 else { return [] }
            p += 8
            return (0..<n).map { i in (p.load(fromByteOffset: 8 * i, as: UInt32.self) & 0xf, rel(p + 8 * i + 4)) }
        }
        func classFieldOffsets(_ meta: UnsafeRawPointer) -> [Int] {
            let n = Int(address.load(fromByteOffset: 36, as: UInt32.self))
            let vec = Int(address.load(fromByteOffset: 40, as: UInt32.self))
            guard kind == 16, flags >> 16 & 0x2000 == 0, n < 4096, vec >= 8 else { return [] }
            return (0..<n).map { meta.load(fromByteOffset: vec * 8 + $0 * 8, as: Int.self) }
        }
    }

    func types(named name: String, kind: UInt32, generic: Bool = false) -> [TypeDescriptor] {
        guard let s = RexImage.section(header, "__TEXT", "__swift5_types"), let base = s.baseAddress else { return [] }
        var out: [TypeDescriptor] = []
        name.withCString { want in
            for off in stride(from: 0, to: s.count, by: 4) {
                let d = base.load(fromByteOffset: off, as: Int32.self)
                guard d & 3 == 0, d != 0 else { continue }
                let t = TypeDescriptor(address: base + off + Int(d))
                guard t.kind == kind, t.isGeneric == generic, let n = rel(t.address + 8),
                    strcmp(n.assumingMemoryBound(to: CChar.self), want) == 0
                else { continue }
                out.append(t)
            }
        }
        return out
    }

    func metadata(_ name: String, kind: UInt32, qualified suffix: String) -> UnsafeRawPointer? {
        let found = types(named: name, kind: kind).compactMap { t -> UnsafeRawPointer? in
            guard let acc = t.accessor, contains(acc) else { return nil }
            let meta = unsafeBitCast(acc, to: (@convention(c) (Int) -> UnsafeRawPointer).self)(0)
            return _typeName(unsafeBitCast(meta, to: Any.Type.self), qualified: true).hasSuffix(suffix) ? meta : nil
        }
        return found.count == 1 ? found[0] : nil
    }

    func descriptor(of meta: UnsafeRawPointer) -> TypeDescriptor {
        let isClass = meta.load(as: UInt.self) > 0x7ff
        return TypeDescriptor(address: meta.load(fromByteOffset: isClass ? 64 : 8, as: UnsafeRawPointer.self))
    }

    func insn(_ p: UnsafeRawPointer) -> UInt32 { p.load(as: UInt32.self) }

    func blTarget(_ p: UnsafeRawPointer) -> UnsafeRawPointer? {
        let i = insn(p)
        guard i & 0xfc00_0000 == 0x9400_0000 else { return nil }
        let imm = Int(Int32(bitPattern: i << 6) >> 6) * 4
        return p + imm
    }

    func adrpAdd(_ p: UnsafeRawPointer) -> UnsafeRawPointer? {
        let a = insn(p)
        let b = insn(p + 4)
        guard a & 0x9f00_001f == 0x9000_0000, b & 0xffc0_03ff == 0x9100_0000 else { return nil }
        let immlo = Int((a >> 29) & 3)
        let immhi = Int(Int32(bitPattern: (a >> 5 & 0x7ffff) << 13) >> 13)
        let page = UInt(bitPattern: p) & ~UInt(0xfff)
        return UnsafeRawPointer(
            bitPattern: Int(bitPattern: page) + ((immhi << 2 | immlo) << 12) + Int((b >> 10) & 0xfff))
    }

    func isStub(_ p: UnsafeRawPointer, to function: UnsafeRawPointer) -> Bool {
        let a = insn(p)
        let b = insn(p + 4)
        let c = insn(p + 8)
        guard a & 0x9f00_001f == 0x9000_0010, b & 0xffc0_03ff == 0xf940_0210, c == 0xd61f_0200 else { return false }
        let immlo = Int((a >> 29) & 3)
        let immhi = Int(Int32(bitPattern: (a >> 5 & 0x7ffff) << 13) >> 13)
        let page = Int(bitPattern: UInt(bitPattern: p) & ~UInt(0xfff))
        guard let got = UnsafeRawPointer(bitPattern: page + ((immhi << 2 | immlo) << 12) + Int((b >> 10) & 0xfff) * 8)
        else { return false }
        return got.load(as: UnsafeRawPointer?.self) == function
    }

    func calls(to target: UnsafeRawPointer) -> [UnsafeRawPointer] {
        guard let base = text.baseAddress else { return [] }
        var out: [UnsafeRawPointer] = []
        for off in stride(from: 0, to: text.count - 4, by: 4) where blTarget(base + off) == target {
            out.append(base + off)
        }
        return out
    }

    func functionStart(containing p: UnsafeRawPointer) -> UnsafeRawPointer? {
        var best: UnsafeRawPointer?
        forEachFunction { f in
            if f > p { return false }
            best = f
            return true
        }
        return best
    }

    func functions(from: UnsafeRawPointer, to: UnsafeRawPointer) -> [UnsafeRawPointer] {
        var out: [UnsafeRawPointer] = []
        forEachFunction { f in
            if f >= to { return false }
            if f >= from { out.append(f) }
            return true
        }
        return out
    }

    private func forEachFunction(_ body: (UnsafeRawPointer) -> Bool) {
        var cmd = UnsafeRawPointer(header) + MemoryLayout<mach_header_64>.size
        var linkedit: segment_command_64?
        var starts: linkedit_data_command?
        for _ in 0..<header.pointee.ncmds {
            let lc = cmd.load(as: load_command.self)
            if lc.cmd == LC_SEGMENT_64 {
                let seg = cmd.load(as: segment_command_64.self)
                if withUnsafeBytes(of: seg.segname, { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) })
                    == "__LINKEDIT"
                {
                    linkedit = seg
                }
            } else if lc.cmd == LC_FUNCTION_STARTS {
                starts = cmd.load(as: linkedit_data_command.self)
            }
            cmd += Int(lc.cmdsize)
        }
        guard let le = linkedit, let fs = starts,
            var q = UnsafeRawPointer(bitPattern: Int(le.vmaddr) + slide + Int(fs.dataoff) - Int(le.fileoff))
        else { return }
        let end = q + Int(fs.datasize)
        var addr = UnsafeRawPointer(header)
        while q < end {
            var delta = 0
            var shift = 0
            while q < end {
                let byte = q.load(as: UInt8.self)
                q += 1
                delta |= Int(byte & 0x7f) << shift
                shift += 7
                if byte & 0x80 == 0 { break }
            }
            if delta == 0 { break }
            addr += delta
            if !body(addr) { break }
        }
    }
}

enum Lib {
    static let swiftCore = dlopen("/usr/lib/swift/libswiftCore.dylib", RTLD_NOLOAD | RTLD_LAZY)
    static let swiftUI = dlopen(
        "/System/Library/Frameworks/SwiftUI.framework/Versions/A/SwiftUI", RTLD_NOLOAD | RTLD_LAZY)
    static func core(_ name: String) -> UnsafeMutableRawPointer? {
        dlsym(swiftCore ?? UnsafeMutableRawPointer(bitPattern: -2), name)
    }
    static func ui(_ name: String) -> UnsafeMutableRawPointer? {
        dlsym(swiftUI ?? UnsafeMutableRawPointer(bitPattern: -2), name)
    }
    static let view = ui("$s7SwiftUI4ViewMp")
    static let viewBody = ui("$s7SwiftUI4ViewP4body4BodyQzvgTq")
}

func timed<T>(_ what: String, _ body: () -> T) -> T {
    let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    let r = body()
    rexLog(String(format: "%@: resolved in %.2f ms", what, Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6))
    return r
}

func rel(_ p: UnsafeRawPointer) -> UnsafeRawPointer? {
    let d = p.load(as: Int32.self)
    return d == 0 ? nil : p + Int(d)
}

func relIndirect(_ p: UnsafeRawPointer) -> UnsafeRawPointer? {
    let d = p.load(as: Int32.self)
    if d == 0 { return nil }
    let t = p + Int(d & ~1)
    return d & 1 != 0 ? t.load(as: UnsafeRawPointer?.self) : t
}
