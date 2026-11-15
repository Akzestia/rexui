// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
import AppKit

enum Reads {
    private static weak var model: AnyObject?
    static func windowModel() -> AnyObject? {
        if let m = model { return m }
        model = RexWindow.windowModel()
        return model
    }

    static func block(in v: Any?) -> String {
        guard let v = unwrap(v) else { return "" }
        let s = String(describing: v)
        guard let r = s.range(of: #"block:[0-9a-f-]+"#, options: .regularExpression) else { return "" }
        return String(s[r])
    }

    private static var activeOffset: Int?? = nil
    private static func activeArrangement(_ wm: AnyObject) -> Any? {
        if activeOffset == nil { activeOffset = .some(classFieldOffset(wm, rxs(RXN_043))) }
        guard let off = activeOffset ?? nil else { return unwrap(field(wm, rxs(RXN_043))) }
        guard let p = swiftWeakLoadStrong(UnsafeMutableRawPointer(Unmanaged.passUnretained(wm).toOpaque()) + off) else {
            return nil
        }
        return Unmanaged<AnyObject>.fromOpaque(p).takeRetainedValue()
    }

    static func layout() -> [String: Any] {
        guard let wm = windowModel(), let lm = activeArrangement(wm) else { return [:] }
        var f: [String: Any] = [:]
        let want: Set<String> = [rxs(RXN_050), rxs(RXN_051), rxs(RXN_052), rxs(RXN_053), rxs(RXN_049)]
        for c in Mirror(reflecting: lm).children {
            if let l = c.label, want.contains(l) { f[l] = c.value }
            if f.count == want.count { break }
        }
        return [
            "zoomed": Activity.raw(f[rxs(RXN_050)]),
            "busy": ((f[rxs(RXN_051)] as? Int) ?? 0) > 0,
            "failure": (unwrap(f[rxs(RXN_052)]) as? String) ?? "",
            "arriving": block(in: f[rxs(RXN_053)]),
            "focused": Activity.raw(f[rxs(RXN_049)]),
        ]
    }

    static func hoveredLink(_ surface: NSView) -> String? {
        guard let h = unwrap(field(surface, rxs(RXN_054))), let uri = field(h, rxs(RXN_055)) as? String, !uri.isEmpty
        else { return nil }
        return uri
    }

    private static weak var hints: AnyObject?
    private static var hintsLooked = false
    static func hintsRevealed() -> Int {
        if hints == nil, !hintsLooked {
            hintsLooked = true
            for n in [rxs(RXN_150), rxs(RXN_151)]
            where NSClassFromString(n) != nil {
                hints = heapObjects(n).first
                if hints != nil { break }
            }
            if hints == nil { rexLog("keys: Rex's tab shortcut hint monitor not found (keys.hints stays false)") }
        }
        guard let m = hints else { return -1 }
        return unwrap(field(m, rxs(RXN_056))) != nil ? 1 : 0
    }

    private static weak var animSettings: AnyObject?
    private static var animLooked = false
    private static func motion() -> AnyObject? {
        if let s = animSettings { return s }
        if !animLooked {
            animLooked = true
            for n in [rxs(RXN_152), rxs(RXN_153)]
            where NSClassFromString(n) != nil {
                if let o = heapObjects(n).first {
                    animSettings = o
                    return o
                }
            }
        }
        for w in NSApp.windows {
            guard let c = w.contentView, let chrome = chrome(c.superview ?? c, 0), let sb = field(chrome, rxs(RXN_141)),
                let s = unwrap(field(sb, rxs(RXN_057))), type(of: s) is AnyClass
            else { continue }
            return s as AnyObject
        }
        return nil
    }

    static func chrome(_ v: NSView, _ depth: Int) -> NSView? {
        if NSStringFromClass(type(of: v)).hasSuffix(rxs(RXN_029)) { return v }
        guard depth < 8 else { return nil }
        for s in v.subviews { if let c = chrome(s, depth + 1) { return c } }
        return nil
    }

    static func timeScale(_ set: Double?) -> Double {
        guard let s = motion(), let off = classFieldOffset(s, rxs(RXN_058)) else { return -1 }
        let p = UnsafeMutableRawPointer(Unmanaged.passUnretained(s).toOpaque()) + off
        if let v = set {
            p.storeBytes(of: v > 0 ? v : 0, as: Double.self)
            p.storeBytes(of: v > 0 ? 0 : 1, toByteOffset: 8, as: UInt8.self)
        }
        return p.load(fromByteOffset: 8, as: UInt8.self) == 0 ? p.load(as: Double.self) : 0
    }

    private static func hub() -> Any? { RexApp.object(rxs(RXN_139)).flatMap { field($0, rxs(RXN_059)) } }

    static func keymap() -> [[String: Any]] {
        guard let hub = hub() else { return [] }
        var titles: [String: (String, String)] = [:]
        if let kc = unwrap(field(hub, rxs(RXN_060))), let acts = field(kc, rxs(RXN_037)) {
            for a in Mirror(reflecting: acts).children {
                titles[Activity.raw(field(a.value, rxs(RXN_014)))] = (
                    (field(a.value, rxs(RXN_015)) as? String) ?? "",
                    (unwrap(field(a.value, rxs(RXN_061))) as? String) ?? ""
                )
            }
        }
        var out: [[String: Any]] = []
        guard let servers = field(hub, rxs(RXN_062)), let s = Mirror(reflecting: servers).children.first?.value,
            let km = unwrap(field(s, rxs(RXN_063))), let reply = field(km, rxs(RXN_064)),
            let keymap = field(reply, rxs(RXN_065)),
            let bindings = field(keymap, rxs(RXN_066))
        else { return out }
        for b in Mirror(reflecting: bindings).children {
            let keys =
                field(b.value, rxs(RXN_067)).map {
                    Mirror(reflecting: $0).children.map { String(describing: $0.value) }
                } ?? []
            let inv = field(b.value, rxs(RXN_068))
            let action = Activity.raw(inv.flatMap { field($0, rxs(RXN_069)) })
            let data = inv.flatMap { unwrap(field($0, rxs(RXN_200))) }.flatMap { field($0, rxs(RXN_201)) } as? Data
            let args = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
            let t = titles[action]
            out.append([
                "keys": keys, "action": action, "args": args, "title": t?.0 ?? "", "category": t?.1 ?? "",
                "source": (unwrap(field(b.value, rxs(RXN_134))) as? String) ?? "",
                "mode": (unwrap(field(b.value, rxs(RXN_070))) as? String) ?? "",
            ])
        }
        return out
    }

    static func hosts() -> [[String: Any]] {
        guard let hub = hub(), let servers = field(hub, rxs(RXN_062)) else { return [] }
        let home = Activity.raw(unwrap(field(hub, rxs(RXN_071))).flatMap { field($0, rxs(RXN_000)) })
        return Mirror(reflecting: servers).children.map { c in
            let id = (field(c.value, rxs(RXN_004)).flatMap { field($0, rxs(RXN_000)) }).map { "\($0)" } ?? ""
            let version = unwrap(field(c.value, rxs(RXN_072))).flatMap { field($0, rxs(RXN_073)) } as? String ?? ""
            return [
                "id": id, "name": (field(c.value, rxs(RXN_074)) as? String) ?? "", "home": id == home || home.isEmpty,
                "connection": String(describing: field(c.value, rxs(RXN_075)) ?? ""), "version": version,
                "sessions": Mirror(reflecting: field(c.value, rxs(RXN_076)) ?? []).children.count,
            ]
        }
    }

    static func themes() -> [String: Any] {
        palettesRead.wait()
        guard let ts = RexApp.object(rxs(RXN_077)) else { return palettes.isEmpty ? [:] : ["palettes": palettes] }
        var list: [[String: Any]] = []
        if let store = field(ts, rxs(RXN_078)), let rt = field(store, rxs(RXN_079)) {
            for t in Mirror(reflecting: rt).children {
                var colors: [String: String] = [:]
                if let cs = field(t.value, rxs(RXN_080)) {
                    for kv in Mirror(reflecting: cs).children {
                        guard let k = field(kv.value, "key"), let v = field(kv.value, rxs(RXN_003)),
                            let r = field(v, rxs(RXN_081)) as? Double,
                            let g = field(v, rxs(RXN_082)) as? Double, let b = field(v, rxs(RXN_083)) as? Double
                        else { continue }
                        let a = (field(v, rxs(RXN_084)) as? Double) ?? 1
                        let name = String(describing: k).components(separatedBy: ".").last ?? "\(k)"
                        colors[name] = String(
                            format: "#%02x%02x%02x%02x", Int(a * 255), Int(r * 255), Int(g * 255), Int(b * 255))
                    }
                }
                list.append([
                    "id": (field(t.value, rxs(RXN_004)) as? String) ?? "",
                    "name": (field(t.value, rxs(RXN_014)) as? String) ?? "",
                    "appearance": String(describing: field(t.value, rxs(RXN_085)) ?? ""), "colors": colors,
                ])
            }
        }
        return [
            "light": (field(ts, rxs(RXN_086)) as? String) ?? "", "dark": (field(ts, rxs(RXN_087)) as? String) ?? "",
            "custom": list,
            "palettes": palettes,
        ]
    }

    private static var palettes: [[String]] = []
    private static let palettesRead = DispatchGroup()
    static func prefetchPalettes() {
        palettesRead.enter()
        DispatchQueue.global(qos: .utility).async {
            palettes = readPalettes()
            palettesRead.leave()
        }
    }

    private static func readPalettes() -> [[String]] {
        guard let res = Bundle.main.resourceURL,
            let data = try? Data(
                contentsOf: res.appendingPathComponent(rxs(RXN_208))
                    .appendingPathComponent("Contents/Resources").appendingPathComponent(rxs(RXN_209))),
            let all = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [] }
        let prefix = rxs(RXN_211)
        func rgba(_ v: String) -> [Double] {
            let v = v.trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("#"), v.count >= 7 {
                let h = Array(v.utf8)
                func byte(_ i: Int) -> Double {
                    Double(Int(String(decoding: h[i..<i + 2], as: UTF8.self), radix: 16) ?? 0)
                }
                return [byte(1), byte(3), byte(5), 1]
            }
            var n: [Double] = []
            var cur = ""
            for ch in v + " " {
                if ch.isNumber || ch == "." {
                    cur.append(ch)
                } else if !cur.isEmpty {
                    n.append(Double(cur) ?? 0)
                    cur = ""
                }
            }
            while n.count < 3 { n.append(0) }
            return Array(n.prefix(3)) + [n.count > 3 ? n[3] : 1]
        }
        func over(_ top: [Double], _ under: [Double]) -> String {
            (0..<3).map { i in
                String(format: "%02x", Int((top[i] * top[3] + under[i] * (1 - top[3])).rounded(.toNearestOrEven)))
            }.joined()
        }
        var out: [(first: Bool, flavour: String, light: Bool, name: String, colours: String)] = []
        let ids = Set(all.compactMap { $0[rxs(RXN_004)] as? String })
        for t in all {
            guard let id = t[rxs(RXN_004)] as? String, let mode = t[rxs(RXN_085)] as? String,
                let css = t[rxs(RXN_210)] as? [String: String]
            else { continue }
            var c: [String: [Double]] = [:]
            for (k, v) in css where k.hasPrefix(prefix) { c[String(k.dropFirst(prefix.count))] = rgba(v) }
            let light = mode == "light"
            let bg = c[rxs(RXN_212)] ?? [0, 0, 0, 1]
            func hex(_ token: String, _ under: [Double]? = nil) -> String {
                over(c[token] ?? [0, 0, 0, 1], under ?? bg)
            }
            let raised = c[rxs(RXN_214)] ?? bg
            let sidebar = c[rxs(RXN_213)] ?? bg
            let roles = [
                hex(rxs(RXN_212)), hex(rxs(RXN_213)), light ? hex(rxs(RXN_215)) : hex(rxs(RXN_214)),
                hex(rxs(RXN_215), light ? sidebar : raised),
                hex(rxs(RXN_216)), hex(rxs(RXN_217)), hex(rxs(RXN_218)), hex(rxs(RXN_219)),
                hex(rxs(RXN_220)), hex(rxs(RXN_221)), hex(rxs(RXN_222)), hex(rxs(RXN_223)),
                hex(rxs(RXN_224)), hex(rxs(RXN_225)), hex(rxs(RXN_039)), hex(rxs(RXN_226)), hex(rxs(RXN_227)),
                hex(rxs(RXN_228)),
            ]
            var flavour = id
            for m in ["-dark", "-light"] where id.hasSuffix(m) {
                let base = String(id.dropLast(m.count))
                if ids.contains(base + "-dark") && ids.contains(base + "-light") { flavour = base }
            }
            out.append(
                (
                    flavour != rxs(RXN_229), flavour, mode != "dark", "rex/\(flavour)/\(mode)",
                    roles.joined(separator: " ")
                ))
        }
        out.sort { a, b in
            if a.first != b.first { return !a.first }
            if a.flavour != b.flavour { return a.flavour < b.flavour }
            if a.light != b.light { return !a.light }
            return a.name < b.name
        }
        return out.map { [$0.name, $0.colours] }
    }

