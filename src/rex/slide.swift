// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
import AppKit
import QuartzCore

final class SlideLayer: CALayer {
    override func action(forKey event: String) -> CAAction? { nil }
}

enum Slide {
    private static weak var content: NSView?
    private static var overlay: SlideLayer?
    private static let maxTabs = 10
    private static var shownID: String?
    static var shownTab: String? { shownID }
    private static var shownSession: String?
    private static var sliding = false
    static var busy: Bool { sliding }
    static func serverID(_ printed: String) -> String {
        guard let r = printed.range(of: "window:") else { return printed }
        return String(printed[r.lowerBound...].prefix { $0 != "\"" && $0 != ")" })
    }
    private static func termLayer(_ id: String) -> CALayer? {
        rexui_term_tab(serverID(id)).map { Unmanaged<CALayer>.fromOpaque($0).takeUnretainedValue() }
    }
    private static func termFit(_ o: CALayer) -> Bool {
        let i = paneInsets
        return rexui_term_fit(o.bounds.width, o.bounds.height, i.top, i.left, i.bottom, i.right, paneGap)
    }
    private static var finish: (() -> Void)?
    private static var queued = 0
    private static var fitting = 0

    private struct Settings { var on = true, ms = 300.0, curve: [Float] = [0.05, 0.9, 0.1, 1.05] }
    private static var settings: Settings {
        var ms = 0.0
        var c = [Double](repeating: 0, count: 4)
        let on = rex_slide_settings(&ms, &c)
        return Settings(on: on, ms: ms, curve: c.map(Float.init))
    }

