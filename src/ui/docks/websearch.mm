// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "web/web.h"

static constexpr CGFloat kSearchW = 440, kSearchH = 44;

NSString* tabs_dir(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/rexui/tabs"];
}

NSString* bar_search_engine(RXSlot* slot) {
    RXDoc* lead = slot.lead ?: slot.members.firstObject;
    NSString* s = lead.root ? str(lead.root, P::search, @"") : @"";
    return s.length ? s : nil;
}

bool is_web_doc(RXDoc* doc) {
    for (RXNode* n in doc.natives)
        if (is_elem(n, E::WebView))
            return true;
    return false;
}

bool is_tab_doc(RXDoc* doc) {
    return [doc.path.stringByDeletingLastPathComponent isEqualToString:tabs_dir()];
}

int bar_part(RXDoc* doc) {
    return !is_web_doc(doc) ? 0 : is_tab_doc(doc) ? 2 : 1;
}

@interface RXSearchBar : RXDockView
@property(nonatomic) RXSlot* owner;
@property(nonatomic, strong) RXEditor* field;
@end
@interface RXSearchBar () {
    __weak RXSlot* _w_owner;
}
@end
@implementation RXSearchBar
- (RXSlot*)owner {
    return _w_owner;
}
- (void)setOwner:(RXSlot*)v {
    _w_owner = v;
}
- (void)mouseDown:(NSEvent*)e {
    editor_focus(self.field);
    CGPoint p = [self.field.layer convertPoint:NSPointToCGPoint([self convertPoint:e.locationInWindow fromView:nil])
                                     fromLayer:self.layer];
    [self.field pressAt:p clicks:ui_clicks(e) extend:(e.modifierFlags & NSEventModifierFlagShift) != 0];
}
- (void)mouseDragged:(NSEvent*)e {
    [self.field dragTo:[self.field.layer convertPoint:NSPointToCGPoint([self convertPoint:e.locationInWindow
                                                                                 fromView:nil])
                                            fromLayer:self.layer]];
}
- (void)mouseUp:(NSEvent*)e {
}
@end

static RXSearchBar* g_search;

static id bar_host(RXSlot* slot) {
    if (slot.floating && slot.bar.layer.superlayer == slot.floating.layer)
        return slot.floating;
    return slot.bar.layer.superlayer == slot.view.layer ? slot.view : nil;
}

static NSString* js_string(NSString* s) {
    NSData* d = json_data(@[s ?: @""], 0);
    NSString* a = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    return [a substringWithRange:NSMakeRange(1, a.length - 2)];
}

static void dismiss(bool refocus) {
    RXSearchBar* bar = g_search;
    if (!bar)
        return;
    g_search = nil;
    RXSlot* slot = bar.owner;
    NSWindow* w = bar.window;
    bool focused = editor_in(w) == bar.field;
    bar.field.ended = nil;
    if (focused) {
        if (refocus)
            editor_blur(bar.field);
        else
            bar.field.focused = false;
    }
    CABasicAnimation* a = [CABasicAnimation animationWithKeyPath:@"opacity"];
    a.fromValue = @1, a.toValue = @0, a.duration = 0.12;
    bar.layer.opacity = 0;
    [bar.layer addAnimation:a forKey:@"out"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 130 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [bar removeFromSuperview];
    });
    slot.searching = false;
    float_bar_refresh(slot);
}