    static func keyLayout() -> [String: String] {
        guard let km = RexApp.object(rxs(RXN_088)), let ls = field(km, rxs(RXN_089)),
            let layout = unwrap(field(ls, rxs(RXN_090))),
            let chars = field(layout, rxs(RXN_091))
        else { return [:] }
        var out: [String: String] = [:]
        for kv in Mirror(reflecting: chars).children {
            guard let code = field(kv.value, "key") as? UInt16,
                let ch = unwrap(field(kv.value, rxs(RXN_003))) as? Unicode.Scalar
            else { continue }
            out[String(code)] = String(ch)
        }
        return out
    }

    static func openDirectory(_ paths: [String]) -> Bool {
        guard let reg = RexApp.object(rxs(RXN_092)), let off = classFieldOffset(reg, rxs(RXN_093)) else { return false }
        let p = (UnsafeMutableRawPointer(Unmanaged.passUnretained(reg).toOpaque()) + off).assumingMemoryBound(
            to: Optional<([String]) -> Void>.self)
        guard let f = p.pointee else { return false }
        f(paths)
        return true
    }
}

@_cdecl("rex_layout_state") public func rexLayoutState() -> UnsafeMutableRawPointer? {
    RexDeps.on("layout") ? Unmanaged.passRetained(Reads.layout() as NSDictionary).toOpaque() : nil
}
@_cdecl("rex_hovered_link") public func rexHoveredLink(_ surface: UnsafeRawPointer) -> UnsafeMutableRawPointer? {
    guard RexDeps.on("hovered-link") else { return nil }
    let v = Unmanaged<NSView>.fromOpaque(surface).takeUnretainedValue()
    return Reads.hoveredLink(v).map { Unmanaged.passRetained($0 as NSString).toOpaque() }
}
@_cdecl("rex_hints_revealed") public func rexHintsRevealed() -> Int { RexDeps.on("hints") ? Reads.hintsRevealed() : -1 }
@_cdecl("rex_time_scale") public func rexTimeScale(_ set: Double, _ write: Bool) -> Double {
    RexDeps.on("time-scale") ? Reads.timeScale(write ? set : nil) : -1
}
@_cdecl("rex_keymap") public func rexKeymap() -> UnsafeMutableRawPointer? {
    RexDeps.on("keymap") ? Unmanaged.passRetained(Reads.keymap() as NSArray).toOpaque() : nil
}
@_cdecl("rex_hosts") public func rexHosts() -> UnsafeMutableRawPointer? {
    RexDeps.on("hosts") ? Unmanaged.passRetained(Reads.hosts() as NSArray).toOpaque() : nil
}
@_cdecl("rex_themes") public func rexThemes() -> UnsafeMutableRawPointer? {
    RexDeps.on("themes") ? Unmanaged.passRetained(Reads.themes() as NSDictionary).toOpaque() : nil
}
@_cdecl("rex_key_layout") public func rexKeyLayout() -> UnsafeMutableRawPointer? {
    RexDeps.on("key-layout") ? Unmanaged.passRetained(Reads.keyLayout() as NSDictionary).toOpaque() : nil
}
@_cdecl("rex_open_directory") public func rexOpenDirectory(_ paths: UnsafeRawPointer) -> Bool {
    guard RexDeps.on("open-directory") else { return false }
    let a = Unmanaged<NSArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
    return !a.isEmpty && Reads.openDirectory(a)
}