    private static var measuredAt = 0.0
    private static let store = UserDefaults(
        suiteName: ProcessInfo.processInfo.environment["REXUI_SUITE"].flatMap { $0.isEmpty ? nil : $0 } ?? "rexui")
    private static var paneInsets: NSEdgeInsets = {
        guard let a = store?.array(forKey: "slideInsets") as? [Double], a.count == 4,
            a.allSatisfy({ $0 >= 0 && $0 <= 40 })
        else {
            return NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        }
        return NSEdgeInsets(top: a[0], left: a[1], bottom: a[2], right: a[3])
    }()
    static var insets: NSEdgeInsets { paneInsets }
    private static var paneGap: Double = {
        let g = store?.double(forKey: "slideGap") ?? 0
        return g > 0 && g <= 40 ? g : 8.0
    }()
    private static var pending: NSEdgeInsets?
    private static var lastArea = NSSize.zero
    static func measure(_ c: NSView) {
        var u = NSRect.null
        var frames: [NSRect] = []
        var moving = false
        func walk(_ v: NSView, _ depth: Int) {
            if depth > 30 || v.isHidden { return }
            if NSStringFromClass(type(of: v)).contains(rxs(RXN_157)) {
                let f = v.convert(v.bounds, to: c)
                u = u.union(f)
                frames.append(f)
                if let keys = v.layer?.animationKeys(), !keys.isEmpty { moving = true }
                return
            }
            for s in v.subviews { walk(s, depth + 1) }
        }
        walk(c, 0)
        var gap = Double.infinity
        for a in frames {
            for b in frames where a != b {
                if b.minX >= a.maxX, b.minY < a.maxY, a.minY < b.maxY { gap = min(gap, b.minX - a.maxX) }
                if b.minY >= a.maxY, b.minX < a.maxX, a.minX < b.maxX { gap = min(gap, b.minY - a.maxY) }
            }
        }
        if gap.isFinite, gap <= 40, gap != paneGap {
            paneGap = gap
            store?.set(gap, forKey: "slideGap")
        }
        let b = c.bounds
        let areaSame = b.size == lastArea
        lastArea = b.size
        guard !u.isNull, u.width > 40, u.height > 40, areaSame, !moving else {
            pending = nil
            return
        }
        let top = c.isFlipped ? u.minY - b.minY : b.maxY - u.maxY
        let bottom = c.isFlipped ? b.maxY - u.maxY : u.minY - b.minY
        func tidy(_ x: CGFloat) -> CGFloat { (max(0, x) * 64).rounded() / 64 }
        let i = NSEdgeInsets(
            top: tidy(top), left: tidy(u.minX - b.minX), bottom: tidy(bottom), right: tidy(b.maxX - u.maxX))
        guard [i.top, i.left, i.bottom, i.right].allSatisfy({ $0 <= 40 }) else {
            pending = nil
            return
        }
        func same(_ a: NSEdgeInsets, _ b: NSEdgeInsets) -> Bool {
            a.top == b.top && a.left == b.left && a.bottom == b.bottom && a.right == b.right
        }
        if same(paneInsets, i) {
            pending = nil
            return
        }
        guard let p = pending, same(p, i) else {
            pending = i
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard pending != nil, !sliding, let c = content else { return }
                measuredAt = CACurrentMediaTime()
                measure(c)
                later()
            }
            return
        }
        pending = nil
        paneInsets = i
        store?.set([i.top, i.left, i.bottom, i.right].map { Double($0) }, forKey: "slideInsets")
        let shown = frames.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" }.joined(
            separator: "; ")
        rexLog(
            "slide: Rex's panes sit \(i.top) \(i.left) \(i.bottom) \(i.right) inside the pane area (\(Int(b.width))x\(Int(b.height)): \(shown))"
        )
    }

    static func place(chrome: NSView, content c: NSView) {
        content = c
        if !sliding, CACurrentMediaTime() - measuredAt > 0.5 {
            measuredAt = CACurrentMediaTime()
            measure(c)
        }
        guard Rex.shared != nil, let cl = c.layer, let parent = cl.superlayer else { return tearDown() }
        let o =
            overlay
            ?? {
                let o = SlideLayer()
                o.masksToBounds = true
                o.opacity = 0
                overlay = o
                return o
            }()
        o.isGeometryFlipped = !chrome.isFlipped
        if o.superlayer !== parent { parent.insertSublayer(o, above: cl) }
        if !sliding, o.frame != cl.frame {
            o.frame = cl.frame
            settle()
        }
        later()
    }

    private static func settle() {
        fitting += 1
        let gen = fitting
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if gen == fitting, !sliding, let o = overlay, termFit(o) { rexui_panes_now() }
        }
    }

    private static func tearDown() {
        overlay?.removeFromSuperlayer()
        overlay = nil
    }

    static func rendered() {
        guard let rex = Rex.shared, let src = rex_body_capture() else { return }
        let captured = swiftValue(at: src, meta: rex.stack)
        guard let now = Tabs.shown(captured) else { return }
        let session = Tabs.session(captured).map(Tabs.sessionKey)
        let old = shownID
        let oldSession = shownSession
        shownID = now
        shownSession = session
        if let old, old != now {
            panes_tab_switched()
            if let oldSession, let session, oldSession != session {
                let a = rex_session_index(oldSession)
                let b = rex_session_index(session)
                switched(from: old, to: now, dir: a >= 0 && b >= 0 && b < a ? -1 : 1, vertical: !rex_slide_vertical())
            } else {
                let ids = Tabs.windows(captured).map { Tabs.id($0) }
                if let from = ids.firstIndex(of: old), let to = ids.firstIndex(of: now) {
                    switched(from: old, to: now, dir: to > from ? 1 : -1, vertical: rex_slide_vertical())
                }
            }
        }
        later()
    }

    private static func later() {
        queued += 1
        let gen = queued
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if gen != queued { return }
            if sliding { return }
            guard let o = overlay, let rex = Rex.shared, let src = rex_body_capture() else { return }
            let captured = swiftValue(at: src, meta: rex.stack)
            let ids =
                Tabs.windows(captured).compactMap { Tabs.id($0) }.prefix(maxTabs)
                + Tabs.otherSessionTabs(captured).prefix(maxTabs)
            _ = termFit(o)
            rexui_term_want(
                settings.on ? ids.map(serverID).joined(separator: "\n") : "", Unmanaged.passUnretained(o).toOpaque())
            if let shownID { rexui_term_shown(serverID(shownID)) }
        }
    }

    static func configChanged() { later() }

    static func logState() {
        rexLog(
            "slide: shown \(shownID ?? "-") sliding \(sliding) overlay \(overlay.map { "\($0.bounds.size)" } ?? "none")"
        )
    }

    private static func switched(from old: String, to new: String, dir: CGFloat, vertical: Bool) {
        let s = settings
        guard s.on, let o = overlay, let c = content, let chrome = c.superview, let cl = c.layer else { return }
        if sliding { finish?() }
        let outl = termLayer(old)
        let inl = termLayer(new)
        let size = vertical ? c.bounds.height : c.bounds.width
        func along(_ v: NSView, _ d: CGFloat) -> CGFloat { vertical && !v.isFlipped ? -d : d }
        sliding = true
        if let inl { rexui_term_arrived(Unmanaged.passUnretained(inl).toOpaque()) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let timing = CAMediaTimingFunction(controlPoints: s.curve[0], s.curve[1], s.curve[2], s.curve[3])
        func slide(_ l: CALayer, _ a: CGFloat, _ b: CGFloat) {
            let an = CABasicAnimation(keyPath: vertical ? "transform.translation.y" : "transform.translation.x")
            an.fromValue = a
            an.toValue = b
            an.duration = s.ms / 1000
            an.timingFunction = timing
            an.fillMode = .both
            an.isRemovedOnCompletion = false
            l.add(an, forKey: "rexui.slide")
        }
        var done = false
        let end = {
            if done { return }
            done = true
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            outl?.removeAnimation(forKey: "rexui.slide")
            outl?.opacity = 0
            cl.removeAnimation(forKey: "rexui.slide")
            cl.mask = nil
            if let inl { rexui_term_arrived(Unmanaged.passUnretained(inl).toOpaque()) }
            rexui_panes_now()
            panes_attach_now()
            cl.opacity = 1
            o.opacity = 0
            inl?.removeAnimation(forKey: "rexui.slide")
            inl?.opacity = 0
            CATransaction.commit()
            sliding = false
            finish = nil
            later()
        }
        finish = end
        DispatchQueue.main.asyncAfter(deadline: .now() + s.ms / 1000 + 0.25) {
            if !done { rexLog("slide: ended by the clock (Core Animation's end didn't come)") }
            end()
        }
        CATransaction.setCompletionBlock { end() }
        if let parent = cl.superlayer, let at = parent.sublayers?.firstIndex(of: cl),
            parent.sublayers?.firstIndex(of: o) != at + 1
        {
            parent.insertSublayer(o, above: cl)
        }
        o.frame = cl.frame
        if termFit(o) { rexui_panes_now() }
        o.opacity = 1
        if let outl {
            outl.opacity = 1
            slide(outl, 0, -dir * size)
        }
        if let inl {
            inl.opacity = 1
            slide(inl, dir * size, 0)
            cl.opacity = 0
        } else {
            let mask = CALayer()
            mask.frame = cl.bounds
            mask.backgroundColor = CGColor(gray: 0, alpha: 1)
            cl.mask = mask
            slide(cl, along(chrome, dir * size), 0)
            slide(mask, along(c, -dir * size), 0)
        }
        for l in [outl, inl] { if let l { rexui_term_wake(Unmanaged.passUnretained(l).toOpaque()) } }
        for l in [outl, inl] { if let l { rexui_shaders_wake(Unmanaged.passUnretained(l).toOpaque()) } }
        CATransaction.commit()
    }
}

