// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "ui/ui.h"

static constexpr CGFloat kRowH = 22, kPadY = 5, kPadX = 12, kSepH = 9, kRadius = 8;

@interface RXMenuHost : RXDockView
@property(nonatomic, copy) NSArray<NSDictionary*>* items;
@property(nonatomic, strong) NSMutableArray<CALayer*>* rows;
@property(nonatomic, strong) CALayer* highlight;
@property(nonatomic) NSInteger hot;
@property(nonatomic) double opened;
@end

static RXMenuHost* g_menu;

static bool selectable(NSDictionary* it) {
    return [it[@"title"] length] && truthy_of(it[@"enabled"], true);
}

@implementation RXMenuHost
- (NSInteger)itemAt:(NSPoint)p {
    if (!NSPointInRect(p, self.bounds))
        return -1;
    for (NSUInteger i = 0; i < self.rows.count; i++)
        if (CGRectContainsPoint(self.rows[i].frame, NSPointToCGPoint(p)))
            return selectable(self.items[i]) ? (NSInteger)i : -1;
    return -1;
}
- (void)setHot:(NSInteger)i {
    _hot = i;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.highlight.hidden = i < 0;
    if (i >= 0)
        self.highlight.frame = CGRectInset(self.rows[(NSUInteger)i].frame, 4, 0);
    for (NSUInteger k = 0; k < self.rows.count; k++) {
        for (CALayer* l in self.rows[k].sublayers)
            if ([l isKindOfClass:RXTextLayer.class])
                ((RXTextLayer*)l).color = (NSInteger)k == i
                    ? NSColor.whiteColor
                    : (selectable(self.items[k]) ? g_theme.fg : [g_theme.fg colorWithAlphaComponent:0.35]);
    }
    [CATransaction commit];
}
- (void)choose:(NSInteger)i {
    if (i < 0 || i >= (NSInteger)self.items.count || !selectable(self.items[(NSUInteger)i]))
        return;
    void (^run)(void) = self.items[(NSUInteger)i][@"run"];
    menu_close();
    if (run)
        dispatch_async(dispatch_get_main_queue(), run);
}
- (void)pointer:(NSPoint)p {
    self.hot = [self itemAt:p];
}
- (void)pointerLeft:(NSPoint)p {
    self.hot = -1;
}
- (void)mouseDown:(NSEvent*)e {
    self.hot = [self itemAt:[self convertPoint:e.locationInWindow fromView:nil]];
}
- (void)mouseDragged:(NSEvent*)e {
    self.hot = [self itemAt:[self convertPoint:e.locationInWindow fromView:nil]];
}
- (void)mouseUp:(NSEvent*)e {
    [self choose:[self itemAt:[self convertPoint:e.locationInWindow fromView:nil]]];
}
- (void)rightMouseDown:(NSEvent*)e {
    [self mouseDown:e];
}
- (void)rightMouseDragged:(NSEvent*)e {
    [self mouseDragged:e];
}
- (void)rightMouseUp:(NSEvent*)e {
    if (CACurrentMediaTime() - self.opened > 0.3)
        [self mouseUp:e];
}
- (void)scrollWheel:(NSEvent*)e {
}
@end

bool menu_open_now(void) {
    return g_menu != nil;
}

void menu_close(void) {
    RXMenuHost* m = g_menu;
    if (!m)
        return;
    g_menu = nil;
    CABasicAnimation* a = [CABasicAnimation animationWithKeyPath:@"opacity"];
    a.fromValue = @1, a.toValue = @0, a.duration = 0.12;
    m.layer.opacity = 0;
    [m.layer addAnimation:a forKey:@"out"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 130 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [m removeFromSuperview];
    });
}

