// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
import AppKit

@_cdecl("rex_cell_height") public func rexCellHeight(_ view: UnsafeRawPointer) -> Double {
    guard RexDeps.on("terminal") else { return 0 }
    let v = Unmanaged<NSView>.fromOpaque(view).takeUnretainedValue()
    guard let rv = field(v, rxs(RXN_107)), let core = field(rv, rxs(RXN_108)),
        let layout = unwrap(field(core, rxs(RXN_090))),
        let grid = field(layout, rxs(RXN_109)), let rows = field(grid, rxs(RXN_110)) as? Int, rows > 0,
        let pad = field(layout, rxs(RXN_111)), let top = field(pad, rxs(RXN_112)) as? Int,
        let bottom = field(pad, rxs(RXN_113)) as? Int,
        let size = field(layout, rxs(RXN_143)) as? CGSize, size.height > 0, v.bounds.height > 0
    else { return 0 }
    let cell = (size.height - CGFloat(top + bottom)) / CGFloat(rows)
    return Double(cell * v.bounds.height / size.height)
}

@_cdecl("rex_terminal_state") public func rexTerminalState(_ view: UnsafeRawPointer) -> Int32 {
    guard RexDeps.on("terminal") else { return 0 }
    let v = Unmanaged<AnyObject>.fromOpaque(view).takeUnretainedValue()
    var out: Int32 = 0
    if let modes = field(v, rxs(RXN_114)) {
        if (field(modes, rxs(RXN_115)) as? Bool) == true { out |= 1 }
        if (field(modes, rxs(RXN_116)) as? Bool) == true { out |= 4 }
    }
    if let t = unwrap(field(v, rxs(RXN_117))), let s = unwrap(field(t, rxs(RXN_138))),
        (field(s, rxs(RXN_118)) as? Bool) == true
    {
        out |= 2
    }
    return out
}