static void open_tab(RXSlot* slot, NSURL* url, bool show) {
    RXDoc* active = active_member(slot);
    NSString* group = [slot.key substringFromIndex:@"group:".length];
    NSFileManager* fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:tabs_dir() withIntermediateDirectories:YES attributes:nil error:nil];
    NSDateFormatter* f = [NSDateFormatter new];
    f.dateFormat = @"yyyyMMdd-HHmmss";
    NSString* name =
        [NSString stringWithFormat:@"web-%@-%04x.rui", [f stringFromDate:NSDate.date], arc4random_uniform(0x10000)];
    NSString* path = [tabs_dir() stringByAppendingPathComponent:name];
    NSString* src = [NSString stringWithFormat:@"Dock {\n"
                                               @"    side: %@; width: %d\n"
                                               @"    group: %@; title: web.title || %@; iconColor: %@\n"
                                               @"    icon: web.favicon || \"globe\"\n\n"
                                               @"    Rectangle {\n"
                                               @"        grow: 1; radius: 10\n"
                                               @"        WebView { id: web; url: %@ }\n"
                                               @"    }\n"
                                               @"}\n",
                                               js_string(side_of(slot)), (int)num(active.root, P::width, 480),
                                               js_string(group), js_string(url.host ?: url.absoluteString),
                                               js_string(str(slot.lead.root ?: active.root, @"searchColor", @"")),
                                               js_string(url.absoluteString)];
    if (![src writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
        rexui_log([NSString stringWithFormat:@"search: couldn't write %@", path]);
        return;
    }
    rexui_log([NSString stringWithFormat:@"search: %@ opens %@", name, url.host ?: url.absoluteString]);
    scan();
    if (!show)
        return;
    slot.active = path;
    slot.shown = true;
    save_slot(slot);
    chrome_relayout();
}

bool web_open_tab(RXDoc* from, NSURL* url, bool show) {
    if (from.pane)
        return false;
    NSString* g = group_of(from);
    if (!g.length || !url || [url.absoluteString isEqualToString:@"about:blank"])
        return false;
    open_tab(slot_named([@"group:" stringByAppendingString:g]), url, show);
    return true;
}

static void submit(void) {
    RXSearchBar* bar = g_search;
    RXSlot* slot = bar.owner;
    NSURL* url = web_url_with(bar.field.text, slot ? bar_search_engine(slot) : nil);
    dismiss(!url);
    if (url && slot)
        open_tab(slot, url, true);
}

void bar_search(RXSlot* slot) {
    if (g_search) {
        bool same = g_search.owner == slot;
        dismiss(true);
        if (same)
            return;
    }
    if (!bar_search_engine(slot))
        return;
    RXAppBar* bar = slot.bar;
    id bh = bar_host(slot);
    NSWindow* w = [bh window];
    if (!w)
        return;
    RXRoot* host = ui_root(chrome_of(w));
    RXSearchBar* s = [[RXSearchBar alloc] initWithFrame:NSZeroRect];
    s.owner = slot;
    NSColor* fill = parse_color(str(slot.lead.root, P::barColor, @"")) ?: g_theme.bg;
    s.layer.backgroundColor = fill.CGColor;
    s.layer.cornerRadius = 14;
    s.layer.cornerCurve = kCACornerCurveContinuous;
    s.layer.borderWidth = 0.5;
    s.layer.borderColor = [g_theme.fg colorWithAlphaComponent:0.14].CGColor;
    s.layer.shadowOpacity = 0.3, s.layer.shadowRadius = 10, s.layer.shadowOffset = CGSizeMake(0, -3);
    CALayer* icon = [RXLayer layer];
    put_symbol(icon, symbol(@"magnifyingglass", 14, NSFontWeightMedium, [g_theme.fg colorWithAlphaComponent:0.55]),
               NSMakeRect(14, (kSearchH - 18) / 2, 18, 18));
    [s.layer addSublayer:icon];
    RXEditor* field = [[RXEditor alloc] initMultiline:false];
    field.font = [NSFont systemFontOfSize:15];
    field.color = g_theme.fg;
    field.placeholder = tr(@"Search or type an address");
    field.host = s;
    field.layer.frame = CGRectMake(40, (kSearchH - 22) / 2, kSearchW - 54, 22);
    field.layer.contentsScale = w.backingScaleFactor ?: 2;
    field.command = ^bool(SEL sel) {
        if (sel == @selector(insertNewline:))
            return submit(), true;
        if (sel == @selector(cancelOperation:))
            return dismiss(true), true;
        return false;
    };
    [s.layer addSublayer:field.layer];
    [field styleChanged];
    s.field = field;
    NSRect pill = [bh convertRect:NSOffsetRect(NSRectFromCGRect(bar.pill.frame), NSMinX(bar.frame), NSMinY(bar.frame))
                           toView:host];
    CGFloat x = MAX(12, MIN(round(NSMidX(pill) - kSearchW / 2), host.bounds.size.width - kSearchW - 12));
    CGFloat y = NSMinY(pill) - 10 - kSearchH;
    if (y < 8)
        y = NSMaxY(pill) + 10;
    s.frame = NSMakeRect(x, round(y), kSearchW, kSearchH);
    [host addHost:s band:kBandSearch];
    g_search = s;
    slot.searching = true;
    float_bar_refresh(slot);
    CABasicAnimation* o = [CABasicAnimation animationWithKeyPath:@"opacity"];
    o.fromValue = @0, o.toValue = @1;
    CABasicAnimation* t = [CABasicAnimation animationWithKeyPath:@"transform"];
    t.fromValue = [NSValue valueWithCATransform3D:CATransform3DMakeTranslation(0, -8, 0)];
    t.toValue = [NSValue valueWithCATransform3D:CATransform3DIdentity];
    CAAnimationGroup* g = [CAAnimationGroup animation];
    g.animations = @[o, t];
    g.duration = 0.18;
    g.timingFunction = [CAMediaTimingFunction functionWithControlPoints:kStandard[0]:kStandard[1]:kStandard[2
    ]:kStandard[3]];
    [s.layer addAnimation:g forKey:@"in"];
    editor_focus(field);
}

