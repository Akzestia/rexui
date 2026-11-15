// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI

public final class RexPaneState: ObservableObject {
    public static let shared = RexPaneState()
    @Published public var focused = false
    @Published public var visible = true
    @Published public var embedded = false
}

public enum RexPane {
    public static func run<V: View>(name: String, @ViewBuilder content: () -> V) -> Never {
        let state = RexPaneState.shared
        run(name: name, view: NSHostingView(rootView: content().environmentObject(state)))
    }

    public static func run(name: String, view: NSView) -> Never {
        let app = NSApplication.shared
        let host = Host(name: name, view: view)
        app.delegate = host
        withExtendedLifetime(host) { app.run() }
        exit(0)
    }
}

final class PaneWindow: NSWindow {
    var focused = false
    override func sendEvent(_ e: NSEvent) {
        if e.type == .mouseMoved, let r = firstResponder { return r.mouseMoved(with: e) }
        super.sendEvent(e)
    }
    var scale: CGFloat = 0
    override var isKeyWindow: Bool { focused }
    override var isMainWindow: Bool { focused }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var backingScaleFactor: CGFloat { scale > 0 ? scale : super.backingScaleFactor }
    override func constrainFrameRect(_ r: NSRect, to s: NSScreen?) -> NSRect { r }
}

final class Host: NSObject, NSApplicationDelegate {
    let name: String
    let view: NSView
    var link: PaneLink?

    init(name: String, view: NSView) {
        self.name = name
        self.view = view
    }

