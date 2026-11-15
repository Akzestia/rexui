// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "core/keys/keys.h"
#include "base/trace.h"
#include "chrome/chrome.h"
#include "rex/rex.h"
#include "web/web.h"

RXNode* autofocus_field(RXNode* n) {
    if ((is_elem(n, E::TextField) || is_elem(n, E::MouseArea)) && flag(n, P::autofocus, false))
        return n;
    for (RXNode* c in n.children) {
        if (RXNode* f = autofocus_field(c))
            return f;
    }
    return nil;
}

bool focus_in(id view) {
    if ([view isKindOfClass:RXLayerHost.class]) {
        RXEditor* ed = editor_in([view window]);
        if (ed && [ed.host isDescendantOf:view])
            return true;
        if (RXNode* f = focus_in_window([view window]); f && [host_of(f) isDescendantOf:view])
            return true;
        view = [view hasCarrier] ? [view carrier] : nil;
    }
    NSView* v = view;
    NSResponder* r = v.window.firstResponder;
    return v && [r isKindOfClass:NSView.class] && [(NSView*)r isDescendantOf:v];
}

static __weak RXNode* g_recorder;
static bool g_recording;

static void recorded(RXNode* n, NSString* key) {
    if (n.doc.ctx)
        doc_call(n.doc, @"emit", @[@(n.uid), @"keyRecorded", @[key]]);
}

void record_key(RXNode* n, bool on) {
    RXNode* was = g_recorder;
    RXNode* now = on ? n : nil;
    g_recorder = now;
    g_recording = on && n;
    if (was && was != now)
        recorded(was, @"");
}

NSString* key_base(NSEvent* e) {
    static NSDictionary<NSNumber*, NSString*>* names = @{
        @36: @"enter",
        @76: @"enter",
        @48: @"tab",
        @49: @"space",
        @51: @"backspace",
        @117: @"delete",
        @53: @"escape",
        @123: @"left",
        @124: @"right",
        @125: @"down",
        @126: @"up",
        @115: @"home",
        @119: @"end",
        @116: @"pageup",
        @121: @"pagedown",
        @122: @"f1",
        @120: @"f2",
        @99: @"f3",
        @118: @"f4",
        @96: @"f5",
        @97: @"f6",
        @98: @"f7",
        @100: @"f8",
        @101: @"f9",
        @109: @"f10",
        @103: @"f11",
        @111: @"f12",
    };
    NSString* key = names[@(e.keyCode)];
    if (!key)
        key = [e charactersByApplyingModifiers:0].lowercaseString;
    return key.length ? key : nil;
}

NSString* key_text(NSEvent* e) {
    const NSEventModifierFlags m = e.modifierFlags;
    if (!(m & NSEventModifierFlagCapsLock) || (e.type != NSEventTypeKeyDown && e.type != NSEventTypeKeyUp))
        return e.characters ?: @"";
    return [e charactersByApplyingModifiers:m & NSEventModifierFlagDeviceIndependentFlagsMask
               & ~NSEventModifierFlagCapsLock]
        ?: @"";
}

NSString* key_mods(NSEventModifierFlags m) {
    NSMutableArray* parts = [NSMutableArray arrayWithCapacity:4];
    if (m & NSEventModifierFlagCommand)
        [parts addObject:@"cmd"];
    if (m & NSEventModifierFlagControl)
        [parts addObject:@"ctrl"];
    if (m & NSEventModifierFlagOption)
        [parts addObject:@"alt"];
    if (m & NSEventModifierFlagShift)
        [parts addObject:@"shift"];
    return [parts componentsJoinedByString:@"+"];
}

static NSString* key_spec(NSEvent* e) {
    NSEventModifierFlags m = e.modifierFlags;
    NSString* key = key_base(e);
    if (!key)
        return nil;
    bool fkey = [key hasPrefix:@"f"] && key.length > 1 && isdigit([key characterAtIndex:1]);
    if (!(m & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption)) && !fkey)
        return nil;
    NSMutableString* s = [NSMutableString string];
    if (m & NSEventModifierFlagCommand)
        [s appendString:@"cmd+"];
    if (m & NSEventModifierFlagControl)
        [s appendString:@"ctrl+"];
    if (m & NSEventModifierFlagOption)
        [s appendString:@"alt+"];
    if (m & NSEventModifierFlagShift)
        [s appendString:@"shift+"];
    [s appendString:key];
    return s;
}

