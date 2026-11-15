// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "chrome/chrome.h"

void swizzle(Class cls, SEL sel, IMP hook, IMP* orig) {
    Method m = cls ? class_getInstanceMethod(cls, sel) : nullptr;
    if (!m) {
        rexui_log([NSString stringWithFormat:@"swizzle: %@ has no -%@; not hooked",
                                             cls ? NSStringFromClass(cls) : @"(no class)", NSStringFromSelector(sel)]);
        return;
    }
    if (class_addMethod(cls, sel, hook, method_getTypeEncoding(m))) {
        *orig = method_getImplementation(m);
    } else {
        *orig = method_setImplementation(m, hook);
    }
}

void (*orig_set_background)(id, SEL, CGColorRef);
void (*orig_set_fill)(id, SEL, CGColorRef);
void (*orig_set_bounds)(id, SEL, CGRect);
void (*orig_set_shadow_opacity)(id, SEL, float);
void (*orig_add_animation)(id, SEL, CAAnimation*, NSString*);
void (*orig_set_clear)(id, SEL, MTLClearColor);
void (*orig_window_set_background)(id, SEL, NSColor*);

id saved(CGColorRef c) {
    return c ? (__bridge id)c : (id)NSNull.null;
}
CGColorRef unsaved(id v) {
    return v == NSNull.null ? NULL : (__bridge CGColorRef)v;
}

void hook_set_background(CALayer* self, SEL sel, CGColorRef c) {
    if (transparent() && is_background(self)) {
        [g_saved_bg setObject:saved(c) forKey:self];
        if (has_color(c))
            c = NULL;
    }
    orig_set_background(self, sel, c);
    if (has_color(c))
        mark_dirty(self);
}

void hook_set_fill(CAShapeLayer* self, SEL sel, CGColorRef c) {
    if (transparent() && is_background(self)) {
        [g_saved_fill setObject:saved(c) forKey:self];
        if (has_color(c))
            c = NULL;
    }
    orig_set_fill(self, sel, c);
    if (has_color(c))
        mark_dirty(self);
    else
        rex_border_changed(self);
}

static void mark_if_coloured(CALayer* layer) {
    if (has_color(layer.backgroundColor)
        || ([layer isKindOfClass:[CAShapeLayer class]] && has_color(((CAShapeLayer*)layer).fillColor))) {
        mark_dirty(layer);
    }
}

extern "C" void rexui_layer_resized(CALayer* l);
extern "C" void panes_layer_resized(CALayer* l);

void hook_set_bounds(CALayer* self, SEL sel, CGRect r) {
    orig_set_bounds(self, sel, r);
    mark_if_coloured(self);
    rexui_layer_resized(self);
    panes_layer_resized(self);
    if ([self isKindOfClass:CAShapeLayer.class])
        rex_border_changed((CAShapeLayer*)self);
}

void (*orig_set_frame)(id, SEL, CGRect);
void hook_set_frame(CALayer* self, SEL sel, CGRect r) {
    orig_set_frame(self, sel, r);
    mark_if_coloured(self);
    rexui_layer_resized(self);
    panes_layer_resized(self);
    if ([self isKindOfClass:CAShapeLayer.class])
        rex_border_changed((CAShapeLayer*)self);
}

void (*orig_set_path)(id, SEL, CGPathRef);
void hook_set_path(CAShapeLayer* self, SEL sel, CGPathRef p) {
    orig_set_path(self, sel, p);
    mark_if_coloured(self);
    rex_border_changed(self);
}

void (*orig_set_mask)(id, SEL, CALayer*);
void hook_set_mask(CALayer* self, SEL sel, CALayer* mask) {
    orig_set_mask(self, sel, mask);
    pane_mask_changed(self);
}

void hook_add_animation(CALayer* self, SEL sel, CAAnimation* anim, NSString* key) {
    if (transparent() && is_background(self) && [anim isKindOfClass:[CAPropertyAnimation class]]) {
        NSString* path = ((CAPropertyAnimation*)anim).keyPath;
        if ([path isEqualToString:@"backgroundColor"] || [path isEqualToString:@"fillColor"])
            return;
    }
    if ([self isKindOfClass:CAShapeLayer.class] && rex_border_drops(self, anim))
        return;
    orig_add_animation(self, sel, anim, key);
}

void (*orig_add_sublayer)(id, SEL, CALayer*);
void (*orig_insert_at)(id, SEL, CALayer*, unsigned);
void (*orig_insert_below)(id, SEL, CALayer*, CALayer*);
void (*orig_insert_above)(id, SEL, CALayer*, CALayer*);
void (*orig_replace_sublayer)(id, SEL, CALayer*, CALayer*);