bool bar_search_key(NSEvent* e) {
    NSWindow* ew = e.window;
    RXSearchBar* bar = g_search;
    if (!bar || ew != bar.window)
        return false;
    if (editor_in(ew) != bar.field)
        return false;
    if (e.keyCode == 53) {
        dismiss(true);
        return true;
    }
    if (e.keyCode == 36 || e.keyCode == 76) {
        submit();
        return true;
    }
    return false;
}

void bar_search_click(NSEvent* e) {
    RXSearchBar* bar = g_search;
    if (!bar || e.window != bar.window)
        return;
    NSPoint p = [bar convertPoint:e.locationInWindow fromView:nil];
    if (NSPointInRect(p, bar.bounds))
        return;
    RXAppBar* ab = bar.owner.bar;
    id bh = bar_host(bar.owner);
    NSPoint q = [bh convertPoint:e.locationInWindow fromView:nil];
    q = NSMakePoint(q.x - NSMinX(ab.frame), q.y - NSMinY(ab.frame));
    if (bh && NSPointInRect(q, NSMakeRect(0, 0, ab.frame.size.width, ab.frame.size.height))) {
        for (RXTile* t in ab.tiles) {
            if (t.kind == kTileSearch && q.x >= NSMinX(t.frame) - kTileGap / 2 && q.x <= NSMaxX(t.frame) + kTileGap / 2)
                return;
        }
    }
    dismiss(false);
}

void close_web_doc(RXSlot* slot, RXDoc* doc) {
    if ([active_member(slot).path isEqualToString:doc.path]) {
        NSUInteger i = [slot.members indexOfObject:doc];
        RXDoc* next = nil;
        if (i != NSNotFound && i > 0)
            next = slot.members[i - 1];
        else if (i != NSNotFound && i + 1 < slot.members.count)
            next = slot.members[i + 1];
        if (next)
            slot_switch(slot, next.path);
        else {
            slot.shown = false;
            save_slot(slot);
            chrome_relayout();
        }
    }
    if (!is_tab_doc(doc)) {
        web_close_pages(doc);
        return;
    }
    NSString *path = doc.path, *name = path.lastPathComponent;
    rexui_log([NSString stringWithFormat:@"%@: closed", name]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        NSFileManager* fm = NSFileManager.defaultManager;
        [fm removeItemAtPath:path error:nil];
        scan();
        NSString* sessions =
            [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/rexui/sessions"];
        for (NSString* f in [fm contentsOfDirectoryAtPath:sessions error:nil]) {
            if ([f hasPrefix:[name stringByAppendingString:@"."]])
                [fm removeItemAtPath:[sessions stringByAppendingPathComponent:f] error:nil];
        }
    });
}