static void group_key(RXSlot* slot, RXDoc* doc);
static void group_toggle(RXSlot* slot);

static std::u16string_view lower_utf16(NSString* s, unichar* buf, NSUInteger cap) {
    NSUInteger n = s.length;
    if (!n)
        return {};
    if (n > cap)
        n = cap;
    [s getCharacters:buf range:NSMakeRange(0, n)];
    bool ascii = true;
    for (NSUInteger i = 0; i < n; i++) {
        if (buf[i] >= 0x80)
            ascii = false;
        else if (buf[i] >= 'A' && buf[i] <= 'Z')
            buf[i] += 32;
    }
    if (!ascii) {
        NSString* low = s.lowercaseString;
        n = MIN(low.length, cap);
        [low getCharacters:buf range:NSMakeRange(0, n)];
    }
    return {(const char16_t*)buf, n};
}

uint8_t key_mods(NSEvent* e) {
    NSEventModifierFlags m = e.modifierFlags;
    return (m & NSEventModifierFlagCommand ? rx::keys::k_cmd : 0)
        | (m & NSEventModifierFlagControl ? rx::keys::k_ctrl : 0)
        | (m & NSEventModifierFlagOption ? rx::keys::k_alt : 0)
        | (m & NSEventModifierFlagShift ? rx::keys::k_shift : 0);
}

std::expected<rx::keys::Chord, rx::keys::Error> key_parse(NSString* spec) {
    unichar buf[64];
    return rx::keys::parse(lower_utf16(spec, buf, 64));
}

bool chord_matches(const rx::keys::Chord& c, NSEvent* e) {
    if ((c.mods & 15) != key_mods(e))
        return false;
    if (c.code != rx::keys::k_by_chars)
        return e.keyCode == c.code;
    unichar buf[rx::keys::k_max_chars];
    return lower_utf16(e.charactersIgnoringModifiers, buf, rx::keys::k_max_chars) == c.key();
}

bool key_matches(NSString* spec, NSEvent* e) {
    if (!spec.length)
        return false;
    auto c = key_parse(spec);
    return c && chord_matches(*c, e);
}
bool ui_key_matches(NSString* spec, NSEvent* e) {
    return key_matches(spec, e);
}

static rx::keys::Table g_key_table;
static NSMutableArray* g_key_refs;
static bool g_keys_dirty = true;
static void rebuild_keys(void);

void keys_dirty(void) {
    static bool queued;
    g_keys_dirty = true;
    if (queued)
        return;
    queued = true;
    dispatch_async(dispatch_get_main_queue(), ^{
        queued = false;
        if (g_keys_dirty)
            rebuild_keys();
    });
}

static void add_key(NSString* spec, rx::keys::Kind kind, uint32_t order, id ref) {
    if (!spec.length)
        return;
    unichar buf[256];
    if (g_key_table.add(lower_utf16(spec, buf, 256), {kind, order, (__bridge const void*)ref}))
        [g_key_refs addObject:ref];
}

static void rebuild_keys(void) {
    RX_INTERVAL(key, "rebuild");
    using rx::keys::Kind;
    g_key_table.clear();
    g_key_refs = [NSMutableArray array];
    uint32_t i = 0;
    for (RXNode* n in all_drawers())
        add_key(str(n, P::key, @""), Kind::drawer, i++, n);
    i = 0;
    for (RXDoc* doc in g_docs) {
        if (!doc.ctx)
            continue;
        NSMutableArray<RXNode*>* cuts = nil;
        for (RXNode* n in doc.nodes.objectEnumerator)
            if (is_elem(n, E::Shortcut))
                [cuts ?: (cuts = [NSMutableArray array]) addObject:n];
        [cuts sortUsingComparator:^NSComparisonResult(RXNode* a, RXNode* b) {
            return a.uid < b.uid ? NSOrderedAscending : a.uid > b.uid ? NSOrderedDescending : NSOrderedSame;
        }];
        for (RXNode* n in cuts)
            add_key(str(n, P::key, @""), Kind::shortcut, i++, n);
    }
    i = 0;
    for (RXDoc* doc in g_docs) {
        if (!doc.ctx || !doc.root)
            continue;
        add_key(str(doc.root, P::barKey, @""), Kind::bar, i, doc);
        add_key(str(doc.root, P::searchKey, @""), Kind::search, i, doc);
        add_key(str(doc.root, P::groupKey, @""), Kind::group, i, doc);
        add_key(str(doc.root, P::key, @""), Kind::dock, i, doc);
        i++;
    }
    g_key_table.seal();
    g_keys_dirty = false;
}

