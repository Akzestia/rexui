// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "ui/ui.h"

static bool is_text_input(RXNode* n) {
    return is_elem(n, E::TextField) || is_elem(n, E::TextArea);
}
static bool takes_focus(RXNode* n) {
    if (!n.layer || !node_on_screen(n))
        return false;
    switch (n->ps.elem()) {
    case E::TextField:
        return flag(n, P::enabled, true);
    case E::TextArea:
        return true;
    case E::Button:
    case E::MouseArea:
    case E::Slider:
        return flag(n, P::enabled, true) && flag(n, P::focusable, false);
    case E::List:
        return flag(n, P::focusable, false);
    default:
        return false;
    }
}

NSPasteboard* ui_pasteboard(void) {
    static NSPasteboard* own = getenv("REXUI_SUITE") ? [NSPasteboard pasteboardWithUniqueName] : nil;
    return own ?: NSPasteboard.generalPasteboard;
}

static RXRoot* root_for(RXNode* n) {
    id h = host_of(n);
    return [h respondsToSelector:@selector(rootView)] ? [h rootView] : nil;
}

RXNode* focus_in_window(NSWindow* w) {
    id r = w.firstResponder;
    return [r isKindOfClass:RXRoot.class] ? ((RXRoot*)r).focus : nil;
}

void focus_changed(RXNode* n, bool on) {
    if (n.doc.ctx && !is_elem(n, E::TabPreview))
        doc_call(n.doc, @"update", @[@(n.uid), @{@"focused": @(on)}]);
    if (!on)
        focus_ring(n, false);
}

