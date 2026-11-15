// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
import AppKit
import Metal
import QuartzCore

@_silgen_name("rexui_embed_rebind") func rexui_embed_rebind()
@_silgen_name("rexui_embed_rebind_wine") func rexui_embed_rebind_wine()
@_silgen_name("rexui_embed_set_pane") func rexui_embed_set_pane(_ w: Double, _ h: Double, _ scale: Double)
@_silgen_name("rexui_embed_display_pixels_high") func rexui_embed_display_pixels_high() -> Double

enum Embed {
    static var link: PaneLink?
    static var adopted: NSWindow?
    static var focused = false
    static var timer: Timer?
    static var launched = false
    static let wine = ProcessInfo.processInfo.environment["REXUI_EMBED_WINE"] != nil

    static func start() {
        if wine {
            rexui_embed_rebind_wine()
        } else {
            rexui_embed_rebind()
            PaneLink.sizeChanged = { size, scale in
                rexui_embed_set_pane(Double(size.width), Double(size.height), Double(scale))
            }
        }
        PaneLink.placeMove = { f, w in
            fraction = f
            guard let (sw, sh) = sdlWindowSize(), sw > 0, sh > 0 else { return nil }
            return NSPoint(x: f.x * Double(sw), y: Double(sh) - f.y * Double(sh))
        }
        PaneLink.mouseMoved = { p in
            mouse = p
            if wine { Wine.forward(throttled: true) }
            pickCursor()
            diagnose(p)
        }
        hookActivation()
        hookCursorRects()
        Cursor.rectDecides = { !picked.isEmpty }
        hookWindows()
        if wine { Wine.start() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willFinishLaunchingNotification, object: nil, queue: .main
        ) { _ in
            launched = true
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
        ) { _ in
            launch()
        }
        if wine {
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) {
                n in
                if let w = n.object as? NSWindow, isAdopted(w) { release() }
            }
        }
    }

    static func launch() {
        guard timer == nil else { return }
        launched = true
        if wine { Wine.hookClipping() }
        NSApp.setActivationPolicy(.accessory)
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in look() }
        look()
    }

    static func look() {
        if PaneLink.debug { snapshot() }
        if wine, adopted != nil {
            Wine.popups()
            FirstFrame.scan()
        }
        if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
        guard adopted == nil, launched else { return }
        let candidates = NSApp.windows.filter { $0.isVisible && candidate($0) }
        guard let w = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            return
        }
        adopt(w)
    }

    static func adopt(_ w: NSWindow) {
        guard adopted == nil, !wine || Lock.take() else { return }
        adopted = w
        if wine {
            hookWindows(type(of: w))
            Wine.hide(w)
        } else {
            timer?.invalidate()
        }
        hideButtons(w)
        w.hasShadow = false
        w.level = .normal
        w.acceptsMouseMovedEvents = true
        w.isMovable = false
        w.isMovableByWindowBackground = false
        if w.isMiniaturized { w.deminiaturize(nil) }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: w)
        }
        if w.firstResponder === w, let c = w.contentView { w.makeFirstResponder(c) }
        acceptFirstClicks(w)
        DispatchQueue.main.async { resetCursorRects() }
        let env = ProcessInfo.processInfo.environment
        let chosen = wine && !(env["REXUI_EMBED_EXE"] ?? "").isEmpty ? WineProgram.name : nil
        let name =
            chosen ?? env["REXUI_EMBED_NAME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (wine ? WineProgram.name : nil) ?? (Bundle.main.infoDictionary?["CFBundleName"] as? String)
            ?? ProcessInfo.processInfo.processName
        if PaneLink.debug {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                func dump(_ v: NSView, _ d: Int) {
                    guard d < 14 else { return }
                    let l = v.layer
                    let line =
                        String(repeating: "  ", count: d)
                        + "\(type(of: v)) \(v.frame) hidden=\(v.isHidden) layer=\(l.map { "\(type(of: $0)) contents=\($0.contents.map { "\(type(of: $0))" } ?? "nil") sub=\($0.sublayers?.count ?? 0)" } ?? "none") wantsLayer=\(v.wantsLayer)"
                    rexPaneLine(line)
                    for s in v.subviews { dump(s, d + 1) }
                }
                rexPaneLine("embed: windows \(NSApp.windows.map { "\(type(of: $0)) \($0.frame) \($0.isVisible)" })")
                if let f = w.contentView?.superview { dump(f, 0) }
            }
        }
        PaneLink.waitsForFrame = wine
        PaneLink.opaque = true
        if wine { FirstFrame.start { Embed.link?.markDrawn() } }
        link = PaneLink(
            name: name, window: w,
            focus: { on in
                focused = on || (wine && focused)
                if on { w.makeFirstResponder(w.firstResponder) }
                if on, wine {
                    Wine.forward(throttled: false)
                    Wine.unminimize(w)
                }
            }, scale: { _ in })
        if wine, Wine.clipper.locks { rexuiEmbedCapture(1) }
        if PaneLink.debug {
            rexPaneLine("embed: adopted \(type(of: w)) '\(w.title)' \(w.frame) in \(getpid()) \(name)")
        }
    }

    static func release() {
        guard let w = adopted else { return }
        if PaneLink.debug { rexPaneLine("embed: let go of '\(w.title)' in \(getpid())") }
        link?.stop()
        link = nil
        adopted = nil
        FirstFrame.stop()
        Wine.unhidePopups()
        w.alphaValue = 1
        w.ignoresMouseEvents = false
        focused = false
        rects.removeAll()
        Lock.give()
    }

    static func snapshot() {
        let trigger = (ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp/") + "rexui-embed-snap"
        guard let w = adopted, FileManager.default.fileExists(atPath: trigger) else { return }
        try? FileManager.default.removeItem(atPath: trigger)
        var l = w.contentView?.layer
        while let p = l?.superlayer { l = p }
        guard let root = l, root.bounds.width > 0 else { return }
        let scale = w.backingScaleFactor
        let pw = Int(root.bounds.width * scale)
        let ph = Int(root.bounds.height * scale)
        guard
            let ctx = CGContext(
                data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.scaleBy(x: scale, y: scale)
        root.render(in: ctx)
        if let img = ctx.makeImage() {
            NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]).map {
                try? $0.write(to: URL(fileURLWithPath: trigger + ".png"))
            }
        }
    }

    static func hideButtons(_ w: NSWindow) {
        let covers =
            w.styleMask.contains(.fullSizeContentView)
            || (w.contentView.map { $0.frame.height >= w.frame.height } ?? false)
        guard covers else { return }
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            w.standardWindowButton(b)?.isHidden = true
        }
    }

    static func isAdopted(_ w: NSWindow) -> Bool { adopted != nil && w === adopted }

    static var sdlSeen = false
    static func sdlApp() -> Bool {
        if !sdlSeen, dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SDL_Init") != nil { sdlSeen = sdlWindow() != nil }
        return sdlSeen
    }

    static func isSDLText(_ v: NSView) -> Bool { NSStringFromClass(type(of: v)).hasSuffix("TranslatorResponder") }

    static var lastDiagnosis = 0.0
    typealias SDLMouse = @convention(c) (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>) -> UInt32
    typealias SDLFocus = @convention(c) () -> OpaquePointer?
    typealias SDLSize = @convention(c) (OpaquePointer, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Bool
    static let sdlMouse = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SDL_GetMouseState").map {
        unsafeBitCast($0, to: SDLMouse.self)
    }
    static let sdlFocus = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SDL_GetMouseFocus").map {
        unsafeBitCast($0, to: SDLFocus.self)
    }
    typealias SDLFlags = @convention(c) (OpaquePointer) -> UInt64
    static let sdlFlags = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SDL_GetWindowFlags").map {
        unsafeBitCast($0, to: SDLFlags.self)
    }
    static let sdlSize = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SDL_GetWindowSize").map {
        unsafeBitCast($0, to: SDLSize.self)
    }

    static var fraction: NSPoint?
    typealias SDLPosition =
        @convention(c) (OpaquePointer, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Void
    static let sdlPosition = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SDL_GetWindowPosition").map {
        unsafeBitCast($0, to: SDLPosition.self)
    }

    static func globalMouse() -> NSPoint? {
        guard let f = fraction, adopted != nil, let win = sdlWindow(), let size = sdlSize else { return nil }
        var x: Int32 = 0
        var y: Int32 = 0
        var w: Int32 = 0
        var h: Int32 = 0
        sdlPosition?(win, &x, &y)
        _ = size(win, &w, &h)
        return NSPoint(x: Double(x) + f.x * Double(w), y: Double(y) + f.y * Double(h))
    }

    static var lastWindowID: UInt32 = 0
    static func sdlWindow() -> OpaquePointer? {
        if let w = sdlFocus?() ?? sdlKeyFocus?() {
            if let id = sdlWindowID?(w), id != 0 { lastWindowID = id }
            return w
        }
        if lastWindowID != 0, let w = sdlFromID?(lastWindowID) { return w }
        return sdlFromID?(1) ?? sdlFromID?(2)
    }
    typealias SDLWindowID = @convention(c) (OpaquePointer) -> UInt32
    static let sdlWindowID = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SDL_GetWindowID").map {
        unsafeBitCast($0, to: SDLWindowID.self)
    }

    typealias SDLWindowFromID = @convention(c) (UInt32) -> OpaquePointer?
    static let sdlFromID = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SDL_GetWindowFromID").map {
        unsafeBitCast($0, to: SDLWindowFromID.self)
    }
    typealias SDLKeyboardFocus = @convention(c) () -> OpaquePointer?
    static let sdlKeyFocus = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SDL_GetKeyboardFocus").map {
        unsafeBitCast($0, to: SDLKeyboardFocus.self)
    }
    static let sdl3 = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SDL_GetWindowRelativeMouseMode") != nil

    static func sdlWindowSize() -> (Int32, Int32)? {
        guard let size = sdlSize, let win = sdlWindow() else { return nil }
        var w: Int32 = 0
        var h: Int32 = 0
        _ = size(win, &w, &h)
        return (w, h)
    }

    static func diagnose(_ p: NSPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        guard PaneLink.debug, now - lastDiagnosis > 0.5, let w = adopted else { return }
        lastDiagnosis = now
        var line = String(
            format: "%.1f event in window %.0f,%.0f; window %@ content %@ style %lu",
            now, p.x, p.y, NSStringFromRect(w.frame), NSStringFromRect(w.contentView?.frame ?? .zero),
            w.styleMask.rawValue)
        line += "; first responder \(w.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")"
        line +=
            " content \(w.contentView.map { String(describing: type(of: $0)) } ?? "nil") next \(w.contentView?.nextResponder.map { String(describing: type(of: $0)) } ?? "nil")"
        line +=
            " delegate \(w.delegate.map { String(describing: type(of: $0)) } ?? "nil") moved-events \(w.acceptsMouseMovedEvents)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let m = sdlMouse {
                if sdl3 {
                    var x: Float = 0
                    var y: Float = 0
                    _ = m(&x, &y)
                    line += String(format: "; SDL3 mouse %.0f,%.0f", x, y)
                } else {
                    var x: Int32 = 0
                    var y: Int32 = 0
                    withUnsafeMutablePointer(to: &x) { px in
                        withUnsafeMutablePointer(to: &y) { py in
                            _ = m(
                                UnsafeMutableRawPointer(px).assumingMemoryBound(to: Float.self),
                                UnsafeMutableRawPointer(py).assumingMemoryBound(to: Float.self))
                        }
                    }
                    line += " ; SDL2 mouse \(x),\(y)"
                }
            }
            if let f = sdlFocus, let s = sdlSize, let win = f() {
                var ww: Int32 = 0
                var wh: Int32 = 0
                _ = s(win, &ww, &wh)
                line += " in its window \(ww)x\(wh)"
                if let fl = sdlFlags { line += String(format: " flags %llx", fl(win)) }
            } else {
                line += " (no SDL mouse focus)"
            }
            if let g = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SDL_GetGlobalMouseState"), !sdl3,
                let f = fraction,
                let win = sdlWindow(), let size = sdlSize
            {
                typealias G = @convention(c) (UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> UInt32
                var gx: Int32 = 0
                var gy: Int32 = 0
                var x: Int32 = 0
                var y: Int32 = 0
                var w: Int32 = 0
                var h: Int32 = 0
                _ = unsafeBitCast(g, to: G.self)(&gx, &gy)
                sdlPosition?(win, &x, &y)
                _ = size(win, &w, &h)
                line += String(
                    format:
                        "; global %d,%d at window %d,%d: in it %d,%d, the pane's fraction %.3f,%.3f of %dx%d is %.0f,%.0f",
                    gx, gy, x, y, gx - x, gy - y, f.x, f.y, w, h, f.x * Double(w), f.y * Double(h))
            }
            let path = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/rexui-embed.log")
            if let h = FileHandle(forWritingAtPath: path)
                ?? {
                    FileManager.default.createFile(atPath: path, contents: nil)
                    return FileHandle(forWritingAtPath: path)
                }()
            {
                h.seekToEndOfFile()
                h.write((line + "\n").data(using: .utf8)!)
                h.closeFile()
            }
        }
    }

    static var rects: [(view: NSView, rect: NSRect, cursor: NSCursor)] = []
    static var mouse: NSPoint?
    static var resetting = false
    static var picked = ""

    static func hookCursorRects() {
        hook(NSView.self, #selector(NSView.addCursorRect(_:cursor:))) { imp in
            typealias F = @convention(c) (AnyObject, Selector, NSRect, NSCursor) -> Void
            let orig = unsafeBitCast(imp, to: F.self)
            let b: @convention(block) (NSView, NSRect, NSCursor) -> Void = { v, r, c in
                if let w = v.window, isAdopted(w) { rects.append((v, r, c)) }
                orig(v, #selector(NSView.addCursorRect(_:cursor:)), r, c)
            }
            return b
        }
        hook(NSWindow.self, #selector(NSWindow.invalidateCursorRects(for:))) { imp in
            typealias F = @convention(c) (AnyObject, Selector, NSView) -> Void
            let orig = unsafeBitCast(imp, to: F.self)
            let b: @convention(block) (NSWindow, NSView) -> Void = { w, v in
                orig(w, #selector(NSWindow.invalidateCursorRects(for:)), v)
                if isAdopted(w) { DispatchQueue.main.async { resetCursorRects() } }
            }
            return b
        }
    }

    static func resetCursorRects() {
        guard let w = adopted, !resetting else { return }
        resetting = true
        rects.removeAll()
        func visit(_ v: NSView) {
            if !v.isHidden { v.resetCursorRects() }
            for s in v.subviews { visit(s) }
        }
        if let root = w.contentView?.superview ?? w.contentView { visit(root) }
        resetting = false
        pickCursor()
    }

    static func pickCursor() {
        guard let p = mouse, let w = adopted else { return }
        var best: (depth: Int, cursor: NSCursor)?
        for r in rects where r.view.window === w && !isSDLText(r.view) {
            let local = r.view.convert(p, from: nil)
            guard r.rect.contains(local) else { continue }
            var d = 0
            var s = r.view.superview
            while s != nil {
                d += 1
                s = s?.superview
            }
            if best == nil || d >= best!.depth { best = (d, r.cursor) }
        }
        guard let c = best?.cursor else {
            picked = ""
            return
        }
        let name = Cursor.name(c)
        if PaneLink.debug, name != picked {
            let reps = c.image.representations.map { "\(type(of: $0)) \($0.pixelsWide)x\($0.pixelsHigh)" }
            rexPaneLine("embed: cursor rect \(name), image \(c.image.size) \(reps)")
        }
        guard name != picked else { return }
        picked = name
        Cursor.last = name
        if !Cursor.hidden { Cursor.report?(name) }
    }

    static var firstClickClasses = Set<ObjectIdentifier>()

    static func acceptFirstClicks(_ w: NSWindow) {
        func visit(_ v: NSView) {
            var cls: AnyClass? = type(of: v)
            while let c = cls, c != NSResponder.self {
                if !firstClickClasses.contains(ObjectIdentifier(c)),
                    let m = class_getInstanceMethod(c, #selector(NSView.acceptsFirstMouse(for:))),
                    method_getImplementation(m)
                        != class_getMethodImplementation(
                            class_getSuperclass(c), #selector(NSView.acceptsFirstMouse(for:))) || c == NSView.self
                {
                    firstClickClasses.insert(ObjectIdentifier(c))
                    hook(c, #selector(NSView.acceptsFirstMouse(for:))) { imp in
                        typealias F = @convention(c) (AnyObject, Selector, NSEvent?) -> Bool
                        let orig = unsafeBitCast(imp, to: F.self)
                        let b: @convention(block) (NSView, NSEvent?) -> Bool = { v, e in
                            (v.window.map(isAdopted) ?? false) || orig(v, #selector(NSView.acceptsFirstMouse(for:)), e)
                        }
                        return b
                    }
                }
                cls = class_getSuperclass(c)
            }
            for s in v.subviews { visit(s) }
        }
        if let root = w.contentView?.superview ?? w.contentView { visit(root) }
    }

    static func paneFrameSize(_ w: NSWindow) -> NSSize? {
        guard let p = link?.paneSize else { return nil }
        let c = p
        if let v = w.contentView, v.frame.width > 0, v.frame.height > 0 {
            let extra = NSSize(width: w.frame.width - v.frame.width, height: w.frame.height - v.frame.height)
            if extra.width >= 0, extra.height >= 0 {
                return NSSize(width: c.width + extra.width, height: c.height + extra.height)
            }
        }
        return w.frameRect(forContentRect: NSRect(origin: .zero, size: c)).size
    }

    typealias GetBool = @convention(c) (AnyObject, Selector) -> Bool
    typealias GetObject = @convention(c) (AnyObject, Selector) -> AnyObject?
    typealias Constrain = @convention(c) (AnyObject, Selector, NSRect, NSScreen?) -> NSRect
    typealias SetFrame = @convention(c) (AnyObject, Selector, NSRect, Bool) -> Void
    typealias SetOrigin = @convention(c) (AnyObject, Selector, NSPoint) -> Void
    typealias Order = @convention(c) (AnyObject, Selector, Int, Int) -> Void

    static func candidate(_ w: NSWindow) -> Bool {
        if wine {
            return NSStringFromClass(type(of: w)) == "WineWindow" && w.parent == nil && w.level == .normal
                && w.frame.width >= 320 && w.frame.height >= 240
        }
        return !(w is NSPanel) && w.level == .normal && w.frame.width >= 200 && w.frame.height >= 150
    }

    static func hookActivation() {
        let app: AnyClass = NSApplication.self
        let nothing: @convention(block) (AnyObject) -> Void = { _ in }
        let nothingWith: @convention(block) (AnyObject, Bool) -> Void = { _, _ in }
        hook(app, NSSelectorFromString("activateIgnoringOtherApps:")) { _ in nothingWith }
        hook(app, NSSelectorFromString("activate")) { _ in nothing }
        let activate: @convention(block) (NSRunningApplication, UInt) -> Bool = { _, _ in true }
        if NSRunningApplication.current.responds(to: NSSelectorFromString("activateWithOptions:")) {
            hook(NSRunningApplication.self, NSSelectorFromString("activateWithOptions:")) { imp in
                typealias F = @convention(c) (AnyObject, Selector, UInt) -> Bool
                let orig = unsafeBitCast(imp, to: F.self)
                let b: @convention(block) (NSRunningApplication, UInt) -> Bool = { r, o in
                    r.processIdentifier == getpid()
                        ? activate(r, o) : orig(r, NSSelectorFromString("activateWithOptions:"), o)
                }
                return b
            }
        }
        do {
            hook(app, #selector(NSApplication.setActivationPolicy(_:))) { imp in
                typealias F = @convention(c) (AnyObject, Selector, Int) -> Bool
                let orig = unsafeBitCast(imp, to: F.self)
                let b: @convention(block) (AnyObject, Int) -> Bool = { a, _ in
                    orig(
                        a, #selector(NSApplication.setActivationPolicy(_:)),
                        NSApplication.ActivationPolicy.accessory.rawValue)
                }
                return b
            }
        }
        hook(app, NSSelectorFromString("isActive")) { imp in
            let orig = unsafeBitCast(imp, to: GetBool.self)
            let b: @convention(block) (AnyObject) -> Bool = { a in
                adopted != nil ? focused : orig(a, NSSelectorFromString("isActive"))
            }
            return b
        }
        hook(app, NSSelectorFromString("keyWindow")) { imp in
            let orig = unsafeBitCast(imp, to: GetObject.self)
            let b: @convention(block) (AnyObject) -> AnyObject? = { a in
                adopted != nil ? (focused ? adopted : nil) : orig(a, NSSelectorFromString("keyWindow"))
            }
            return b
        }
        hook(app, NSSelectorFromString("mainWindow")) { imp in
            let orig = unsafeBitCast(imp, to: GetObject.self)
            let b: @convention(block) (AnyObject) -> AnyObject? = { a in
                adopted ?? orig(a, NSSelectorFromString("mainWindow"))
            }
            return b
        }
    }

    static var hookedWindowClasses = Set<ObjectIdentifier>()

    static func hookWindows(_ win: AnyClass = NSWindow.self) {
        guard hookedWindowClasses.insert(ObjectIdentifier(win)).inserted else { return }
        let base = win === NSWindow.self
        func hook(_ cls: AnyClass, _ sel: Selector, _ make: (IMP) -> Any) {
            guard cls === win else {
                if base { Embed.hook(cls, sel, make) }
                return
            }
            if !base, class_getMethodImplementation(win, sel) == class_getMethodImplementation(NSWindow.self, sel) {
                return
            }
            Embed.hook(cls, sel, make)
        }
        hook(win, NSSelectorFromString("isKeyWindow")) { imp in
            let orig = unsafeBitCast(imp, to: GetBool.self)
            let b: @convention(block) (NSWindow) -> Bool = { w in
                isAdopted(w) || (wine && adopted != nil && w === Wine.keyTarget)
                    ? focused : orig(w, NSSelectorFromString("isKeyWindow"))
            }
            return b
        }
        hook(win, NSSelectorFromString("isMainWindow")) { imp in
            let orig = unsafeBitCast(imp, to: GetBool.self)
            let b: @convention(block) (NSWindow) -> Bool = { w in
                isAdopted(w) ? true : orig(w, NSSelectorFromString("isMainWindow"))
            }
            return b
        }
        hook(win, #selector(NSWindow.constrainFrameRect(_:to:))) { imp in
            let orig = unsafeBitCast(imp, to: Constrain.self)
            let b: @convention(block) (NSWindow, NSRect, NSScreen?) -> NSRect = { w, r, s in
                isAdopted(w) ? r : orig(w, #selector(NSWindow.constrainFrameRect(_:to:)), r, s)
            }
            return b
        }
        hook(win, #selector(NSWindow.setFrame(_:display:))) { imp in
            let orig = unsafeBitCast(imp, to: SetFrame.self)
            let b: @convention(block) (NSWindow, NSRect, Bool) -> Void = { w, r, d in
                guard isAdopted(w) else { return orig(w, #selector(NSWindow.setFrame(_:display:)), r, d) }
                if wine, Wine.fullScreen(r) { return orig(w, #selector(NSWindow.setFrame(_:display:)), r, d) }
                if wine, !PaneLink.sizing {
                    DispatchQueue.main.async { hideButtons(w) }
                    return orig(
                        w, #selector(NSWindow.setFrame(_:display:)),
                        NSRect(origin: Wine.origin(w, r.size), size: r.size), d)
                }
                let size = paneFrameSize(w) ?? r.size
                orig(w, #selector(NSWindow.setFrame(_:display:)), NSRect(origin: PaneLink.origin, size: size), d)
                DispatchQueue.main.async { hideButtons(w) }
                if size != r.size {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: w)
                    }
                }
            }
            return b
        }
        hook(win, #selector(NSWindow.sendEvent(_:))) { imp in
            typealias F = @convention(c) (AnyObject, Selector, NSEvent) -> Void
            let orig = unsafeBitCast(imp, to: F.self)
            let b: @convention(block) (NSWindow, NSEvent) -> Void = { w, e in
                if isAdopted(w), !wine, e.type == .mouseMoved, let c = w.contentView {
                    let v = c.superview?.hitTest(e.locationInWindow) ?? c
                    (v is NSTextView && isSDLText(v) ? c : v).mouseMoved(with: e)
                    return
                }
                orig(w, #selector(NSWindow.sendEvent(_:)), e)
            }
            return b
        }
        hook(win, #selector(NSWindow.setContentSize(_:))) { imp in
            typealias F = @convention(c) (AnyObject, Selector, NSSize) -> Void
            let orig = unsafeBitCast(imp, to: F.self)
            let b: @convention(block) (NSWindow, NSSize) -> Void = { w, s in
                if isAdopted(w), !wine, let f = paneFrameSize(w) {
                    w.setFrame(NSRect(origin: PaneLink.origin, size: f), display: true)
                } else {
                    orig(w, #selector(NSWindow.setContentSize(_:)), s)
                }
            }
            return b
        }
        hook(win, #selector(NSWindow.setFrameOrigin(_:))) { imp in
            let orig = unsafeBitCast(imp, to: SetOrigin.self)
            let b: @convention(block) (NSWindow, NSPoint) -> Void = { w, p in
                let o =
                    !isAdopted(w)
                    ? p : wine ? (Wine.fullScreen(w.frame) ? p : Wine.origin(w, w.frame.size)) : PaneLink.origin
                orig(w, #selector(NSWindow.setFrameOrigin(_:)), o)
            }
            return b
        }
        hook(win, #selector(getter: NSWindow.occlusionState)) { imp in
            typealias F = @convention(c) (AnyObject, Selector) -> UInt
            let orig = unsafeBitCast(imp, to: F.self)
            let b: @convention(block) (NSWindow) -> UInt = { w in
                isAdopted(w)
                    ? NSWindow.OcclusionState.visible.rawValue : orig(w, #selector(getter: NSWindow.occlusionState))
            }
            return b
        }
        hook(win, #selector(getter: NSWindow.screen)) { imp in
            typealias F = @convention(c) (AnyObject, Selector) -> NSScreen?
            let orig = unsafeBitCast(imp, to: F.self)
            let b: @convention(block) (NSWindow) -> NSScreen? = { w in
                let s = orig(w, #selector(getter: NSWindow.screen))
                return isAdopted(w) && s == nil && !sdlApp() ? (NSScreen.main ?? NSScreen.screens.first) : s
            }
            return b
        }
        for sel in [#selector(NSWindow.miniaturize(_:)), #selector(NSWindow.performMiniaturize(_:))] {
            hook(win, sel) { imp in
                typealias F = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
                let orig = unsafeBitCast(imp, to: F.self)
                let b: @convention(block) (NSWindow, AnyObject?) -> Void = { w, s in
                    if !isAdopted(w) { return orig(w, sel, s) }
                    if wine { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Wine.unminimize(w) } }
                }
                return b
            }
        }
        hook(win, #selector(setter: NSWindow.isMovable)) { imp in
            typealias F = @convention(c) (AnyObject, Selector, Bool) -> Void
            let orig = unsafeBitCast(imp, to: F.self)
            let b: @convention(block) (NSWindow, Bool) -> Void = { w, m in
                orig(w, #selector(setter: NSWindow.isMovable), isAdopted(w) ? false : m)
            }
            return b
        }
        hook(NSView.self, #selector(getter: NSView.mouseDownCanMoveWindow)) { imp in
            let orig = unsafeBitCast(imp, to: GetBool.self)
            let b: @convention(block) (NSView) -> Bool = { v in
                if let w = v.window, isAdopted(w) { return false }
                return orig(v, #selector(getter: NSView.mouseDownCanMoveWindow))
            }
            return b
        }
        hook(win, #selector(NSWindow.performDrag(with:))) { imp in
            typealias F = @convention(c) (AnyObject, Selector, NSEvent) -> Void
            let orig = unsafeBitCast(imp, to: F.self)
            let b: @convention(block) (NSWindow, NSEvent) -> Void = { w, e in
                if !isAdopted(w) { orig(w, #selector(NSWindow.performDrag(with:)), e) }
            }
            return b
        }
        hook(NSView.self, #selector(NSView.hitTest(_:))) { imp in
            typealias F = @convention(c) (AnyObject, Selector, NSPoint) -> NSView?
            let orig = unsafeBitCast(imp, to: F.self)
            let b: @convention(block) (NSView, NSPoint) -> NSView? = { v, p in
                let r = orig(v, #selector(NSView.hitTest(_:)), p)
                if let r, let w = r.window, isAdopted(w), isSDLText(r) { return r.superview }
                return r
            }
            return b
        }
        hook(win, #selector(NSWindow.order(_:relativeTo:))) { imp in
            let orig = unsafeBitCast(imp, to: Order.self)
            let b: @convention(block) (NSWindow, Int, Int) -> Void = { w, place, other in
                let showing = place != NSWindow.OrderingMode.out.rawValue
                if PaneLink.debug {
                    rexPaneLine(
                        "embed: order \(place) \(type(of: w)) '\(w.title)' \(w.frame) level \(w.level.rawValue) candidate \(candidate(w)) adopted \(adopted.map { $0 === w } ?? false)"
                    )
                }
                if wine, showing, !launched, NSApp != nil {
                    DispatchQueue.main.async { launch() }
                    launched = true
                }
                if wine, showing, let a = adopted, w !== a, NSStringFromClass(type(of: w)) == "WineWindow",
                    w.frame.intersects(a.frame)
                {
                    Wine.hidePopup(w)
                    DispatchQueue.main.async { Wine.popups() }
                }
                if showing, adopted == nil, launched, candidate(w) { adopt(w) }
                orig(w, #selector(NSWindow.order(_:relativeTo:)), place, other)
                if wine, !showing, isAdopted(w) { release() }
            }
            return b
        }
        hook(win, #selector(setter: NSWindow.level)) { imp in
            typealias F = @convention(c) (AnyObject, Selector, Int) -> Void
            let orig = unsafeBitCast(imp, to: F.self)
            let b: @convention(block) (NSWindow, Int) -> Void = { w, l in
                orig(w, #selector(setter: NSWindow.level), isAdopted(w) ? NSWindow.Level.normal.rawValue : l)
            }
            return b
        }
        hook(win, #selector(NSWindow.accessibilitySubrole)) { imp in
            typealias F = @convention(c) (AnyObject, Selector) -> NSAccessibility.Subrole?
            let orig = unsafeBitCast(imp, to: F.self)
            let b: @convention(block) (NSWindow) -> NSAccessibility.Subrole? = { w in
                isAdopted(w) ? .floatingWindow : orig(w, #selector(NSWindow.accessibilitySubrole))
            }
            return b
        }
        hook(win, #selector(NSWindow.toggleFullScreen(_:))) { imp in
            typealias F = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
            let orig = unsafeBitCast(imp, to: F.self)
            let b: @convention(block) (NSWindow, AnyObject?) -> Void = { w, s in
                if !isAdopted(w) { orig(w, #selector(NSWindow.toggleFullScreen(_:)), s) }
            }
            return b
        }
    }

    static func hook(_ cls: AnyClass, _ sel: Selector, _ make: (IMP) -> Any) {
        guard let m = class_getInstanceMethod(cls, sel) else { return }
        let imp = imp_implementationWithBlock(make(method_getImplementation(m)))
        if !class_addMethod(cls, sel, imp, method_getTypeEncoding(m)) { method_setImplementation(m, imp) }
    }
}

enum FirstFrame {
    static let lock = NSLock()
    static var watched = Set<ObjectIdentifier>()
    static var active = false
    static var seen = false
    static var startedAt = 0.0
    static let logging = PaneLink.debug
    static let logFor = 25.0
    static let logPath = NSHomeDirectory() + "/Library/Logs/rexui-embed-frames.log"
    static func log(_ s: String) {
        let t = ProcessInfo.processInfo.systemUptime - startedAt
        guard logging, t < logFor + 1 else { return }
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = String(format: "%@ %6.2f [%d] ", stamp.string(from: Date()), t, getpid()) + s + "\n"
        if let h = FileHandle(forWritingAtPath: logPath)
            ?? (FileManager.default.createFile(atPath: logPath, contents: nil)
                ? FileHandle(forWritingAtPath: logPath) : nil)
        {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        }
    }
    static var pending: MTLTexture?
    static var inFlight = false
    static var streak = 0
    static var lastSample = 0.0
    static var queues: [ObjectIdentifier: MTLCommandQueue] = [:]
    static var layers: [(layer: CAMetalLayer, fbOnly: Bool)] = []
    static var onSeen: (() -> Void)?
    static var generation = 0
    static var hookedClasses = Set<ObjectIdentifier>()
    static var gone = Set<ObjectIdentifier>()
    static let base = class_getMethodImplementation(CAMetalLayer.self, #selector(CAMetalLayer.nextDrawable))

    static func start(_ report: @escaping () -> Void) {
        stop()
        onSeen = report
        lock.lock()
        active = true
        seen = false
        streak = 0
        startedAt = ProcessInfo.processInfo.systemUptime
        lock.unlock()
        generation += 1
        let g = generation
        log("adopted '\(Embed.adopted?.title ?? "")' \(Embed.adopted.map { "\($0.frame.size)" } ?? "")")
        hook(CAMetalLayer.self)
        scan()
        if logging {
            DispatchQueue.main.asyncAfter(deadline: .now() + logFor) {
                guard g == generation, seen else { return }
                log("done")
                stop()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            guard g == generation, onSeen != nil, !seen else { return }
            Wine.trace("first frame: none seen in 30 s, drawn anyway")
            log("none seen in 30 s: drawn anyway")
            seenNow()
            stop()
        }
    }

    static func stop() {
        lock.lock()
        active = false
        watched.removeAll()
        pending = nil
        lock.unlock()
        for l in layers { l.layer.framebufferOnly = l.fbOnly }
        layers.removeAll()
        gone.removeAll()
        onSeen = nil
    }

    static func seenNow() {
        guard !seen else { return }
        seen = true
        let f = onSeen
        f?()
        if !logging || ProcessInfo.processInfo.systemUptime - startedAt >= logFor { stop() }
    }

    static func scan() {
        guard onSeen != nil, let w = Embed.adopted, let root = w.contentView?.superview?.layer ?? w.contentView?.layer
        else { return }
        var found: [CAMetalLayer] = []
        func walk(_ l: CALayer, _ depth: Int) {
            if let m = l as? CAMetalLayer { found.append(m) }
            guard depth < 12 else { return }
            for s in l.sublayers ?? [] { walk(s, depth + 1) }
        }
        walk(root, 0)
        for l in layers where !found.contains(where: { $0 === l.layer }) {
            if gone.insert(ObjectIdentifier(l.layer)).inserted {
                log("layer \(UInt(bitPattern: ObjectIdentifier(l.layer).hashValue) & 0xFFFF) left the window")
            }
        }
        for m in found where !layers.contains(where: { $0.layer === m }) {
            hook(type(of: m))
            layers.append((m, m.framebufferOnly))
            m.framebufferOnly = false
            lock.lock()
            watched.insert(ObjectIdentifier(m))
            lock.unlock()
            Wine.trace("first frame: watching \(type(of: m)) \(m.drawableSize) \(m.pixelFormat.rawValue)")
            log(
                "watching layer \(UInt(bitPattern: ObjectIdentifier(m).hashValue) & 0xFFFF) \(type(of: m)) drawable \(m.drawableSize) bounds \(m.bounds.size) format \(m.pixelFormat.rawValue) hidden \(m.isHidden) opacity \(m.opacity)"
            )
        }
    }

    typealias Next = @convention(c) (CAMetalLayer, Selector) -> CAMetalDrawable?

    static func hook(_ cls: AnyClass) {
        guard hookedClasses.insert(ObjectIdentifier(cls)).inserted else { return }
        let sel = #selector(CAMetalLayer.nextDrawable)
        if cls !== CAMetalLayer.self,
            class_getMethodImplementation(cls, sel) == class_getMethodImplementation(CAMetalLayer.self, sel)
        {
            return
        }
        Embed.hook(cls, sel) { imp in
            let orig = unsafeBitCast(imp, to: Next.self)
            let b: @convention(block) (CAMetalLayer) -> CAMetalDrawable? = { layer in
                let d = orig(layer, #selector(CAMetalLayer.nextDrawable))
                drew(layer, d)
                return d
            }
            return b
        }
    }

    static func drew(_ layer: CAMetalLayer, _ d: CAMetalDrawable?) {
        lock.lock()
        guard active, watched.contains(ObjectIdentifier(layer)) else {
            lock.unlock()
            return
        }
        let read = pending
        pending = nil
        let now = ProcessInfo.processInfo.systemUptime
        if read == nil, !inFlight, now - lastSample >= 0.15, let t = d?.texture, !t.isFramebufferOnly {
            pending = t
            lastSample = now
        }
        var queue: MTLCommandQueue?
        if let t = read {
            let key = ObjectIdentifier(t.device)
            if queues[key] == nil { queues[key] = t.device.makeCommandQueue() }
            queue = queues[key]
            if queue != nil { inFlight = true }
        }
        lock.unlock()
        if let t = read, let q = queue { sample(t, q, UInt(bitPattern: ObjectIdentifier(layer).hashValue) & 0xFFFF) }
    }

    static func sample(_ t: MTLTexture, _ q: MTLCommandQueue, _ layerID: UInt) {
        let (bpp, mask): (Int, UInt64)
        switch t.pixelFormat {
        case .bgra8Unorm, .bgra8Unorm_srgb, .rgba8Unorm, .rgba8Unorm_srgb: (bpp, mask) = (4, 0x00FF_FFFF)
        case .rgb10a2Unorm, .bgr10a2Unorm: (bpp, mask) = (4, 0x3FFF_FFFF)
        case .rgba16Float: (bpp, mask) = (8, 0x0000_FFFF_FFFF_FFFF)
        default: (bpp, mask) = (0, 0)
        }
        let n = 9
        guard bpp > 0, t.width >= n, t.height >= n, t.sampleCount == 1,
            let buf = t.device.makeBuffer(length: n * n * bpp, options: .storageModeShared),
            let cb = q.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder()
        else {
            lock.lock()
            inFlight = false
            lock.unlock()
            return
        }
        for i in 0..<(n * n) {
            let x = (2 * (i % n) + 1) * t.width / (2 * n)
            let y = (2 * (i / n) + 1) * t.height / (2 * n)
            blit.copy(
                from: t, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: x, y: y, z: 0),
                sourceSize: MTLSize(width: 1, height: 1, depth: 1),
                to: buf, destinationOffset: i * bpp, destinationBytesPerRow: bpp, destinationBytesPerImage: bpp)
        }
        blit.endEncoding()
        cb.addCompletedHandler { _ in
            let p = buf.contents()
            func px(_ i: Int) -> UInt64 {
                bpp == 8
                    ? p.load(fromByteOffset: i * 8, as: UInt64.self) & mask
                    : UInt64(p.load(fromByteOffset: i * 4, as: UInt32.self)) & mask
            }
            let first = px(0)
            var other = 0
            for i in 1..<(n * n) where px(i) != first { other += 1 }
            var mean = 0.0
            if bpp == 4, mask == 0x00FF_FFFF {
                for i in 0..<(n * n) {
                    let v = px(i)
                    let sum: UInt64 = (v & 0xFF) + ((v >> 8) & 0xFF) + ((v >> 16) & 0xFF)
                    mean += Double(sum) / 3
                }
                mean /= Double(n * n)
            }
            log("layer \(layerID) \(t.width)x\(t.height): \(other) of \(n * n) differ, mean \(Int(mean))")
            let picture = bpp == 4 && mask == 0x00FF_FFFF ? other >= (n * n) / 4 && mean >= 24 : other >= (n * n) / 2
            lock.lock()
            inFlight = false
            streak = picture ? streak + 1 : 0
            let report = !seen && active && streak >= 2
            lock.unlock()
            guard report else { return }
            DispatchQueue.main.async {
                log("drawn: told rexui")
                Wine.trace("first frame: drawn (\(other) of \(n * n) points differ)")
                seenNow()
            }
        }
        cb.commit()
    }
}

enum WineProgram {
    static let path: String? = {
        let a = CommandLine.arguments
        guard a.count >= 2 else { return nil }
        let p = a[1]
        guard p.count > 3, p.first!.isLetter, p.dropFirst().first == ":", "\\/".contains(p.dropFirst(2).first!) else {
            return nil
        }
        return p
    }()
    static let exe: String? = path.map {
        String($0.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last ?? "").lowercased()
    }
    static let name: String? = exe.map { $0.hasSuffix(".exe") ? String($0.dropLast(4)) : $0 }.map {
        $0.prefix(1).uppercased() + $0.dropFirst()
    }

    static let system: Set<String> = [
        "wineboot.exe", "services.exe", "winedevice.exe", "plugplay.exe", "svchost.exe",
        "explorer.exe", "rpcss.exe", "winewrapper.exe", "conhost.exe", "start.exe", "cmd.exe", "rundll32.exe",
        "tabtip.exe", "winemenubuilder.exe", "cxmanip.exe", "mscorsvw.exe", "crashpad_handler.exe",
    ]

    static var wanted: Bool {
        guard let exe, !system.contains(exe) else { return false }
        let only = (ProcessInfo.processInfo.environment["REXUI_EMBED_EXE"] ?? "").lowercased().split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map {
                $0.hasSuffix(".exe") ? $0 : $0 + ".exe"
            }
        return only.isEmpty || only.contains(exe)
    }
}

enum Lock {
    static var fd: Int32 = -1
    static func take() -> Bool {
        if fd >= 0 { return true }
        let env = ProcessInfo.processInfo.environment
        let targeted = PaneLink.retarget()
        let path =
            (targeted ? nil : env["REXUI_EMBED_LOCK"])
            ?? ((env["TMPDIR"] ?? "/tmp/")
                + "rexui-embed-\(String((PaneLink.block ?? "").map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })).lock")
        let f = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard f >= 0 else { return false }
        guard flock(f, LOCK_EX | LOCK_NB) == 0 else {
            close(f)
            return false
        }
        fd = f
        return true
    }
    static func give() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }
}

enum Wine {
    static func start() {
        if let s = NSScreen.screens.first { PaneLink.origin = s.frame.origin }
        PaneLink.screenChanged = { r in
            pane = r
            guard let w = Embed.adopted, !fullScreen(w.frame) else { return }
            PaneLink.origin = origin(w, w.frame.size)
            if w.frame.origin != PaneLink.origin { w.setFrameOrigin(PaneLink.origin) }
        }
        hookWindowAtPoint()
        PaneLink.postScrolls = true
        PaneLink.keysToWindow = true
        PaneLink.moveTo = { _, dx, dy in lockedMove(dx, dy) }
        PaneLink.tellsFocusLoss = false
        if ProcessInfo.processInfo.environment["REXUI_WINE_KEYS"] == "dvorak" {
            PaneLink.keyMap = [43: 13, 31: 1, 14: 2]
        }
        var askedAt: Date?
        PaneLink.quit = {
            if let t = askedAt, Date().timeIntervalSince(t) < 20 {
                rexPaneLine("embed: cmd+q again: \(WineProgram.name ?? "the program") ended")
                exit(0)
            }
            askedAt = Date()
            guard let w = Embed.adopted, let d = w.delegate,
                d.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:)))
            else {
                rexPaneLine("embed: cmd+q: no window to close: \(WineProgram.name ?? "the program") ended")
                exit(0)
            }
            rexPaneLine(
                "embed: cmd+q: \(WineProgram.name ?? "the program") asked to close its window (cmd+q again within 20 s ends it)"
            )
            _ = d.windowShouldClose?(w)
        }
        PaneLink.sizable = { $0.styleMask.contains(.resizable) && !fullScreen($0.frame) }
        PaneLink.keyWindow = { keyTarget }
        Embed.hook(NSEvent.self, #selector(getter: NSEvent.window)) { imp in
            typealias F = @convention(c) (AnyObject, Selector) -> NSWindow?
            let orig = unsafeBitCast(imp, to: F.self)
            let b: @convention(block) (NSEvent) -> NSWindow? = { e in
                if e.type == .scrollWheel, let w = Embed.adopted,
                    e.cgEvent?.getIntegerValueField(.eventSourceUserData) == PaneLink.postedMark
                {
                    return w
                }
                return orig(e, #selector(getter: NSEvent.window))
            }
            return b
        }
        Embed.hook(NSWindow.self, #selector(setter: NSWindow.alphaValue)) { imp in
            typealias F = @convention(c) (AnyObject, Selector, CGFloat) -> Void
            let orig = unsafeBitCast(imp, to: F.self)
            let b: @convention(block) (NSWindow, CGFloat) -> Void = { w, a in
                orig(w, #selector(setter: NSWindow.alphaValue), Embed.isAdopted(w) || isHidden(w) ? 0 : a)
            }
            return b
        }
        Embed.hook(NSWindow.self, #selector(setter: NSWindow.ignoresMouseEvents)) { imp in
            typealias F = @convention(c) (AnyObject, Selector, Bool) -> Void
            let orig = unsafeBitCast(imp, to: F.self)
            let b: @convention(block) (NSWindow, Bool) -> Void = { w, i in
                orig(w, #selector(setter: NSWindow.ignoresMouseEvents), Embed.isAdopted(w) || isHidden(w) || i)
            }
            return b
        }
    }

    static func hide(_ w: NSWindow) {
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        DispatchQueue.main.async { forward(throttled: false) }
    }

    static var forwarded = 0.0

    static var traced = 0
    static func trace(_ s: String) {
        guard PaneLink.debug, traced < 4000 else { return }
        traced += 1
        rexPaneLine("embed: \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime)) \(s)")
    }

    static let clipper = Clipper()
    static var installed = false
    static var locked: CGPoint?

    static func install(_ c: AnyObject) -> Bool {
        if installed { return true }
        guard let iv = class_getInstanceVariable(type(of: c), "clipCursorHandler") else { return false }
        object_setIvar(c, iv, clipper)
        _ = Unmanaged.passRetained(clipper)
        installed = true
        trace("clip handler installed")
        return true
    }

    static func hookClipping() {
        guard let cls = NSClassFromString("WineApplicationController") else { return }
        if let c = NSApp?.delegate as? NSObject, c.isKind(of: cls) { _ = install(c) }
        let start = NSSelectorFromString("startClippingCursor:")
        Embed.hook(cls, start) { imp in
            typealias F = @convention(c) (AnyObject, Selector, CGRect) -> Bool
            let orig = unsafeBitCast(imp, to: F.self)
            let b: @convention(block) (AnyObject, CGRect) -> Bool = { c, r in
                if install(c) || Embed.adopted == nil { return orig(c, start, r) }
                rexuiEmbedCapture(1)
                return true
            }
            return b
        }
        let stop = NSSelectorFromString("stopClippingCursor")
        Embed.hook(cls, stop) { imp in
            typealias F = @convention(c) (AnyObject, Selector) -> Bool
            let orig = unsafeBitCast(imp, to: F.self)
            let b: @convention(block) (AnyObject) -> Bool = { c in
                if !installed { rexuiEmbedCapture(0) }
                return orig(c, stop)
            }
            return b
        }
        let move = NSSelectorFromString("handleMouseMove:")
        Embed.hook(cls, move) { imp in
            typealias F = @convention(c) (AnyObject, Selector, NSEvent) -> Void
            let orig = unsafeBitCast(imp, to: F.self)
            let b: @convention(block) (AnyObject, NSEvent) -> Void = { c, e in
                if let a = Embed.adopted, !PaneLink.posted(e),
                    e.window == nil || e.window === a || e.window.map(isHidden) == true
                {
                    trace(
                        "a move not the pane's dropped: \(e.locationInWindow) in \(e.window.map { "\($0.windowNumber)" } ?? "none")"
                    )
                    return
                }
                if clipper.locks { relative(c) }
                orig(c, move, e)
            }
            return b
        }
        let resign = NSSelectorFromString("applicationDidResignActive:")
        Embed.hook(cls, resign) { imp in
            typealias F = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
            let orig = unsafeBitCast(imp, to: F.self)
            let b: @convention(block) (AnyObject, AnyObject?) -> Void = { c, n in
                if Embed.adopted != nil { return trace("the app resigning active: not told") }
                orig(c, resign, n)
            }
            return b
        }
        if let win = NSClassFromString("WineWindow") {
            let key = NSSelectorFromString("windowDidResignKey:")
            Embed.hook(win, key) { imp in
                typealias F = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
                let orig = unsafeBitCast(imp, to: F.self)
                let b: @convention(block) (NSWindow, AnyObject?) -> Void = { w, n in
                    if Embed.isAdopted(w) { return trace("the window resigning key: not told") }
                    orig(w, key, n)
                }
                return b
            }
        }
    }

    static func clipChanged() {
        locked =
            clipper.locks
            ? centred(locked ?? pointer() ?? CGPoint(x: clipper.cursorClipRect.midX, y: clipper.cursorClipRect.midY))
            : nil
        trace(
            clipper.clippingCursor
                ? "clip \(clipper.cursorClipRect)\(clipper.locks ? ": locked at \(locked!)" : "")" : "clip none")
        rexuiEmbedCapture(clipper.locks ? 1 : 0)
    }

    static func centred(_ p: CGPoint) -> CGPoint {
        let r = clipper.cursorClipRect
        return CGPoint(x: max(min(p.x, r.maxX - 0.5), r.minX + 0.5), y: max(min(p.y, r.maxY - 0.5), r.minY + 0.5))
    }

    static func lockedMove(_ dx: Double, _ dy: Double) -> NSPoint? {
        guard clipper.locks, let w = Embed.adopted else { return nil }
        let r = clipper.cursorClipRect
        let from = locked ?? CGPoint(x: r.midX, y: r.midY)
        let p = centred(CGPoint(x: from.x + dx, y: from.y + dy))
        locked = p
        if traced < 600 { trace("locked move \(dx),\(dy) at \(p)") }
        let top = NSScreen.screens.first?.frame.height ?? 0
        return NSPoint(x: p.x - w.frame.minX, y: top - p.y - w.frame.minY)
    }

    static var forceAbsolute: Int?
    static func relative(_ c: AnyObject) {
        if forceAbsolute == nil, let iv = class_getInstanceVariable(type(of: c), "forceNextMouseMoveAbsolute") {
            forceAbsolute = ivar_getOffset(iv)
        }
        guard let off = forceAbsolute else { return }
        Unmanaged.passUnretained(c).toOpaque().advanced(by: off).storeBytes(of: false, as: Bool.self)
    }

    static func pointer() -> CGPoint? {
        guard let w = Embed.adopted, let m = Embed.mouse else { return nil }
        let s = w.convertPoint(toScreen: m)
        return CGPoint(x: s.x, y: (NSScreen.screens.first?.frame.height ?? 0) - s.y)
    }

    static func cursorLocation() -> NSPoint? {
        guard var p = locked ?? pointer() else { return nil }
        if clipper.clippingCursor { clipper.clipCursorLocation(&p) }
        return NSPoint(x: p.x, y: (NSScreen.screens.first?.frame.height ?? 0) - p.y)
    }

    static func unminimize(_ w: NSWindow) {
        let sel = NSSelectorFromString("postDidUnminimizeEvent")
        if Embed.isAdopted(w), w.responds(to: sel) { w.perform(sel) }
    }
    static var pane: NSRect?

    static func origin(_ w: NSWindow, _ size: NSSize) -> NSPoint {
        let c = w.contentView?.frame ?? NSRect(origin: .zero, size: w.frame.size)
        let above = w.frame.height - c.maxY
        guard let p = pane else { return PaneLink.origin }
        var o = NSPoint(x: p.minX - c.minX, y: p.maxY + above - size.height)
        if let s = (NSScreen.screens.first { $0.frame.intersects(p) } ?? NSScreen.screens.first)?.frame {
            if size.width <= s.width { o.x = min(max(o.x, s.minX), s.maxX - size.width) }
            if size.height <= s.height { o.y = min(max(o.y, s.minY), s.maxY - size.height) }
        }
        return o
    }

    static weak var front: NSWindow?
    static var keyTarget: NSWindow? {
        guard let main = Embed.adopted else { return nil }
        if disabled(main), let f = front, !disabled(f) { return f }
        return main
    }
    static func disabled(_ w: NSWindow) -> Bool {
        w.responds(to: NSSelectorFromString("disabled")) && (w.value(forKey: "disabled") as? Bool) == true
    }

    static let hidden = NSHashTable<NSWindow>.weakObjects()
    static var sentPopups = ""

    static func isHidden(_ w: NSWindow) -> Bool { hidden.contains(w) }

    static func hidePopup(_ w: NSWindow) {
        guard !hidden.contains(w) else { return }
        hidden.add(w)
        w.alphaValue = 0
        w.ignoresMouseEvents = true
    }

    static func unhidePopups() {
        let ws = hidden.allObjects
        hidden.removeAllObjects()
        sentPopups = ""
        for w in ws {
            w.alphaValue = 1
            w.ignoresMouseEvents = false
        }
    }

    static func popups() {
        guard let main = Embed.adopted, let link = Embed.link else { return }
        let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        let pid = getpid()
        var front: [NSWindow] = []
        for d in info where (d[kCGWindowOwnerPID as String] as? Int).map(Int32.init) == pid {
            guard let n = d[kCGWindowNumber as String] as? Int, let w = NSApp.window(withWindowNumber: n), w !== main,
                NSStringFromClass(type(of: w)) == "WineWindow", w.frame.width > 2, w.frame.height > 2,
                w.frame.intersects(main.frame)
            else { continue }
            front.append(w)
        }
        for w in front { hidePopup(w) }
        Wine.front = front.first
        let list: [[String: Any]] = front.reversed().map { w in
            [
                "context": Int(PaneLink.context(of: w)),
                "frame": [
                    Double(w.frame.minX - main.frame.minX), Double(w.frame.minY - main.frame.minY),
                    Double(w.frame.width), Double(w.frame.height),
                ],
            ]
        }
        let key = list.map { "\($0["context"]!) \($0["frame"]!)" }.joined(separator: ";")
        guard key != sentPopups else { return }
        sentPopups = key
        link.sendPopups(list)
        if PaneLink.debug { rexPaneLine("embed: popups \(key)") }
    }

    static func fullScreen(_ r: NSRect) -> Bool {
        NSScreen.screens.contains { s in
            abs(s.frame.minX - r.minX) < 1 && abs(s.frame.minY - r.minY) < 1 && abs(s.frame.width - r.width) < 1
                && abs(s.frame.height - r.height) < 1
        }
    }

    static func forward(throttled: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard let w = Embed.adopted, !throttled || now - forwarded > 2 else { return }
        forwarded = now
        let sel = NSSelectorFromString("postBroughtForwardEvent")
        if w.responds(to: sel) { w.perform(sel) }
    }

    static func hookWindowAtPoint() {
        let meta: AnyClass = object_getClass(NSWindow.self)!
        let sel = NSSelectorFromString("windowNumberAtPoint:belowWindowWithWindowNumber:")
        Embed.hook(meta, sel) { imp in
            typealias F = @convention(c) (AnyObject, Selector, NSPoint, Int) -> Int
            let orig = unsafeBitCast(imp, to: F.self)
            let b: @convention(block) (AnyObject, NSPoint, Int) -> Int = { c, p, below in
                if below == 0, Thread.isMainThread, let w = Embed.adopted, w.frame.contains(p) { return w.windowNumber }
                return orig(c, sel, p, below)
            }
            return b
        }
    }
}

final class Clipper: NSObject {
    @objc private(set) var clippingCursor = false
    @objc private(set) var cursorClipRect = CGRect.zero

    var locks: Bool { clippingCursor && cursorClipRect.width <= 16 && cursorClipRect.height <= 16 }

    @objc(startClippingCursor:) func startClippingCursor(_ r: CGRect) -> Bool {
        clippingCursor = true
        cursorClipRect = r
        Wine.clipChanged()
        return true
    }

    @objc(stopClippingCursor) func stopClippingCursor() -> Bool {
        clippingCursor = false
        Wine.clipChanged()
        return true
    }

    @objc(clipCursorLocation:) func clipCursorLocation(_ p: UnsafeMutablePointer<CGPoint>) {
        let r = cursorClipRect
        p.pointee = CGPoint(x: max(min(p.pointee.x, r.maxX - 1), r.minX), y: max(min(p.pointee.y, r.maxY - 1), r.minY))
    }

    @objc(setRetinaMode:) func setRetinaMode(_ on: Bool) {
        let s: CGFloat = on ? 0.5 : 2
        let r = cursorClipRect
        cursorClipRect = CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s)
    }

    @objc(setCursorPosition:) func setCursorPosition(_ p: CGPoint) -> Bool {
        var q = p
        clipCursorLocation(&q)
        if locks { Wine.locked = Wine.centred(q) }
        Wine.trace("clipped cursor to \(q)")
        rexuiEmbedWarp(Double(q.x), Double(q.y))
        return true
    }
}

@_cdecl("rexui_embed_wine_mouse_location") public func rexuiEmbedWineMouseLocation(
    _ x: UnsafeMutablePointer<Double>, _ y: UnsafeMutablePointer<Double>
) -> Bool {
    guard Thread.isMainThread, let p = Wine.cursorLocation() else { return false }
    x.pointee = p.x
    y.pointee = p.y
    return true
}

@_cdecl("rexui_embed_cursor_hidden") public func rexuiEmbedCursorHidden(_ h: Int32) {
    DispatchQueue.main.async { Cursor.setHidden(h != 0) }
}

@_cdecl("rexui_embed_global_mouse") public func rexuiEmbedGlobalMouse(
    _ x: UnsafeMutablePointer<Double>, _ y: UnsafeMutablePointer<Double>
) -> Bool {
    guard Thread.isMainThread, let p = Embed.globalMouse() else { return false }
    x.pointee = p.x
    y.pointee = p.y
    return true
}

@_cdecl("rexui_embed_mouse_location") public func rexuiEmbedMouseLocation(
    _ x: UnsafeMutablePointer<Double>, _ y: UnsafeMutablePointer<Double>
) -> Bool {
    guard Thread.isMainThread, let w = Embed.adopted, let p = Embed.mouse else { return false }
    let s = w.convertPoint(toScreen: p)
    x.pointee = s.x
    y.pointee = s.y
    return true
}

@_cdecl("rexui_embed_mouse_in_window") public func rexuiEmbedMouseInWindow(
    _ window: UnsafeRawPointer, _ x: UnsafeMutablePointer<Double>,
    _ y: UnsafeMutablePointer<Double>
) -> Bool {
    guard Thread.isMainThread, let w = Embed.adopted,
        Unmanaged.passUnretained(w).toOpaque() == UnsafeMutableRawPointer(mutating: window),
        let p = Embed.mouse
    else { return false }
    x.pointee = p.x
    y.pointee = p.y
    return true
}

@_cdecl("rexui_embed_adopted_frame") public func rexuiEmbedAdoptedFrame(_ r: UnsafeMutablePointer<Double>) -> Bool {
    guard Thread.isMainThread, let w = Embed.adopted else { return false }
    let f = w.frame
    (r[0], r[1], r[2], r[3]) = (f.minX, f.minY, f.width, f.height)
    return true
}

@_cdecl("rexui_embed_capture") public func rexuiEmbedCapture(_ on: Int32) {
    DispatchQueue.main.async { Embed.link?.sendSticky("capture", on != 0) }
}

@_cdecl("rexui_embed_warp") public func rexuiEmbedWarp(_ x: Double, _ y: Double) {
    if Thread.isMainThread, let w = Embed.adopted {
        let top = NSScreen.screens.first?.frame.height ?? 0
        Embed.mouse = NSPoint(x: x - w.frame.minX, y: (top - y) - w.frame.minY)
    }
    DispatchQueue.main.async {
        guard let w = Embed.adopted, let link = Embed.link else { return }
        let top = NSScreen.screens.first?.frame.height ?? 0
        let inWindow = NSPoint(x: x - w.frame.minX, y: (top - y) - w.frame.minY)
        let c = w.contentView?.frame ?? NSRect(origin: .zero, size: w.frame.size)
        link.send(["warp": [Double(inWindow.x - c.minX), Double(c.maxY - inWindow.y)]])
    }
}

@_cdecl("rexui_embed_start") public func rexuiEmbedStart() {
    let env = ProcessInfo.processInfo.environment
    guard PaneLink.block != nil else { return }
    if Embed.wine {
        guard WineProgram.wanted else { return }
    } else {
        guard env["REXUI_EMBED_PID"].flatMap(Int32.init) == getpid() else { return }
    }
    Embed.start()
}