static bool table_key(NSEvent* e) {
    NSWindow* ew = e.window;
    using rx::keys::Kind;
    if (g_keys_dirty)
        rebuild_keys();
    uint8_t mods = key_mods(e);
    unichar cbuf[rx::keys::k_max_chars];
    std::u16string_view chars;
    if (g_key_table.wants_chars(mods))
        chars = lower_utf16(e.charactersIgnoringModifiers, cbuf, rx::keys::k_max_chars);
    rx::keys::Target found[32];
    size_t n = MIN(g_key_table.find(e.keyCode, mods, chars, found, 32), (size_t)32);
    for (size_t i = 0; i < n; i++) {
        const rx::keys::Target& t = found[i];
        switch (t.kind) {
        case Kind::drawer: {
            RXNode* d = (__bridge RXNode*)t.ref;
            if (!d.doc)
                continue;
            drawer_set_open(d, !flag(d, P::open, false));
            return true;
        }
        case Kind::shortcut: {
            RXNode* s = (__bridge RXNode*)t.ref;
            RXDoc* doc = s.doc;
            if (!doc.ctx || !flag(s, P::enabled, true))
                continue;
            doc_call(doc, @"emit", @[@(s.uid), @"activated", @[]]);
            return true;
        }
        case Kind::bar: {
            RXDoc* doc = (__bridge RXDoc*)t.ref;
            NSString* g = group_of(doc);
            if (!doc.ctx || !g.length)
                continue;
            RXSlot* slot = slot_named([@"group:" stringByAppendingString:g]);
            if (!is_float_bar(slot) || (slot.lead ?: slot.members.firstObject) != doc)
                continue;
            float_bar_toggle(slot);
            return true;
        }
        case Kind::search: {
            RXDoc* doc = (__bridge RXDoc*)t.ref;
            NSString* g = group_of(doc);
            if (!doc.ctx || !g.length)
                continue;
            RXSlot* slot = slot_named([@"group:" stringByAppendingString:g]);
            if ((slot.lead ?: slot.members.firstObject) != doc || !bar_search_engine(slot))
                continue;
            bar_search(slot);
            return true;
        }
        case Kind::group: {
            RXDoc* doc = (__bridge RXDoc*)t.ref;
            NSString* g = group_of(doc);
            if (!doc.ctx || !g.length)
                continue;
            group_toggle(slot_named([@"group:" stringByAppendingString:g]));
            return true;
        }
        case Kind::dock: {
            RXDoc* doc = (__bridge RXDoc*)t.ref;
            if (!doc.ctx || ![g_docs containsObject:doc])
                continue;
            NSString* g = group_of(doc);
            if (g.length) {
                group_key(slot_named([@"group:" stringByAppendingString:g]), doc);
            } else {
                if (flag(doc.root, P::visible, true) && focus_in(doc.root.host))
                    focus_terminal(ew);
                doc_call(doc, @"toggle", @[@(doc.root.uid)]);
            }
            return true;
        }
        }
    }
    return false;
}

static bool in_editor(NSResponder* r) {
    return [r isKindOfClass:RXRoot.class] && [((RXRoot*)r).editor isKindOfClass:RXTermInput.class];
}

static bool in_dock(NSResponder* r) {
    if (![r isKindOfClass:NSView.class])
        return false;
    for (NSView* v = (NSView*)r; v; v = v.superview) {
        if (ui_is_dock(v))
            return true;
    }
    return false;
}

void ui_first_responder(NSWindow* w, NSResponder* r) {
    if ([r isKindOfClass:NSView.class] && !in_dock(r) && is_rex_window(w))
        g_terminal = r;
    if (is_rex_window(w))
        pane_styles_focus();
}

void focus_terminal(NSWindow* w) {
    NSResponder* t = g_terminal;
    if (t && [t isKindOfClass:NSView.class] && ((NSView*)t).window == w)
        [w makeFirstResponder:t];
    else
        [w makeFirstResponder:nil];
}

static void group_key(RXSlot* slot, RXDoc* doc) {
    if (!slot.shown)
        slot_show(slot, doc.path);
    else if ([slot.active isEqualToString:doc.path])
        slot_hide(slot);
    else
        slot_switch(slot, doc.path);
}