static char k_ring;
void focus_ring(RXNode* n, bool on) {
    CALayer* ring = objc_getAssociatedObject(n, &k_ring);
    if (!on || !n.layer) {
        [ring removeFromSuperlayer];
        objc_setAssociatedObject(n, &k_ring, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (is_text_input(n) || !flag(n, P::focusRing, true) || !g_config.focus_ring)
        return;
    if (!ring) {
        ring = [RXLayer layer];
        ring.zPosition = 9999;
        ring.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
        [n.layer addSublayer:ring];
        objc_setAssociatedObject(n, &k_ring, ring, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    ring.frame = n.layer.bounds;
    CGColorRef accent = (ui_accent() ?: NSColor.controlAccentColor).CGColor;
    const CGFloat r = is_elem(n, E::Button) ? num(n, P::stateRadius, -1) : num(n, P::radius, 0);
    NSString* spec = str(n, P::shape, @"");
    if (!spec.length && is_elem(n, E::Button) && r < 0) {
        for (RXNode* c in n.parent.children) {
            if (c == n)
                break;
            if (is_elem(c, E::Rectangle) && flag(c, P::visible, true))
                spec = str(c, P::shape, @"");
        }
    }
    CAShapeLayer* line = ring.sublayers.count ? (CAShapeLayer*)ring.sublayers.firstObject : nil;
    CGPathRef path = spec.length ? box_path(spec, ring.bounds.size) : NULL;
    if (path) {
        if (!line) {
            line = [CAShapeLayer layer];
            line.actions = @{@"path": NSNull.null, @"bounds": NSNull.null, @"position": NSNull.null};
            line.fillColor = NULL;
            line.lineWidth = 4;
            [ring addSublayer:line];
        }
        line.frame = ring.bounds;
        line.path = path;
        line.strokeColor = accent;
        line.mask = line.mask ?: [CAShapeLayer layer];
        ((CAShapeLayer*)line.mask).frame = ring.bounds;
        ((CAShapeLayer*)line.mask).path = path;
        CGPathRelease(path);
        ring.borderWidth = 0;
        ring.cornerRadius = 0;
        return;
    }
    [line removeFromSuperlayer];
    ring.borderWidth = 2;
    ring.borderColor = accent;
    ring.cornerRadius = r >= 0 ? r : 6;
}

static void reveal_focus(RXNode* n) {
    for (RXNode* x = n.parent; x; x = x.parent) {
        if (!is_list(x))
            continue;
        RXScrollLayer* sv = (RXScrollLayer*)x.layer;
        CGRect r = [sv.doc convertRect:n.layer.bounds fromLayer:n.layer];
        r.origin.y += sv.base;
        [sv reveal:NSRectFromCGRect(r)];
    }
}

static void note_before(RXNode* n) {
    RXNode* d = n.parent;
    while (d && !is_drawer(d))
        d = d.parent;
    if (!d || d.focus_before)
        return;
    RXRoot* root = root_for(n);
    RXNode* was = root.focus ?: root.editor.node;
    if (!was || was == n)
        return;
    for (RXNode* x = was; x; x = x.parent)
        if (x == d)
            return;
    d.focus_before = was;
}

void focus_back(RXNode* drawer, NSWindow* w) {
    RXNode* was = drawer.focus_before;
    drawer.focus_before = nil;
    if (was && was.doc && node_on_screen(was))
        focus_node(was, false);
    else
        focus_terminal(w);
}

void focus_node(RXNode* n, bool by_keyboard) {
    if (!n || is_native(n))
        return;
    note_before(n);
    if (is_text_input(n)) {
        if (is_elem(n, E::TextField))
            field_edit(n);
        else if (RXEditor* e = node_editor(n, true))
            editor_focus(e);
        if (by_keyboard && is_elem(n, E::TextField))
            (void)[n.editor perform:@selector(selectAll:)];
        if (by_keyboard)
            reveal_focus(n);
        return;
    }
    if (!is_elem(n, E::Button) && !is_elem(n, E::Slider) && !is_elem(n, E::List) && !is_elem(n, E::MouseArea))
        return;
    RXRoot* root = root_for(n);
    NSWindow* w = root.window;
    if (!root || !w)
        return;
    if (RXEditor* ed = root.editor) {
        root.editor = nil;
        ed.focused = false;
        if (ed.ended)
            ed.ended();
    }
    RXNode* was = root.focus;
    if (was != n) {
        if (was)
            focus_changed(was, false);
        root.focus = n;
        focus_changed(n, true);
    }
    if (w.firstResponder != root)
        [w makeFirstResponder:root];
    focus_ring(n, by_keyboard);
    if (by_keyboard)
        reveal_focus(n);
}

void focus_release(RXNode* n) {
    if (RXEditor* e = n.editor; e && is_text_input(n)) {
        if (e.focused)
            editor_blur(e);
        return;
    }
    RXRoot* root = root_for(n);
    if (!root || root.focus != n)
        return;
    focus_changed(n, false);
    root.focus = nil;
    if (root.window.firstResponder == root)
        focus_terminal(root.window);
}

void focus_gone(RXNode* n) {
    if (RXRoot* root = root_for(n); root && root.focus == n)
        focus_release(n);
    focus_ring(n, false);
}

static void collect(RXNode* n, RXNode* scope, NSMutableArray<RXNode*>* out) {
    if (n != scope && is_drawer(n))
        return;
    if (takes_focus(n))
        [out addObject:n];
    for (RXNode* c in n.children)
        collect(c, scope, out);
}

void focus_move(RXNode* from, int dir) {
    RXNode* scope = from;
    while (scope.parent && !is_drawer(scope))
        scope = scope.parent;
    NSMutableArray<RXNode*>* stops = [NSMutableArray array];
    collect(scope, scope, stops);
    if (!stops.count)
        return;
    bool ordered = false;
    for (RXNode* x in stops)
        ordered = ordered || num(x, P::tabIndex, 0) > 0;
    if (ordered)
        [stops sortWithOptions:NSSortStable
               usingComparator:^NSComparisonResult(RXNode* a, RXNode* b) {
                   const double ta = num(a, P::tabIndex, 0), tb = num(b, P::tabIndex, 0);
                   const double ka = ta > 0 ? ta : 1e12, kb = tb > 0 ? tb : 1e12;
                   return ka < kb ? NSOrderedAscending : ka > kb ? NSOrderedDescending : NSOrderedSame;
               }];
    NSUInteger i = [stops indexOfObjectIdenticalTo:from];
    const NSInteger n = (NSInteger)stops.count;
    const NSInteger next = i == NSNotFound ? 0 : (((NSInteger)i + dir) % n + n) % n;
    if (stops[(NSUInteger)next] != from)
        focus_node(stops[(NSUInteger)next], true);
}

static bool tell(RXNode* n, NSString* signal, NSArray* args) {
    for (RXNode* x = n; x; x = x.parent) {
        if (!x.doc.ctx || !flag(x, @"wantsKeys", false))
            continue;
        id said = doc_call(x.doc, @"keyDelegate", @[@(x.uid), signal, args]);
        if ([said isKindOfClass:NSNumber.class] && [said boolValue])
            return true;
    }
    return false;
}

void focus_key_up(RXNode* n, NSEvent* e) {
    if (NSString* key = key_base(e))
        tell(n, @"keyReleased", @[key, key_mods(e.modifierFlags)]);
}

static struct {
    __unsafe_unretained NSEvent* e;
    NSTimeInterval t;
    unsigned short code;
} g_offered;
static bool offered(NSEvent* e) {
    return e == g_offered.e && e.timestamp == g_offered.t && e.keyCode == g_offered.code;
}

bool focus_key_heard(RXNode* n, NSEvent* e) {
    NSString* key = offered(e) ? nil : key_base(e);
    return key && tell(n, @"keyPressed", @[key, key_mods(e.modifierFlags), key_text(e)]);
}

bool focus_key_first(RXNode* n, NSEvent* e) {
    if (!n || !node_on_screen(n))
        return false;
    const NSEventModifierFlags m = e.modifierFlags;
    NSString* key = key_base(e);
    bool fkey = key.length > 1 && [key hasPrefix:@"f"] && isdigit([key characterAtIndex:1]);
    if (!key || (!(m & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption)) && !fkey))
        return false;
    if (tell(n, @"keyPressed", @[key, key_mods(m), key_text(e)]))
        return true;
    g_offered = {e, e.timestamp, e.keyCode};
    return false;
}

void focus_key(RXNode* n, NSEvent* e) {
    NSString* key = key_base(e);
    if (!key)
        return;
    const NSEventModifierFlags m = e.modifierFlags;
    if (!node_on_screen(n))
        return focus_release(n);
    if (!offered(e) && tell(n, @"keyPressed", @[key, key_mods(m), key_text(e)]))
        return;
    if ([key isEqualToString:@"escape"])
        return focus_release(n);
    const bool plain = !(m & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption));
    if (!plain)
        return;
    if ([key isEqualToString:@"tab"])
        return focus_move(n, (m & NSEventModifierFlagShift) ? -1 : 1);
    if (is_elem(n, E::Button)) {
        if (!e.isARepeat && ([key isEqualToString:@"space"] || [key isEqualToString:@"enter"]))
            [n clicked:nil];
    } else if (is_elem(n, E::Slider)) {
        RXSliderLayer* s = (RXSliderLayer*)n.layer;
        const int d = [key isEqualToString:@"left"] || [key isEqualToString:@"down"] ? -1
            : [key isEqualToString:@"right"] || [key isEqualToString:@"up"]          ? 1
                                                                                     : 0;
        if (d && s.enabled && n.doc.ctx) {
            const double v =
                MAX(s.minValue, MIN(s.maxValue, s.value + d * (s.step > 0 ? s.step : (s.maxValue - s.minValue) / 20)));
            s.value = v;
            doc_call(n.doc, @"emit", @[@(n.uid), @"moved", @[@(v)]]);
            doc_call(n.doc, @"emit", @[@(n.uid), @"released", @[@(v)]]);
        }
    } else if (is_list(n)) {
        RXScrollLayer* sv = (RXScrollLayer*)n.layer;
        const CGFloat page = sv.bounds.size.height;
        CGFloat to = sv.offset;
        if ([key isEqualToString:@"up"])
            to -= 40;
        else if ([key isEqualToString:@"down"])
            to += 40;
        else if ([key isEqualToString:@"pageup"])
            to -= page;
        else if ([key isEqualToString:@"pagedown"] || [key isEqualToString:@"space"])
            to += page;
        else if ([key isEqualToString:@"home"])
            to = 0;
        else if ([key isEqualToString:@"end"])
            to = sv.maxOffset;
        if (to != sv.offset)
            sv.offset = to;
    }
}

@interface RXKeysNote : NSObject
@property(nonatomic, weak) RXNode* node;
@property(nonatomic, weak) NSResponder* responder;
@property(nonatomic) bool ring;
@end
@implementation RXKeysNote
@end

id ui_keys_note(NSResponder* fr) {
    if (!fr)
        return nil;
    RXKeysNote* k = [RXKeysNote new];
    k.responder = fr;
    if ([fr isKindOfClass:RXRoot.class]) {
        RXRoot* root = (RXRoot*)fr;
        RXNode* n = root.focus ?: root.editor.node;
        k.node = n;
        k.ring = n && objc_getAssociatedObject(n, &k_ring) != nil;
    }
    return k;
}

bool ui_keys_restore(id note, NSWindow* w) {
    if (![note isKindOfClass:RXKeysNote.class])
        return false;
    RXKeysNote* k = note;
    RXNode* n = k.node;
    if (n && n.doc && root_for(n).window == w) {
        RXRoot* root = root_for(n);
        NSResponder* fr = w.firstResponder;
        if (fr == root && (root.focus == n || root.editor.node == n))
            return true;
        focus_node(n, false);
        if (k.ring)
            focus_ring(n, true);
        fr = w.firstResponder;
        return fr == root;
    }
    NSResponder* r = k.responder;
    if (!n && [r isKindOfClass:NSView.class] && ((NSView*)r).window == w) {
        NSResponder* fr = w.firstResponder;
        if (fr != r)
            [w makeFirstResponder:r];
        fr = w.firstResponder;
        return fr == r;
    }
    return false;
}
