// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "chrome/chrome.h"
#include "rex/rex.h"

void (*orig_chrome_layout)(id, SEL);
static char k_base;
static char k_moved;
static char k_we_hid;

void hook_chrome_layout(NSView* self, SEL sel) {
    orig_chrome_layout(self, sel);
    NSView* tabbar = nil;
    for (NSView* v in self.subviews) {
        if (tabbar_class() && [v isKindOfClass:tabbar_class()])
            tabbar = v;
    }
    CGFloat top = tabbar ? NSMaxY(tabbar.frame) : 0;
    bool bar_hidden = tabbar && !g_config.tab_bar && top > 0;
    NSView* content = nil;
    for (NSView* v in self.subviews) {
        NSRect f = v.frame;
        if (divider_class() && [v isKindOfClass:divider_class()] && f.origin.y <= top + 1) {
            if (bar_hidden && !v.hidden) {
                v.hidden = YES;
                objc_setAssociatedObject(v, &k_we_hid, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            } else if (!bar_hidden && v.hidden && objc_getAssociatedObject(v, &k_we_hid)) {
                v.hidden = NO;
                objc_setAssociatedObject(v, &k_we_hid, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        } else if ([v class] == [NSView class] && f.origin.y >= top - 1
                   && (!content || objc_getAssociatedObject(v, &k_base)
                       || f.size.width * f.size.height > content.frame.size.width * content.frame.size.height)) {
            if (!content || !objc_getAssociatedObject(content, &k_base))
                content = v;
        }
    }
    NSRect area = self.bounds;
    if (content) {
        NSValue* moved = objc_getAssociatedObject(content, &k_moved);
        if (!moved || !NSEqualRects(moved.rectValue, content.frame)) {
            objc_setAssociatedObject(content, &k_base, [NSValue valueWithRect:content.frame],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        NSRect base = [objc_getAssociatedObject(content, &k_base) rectValue];
        CGFloat y0 = bar_hidden ? 0 : base.origin.y;
        Insets d = ui_layout_docks(self, NSMakeRect(0, y0, self.bounds.size.width, self.bounds.size.height - y0));
        const Config& c = g_config;
        CGFloat x = base.origin.x + c.left + d.left, y = y0 + c.top + d.top;
        NSRect to = NSMakeRect(x, y, MAX(0, NSMaxX(base) - c.right - d.right - x),
                               MAX(0, NSMaxY(base) - c.bottom - d.bottom - y));
        glide_before(self, content, to);
        motion_watch(content);
        ui_pointer_feed(self);
        term_full_frame(self, &to);
        if (!NSEqualRects(content.frame, to))
            content.frame = to;
        objc_setAssociatedObject(content, &k_moved, [NSValue valueWithRect:to], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        for (NSView* s in content.subviews) {
            if (!NSEqualRects(s.frame, content.bounds))
                s.frame = content.bounds;
        }
        area = to;
        if (self.window)
            [g_pane_area setObject:[NSValue valueWithSize:to.size] forKey:self.window];
        rex_slide_place((__bridge const void*)self, (__bridge const void*)content);
    } else {
        ui_layout_docks(self, NSMakeRect(0, top, self.bounds.size.width, self.bounds.size.height - top));
    }
    update_gif(self, area);
    poll_tabs();
}

NSView* chrome_content(NSView* chrome) {
    for (NSView* v in chrome.subviews) {
        if (objc_getAssociatedObject(v, &k_base))
            return v;
    }
    return nil;
}

static NSView* find_chrome(NSView* view) {
    if (chrome_class() && [view isKindOfClass:chrome_class()])
        return view;
    for (NSView* sub in view.subviews) {
        if (NSView* found = find_chrome(sub))
            return found;
    }
    return nil;
}

NSView* chrome_of(NSWindow* w) {
    NSView* frame = w.contentView.superview ?: w.contentView;
    return frame ? find_chrome(frame) : nil;
}

void chrome_relayout(void) {
    for (NSWindow* w in NSApp.windows) {
        if (!is_rex_window(w))
            continue;
        if (NSView* chrome = chrome_of(w))
            chrome.needsLayout = YES;
    }
}

bool is_rex_window(NSWindow* w) {
    return w && ![w isKindOfClass:[NSPanel class]] && (w.styleMask & NSWindowStyleMaskTitled)
        && ![w.title hasPrefix:RXNS(RXN_166)] && ![w.identifier containsString:RXNS(RXN_166)];
}