bool dock_key(NSString* file, bool show_only) {
    for (RXDoc* doc in g_docs) {
        if (!doc.ctx || doc.pane || !is_elem(doc.root, E::Dock) || ![doc.path.lastPathComponent isEqualToString:file])
            continue;
        NSString* g = group_of(doc);
        if (show_only) {
            RXSlot* slot = g.length ? slot_named([@"group:" stringByAppendingString:g]) : nil;
            bool on = slot ? slot.shown && active_member(slot) == doc : shown(doc.root);
            if (on)
                return true;
        }
        if (g.length)
            group_key(slot_named([@"group:" stringByAppendingString:g]), doc);
        else
            doc_call(doc, @"toggle", @[@(doc.root.uid)]);
        return true;
    }
    return false;
}

static void group_toggle(RXSlot* slot) {
    if (slot.shown)
        slot_hide(slot);
    else if (RXDoc* doc = active_member(slot) ?: slot.members.firstObject)
        slot_show(slot, doc.path);
}

NSEvent* on_mouse(NSEvent* e) {
    NSWindow* ew = e.window;
    if (e.buttonNumber != 3 && e.buttonNumber != 4)
        return e;
    NSView* frame = ew.contentView.superview ?: ew.contentView;
    RXNode* n = web_at([frame hitTest:e.locationInWindow]);
    if (!n)
        return e;
    WKWebView* w = (WKWebView*)n.view;
    if (e.buttonNumber == 3)
        [w goBack];
    else
        [w goForward];
    return nil;
}

static NSWindow* key_window(NSEvent* e) {
    static NSWindow* last;
    NSInteger n = e.windowNumber;
    if (!last || last.windowNumber != n)
        last = e.window;
    return last;
}

static NSResponder* first_responder(NSWindow* w) {
    return w.firstResponder;
}
static NSEvent* on_key(NSEvent* e) {
    NSWindow* w = key_window(e);
    NSResponder* first = w.firstResponder;
    static __unsafe_unretained NSResponder* seen;
    if (first != seen) {
        seen = first;
        if (!in_dock(first))
            g_terminal = first;
    }
    if (!is_rex_window(w))
        return e;
    if (RXNode* n = g_recording ? g_recorder : nil) {
        bool esc = e.keyCode == 53
            && !(e.modifierFlags
                 & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption
                    | NSEventModifierFlagShift));
        NSString* spec = esc ? @"" : key_spec(e);
        if (!spec)
            return nil;
        g_recorder = nil;
        g_recording = false;
        recorded(n, spec);
        return nil;
    }
    if (e.keyCode == 53 && data_drag_cancel())
        return nil;
    if (text_select_key(e))
        return nil;
    if (debug_key(e))
        return nil;
    if (bar_search_key(e))
        return nil;
    if (table_key(e))
        return nil;
    if (web_key(e))
        return nil;
    RXEditor* editing = editor_in(w);
    if (e.type == NSEventTypeKeyDown && (!editing || editing.marked.location == NSNotFound)) {
        RXNode* holder = editing ? editing.node : [first isKindOfClass:RXRoot.class] ? ((RXRoot*)first).focus : nil;
        if (holder && focus_key_first(holder, e))
            return nil;
    }
    if (e.keyCode == 53 && editing.node && editing.marked.location == NSNotFound && focus_key_heard(editing.node, e))
        return nil;
    if (e.keyCode == 53 && is_elem(editing.node, E::TextField)) {
        RXNode* node = editing.node;
        RXNode* drawer = node.parent;
        while (drawer && !is_drawer(drawer))
            drawer = drawer.parent;
        if (drawer && !flag(drawer, P::open, false))
            drawer = nil;
        const bool had_text = editing.text.length > 0;
        if (drawer && had_text) {
            [editing setText:@""];
            if (editing.changed)
                editing.changed(@"");
        }
        if (node.doc.ctx)
            doc_call(node.doc, @"emit", @[@(node.uid), @"cancelled", @[]]);
        if (drawer) {
            if (!had_text && flag(drawer, P::open, false))
                drawer_set_open(drawer, false);
            return nil;
        }
        if (first_responder(w) == first)
            editor_blur(editing);
        return nil;
    }
    if (e.keyCode == 53 && !in_editor(first)) {
        bool any = false;
        for (RXNode* n in all_drawers()) {
            if (!flag(n, P::open, false))
                continue;
            drawer_set_open(n, false);
            any = true;
        }
        if (any)
            return nil;
    }
    if (e.keyCode == 53 && is_elem(editing.node, E::TextArea)) {
        editor_blur(editing);
        return nil;
    }
    return e;
}