@_cdecl("rex_tabs_rendered") public func rexTabsRendered() { Slide.rendered() }

@_cdecl("rex_slide_config_changed") public func rexSlideConfigChanged() { Slide.configChanged() }

@_cdecl("rex_slide_place") public func rexSlidePlace(_ chrome: UnsafeRawPointer, _ content: UnsafeRawPointer) {
    Slide.place(
        chrome: Unmanaged<NSView>.fromOpaque(chrome).takeUnretainedValue(),
        content: Unmanaged<NSView>.fromOpaque(content).takeUnretainedValue())
}

@_cdecl("rex_slide_state") public func rexSlideState() { Slide.logState() }

@_cdecl("rex_pane_insets") public func rexPaneInsets(_ out: UnsafeMutablePointer<Double>) {
    let i = Slide.insets
    out[0] = Double(i.top)
    out[1] = Double(i.left)
    out[2] = Double(i.bottom)
    out[3] = Double(i.right)
}

@_cdecl("rex_shown_tab") public func rexShownTab() -> UnsafeMutableRawPointer? {
    guard let id = Slide.shownTab else { return nil }
    return Unmanaged.passRetained(id as NSString).toOpaque()
}

@_cdecl("rex_tab_id") public func rexTabID(_ index: Int) -> UnsafeMutableRawPointer? {
    guard let rex = Rex.shared, let src = rex_body_capture() else { return nil }
    let tabs = Tabs.windows(swiftValue(at: src, meta: rex.stack))
    guard tabs.indices.contains(index), let id = Tabs.id(tabs[index]) else { return nil }
    return Unmanaged.passRetained(Slide.serverID(id) as NSString).toOpaque()
}