    func applicationDidFinishLaunching(_: Notification) {
        guard PaneLink.block != nil else { return standalone() }
        RexPaneState.shared.embedded = true
        NSApp.setActivationPolicy(.prohibited)
        let window = PaneWindow(
            contentRect: NSRect(origin: PaneLink.origin, size: NSSize(width: 400, height: 300)),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.contentView = view
        view.wantsLayer = true
        link = PaneLink(
            name: name, window: window,
            focus: { on in
                window.focused = on
                RexPaneState.shared.focused = on
            }, scale: { window.scale = $0 })
    }

    func standalone() {
        NSApp.setActivationPolicy(.regular)
        let w = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 640, height: 420),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = name
        w.contentView = view
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        RexPaneState.shared.focused = true
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            exit(0)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { PaneLink.block == nil }
}

func rexPaneLine(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

public final class PaneLink {
    public private(set) static var block = ProcessInfo.processInfo.environment["REX_BLOCK"]
    @discardableResult public static func retarget() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["REXUI_EMBED_TARGET"],
            let d = FileManager.default.contents(atPath: path),
            let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
            let b = j["block"] as? String, b.hasPrefix("block:")
        else { return false }
        block = b
        session = j["session"] as? String ?? session
        return true
    }
    public static var sizeChanged: ((NSSize, CGFloat) -> Void)?
    public static var screenChanged: ((NSRect) -> Void)?
    public static var postScrolls = false
    public static var keysToWindow = false
    public static var keyWindow: (() -> NSWindow?)?
    public private(set) static var sizing = false
    public static var sizable: ((NSWindow) -> Bool)?
    public static var tellsFocusLoss = true
    public static var keyMap: [UInt16: UInt16] = [:]
    public static var quit: (() -> Void)?
    var keysDown: [UInt16: NSWindow] = [:]
    var shiftInChord = false
    public static let postedMark: Int64 = 0x7265_7875_6970_616E
    public static func posted(_ e: NSEvent) -> Bool {
        e.cgEvent?.getIntegerValueField(.eventSourceUserData) == postedMark
    }
    public static var mouseMoved: ((NSPoint) -> Void)?
    public static var placeMove: ((_ fraction: NSPoint, _ window: NSWindow) -> NSPoint?)?
    public static var moveTo: ((_ inWindow: NSPoint, _ dx: Double, _ dy: Double) -> NSPoint?)?
    static var session = ProcessInfo.processInfo.environment["REX_SESSION"] ?? ""
    static let fullscreen = ProcessInfo.processInfo.environment["REXUI_PANE_FULLSCREEN"] == "1"
    static let keys = (ProcessInfo.processInfo.environment["REXUI_PANE_KEYS"] ?? "").split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    public static var origin = NSPoint(x: -30000, y: -30000)
    static let debug = ProcessInfo.processInfo.environment["REXPANE_DEBUG"] != nil

    let name: String
    public let window: NSWindow
    let onFocus: (Bool) -> Void
    let onScale: (CGFloat) -> Void
    public private(set) var focused = false
    var scale: CGFloat = 0
    var fd: Int32 = -1
    var reader: DispatchSourceRead?
    var pending = Data()
    var context: UInt32 = 0
    var lastCursor = ""
    var sticky: [String: Any] = [:]
    var clicks = 1
    var lastAt = NSPoint.zero
    var buttons = Set<Int64>()
    var pendingMove: (x: Double, y: Double)?
    var moveRest = (x: 0.0, y: 0.0)
    var timer: Timer?
    var paneSize: NSSize?
    var sentLayout: [Double] = []
    public static var waitsForFrame = false
    public static var opaque = false
    var drawn = !PaneLink.waitsForFrame

    public init(name: String, window: NSWindow, focus: @escaping (Bool) -> Void, scale: @escaping (CGFloat) -> Void) {
        self.name = name
        self.window = window
        onFocus = focus
        onScale = scale
        Terminal.claim(name)
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary, .fullScreenNone]
        window.setFrameOrigin(PaneLink.origin)
        window.orderFrontRegardless()
        Cursor.watch { [weak self] name in self?.cursor(name) }
        connect()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.keepSize() }
        }
    }

    var resizeObserver: NSObjectProtocol?

    public func stop() {
        timer?.invalidate()
        timer = nil
        if let o = resizeObserver { NotificationCenter.default.removeObserver(o) }
        resizeObserver = nil
        disconnect()
    }

    var fights = 0

    func keepSize() {
        defer { reportLayout() }
        guard let want = paneSize, let c = window.contentView?.frame.size else { return }
        guard c != want, fights < 3, PaneLink.sizable?(window) ?? true else { return }
        fights += 1
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: want))
        PaneLink.sizing = true
        defer { PaneLink.sizing = false }
        window.setFrame(NSRect(origin: PaneLink.origin, size: frame.size), display: true)
    }

    static var socketPath: String {
        if let p = ProcessInfo.processInfo.environment["REXUI_PANES_SOCK"] { return p }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("rexui/panes.sock").path
    }

    func connect() {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = PaneLink.socketPath.utf8CString
        withUnsafeMutableBytes(of: &addr.sun_path) { p in
            for (i, c) in path.prefix(p.count - 1).enumerated() { p[i] = UInt8(bitPattern: c) }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else {
            close(s)
            Terminal.shown = false
            Terminal.status("waiting for rexui… (ctrl+c quits)")
            return
        }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        fd = s
        let r = DispatchSource.makeReadSource(fileDescriptor: s, queue: .main)
        r.setEventHandler { [weak self] in self?.readable() }
        r.resume()
        reader = r
        context = currentContext()
        send([
            "hello": 1, "block": PaneLink.block ?? "", "session": PaneLink.session, "pid": Int(getpid()), "name": name,
            "context": Int(context), "keys": PaneLink.keys, "fullscreen": PaneLink.fullscreen, "drawn": drawn,
            "lane": PaneLink.laneFns != nil ? 1 : 0, "opaque": PaneLink.opaque,
        ])
        sentLayout = []
        reportLayout()
        for (k, v) in sticky { send([k: v]) }
        Terminal.shown = true
        Terminal.status(nil)
    }

    func disconnect() {
        stopLane()
        reader?.cancel()
        reader = nil
        if fd >= 0 { close(fd) }
        fd = -1
        pending.removeAll()
        setFocus(false)
        Terminal.shown = false
    }

    static func jsonSafe(_ v: Any) -> Any {
        switch v {
        case let d as [String: Any]: return d.mapValues(jsonSafe)
        case let a as [Any]: return a.map(jsonSafe)
        case is String, is NSNull: return v
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n }
            return n.doubleValue.isFinite ? n : NSNull()
        default: return NSNull()
        }
    }

    func send(_ obj: [String: Any]) {
        let safe = PaneLink.jsonSafe(obj)
        guard fd >= 0, JSONSerialization.isValidJSONObject(safe),
            var data = try? JSONSerialization.data(withJSONObject: safe)
        else { return }
        data.append(0x0A)
        let ok = data.withUnsafeBytes { p -> Bool in
            var off = 0
            while off < p.count {
                let n = write(fd, p.baseAddress! + off, p.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        if !ok { disconnect() }
    }

    func readable() {
        var buf = [UInt8](repeating: 0, count: 65536)
        var ctl = [UInt8](repeating: 0, count: 64)
        let n = buf.withUnsafeMutableBytes { b in
            ctl.withUnsafeMutableBytes { c -> Int in
                var iov = iovec(iov_base: b.baseAddress, iov_len: b.count)
                return withUnsafeMutablePointer(to: &iov) { iovp -> Int in
                    var msg = msghdr()
                    msg.msg_iov = iovp
                    msg.msg_iovlen = 1
                    msg.msg_control = c.baseAddress
                    msg.msg_controllen = socklen_t(c.count)
                    let got = recvmsg(fd, &msg, 0)
                    if got > 0 { takeFds(c, Int(msg.msg_controllen)) }
                    return got
                }
            }
        }
        if n <= 0 { return disconnect() }
        pending.append(buf, count: n)
        while let nl = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<nl]
            pending.removeSubrange(pending.startIndex...nl)
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { handle(obj) }
        }
        replayMove()
    }

    func replayMove() {
        guard let m = pendingMove else { return }
        pendingMove = nil
        let x = m.x + moveRest.x
        let y = m.y + moveRest.y
        let ix = x.rounded(.towardZero)
        let iy = y.rounded(.towardZero)
        moveRest = (x - ix, y - iy)
        guard ix != 0 || iy != 0 else { return }
        let held = buttons.min()
        let type: CGEventType =
            held == nil
            ? .mouseMoved : held == 0 ? .leftMouseDragged : held == 1 ? .rightMouseDragged : .otherMouseDragged
        guard
            let e = CGEvent(
                mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero,
                mouseButton: CGMouseButton(rawValue: UInt32(held ?? 0)) ?? .left)
        else { return }
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(ix))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(iy))
        if let b = held { e.setIntegerValueField(.mouseEventButtonNumber, value: b) }
        replay(e, lastAt)
    }

    func tick() {
        if fd < 0 { return connect() }
        keepSize()
        reportLayout()
        let c = currentContext()
        if c != 0 && c != context {
            context = c
            send(["context": Int(c)])
        }
    }

    func reportLayout() {
        let f = window.frame
        let c = window.contentView?.frame ?? NSRect(origin: .zero, size: f.size)
        let l = [Double(c.minX), Double(f.height - c.maxY), Double(f.width), Double(f.height)]
        guard l != sentLayout else { return }
        sentLayout = l
        send(["layout": l])
    }

    func currentContext() -> UInt32 { PaneLink.context(of: window) }

    public static func context(of window: NSWindow) -> UInt32 {
        window.displayIfNeeded()
        var l = window.contentView?.layer
        while let p = l?.superlayer { l = p }
        guard let ctx = l?.value(forKey: "context") as AnyObject?, !(ctx is NSNull) else { return 0 }
        return (ctx.value(forKey: "contextId") as? NSNumber)?.uint32Value ?? 0
    }

    func handle(_ m: [String: Any]) {
        if (m["lane"] as? NSNumber)?.intValue == 1 { startLane() }
        if let s = m["size"] as? [NSNumber], s.count == 2 {
            let scale = (m["scale"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
            resize(NSSize(width: s[0].doubleValue, height: s[1].doubleValue), scale)
        }
        if let f = m["focus"] as? Bool { setFocus(f) }
        if let r = m["screen"] as? [NSNumber], r.count == 4 {
            PaneLink.screenChanged?(
                NSRect(x: r[0].doubleValue, y: r[1].doubleValue, width: r[2].doubleValue, height: r[3].doubleValue))
        }
        if let v = m["visible"] as? Bool { RexPaneState.shared.visible = v }
        if let a = m["appearance"] as? String {
            NSApp.appearance = NSAppearance(named: a == "light" ? .aqua : .darkAqua)
        }
        if let e = m["event"] as? String, let data = Data(base64Encoded: e),
            let cg = CGEvent(withDataAllocator: nil, data: data as CFData)
        {
            replayMove()
            replay(cg, NSPoint(x: (m["x"] as? NSNumber)?.doubleValue ?? 0, y: (m["y"] as? NSNumber)?.doubleValue ?? 0))
        }
        if let d = m["move"] as? [NSNumber], d.count == 2 {
            let p = pendingMove ?? (0, 0)
            pendingMove = (p.x + d[0].doubleValue, p.y + d[1].doubleValue)
        }
        if m["quit"] != nil { if let q = PaneLink.quit { q() } else { NSApp.terminate(nil) } }
        if let paths = m["drop"] as? [String], !paths.isEmpty {
            drop(paths, NSPoint(x: (m["x"] as? NSNumber)?.doubleValue ?? 0, y: (m["y"] as? NSNumber)?.doubleValue ?? 0))
        }
    }

    func drop(_ paths: [String], _ at: NSPoint) {
        let content = window.contentView?.frame ?? NSRect(origin: .zero, size: window.frame.size)
        let inWindow = NSPoint(x: content.minX + at.x, y: content.maxY - at.y)
        let files: [NSPasteboard.PasteboardType] = [
            .fileURL, NSPasteboard.PasteboardType("NSFilenamesPboardType"), .URL,
        ]
        let performs = #selector(NSDraggingDestination.performDragOperation(_:))
        var target: AnyObject?
        var v = window.contentView?.superview?.hitTest(inWindow) ?? window.contentView
        while let x = v, target == nil {
            if !Set(x.registeredDraggedTypes).isDisjoint(with: files) { target = x }
            v = x.superview
        }
        if target == nil, window.responds(to: performs) { target = window }
        if target == nil, let d = window.delegate, d.responds(to: performs) { target = d }
        guard let t = target else {
            rexPaneLine("rexpane: nothing in the window takes dropped files")
            return
        }
        let info = PaneDrop(paths: paths, at: inWindow, window: window)
        defer { info.pasteboard.releaseGlobally() }
        let op = t.draggingEntered?(info) ?? .copy
        _ = t.draggingUpdated?(info)
        if op.isEmpty {
            t.draggingExited?(info)
            return
        }
        if t.prepareForDragOperation?(info) ?? true, t.performDragOperation?(info) ?? false {
            t.concludeDragOperation?(info)
        }
        t.draggingEnded?(info)
        if PaneLink.debug { rexPaneLine("rexpane: \(paths.count) files dropped on \(type(of: t))") }
    }

    func resize(_ size: NSSize, _ s: CGFloat) {
        if s > 0 && s != scale {
            scale = s
            onScale(s)
            NotificationCenter.default.post(name: NSWindow.didChangeBackingPropertiesNotification, object: window)
            window.contentView?.viewDidChangeBackingProperties()
        }
        if size != paneSize { fights = 0 }
        paneSize = size
        PaneLink.sizeChanged?(size, scale > 0 ? scale : window.backingScaleFactor)
        keepSize()
        tick()
    }

    func setFocus(_ on: Bool) {
        guard focused != on else { return }
        focused = on
        if !on { releaseKeys() }
        onFocus(on)
        if !on && !PaneLink.tellsFocusLoss { return }
        NotificationCenter.default.post(
            name: on ? NSWindow.didBecomeKeyNotification : NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.post(
            name: on ? NSWindow.didBecomeMainNotification : NSWindow.didResignMainNotification, object: window)
        window.contentView?.needsDisplay = true
    }

    func releaseKeys() {
        let held = keysDown
        keysDown.removeAll()
        for (code, w) in held {
            guard
                let up = NSEvent.keyEvent(
                    with: .keyUp, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: w.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                    isARepeat: false, keyCode: code)
            else { continue }
            if PaneLink.keysToWindow { NSApp.sendEvent(up) } else { NSApp.postEvent(up, atStart: false) }
        }
    }

    func withoutChordShift(_ cg: CGEvent) -> CGEvent {
        guard shiftInChord, let c = cg.copy() else { return cg }
        c.flags = CGEventFlags(rawValue: c.flags.rawValue & ~(CGEventFlags.maskShift.rawValue | 0x2 | 0x4))
        return c
    }

    func replay(_ cg: CGEvent, _ paneAt: NSPoint) {
        let at = paneAt
        let content = window.contentView?.frame ?? NSRect(origin: .zero, size: window.frame.size)
        let inWindow = NSPoint(x: content.minX + at.x, y: content.maxY - at.y)
        let wn = window.windowNumber
        var out: NSEvent?
        switch cg.type {
        case .keyDown, .keyUp:
            guard let e = NSEvent(cgEvent: withoutChordShift(cg)) else { return }
            let target = PaneLink.keysToWindow ? (PaneLink.keyWindow?() ?? window) : window
            out = NSEvent.keyEvent(
                with: e.type, location: .zero, modifierFlags: e.modifierFlags,
                timestamp: e.timestamp > 0 ? e.timestamp : ProcessInfo.processInfo.systemUptime,
                windowNumber: target.windowNumber, context: nil, characters: e.characters ?? "",
                charactersIgnoringModifiers: e.charactersIgnoringModifiers ?? "", isARepeat: e.isARepeat,
                keyCode: PaneLink.keyMap[e.keyCode] ?? e.keyCode)
            if e.type == .keyDown {
                keysDown[PaneLink.keyMap[e.keyCode] ?? e.keyCode] = target
            } else {
                keysDown[PaneLink.keyMap[e.keyCode] ?? e.keyCode] = nil
            }
            if PaneLink.keysToWindow, let k = out {
                if k.type == .keyUp { NSApp.sendEvent(k) } else { target.sendEvent(k) }
                return
            }
        case .flagsChanged:
            let flags = cg.flags
            if flags.contains(.maskCommand) && flags.contains(.maskShift) { shiftInChord = true }
            if !flags.contains(.maskShift) { shiftInChord = false }
            if let e = NSEvent(cgEvent: withoutChordShift(cg)) {
                (PaneLink.keysToWindow ? (PaneLink.keyWindow?() ?? window) : window).sendEvent(e)
            }
            return
        case .scrollWheel:
            if PaneLink.postScrolls {
                guard let c = cg.copy() else { return }
                let top = NSScreen.screens.first?.frame.maxY ?? 0
                c.location = CGPoint(x: window.frame.minX + inWindow.x, y: top - (window.frame.minY + inWindow.y))
                c.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(wn))
                c.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(wn))
                c.setIntegerValueField(.eventSourceUserData, value: PaneLink.postedMark)
                if c.timestamp == 0 { c.timestamp = CGEventTimestamp(ProcessInfo.processInfo.systemUptime * 1e9) }
                guard let e = NSEvent(cgEvent: c) else { return }
                if PaneLink.debug { rexPaneLine("rexpane: scroll \(e.scrollingDeltaY) posted") }
                NSApp.postEvent(e, atStart: false)
                return
            }
            guard let e = NSEvent(cgEvent: cg),
                let v = window.contentView?.superview?.hitTest(inWindow) ?? window.contentView
            else { return }
            if PaneLink.debug { rexPaneLine("rexpane: scroll \(e.scrollingDeltaY) to \(type(of: v))") }
            v.scrollWheel(with: e)
            return
        default:
            guard let e = NSEvent(cgEvent: cg) else { return }
            switch e.type {
            case .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                .otherMouseDown, .otherMouseUp, .otherMouseDragged, .mouseMoved:
                let down = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(e.type)
                if down { clicks = max(e.clickCount, 1) }
                let up = [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(e.type)
                let button = cg.getIntegerValueField(.mouseEventButtonNumber)
                if down { buttons.insert(button) } else if up { buttons.remove(button) }
                lastAt = paneAt
                var at = inWindow
                let moving = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(e.type)
                if moving,
                    let p = PaneLink.moveTo?(
                        inWindow, cg.getDoubleValueField(.mouseEventDeltaX), cg.getDoubleValueField(.mouseEventDeltaY))
                {
                    at = p
                } else if moving, content.width > 0,
                    content.height > 0,
                    let p = PaneLink.placeMove?(
                        NSPoint(
                            x: (inWindow.x - content.minX) / content.width,
                            y: (content.maxY - inWindow.y) / content.height), window)
                {
                    at = p
                }
                let made = NSEvent.mouseEvent(
                    with: e.type, location: at, modifierFlags: e.modifierFlags,
                    timestamp: e.timestamp > 0 ? e.timestamp : ProcessInfo.processInfo.systemUptime,
                    windowNumber: wn, context: nil, eventNumber: e.eventNumber,
                    clickCount: down || up ? clicks : e.clickCount, pressure: e.pressure)
                out = made
                if let m = made, let c = m.cgEvent?.copy() {
                    for f in [CGEventField.mouseEventDeltaX, .mouseEventDeltaY] {
                        c.setIntegerValueField(f, value: cg.getIntegerValueField(f))
                        c.setDoubleValueField(f, value: cg.getDoubleValueField(f))
                    }
                    c.setIntegerValueField(
                        .mouseEventButtonNumber, value: cg.getIntegerValueField(.mouseEventButtonNumber))
                    c.setIntegerValueField(.eventSourceUserData, value: PaneLink.postedMark)
                    if let r = NSEvent(cgEvent: c), r.window === window, abs(r.locationInWindow.x - at.x) < 1,
                        abs(r.locationInWindow.y - at.y) < 1
                    {
                        out = r
                    } else if PaneLink.debug {
                        rexPaneLine("rexpane: \(e.type) without its button and movement")
                    }
                }
            default: return
            }
        }
        if PaneLink.debug { rexPaneLine("rexpane: \(out?.description ?? "nil") window \(out?.window === window)") }
        if out?.type != .keyDown && out?.type != .keyUp { PaneLink.mouseMoved?(inWindow) }
        if let out { NSApp.postEvent(out, atStart: false) }
    }

    public func markDrawn() {
        guard !drawn else { return }
        drawn = true
        send(["drawn": true])
    }

    public func sendPopups(_ list: [[String: Any]]) { sendSticky("popups", list) }

    func cursor(_ name: String) {
        guard name != lastCursor else { return }
        lastCursor = name
        sendSticky("cursor", name)
    }

    func sendSticky(_ key: String, _ value: Any) {
        sticky[key] = value
        send([key: value])
        if key == "capture" { pollMoves() }
    }

    typealias LaneOpen = @convention(c) (Int32) -> UnsafeMutableRawPointer?
    typealias LaneNext = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt8>?, UInt32) -> Int
    typealias LaneIdle = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    typealias LaneVoid = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias LaneMoves =
        @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<Double>?, UnsafeMutablePointer<Double>?) -> Int32
    struct LaneFns {
        let open: LaneOpen, next: LaneNext, idle: LaneIdle, awake: LaneVoid, moves: LaneMoves, close: LaneVoid
    }
    static let laneFns: LaneFns? = {
        if ProcessInfo.processInfo.environment["REXPANE_NO_LANE"] != nil { return nil }
        let h = UnsafeMutableRawPointer(bitPattern: -2)
        guard let o = dlsym(h, "rexpane_c_open"), let n = dlsym(h, "rexpane_c_next"),
            let i = dlsym(h, "rexpane_c_idle"),
            let a = dlsym(h, "rexpane_c_awake"), let m = dlsym(h, "rexpane_c_moves"),
            let c = dlsym(h, "rexpane_c_close")
        else { return nil }
        return LaneFns(
            open: unsafeBitCast(o, to: LaneOpen.self), next: unsafeBitCast(n, to: LaneNext.self),
            idle: unsafeBitCast(i, to: LaneIdle.self),
            awake: unsafeBitCast(a, to: LaneVoid.self), moves: unsafeBitCast(m, to: LaneMoves.self),
            close: unsafeBitCast(c, to: LaneVoid.self))
    }()
    var receivedFds: [Int32] = []
    var lane: UnsafeMutableRawPointer?
    var laneBell: DispatchSourceRead?
    var laneRecord = [UInt8](repeating: 0, count: 4096)
    var movePoll: LaneTicker?
    var laneEvents = 0

    func takeFds(_ c: UnsafeMutableRawBufferPointer, _ len: Int) {
        var at = 0
        while at + 12 <= len {
            let l = Int(c.load(fromByteOffset: at, as: UInt32.self))
            let level = c.load(fromByteOffset: at + 4, as: Int32.self)
            let type = c.load(fromByteOffset: at + 8, as: Int32.self)
            guard l >= 12, at + l <= len else { break }
            if level == SOL_SOCKET && type == SCM_RIGHTS {
                for k in 0..<(l - 12) / 4 {
                    receivedFds.append(c.load(fromByteOffset: at + 12 + 4 * k, as: Int32.self))
                }
            }
            at += (l + 3) & ~3
        }
        if receivedFds.count > 8 {
            for f in receivedFds { close(f) }
            receivedFds.removeAll()
        }
    }

    func startLane() {
        stopLane()
        guard receivedFds.count >= 2 else { return }
        let seg = receivedFds[receivedFds.count - 2]
        let bell = receivedFds[receivedFds.count - 1]
        for f in receivedFds.dropLast(2) { close(f) }
        receivedFds.removeAll()
        guard let f = PaneLink.laneFns, let l = f.open(seg) else {
            close(seg)
            close(bell)
            return
        }
        close(seg)
        lane = l
        _ = fcntl(bell, F_SETFL, fcntl(bell, F_GETFL) | O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: bell, queue: .main)
        src.setEventHandler { [weak self] in
            var b = [UInt8](repeating: 0, count: 64)
            while read(bell, &b, b.count) > 0 {}
            self?.drainLane()
        }
        src.setCancelHandler { close(bell) }
        src.resume()
        laneBell = src
        if PaneLink.debug { rexPaneLine("rexpane: input lane on") }
        drainLane()
        pollMoves()
    }

    func stopLane() {
        laneBell?.cancel()
        laneBell = nil
        movePoll?.stop()
        movePoll = nil
        if let l = lane, let f = PaneLink.laneFns { f.close(l) }
        if lane != nil && PaneLink.debug { rexPaneLine("rexpane: input lane off after \(laneEvents) events") }
        lane = nil
    }

    func drainLane() {
        guard let l = lane, let f = PaneLink.laneFns else { return }
        f.awake(l)
        while true {
            let n = laneRecord.withUnsafeMutableBufferPointer { f.next(l, $0.baseAddress, UInt32($0.count)) }
            if n < 0 {
                rexPaneLine("rexpane: the input lane broke; back to rexui's lines")
                return stopLane()
            }
            if n == 0 {
                if f.idle(l) != 0 {
                    f.awake(l)
                    continue
                }
                break
            }
            takeMoves()
            replayMove()
            laneRecord.withUnsafeBytes { replayRecord($0, n) }
        }
        takeMoves()
        replayMove()
    }

    func takeMoves() {
        guard let l = lane, let f = PaneLink.laneFns else { return }
        var dx = 0.0
        var dy = 0.0
        if f.moves(l, &dx, &dy) != 0 {
            let p = pendingMove ?? (0, 0)
            pendingMove = (p.x + dx, p.y + dy)
        }
    }

    func pollMoves() {
        let want = lane != nil && (sticky["capture"] as? Bool ?? false)
        if want, movePoll == nil {
            movePoll = LaneTicker { [weak self] in
                self?.takeMoves()
                self?.replayMove()
            }
        } else if !want {
            movePoll?.stop()
            movePoll = nil
        }
    }

    func replayRecord(_ r: UnsafeRawBufferPointer, _ n: Int) {
        guard n >= 8 else { return }
        let kind = r.loadUnaligned(fromByteOffset: 0, as: UInt16.self)
        let len = Int(r.loadUnaligned(fromByteOffset: 2, as: UInt16.self))
        guard 8 + len <= n else { return }
        laneEvents += 1
        if kind == 1, len == 64 {
            let type = r.loadUnaligned(fromByteOffset: 8, as: UInt32.self)
            let button = r.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
            let flags = r.loadUnaligned(fromByteOffset: 16, as: UInt64.self)
            let x = r.loadUnaligned(fromByteOffset: 24, as: Double.self)
            let y = r.loadUnaligned(fromByteOffset: 32, as: Double.self)
            let dx = r.loadUnaligned(fromByteOffset: 40, as: Double.self)
            let dy = r.loadUnaligned(fromByteOffset: 48, as: Double.self)
            let clicks = r.loadUnaligned(fromByteOffset: 56, as: Int32.self)
            let number = r.loadUnaligned(fromByteOffset: 60, as: UInt32.self)
            let sent = r.loadUnaligned(fromByteOffset: 64, as: UInt64.self)
            guard let t = CGEventType(rawValue: type),
                let e = CGEvent(
                    mouseEventSource: nil, mouseType: t, mouseCursorPosition: .zero,
                    mouseButton: CGMouseButton(rawValue: button) ?? .left)
            else { return }
            e.flags = CGEventFlags(rawValue: flags)
            e.timestamp = sent
            e.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
            e.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
            e.setIntegerValueField(.mouseEventNumber, value: Int64(number))
            let pressed = [
                .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .rightMouseDragged,
                .otherMouseDragged,
            ].contains(t)
            e.setDoubleValueField(.mouseEventPressure, value: pressed ? 1 : 0)
            e.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded(.towardZero)))
            e.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded(.towardZero)))
            e.setDoubleValueField(.mouseEventDeltaX, value: dx)
            e.setDoubleValueField(.mouseEventDeltaY, value: dy)
            replay(e, NSPoint(x: x, y: y))
        } else if kind == 2, len >= 24 {
            let x = r.loadUnaligned(fromByteOffset: 8, as: Double.self)
            let y = r.loadUnaligned(fromByteOffset: 16, as: Double.self)
            let data = Data(bytes: r.baseAddress! + 32, count: len - 24)
            guard let cg = CGEvent(withDataAllocator: nil, data: data as CFData) else { return }
            replay(cg, NSPoint(x: x, y: y))
        }
    }
}