static bool g_keys_pending;
static void pending_keys_check(void) {
    static NSDictionary* last;
    NSDictionary* p = (__bridge_transfer NSDictionary*)rex_pending_keys();
    g_keys_pending = [p[@"keys"] count] > 0 || [p[@"modes"] count] > 0;
    if (!p || [p isEqual:last])
        return;
    last = p;
    for (RXDoc* doc in [g_docs copy])
        if (doc.ctx)
            doc_call(doc, @"setKeys", @[@{@"pending": p}]);
}

static NSArray<NSDictionary*>* all_keys(void);
static NSEvent* g_last_key;
static bool g_keymap_plain;

static void keymap_scan(void) {
    static NSMutableSet<NSString*>* said;
    bool plain = false;
    for (NSDictionary* b in panes_rex_bindings()) {
        for (NSString* k in b[@"keys"]) {
            if (![k isKindOfClass:NSString.class])
                continue;
            auto c = key_parse(k);
            if (!c) {
                if (!said)
                    said = [NSMutableSet set];
                if (![said containsObject:k])
                    [said addObject:k],
                        rexui_log_file(
                            [NSString stringWithFormat:@"keys: Rex's binding %@ isn't one rexui reads: left out", k]);
                continue;
            }
            if (!(c->mods & (rx::keys::k_cmd | rx::keys::k_ctrl | rx::keys::k_alt)))
                plain = true;
        }
    }
    g_keymap_plain = plain;
}
bool keys_rex_plain(void) {
    return g_keymap_plain;
}

static void after_key(void) {
    static bool queued;
    if (queued)
        return;
    queued = true;
    dispatch_async(dispatch_get_main_queue(), ^{
        queued = false;
        pending_keys_check();
        rex_wrap_closures();
        rexstate_layout();
    });
}

bool ui_key(NSEvent* e) {
    if (e.type == NSEventTypeKeyDown)
        engine_urgent();
    RX_INTERVAL(key, "ui_key");
    if (menu_key(e) || picker_key(e))
        return true;
    if (e.type == NSEventTypeKeyDown)
        g_last_key = e;
    if (e.keyCode == 36 || e.keyCode == 76)
        activity_hurry();
    if (g_keys_pending || g_keymap_plain || (key_mods(e) & (rx::keys::k_cmd | rx::keys::k_ctrl | rx::keys::k_alt)))
        after_key();
    return g_docs && !on_key(e);
}

static void emit_all(NSString* signal, NSArray* args, bool (^which)(RXDoc*)) {
    for (RXDoc* d in [g_docs copy])
        if (d.ctx && d.root && (!which || which(d)))
            doc_call(d, @"emit", @[@(d.root.uid), signal, args]);
}

extern "C" void rex_focus_edge(void) {
    NSString* key = g_last_key ? key_spec(g_last_key) : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString* dir = @"";
        for (NSDictionary* k in all_keys())
            if ([k[@"key"] isEqualToString:key] && [k[@"title"] hasPrefix:@"pane.focus."])
                dir = [k[@"title"] substringFromIndex:11];
        rexui_log_file([@"keys: pane focus at the edge, " stringByAppendingString:dir.length ? dir : @"?"]);
        emit_all(@"focusEdge", @[dir], nil);
    });
}

static bool link_taken(NSURL* url) {
    NSString* scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"])
        return false;
    bool taken = false;
    for (RXDoc* d in g_docs)
        taken |= d.takes_links && d.ctx;
    if (!taken)
        return false;
    NSString* u = url.absoluteString;
    dispatch_async(dispatch_get_main_queue(), ^{
        emit_all(@"link", @[u], ^bool(RXDoc* d) {
            return d.takes_links;
        });
    });
    rexui_log_file([@"keys: a link to the docks: " stringByAppendingString:url.host ?: @"?"]);
    return true;
}

static NSString* g_link_block;
static double g_link_until;