id menu_open(NSWindow* w, NSArray<NSDictionary*>* items, NSPoint at) {
    menu_close();
    RXRoot* root = root_of(w);
    if (!root || !items.count)
        return nil;
    tips_hide();
    RXMenuHost* m = [[RXMenuHost alloc] initWithFrame:NSZeroRect];
    m.items = items;
    m.rows = [NSMutableArray array];
    m.hot = -1;
    m.opened = CACurrentMediaTime();
    CALayer* l = m.layer;
    l.backgroundColor = [g_theme.bg colorWithAlphaComponent:0.97].CGColor;
    l.cornerRadius = kRadius;
    l.cornerCurve = kCACornerCurveContinuous;
    l.borderWidth = 0.5;
    l.borderColor = [g_theme.fg colorWithAlphaComponent:0.14].CGColor;
    l.shadowOpacity = 0.35, l.shadowRadius = 12, l.shadowOffset = CGSizeMake(0, 4);
    m.highlight = [RXLayer layer];
    m.highlight.cornerRadius = 4;
    m.highlight.backgroundColor = (ui_accent() ?: NSColor.controlAccentColor).CGColor;
    m.highlight.hidden = YES;
    [l addSublayer:m.highlight];
    NSFont* font = [NSFont systemFontOfSize:13];
    CGFloat scale = w.backingScaleFactor ?: 2, check = 18, width = 0, y = kPadY;
    NSMutableArray<RXTextLayer*>* texts = [NSMutableArray array];
    for (NSDictionary* it in items) {
        CALayer* row = [RXLayer layer];
        NSString* title = it[@"title"];
        if (!title.length) {
            row.frame = CGRectMake(0, y, 0, kSepH);
            CALayer* line = [RXLayer layer];
            line.backgroundColor = [g_theme.fg colorWithAlphaComponent:0.12].CGColor;
            [row addSublayer:line];
            y += kSepH;
        } else {
            row.frame = CGRectMake(0, y, 0, kRowH);
            RXTextLayer* t = [RXTextLayer layer];
            t.font = font;
            t.text = truthy_of(it[@"on"]) ? [@"✓ " stringByAppendingString:title] : title;
            t.color = selectable(it) ? g_theme.fg : [g_theme.fg colorWithAlphaComponent:0.35];
            t.contentsScale = scale;
            NSSize s = text_size(t, CGFLOAT_MAX);
            t.frame = CGRectMake(kPadX + (truthy_of(it[@"on"]) ? 0 : check), (kRowH - ceil(s.height)) / 2,
                                 ceil(s.width) + 1, ceil(s.height));
            width = MAX(width, t.frame.origin.x + t.frame.size.width + kPadX);
            [row addSublayer:t];
            [texts addObject:t];
            y += kRowH;
        }
        [l addSublayer:row];
        [m.rows addObject:row];
    }
    width = MAX(width, 160);
    CGFloat height = y + kPadY;
    for (CALayer* row in m.rows) {
        CGRect f = row.frame;
        row.frame = CGRectMake(0, f.origin.y, width, f.size.height);
        if (f.size.height == kSepH)
            row.sublayers.firstObject.frame = CGRectMake(kPadX, kSepH / 2, width - 2 * kPadX, 1);
    }
    NSPoint p = [root convertPoint:at fromView:nil];
    NSRect b = root.bounds;
    CGFloat x = p.x + 2, top = p.y + 2;
    if (x + width > NSMaxX(b) - 4)
        x = p.x - 2 - width;
    if (top + height > NSMaxY(b) - 4)
        top = p.y - 2 - height;
    x = MAX(4, MIN(x, NSMaxX(b) - width - 4)), top = MAX(4, MIN(top, NSMaxY(b) - height - 4));
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    m.frame = NSMakeRect(round(x), round(top), width, height);
    [root addHost:m band:kBandMenu];
    [CATransaction commit];
    CABasicAnimation* a = [CABasicAnimation animationWithKeyPath:@"opacity"];
    a.fromValue = @0, a.toValue = @1, a.duration = 0.08;
    [l addAnimation:a forKey:@"in"];
    g_menu = m;
    return m;
}

bool menu_press(NSEvent* e) {
    RXMenuHost* m = g_menu;
    if (!m)
        return false;
    if (e.window == m.window && NSPointInRect([m convertPoint:e.locationInWindow fromView:nil], m.bounds))
        return false;
    menu_close();
    bool context = e.type == NSEventTypeRightMouseDown
        || (e.type == NSEventTypeLeftMouseDown && (e.modifierFlags & NSEventModifierFlagControl));
    return !context;
}

bool menu_key(NSEvent* e) {
    RXMenuHost* m = g_menu;
    if (!m || e.type != NSEventTypeKeyDown)
        return false;
    NSInteger n = (NSInteger)m.items.count;
    auto step = [&](int d) {
        NSInteger i = m.hot;
        for (NSInteger k = 0; k < n; k++) {
            i = i < 0 ? (d > 0 ? 0 : n - 1) : (i + d + n) % n;
            if (selectable(m.items[(NSUInteger)i]))
                return (void)(m.hot = i);
        }
    };
    switch (e.keyCode) {
    case 53:
        menu_close();
        return true;
    case 126:
        step(-1);
        return true;
    case 125:
        step(1);
        return true;
    case 36:
    case 76:
        [m choose:m.hot];
        return true;
    default:
        return true;
    }
}