void hook_add_sublayer(CALayer* self, SEL sel, CALayer* l) {
    orig_add_sublayer(self, sel, l);
    if (transparent())
        mark_dirty(l);
}
void hook_insert_at(CALayer* self, SEL sel, CALayer* l, unsigned i) {
    orig_insert_at(self, sel, l, i);
    if (transparent())
        mark_dirty(l);
}
void hook_insert_below(CALayer* self, SEL sel, CALayer* l, CALayer* sib) {
    orig_insert_below(self, sel, l, sib);
    if (transparent())
        mark_dirty(l);
}
void hook_insert_above(CALayer* self, SEL sel, CALayer* l, CALayer* sib) {
    orig_insert_above(self, sel, l, sib);
    if (transparent())
        mark_dirty(l);
}
void hook_replace_sublayer(CALayer* self, SEL sel, CALayer* old, CALayer* l) {
    orig_replace_sublayer(self, sel, old, l);
    if (transparent())
        mark_dirty(l);
}

void (*orig_set_opaque)(id, SEL, BOOL);
void hook_set_opaque(CALayer* self, SEL sel, BOOL opaque) {
    orig_set_opaque(self, sel, transparent() ? NO : opaque);
}

void (*orig_backdrop_set_hidden)(id, SEL, BOOL);
void (*orig_tabbar_set_hidden)(id, SEL, BOOL);
static char k_wants_hidden;

bool wants_hidden(NSView* v) {
    return [objc_getAssociatedObject(v, &k_wants_hidden) boolValue];
}

void hook_backdrop_set_hidden(NSView* self, SEL sel, BOOL hidden) {
    objc_setAssociatedObject(self, &k_wants_hidden, @(hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    orig_backdrop_set_hidden(self, sel, transparent() ? YES : hidden);
}

void hook_tabbar_set_hidden(NSView* self, SEL sel, BOOL hidden) {
    objc_setAssociatedObject(self, &k_wants_hidden, @(hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    orig_tabbar_set_hidden(self, sel, g_config.tab_bar ? hidden : YES);
}

void (*orig_actions_set_hidden)(id, SEL, BOOL);
void (*orig_actions_did_move)(id, SEL);

void hook_actions_set_hidden(NSView* self, SEL sel, BOOL hidden) {
    objc_setAssociatedObject(self, &k_wants_hidden, @(hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    orig_actions_set_hidden(self, sel, g_config.pane_buttons ? hidden : YES);
}

void (*orig_set_has_scroller)(id, SEL, BOOL);
static char k_wants_scroller;

void hook_set_has_scroller(NSScrollView* self, SEL sel, BOOL has) {
    objc_setAssociatedObject(self, &k_wants_scroller, @(has), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    orig_set_has_scroller(self, sel, g_config.pane_scrollbars ? has : NO);
}

void apply_scroller(NSScrollView* view) {
    NSNumber* wants = objc_getAssociatedObject(view, &k_wants_scroller);
    BOOL has = g_config.pane_scrollbars && (wants ? wants.boolValue : view.hasVerticalScroller);
    if (!wants)
        objc_setAssociatedObject(view, &k_wants_scroller, @(view.hasVerticalScroller),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (view.hasVerticalScroller != has)
        orig_set_has_scroller(view, @selector(setHasVerticalScroller:), has);
}

void hook_actions_did_move(NSView* self, SEL sel) {
    orig_actions_did_move(self, sel);
    if (!g_config.pane_buttons && !self.hidden)
        orig_actions_set_hidden(self, @selector(setHidden:), YES);
}

Class actions_class(void) {
    static Class cls = NSClassFromString(RXNS(RXN_199));
    return cls;
}

Class backdrop_class(void) {
    static Class cls = NSClassFromString(RXNS(RXN_194));
    return cls;
}

Class tabbar_class(void) {
    static Class cls = NSClassFromString(RXNS(RXN_195));
    return cls;
}

Class tabitem_class(void) {
    static Class cls = NSClassFromString(RXNS(RXN_198));
    return cls;
}

Class chrome_class(void) {
    static Class cls = NSClassFromString(RXNS(RXN_196));
    return cls;
}

Class term_scroll_class(void) {
    static Class cls = NSClassFromString(RXNS(RXN_188));
    return cls;
}

Class divider_class(void) {
    static Class cls = NSClassFromString(RXNS(RXN_197));
    return cls;
}

void (*orig_section_pending)(id, SEL);
void hook_section_pending(id self, SEL sel) {
}

void (*orig_set_transform)(id, SEL, CATransform3D);
void (*orig_set_sublayer_transform)(id, SEL, CATransform3D);
void (*orig_set_affine_transform)(id, SEL, CGAffineTransform);
void hook_set_transform(CALayer* self, SEL sel, CATransform3D t) {
    transform_set();
    orig_set_transform(self, sel, t);
}
void hook_set_sublayer_transform(CALayer* self, SEL sel, CATransform3D t) {
    transform_set();
    orig_set_sublayer_transform(self, sel, t);
}
void hook_set_affine_transform(CALayer* self, SEL sel, CGAffineTransform t) {
    transform_set();
    orig_set_affine_transform(self, sel, t);
}