static NSString* block_under(NSEvent* e, NSView** surface_out) {
    static Class cls = NSClassFromString(RXNS(RXN_165)) ?: NSClassFromString(RXNS(RXN_164));
    NSWindow* w = e.window;
    if (!cls || !w || !is_rex_window(w))
        return nil;
    NSView* top = w.contentView.superview ?: w.contentView;
    NSView* v = [top hitTest:[top convertPoint:e.locationInWindow fromView:nil]];
    while (v && ![v isKindOfClass:cls])
        v = v.superview;
    if (!v)
        return nil;
    if (surface_out)
        *surface_out = v;
    NSDictionary<NSString*, NSView*>* panes = pane_views_now();
    for (NSString* bid in panes)
        if ([v isDescendantOf:panes[bid]])
            return bid;
    return @"";
}

NSEvent* links_event(NSEvent* e) {
    if (!g_config.link_in_pane)
        return e;
    const NSEventType t = e.type;
    if (t != NSEventTypeMouseMoved && t != NSEventTypeLeftMouseDown && t != NSEventTypeLeftMouseUp
        && t != NSEventTypeLeftMouseDragged)
        return e;
    const NSEventModifierFlags held = e.modifierFlags
        & (NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagControl
           | NSEventModifierFlagOption);
    if (held != (NSEventModifierFlagCommand | NSEventModifierFlagShift))
        return e;
    NSView* surface = nil;
    NSString* block = block_under(e, &surface);
    if (!block && t != NSEventTypeLeftMouseUp)
        return e;
    const NSEventModifierFlags mods = (e.modifierFlags & ~NSEventModifierFlagShift);
    if (t == NSEventTypeLeftMouseDown) {
        g_link_block = block;
        g_link_until = CACurrentMediaTime() + 30;
        if (NSEvent* m = [NSEvent mouseEventWithType:NSEventTypeMouseMoved
                                            location:e.locationInWindow
                                       modifierFlags:mods
                                           timestamp:e.timestamp
                                        windowNumber:e.windowNumber
                                             context:nil
                                         eventNumber:0
                                          clickCount:0
                                            pressure:0])
            if ([surface respondsToSelector:@selector(mouseMoved:)])
                [surface mouseMoved:m];
    } else if (t == NSEventTypeLeftMouseUp && g_link_until > 0) {
        g_link_until = CACurrentMediaTime() + 1.5;
    }
    if (t == NSEventTypeMouseMoved)
        return [NSEvent mouseEventWithType:t
                                  location:e.locationInWindow
                             modifierFlags:mods
                                 timestamp:e.timestamp
                              windowNumber:e.windowNumber
                                   context:nil
                               eventNumber:0
                                clickCount:0
                                  pressure:0]
            ?: e;
    return [NSEvent mouseEventWithType:t
                              location:e.locationInWindow
                         modifierFlags:mods
                             timestamp:e.timestamp
                          windowNumber:e.windowNumber
                               context:nil
                           eventNumber:e.eventNumber
                            clickCount:e.clickCount
                              pressure:e.pressure]
        ?: e;
}

static bool link_to_pane(NSURL* url) {
    if (!(g_link_until > 0 && CACurrentMediaTime() < g_link_until))
        return false;
    NSString* scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"])
        return false;
    g_link_until = 0;
    NSString *u = url.absoluteString, *anchor = g_link_block ?: @"";
    rexui_log_file([@"keys: cmd+shift+click, a link to a pane: " stringByAppendingString:url.host ?: @"?"]);
    dispatch_async(dispatch_get_main_queue(), ^{
        ui_open_pane(
            u,
            @{@"anchor": anchor,
              @"focus": @YES},
            ^{
                rexui_log(@"keys: the link's pane wasn't made; it opens as before");
                [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:u]];
            });
    });
    return true;
}

static BOOL (*orig_open)(id, SEL, NSURL*);
static void (*orig_open_config)(id, SEL, NSURL*, id, void (^)(NSRunningApplication*, NSError*));
static BOOL hook_open(NSWorkspace* self, SEL sel, NSURL* url) {
    return link_to_pane(url) || link_taken(url) || files_route_url(url) ? YES : orig_open(self, sel, url);
}
static void hook_open_config(NSWorkspace* self, SEL sel, NSURL* url, id config,
                             void (^done)(NSRunningApplication*, NSError*)) {
    if (!link_to_pane(url) && !link_taken(url) && !files_route_url(url))
        return orig_open_config(self, sel, url, config, done);
    if (done)
        done(nil, nil);
}