enum Cursor {
    static var report: ((String) -> Void)?
    static var original: IMP?

    static var hidden = false
    static var last = "arrow"
    static var rectDecides: (() -> Bool)?

    static func setHidden(_ h: Bool) {
        hidden = h
        report?(h ? "none" : last)
    }

    static func watch(_ f: @escaping (String) -> Void) {
        report = f
        if original != nil { return }
        let meta: AnyClass = object_getClass(NSCursor.self)!
        for (sel, h) in [(NSSelectorFromString("hide"), true), (NSSelectorFromString("unhide"), false)] {
            guard let m = class_getInstanceMethod(meta, sel) else { continue }
            typealias F = @convention(c) (AnyClass, Selector) -> Void
            let orig = unsafeBitCast(method_getImplementation(m), to: F.self)
            let b: @convention(block) (AnyClass) -> Void = { c in
                Cursor.setHidden(h)
                orig(c, sel)
            }
            method_setImplementation(m, imp_implementationWithBlock(b))
        }
        let m = class_getInstanceMethod(NSCursor.self, #selector(NSCursor.set))!
        let block: @convention(block) (NSCursor) -> Void = { c in
            if Cursor.rectDecides?() != true {
                Cursor.last = Cursor.name(c)
                if !Cursor.hidden { Cursor.report?(Cursor.last) }
            }
            typealias Set = @convention(c) (NSCursor, Selector) -> Void
            unsafeBitCast(Cursor.original!, to: Set.self)(c, #selector(NSCursor.set))
        }
        original = method_setImplementation(m, imp_implementationWithBlock(block))
    }

    static func name(_ c: NSCursor) -> String {
        let known: [(NSCursor, String)] = [
            (.iBeam, "iBeam"), (.pointingHand, "pointingHand"), (.crosshair, "crosshair"), (.openHand, "openHand"),
            (.closedHand, "closedHand"), (.resizeLeftRight, "resizeLeftRight"), (.resizeUpDown, "resizeUpDown"),
            (.resizeLeft, "resizeLeft"), (.resizeRight, "resizeRight"), (.resizeUp, "resizeUp"),
            (.resizeDown, "resizeDown"),
            (.operationNotAllowed, "operationNotAllowed"), (.iBeamCursorForVerticalLayout, "iBeamVertical"),
        ]
        if let k = known.first(where: { $0.0 == c }) { return k.1 }
        return transparent(c) ? "none" : "arrow"
    }

    static var clear: [ObjectIdentifier: Bool] = [:]

    static func transparent(_ c: NSCursor) -> Bool {
        if let v = clear[ObjectIdentifier(c)] { return v }
        var v = c.image.representations.isEmpty
        if let cg = c.image.cgImage(forProposedRect: nil, context: nil, hints: nil), cg.width <= 256, cg.height <= 256,
            let ctx = CGContext(
                data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            if let d = ctx.data?.assumingMemoryBound(to: UInt8.self) {
                v = !(0..<(cg.width * cg.height)).contains { d[$0 * 4 + 3] != 0 }
            }
        }
        clear[ObjectIdentifier(c)] = v
        return v
    }
}

enum Terminal {
    static var saved = termios()
    static var name = ""
    static var shown = false
    static var keys: DispatchSourceRead?

    static func claim(_ n: String) {
        name = n
        guard isatty(0) != 0 else { return }
        tcgetattr(0, &saved)
        var t = saved
        t.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG)
        tcsetattr(0, TCSANOW, &t)
        atexit { Terminal.restore() }
        for s in [SIGINT, SIGTERM, SIGHUP] {
            signal(s) { _ in
                Terminal.restore()
                _exit(0)
            }
        }
        let r = DispatchSource.makeReadSource(fileDescriptor: 0, queue: .main)
        r.setEventHandler {
            var buf = [UInt8](repeating: 0, count: 256)
            let n = read(0, &buf, buf.count)
            if n <= 0 { return r.cancel() }
            if !shown && buf[0..<n].contains(0x03) {
                restore()
                exit(0)
            }
        }
        r.resume()
        keys = r
        out("\u{1b}[?25l\u{1b}]22;default\u{07}")
    }

    static var last: String??

    static func status(_ s: String?) {
        guard last != .some(s) else { return }
        last = .some(s)
        out("\u{1b}[2J\u{1b}[H" + (s.map { "  \(name): \($0)\r\n" } ?? ""))
    }

    static func restore() {
        guard isatty(0) != 0 else { return }
        tcsetattr(0, TCSANOW, &saved)
        out("\u{1b}[2J\u{1b}[H\u{1b}[?25h")
    }

    static func out(_ s: String) {
        guard isatty(1) != 0 else { return }
        s.utf8CString.withUnsafeBufferPointer { p in _ = write(1, p.baseAddress, p.count - 1) }
    }
}

final class LaneTicker: NSObject {
    let fn: () -> Void
    var link: CADisplayLink?
    var timer: Timer?
    init(_ fn: @escaping () -> Void) {
        self.fn = fn
        super.init()
        if let l = NSScreen.main?.displayLink(target: self, selector: #selector(tick)) {
            l.add(to: .main, forMode: .common)
            link = l
        } else {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.fn() }
        }
    }
    @objc func tick() { fn() }
    func stop() {
        link?.invalidate()
        link = nil
        timer?.invalidate()
        timer = nil
    }
}

final class PaneDrop: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    let urls: [URL]
    let at: NSPoint
    weak var window: NSWindow?
    private static var sequence = 0
    private let seq: Int

    init(paths: [String], at: NSPoint, window: NSWindow) {
        urls = paths.map { URL(fileURLWithPath: $0) }
        pasteboard = NSPasteboard(name: NSPasteboard.Name("rexui.drop.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        self.at = at
        self.window = window
        PaneDrop.sequence += 1
        seq = PaneDrop.sequence
    }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .link, .generic, .move] }
    var draggingLocation: NSPoint { at }
    var draggedImageLocation: NSPoint { at }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { seq }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination: Bool = false
    var numberOfValidItemsForDrop: Int = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {
        var stop: ObjCBool = false
        for (i, u) in urls.enumerated() {
            let item = NSDraggingItem(pasteboardWriter: u as NSURL)
            item.draggingFrame = NSRect(x: at.x, y: at.y, width: 32, height: 32)
            block(item, i, &stop)
            if stop.boolValue { break }
        }
    }
}