static void (*orig_paste)(id, SEL, id);
static void hook_paste(NSView* self, SEL sel, id sender) {
    bool taken = false;
    for (RXDoc* d in g_docs)
        taken |= d.takes_paste && d.ctx;
    NSString* text = taken ? [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString] : nil;
    if (!text.length)
        return orig_paste(self, sel, sender);
    NSDictionary* b = panes_last_block() ?: @{};
    emit_all(@"paste", @[text, b[@"block"] ?: @"", b[@"session"] ?: @""], ^bool(RXDoc* d) {
        return d.takes_paste;
    });
}

static NSURL* dropped_link(NSPasteboard* pb) {
    if ([pb.types containsObject:NSPasteboardTypeFileURL])
        return nil;
    if (![pb.types containsObject:NSPasteboardTypeURL])
        return nil;
    for (NSURL* u in [pb readObjectsForClasses:@[NSURL.class] options:nil] ?: @[]) {
        NSString* scheme = u.scheme.lowercaseString;
        if (!u.isFileURL && ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]))
            return u;
    }
    return nil;
}
static BOOL (*orig_drop)(id, SEL, id<NSDraggingInfo>);
static BOOL hook_drop(NSView* self, SEL sel, id<NSDraggingInfo> info) {
    NSURL* url = g_config.pane_drop_links ? dropped_link(info.draggingPasteboard) : nil;
    NSString* block = nil;
    if (url) {
        NSDictionary<NSString*, NSView*>* panes = pane_views_now();
        for (NSString* key in panes) {
            if (![self isDescendantOf:panes[key]])
                continue;
            NSRange r = [key rangeOfString:@"#"];
            block = r.location == NSNotFound ? key : [key substringToIndex:r.location];
        }
    }
    if (![block hasPrefix:@"block:"])
        return orig_drop(self, sel, info);
    rexui_log_file([NSString stringWithFormat:@"keys: a link dropped on %@: %@", block, url.host ?: @"?"]);
    NSString* u = url.absoluteString;
    ui_open_pane(u, @{@"in": block}, ^{
        rexui_log(@"keys: the dropped link's page wasn't shown in its pane");
    });
    return YES;
}

void links_init(void) {
    static Class surface = NSClassFromString(RXNS(RXN_165)) ?: NSClassFromString(RXNS(RXN_164));
    if (surface && [surface instancesRespondToSelector:@selector(paste:)])
        swizzle(surface, @selector(paste:), (IMP)hook_paste, (IMP*)&orig_paste);
    if (surface && [surface instancesRespondToSelector:@selector(performDragOperation:)])
        swizzle(surface, @selector(performDragOperation:), (IMP)hook_drop, (IMP*)&orig_drop);
    swizzle(NSWorkspace.class, @selector(openURL:), (IMP)hook_open, (IMP*)&orig_open);
    swizzle(NSWorkspace.class, @selector(openURL:configuration:completionHandler:), (IMP)hook_open_config,
            (IMP*)&orig_open_config);
}

static NSString* menu_key(NSMenuItem* item) {
    NSString* k = item.keyEquivalent;
    if (!k.length)
        return nil;
    NSEventModifierFlags m = item.keyEquivalentModifierMask;
    unichar c = [k characterAtIndex:0];
    NSDictionary<NSNumber*, NSString*>* names = @{
        @(NSUpArrowFunctionKey): @"up",
        @(NSDownArrowFunctionKey): @"down",
        @(NSLeftArrowFunctionKey): @"left",
        @(NSRightArrowFunctionKey): @"right",
        @'\r': @"enter",
        @'\t': @"tab",
        @' ': @"space",
        @0x1b: @"escape",
        @0x08: @"backspace",
        @0x7f: @"backspace",
        @(NSDeleteFunctionKey): @"delete",
        @(NSHomeFunctionKey): @"home",
        @(NSEndFunctionKey): @"end",
        @(NSPageUpFunctionKey): @"pageup",
        @(NSPageDownFunctionKey): @"pagedown",
    };
    NSString* key = names[@(c)];
    if (!key && c >= NSF1FunctionKey && c <= NSF35FunctionKey)
        key = [NSString stringWithFormat:@"f%d", c - NSF1FunctionKey + 1];
    if (!key) {
        if ([NSCharacterSet.uppercaseLetterCharacterSet characterIsMember:c])
            m |= NSEventModifierFlagShift;
        key = k.lowercaseString;
    }
    NSMutableString* s = [NSMutableString string];
    if (m & NSEventModifierFlagCommand)
        [s appendString:@"cmd+"];
    if (m & NSEventModifierFlagControl)
        [s appendString:@"ctrl+"];
    if (m & NSEventModifierFlagOption)
        [s appendString:@"alt+"];
    if (m & NSEventModifierFlagShift)
        [s appendString:@"shift+"];
    [s appendString:key];
    return s;
}

static void menu_keys(NSMenu* menu, NSString* group, NSMutableArray* out) {
    for (NSMenuItem* item in menu.itemArray) {
        if (item.isSeparatorItem || item.isHidden)
            continue;
        if (item.submenu) {
            menu_keys(item.submenu, group ?: item.title, out);
            continue;
        }
        NSString* key = menu_key(item);
        if (!key || !item.title.length)
            continue;
        [out addObject:@{
            @"key": key,
            @"title": item.title,
            @"kind": @"menu",
            @"group": group ?: @"",
            @"from": @"rex",
            @"source": @""
        }];
    }
}

static NSArray<NSDictionary*>* all_keys(void) {
    NSMutableArray* out = [NSMutableArray array];
    for (RXDoc* doc in g_docs) {
        RXNode* root = doc.root;
        if (!root || doc.pane)
            continue;
        NSString* file = doc.path.lastPathComponent;
        NSString* title = str(root, P::title, @"");
        if (!title.length)
            title = file.stringByDeletingPathExtension;
        NSString* own = str(root, P::keyTitle, @"");
        struct {
            NSString *prop, *kind;
        } dock_keys[] = {{@"key", @"dock"}, {@"groupKey", @"group"}, {@"barKey", @"bar"}, {@"searchKey", @"search"}};
        for (auto& k : dock_keys) {
            NSString* key = str(root, k.prop, @"");
            if (!key.length)
                continue;
            NSString* t = [k.kind isEqualToString:@"dock"] && own.length ? own
                : [k.kind isEqualToString:@"group"]                      ? str(root, P::group, title)
                                                                         : title;
            [out addObject:@{
                @"key": key,
                @"title": t,
                @"kind": k.kind,
                @"group": title,
                @"from": @"rexui",
                @"source": file
            }];
        }
        for (RXNode* n in doc.nodes.allValues) {
            if (!is_drawer(n))
                continue;
            NSString* key = str(n, P::key, @"");
            if (!key.length)
                continue;
            NSString* t = str(n, P::keyTitle, @"");
            if (!t.length)
                t = [obj(n, @"id") isKindOfClass:NSString.class] ? obj(n, @"id") : title;
            [out addObject:@{
                @"key": key,
                @"title": t,
                @"kind": @"drawer",
                @"group": title,
                @"from": @"rexui",
                @"source": file
            }];
        }
        for (RXNode* n in doc.nodes.allValues) {
            NSString* key = is_elem(n, E::Shortcut) ? str(n, P::key, @"") : @"";
            if (!key.length)
                continue;
            NSString* t = str(n, P::keyTitle, @"");
            if (!t.length)
                t = [obj(n, @"id") isKindOfClass:NSString.class] ? obj(n, @"id") : title;
            [out addObject:@{
                @"key": key,
                @"title": t,
                @"kind": @"shortcut",
                @"group": title,
                @"from": @"rexui",
                @"source": file
            }];
        }
    }
    for (NSDictionary* b in panes_rex_bindings()) {
        for (NSString* k in b[@"keys"]) {
            [out addObject:@{
                @"key": k,
                @"title": b[@"action"] ?: @"",
                @"kind": @"binding",
                @"group": @"init.lua",
                @"from": @"init.lua",
                @"source": b[@"source"] ?: @""
            }];
        }
    }
    menu_keys(NSApp.mainMenu, nil, out);
    return out;
}

void set_keys(RXDoc* doc) {
    static NSArray* cached;
    static double at;
    if (!cached || CACurrentMediaTime() - at > 0.1)
        cached = all_keys(), at = CACurrentMediaTime();
    doc_call(doc, @"setKeys", @[@{@"list": cached}]);
}

void ui_keys_changed(void) {
    keys_dirty();
    static bool due;
    if (due)
        return;
    due = true;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        due = false;
        keymap_scan();
        tabs_keys_changed();
        panes_keys_changed();
        for (RXDoc* doc in [g_docs copy]) {
            if (doc.ctx)
                set_keys(doc);
        }
    });
}
