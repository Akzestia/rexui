// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "chrome/chrome.h"

static BOOL (*orig_reduce_motion)(id, SEL);
static BOOL hook_reduce_motion(id self, SEL sel) {
    return g_config.pane_motion == 2 ? NO : orig_reduce_motion(self, sel);
}

void motion_config(void) {
    static bool installed;
    static int last;
    if (!installed) {
        swizzle(NSWorkspace.class, @selector(accessibilityDisplayShouldReduceMotion), (IMP)hook_reduce_motion,
                (IMP*)&orig_reduce_motion);
        installed = true;
        last = g_config.pane_motion;
        return;
    }
    if (last == g_config.pane_motion)
        return;
    last = g_config.pane_motion;
    [NSWorkspace.sharedWorkspace.notificationCenter
        postNotificationName:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification
                      object:NSWorkspace.sharedWorkspace];
}

static NSMutableArray<bool (^)(void)>* g_each;
static bool g_each_armed;

static void run_each(void) {
    g_each_armed = false;
    NSArray<bool (^)(void)>* now = g_each;
    g_each = [NSMutableArray array];
    for (bool (^f)(void) in now) {
        if (f())
            [g_each addObject:f];
    }
}

static void arm_each(void) {
    if (g_each_armed || !g_each.count)
        return;
    g_each_armed = true;
    static SEL sel = @selector(addCommitHandler:forPhase:);
    using Add = BOOL (*)(id, SEL, void (^)(void), int);
    if (![CATransaction respondsToSelector:sel]
        || !((Add)objc_msgSend)(
            [CATransaction class], sel,
            ^{
                run_each();
            },
            1)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 120), dispatch_get_main_queue(), ^{
            run_each();
        });
    }
}

void each_commit(bool (^f)(void)) {
    if (!g_each)
        g_each = [NSMutableArray array];
    [g_each addObject:[f copy]];
    static CFRunLoopObserverRef observer;
    if (!observer) {
        observer = CFRunLoopObserverCreateWithHandler(nullptr, kCFRunLoopBeforeWaiting, true, 1999999,
                                                      ^(CFRunLoopObserverRef, CFRunLoopActivity) {
                                                          arm_each();
                                                      });
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
    }
    arm_each();
}

static double g_ms = -1, g_curve[4];
static bool g_eased;
static CFTimeInterval g_until;

void chrome_glide_panes(double ms, const double* curve) {
    if (!g_config.pane_glide || ms <= 0)
        return;
    g_ms = ms;
    g_eased = !curve;
    if (curve)
        std::copy(curve, curve + 4, g_curve);
    g_until = CACurrentMediaTime() + 0.2;
}

static bool glides(NSView* v) {
    static NSMapTable<Class, NSNumber*>* seen = [NSMapTable strongToStrongObjectsMapTable];
    Class c = v.class;
    NSNumber* yes = [seen objectForKey:c];
    if (!yes) {
        NSString* n = NSStringFromClass(c);
        static NSString *pane = RXNS(RXN_193), *line = RXNS(RXN_183);
        yes = @([n hasPrefix:pane] || [n containsString:line]);
        [seen setObject:yes forKey:c];
    }
    return yes.boolValue;
}

static void collect(NSView* v, NSMutableArray<NSView*>* out, int depth) {
    for (NSView* s in v.subviews) {
        if (glides(s))
            [out addObject:s];
        else if (depth < 12)
            collect(s, out, depth + 1);
    }
}

static NSMapTable<NSView*, NSArray<NSValue*>*>* g_was;
static __weak NSView* g_chrome;
static double g_run_ms, g_run_curve[4];
static bool g_run_eased;
static CFTimeInterval g_wait_until;
static bool g_moved;
static NSView* (^g_arriving)(void);
static CGRect g_arrive_from;
static void (^g_unlift)(bool landed);

static CGRect on_screen(CALayer* l, CALayer* root) {
    CALayer* p = l.presentationLayer ?: l;
    return [l.superlayer convertRect:p.frame toLayer:root];
}

static CGRect laid_out(CALayer* l, CALayer* root) {
    CGSize s = l.bounds.size;
    CGRect r = CGRectMake(l.position.x - l.anchorPoint.x * s.width, l.position.y - l.anchorPoint.y * s.height, s.width,
                          s.height);
    return [l.superlayer convertRect:r toLayer:root];
}

static void unlift(bool landed) {
    g_arriving = nil;
    if (auto u = g_unlift) {
        g_unlift = nil;
        u(landed);
    }
}

static void glide(NSView* v, CGRect was) {
    CALayer *l = v.layer, *sup = l.superlayer;
    if (!l || !sup || g_run_ms <= 0 || !CATransform3DIsIdentity(l.transform))
        return;
    CGRect now = l.frame, old = [sup convertRect:was fromLayer:g_chrome.layer];
    if (now.size.width < 1 || now.size.height < 1 || old.size.width < 1 || old.size.height < 1)
        return;
    if (fabs(old.origin.x - now.origin.x) < 0.5 && fabs(old.origin.y - now.origin.y) < 0.5
        && fabs(old.size.width - now.size.width) < 0.5 && fabs(old.size.height - now.size.height) < 0.5)
        return;
    CGFloat sx = old.size.width / now.size.width, sy = old.size.height / now.size.height;
    CGPoint pos = l.position, off = CGPointMake(pos.x - now.origin.x, pos.y - now.origin.y);
    CGPoint d = CGPointMake(old.origin.x + sx * off.x - pos.x, old.origin.y + sy * off.y - pos.y);
    CAMediaTimingFunction* f = g_run_eased
        ? [CAMediaTimingFunction functionWithControlPoints:0.65:0:0.35:1]
        : [CAMediaTimingFunction functionWithControlPoints:g_run_curve[0]:g_run_curve[1]:g_run_curve[2]:g_run_curve[3]];
    CABasicAnimation* move = [CABasicAnimation animationWithKeyPath:@"position"];
    move.additive = YES;
    move.fromValue = [NSValue valueWithPoint:NSMakePoint(d.x, d.y)];
    move.toValue = [NSValue valueWithPoint:NSZeroPoint];
    CABasicAnimation* scale = [CABasicAnimation animationWithKeyPath:@"transform"];
    scale.fromValue = [NSValue valueWithCATransform3D:CATransform3DMakeScale(sx, sy, 1)];
    scale.toValue = [NSValue valueWithCATransform3D:CATransform3DIdentity];
    for (CABasicAnimation* a in @[move, scale]) {
        a.duration = g_run_ms / 1000;
        a.timingFunction = f;
        a.fillMode = kCAFillModeBackwards;
    }
    [l addAnimation:move forKey:@"rexui.glide.position"];
    [l addAnimation:scale forKey:@"rexui.glide.transform"];
}

static void land(void);
static int g_landing;

static void arm_land(void) {
    int gen = ++g_landing;
    each_commit(^bool {
        if (gen != g_landing)
            return false;
        land();
        return gen == g_landing && (g_arriving || g_was.count);
    });
}

static void landed(CFTimeInterval now) {
    if (g_moved)
        return;
    g_moved = true;
    g_wait_until = MIN(g_wait_until, now + 0.25);
}

static void land(void) {
    NSView* chrome = g_chrome;
    if (!chrome) {
        g_was = nil;
        return unlift(false);
    }
    CALayer* root = chrome.layer;
    CFTimeInterval now = CACurrentMediaTime();
    NSView* arrived = g_arriving ? g_arriving() : nil;
    if (arrived && arrived.layer.superlayer) {
        auto from = g_arrive_from;
        unlift(true);
        landed(now);
        [g_was removeObjectForKey:arrived];
        glide(arrived, from);
    }
    NSMapTable<NSView*, NSArray<NSValue*>*>* still = [NSMapTable weakToStrongObjectsMapTable];
    for (NSView* v in g_was.keyEnumerator.allObjects) {
        CALayer* l = v.layer;
        if (!l.superlayer || !v.window)
            continue;
        NSArray<NSValue*>* snap = [g_was objectForKey:v];
        if (CGRectEqualToRect(CGRectIntegral(laid_out(l, root)), CGRectIntegral(snap[1].rectValue))) {
            [still setObject:snap forKey:v];
        } else {
            if (!g_arriving)
                landed(now);
            glide(v, snap[0].rectValue);
        }
    }
    g_was = still;
    if (!((g_arriving || still.count) && now < g_wait_until)) {
        g_was = nil;
        unlift(false);
    }
}

static void snapshot(NSView* chrome, NSView* content) {
    g_chrome = chrome;
    g_moved = false;
    g_was = [NSMapTable weakToStrongObjectsMapTable];
    NSMutableArray<NSView*>* views = [NSMutableArray array];
    collect(content, views, 0);
    for (NSView* v in views) {
        CALayer* l = v.layer;
        if (!l.superlayer || v.hiddenOrHasHiddenAncestor)
            continue;
        [g_was setObject:@[
            [NSValue valueWithRect:on_screen(l, chrome.layer)], [NSValue valueWithRect:laid_out(l, chrome.layer)]
        ]
                  forKey:v];
    }
}

static CFTimeInterval g_area_at;

void glide_before(NSView* chrome, NSView* content, NSRect to) {
    if (!NSEqualRects(content.frame, to))
        g_area_at = CACurrentMediaTime();
    if (g_ms < 0)
        return;
    if (CACurrentMediaTime() > g_until || !g_config.pane_glide) {
        g_ms = -1;
        return;
    }
    if (NSEqualRects(content.frame, to) || chrome.inLiveResize || !chrome.layer)
        return;
    unlift(false);
    g_run_ms = g_ms;
    g_run_eased = g_eased;
    std::copy(g_curve, g_curve + 4, g_run_curve);
    g_ms = -1;
    snapshot(chrome, content);
    g_wait_until = CACurrentMediaTime() + 0.25;
    if (g_was.count)
        arm_land();
}

void glide_panes_from_now(NSView* chrome, NSView* content, double wait_s, bool others, CGRect from,
                          NSView* (^arriving)(void), void (^unlift_)(bool landed)) {
    unlift(false);
    if (!chrome.layer) {
        if (unlift_)
            unlift_(false);
        return;
    }
    g_run_ms = g_config.pane_glide ? g_config.pane_glide_ms : 0;
    g_run_eased = false;
    std::copy(g_config.pane_glide_curve, g_config.pane_glide_curve + 4, g_run_curve);
    snapshot(chrome, content);
    if (!others)
        [g_was removeAllObjects];
    g_arriving = arriving;
    g_arrive_from = from;
    g_unlift = unlift_;
    g_wait_until = CACurrentMediaTime() + wait_s;
    arm_land();
}

void glide_panes_abandon(void) {
    g_was = nil;
    unlift(false);
}

namespace {
struct HostOrig {
    Class cls;
    IMP frame, origin, size;
};
HostOrig g_host_orig[8];
int g_host_origs;
NSHashTable<NSView*>* g_layouts;
__weak NSWindow* g_note_window;
__weak NSView* g_note_chrome;
}

static const HostOrig* host_orig(id self) {
    for (Class c = object_getClass(self); c; c = class_getSuperclass(c))
        for (int i = 0; i < g_host_origs; i++)
            if (g_host_orig[i].cls == c)
                return &g_host_orig[i];
    return nullptr;
}

static void pop(NSView* v) {
    CALayer* l = v.layer;
    CGRect now = laid_out(l, g_chrome.layer);
    if (now.size.width < 1 || now.size.height < 1)
        return;
    glide(v, CGRectInset(now, now.size.width * 0.035, now.size.height * 0.035));
    CABasicAnimation* fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @0;
    fade.toValue = @(l.opacity);
    fade.duration = g_run_ms / 1000 * 0.6;
    fade.timingFunction = [CAMediaTimingFunction functionWithControlPoints:g_run_curve[0]:g_run_curve[1]:g_run_curve[2
    ]:MIN(1.0, g_run_curve[3])];
    fade.fillMode = kCAFillModeBackwards;
    [l addAnimation:fade forKey:@"rexui.glide.opacity"];
}

static void pop_new(void) {
    if (!g_layouts.count || g_run_ms <= 0 || !g_chrome)
        return;
    for (NSView* sup in g_layouts) {
        for (NSView* s in sup.subviews) {
            CALayer* l = s.layer;
            if (glides(s) && l && !l.presentationLayer && !s.hiddenOrHasHiddenAncestor && s.window)
                pop(s);
        }
    }
}

static bool in_content(NSView* v, NSView* content) {
    for (NSView* s = v.superview; s; s = s.superview)
        if (s == content)
            return true;
    return false;
}

static void note(NSView* v) {
    if (g_config.pane_motion != 1)
        return;
    CALayer* l = v.layer;
    if (!l.superlayer || (g_was && [g_was objectForKey:v]))
        return;
    NSWindow* w = v.window;
    if (!w || w.inLiveResize || NSEvent.pressedMouseButtons)
        return;
    CFTimeInterval now = CACurrentMediaTime();
    if (!g_config.pane_glide && now - g_area_at < 0.1)
        return;
    if (g_note_window != w)
        g_note_window = w, g_note_chrome = chrome_of(w);
    NSView *chrome = g_note_chrome, *content = chrome ? chrome_content(chrome) : nil;
    if (!content || !chrome.layer || !in_content(v, content))
        return;
    if (auto* gliding = g_chrome; g_was && gliding && gliding != chrome)
        return;
    CGRect was = laid_out(l, chrome.layer);
    if (was.size.width < 1 || was.size.height < 1)
        return;
    bool fresh = !g_was;
    if (fresh) {
        g_chrome = chrome;
        g_moved = false;
        g_was = [NSMapTable weakToStrongObjectsMapTable];
        g_run_ms = g_config.pane_glide_ms;
        g_run_eased = false;
        std::copy(g_config.pane_glide_curve, g_config.pane_glide_curve + 4, g_run_curve);
        g_wait_until = now + 0.1;
    } else {
        g_wait_until = MAX(g_wait_until, now + 0.1);
    }
    [g_was setObject:@[[NSValue valueWithRect:on_screen(l, chrome.layer)], [NSValue valueWithRect:was]] forKey:v];
    if (!g_layouts)
        g_layouts = [NSHashTable weakObjectsHashTable];
    if (v.superview)
        [g_layouts addObject:v.superview];
    if (fresh) {
        arm_land();
        each_commit(^bool {
            pop_new();
            if (g_was)
                return true;
            g_layouts = nil;
            return false;
        });
    }
}

static NSRect (^g_frame_filter)(NSView* v, NSRect asked);
void motion_frame_filter(NSRect (^f)(NSView* v, NSRect asked)) {
    g_frame_filter = [f copy];
}

static void host_set_frame(NSView* self, SEL sel, NSRect r) {
    const HostOrig* o = host_orig(self);
    if (auto f = g_frame_filter)
        r = f(self, r);
    if (!NSEqualRects(self.frame, r))
        note(self);
    if (o)
        ((void (*)(id, SEL, NSRect))o->frame)(self, sel, r);
}

static void host_set_origin(NSView* self, SEL sel, NSPoint p) {
    const HostOrig* o = host_orig(self);
    if (auto f = g_frame_filter)
        p = f(self, NSMakeRect(p.x, p.y, self.frame.size.width, self.frame.size.height)).origin;
    if (!NSEqualPoints(self.frame.origin, p))
        note(self);
    if (o)
        ((void (*)(id, SEL, NSPoint))o->origin)(self, sel, p);
}

static void host_set_size(NSView* self, SEL sel, NSSize z) {
    const HostOrig* o = host_orig(self);
    if (auto f = g_frame_filter)
        z = f(self, NSMakeRect(self.frame.origin.x, self.frame.origin.y, z.width, z.height)).size;
    if (!NSEqualSizes(self.frame.size, z))
        note(self);
    if (o)
        ((void (*)(id, SEL, NSSize))o->size)(self, sel, z);
}

static void hook_host_class(Class c) {
    if (g_host_origs == 8)
        return;
    for (Class s = c; s; s = class_getSuperclass(s))
        for (int i = 0; i < g_host_origs; i++)
            if (g_host_orig[i].cls == s)
                return;
    for (SEL sel : { @selector(setFrame:), @selector(setFrameOrigin:), @selector(setFrameSize:) })
        if (!class_getInstanceMethod(c, sel))
            return;
    HostOrig& o = g_host_orig[g_host_origs];
    o.cls = c;
    g_host_origs++;
    swizzle(c, @selector(setFrame:), (IMP)host_set_frame, &o.frame);
    swizzle(c, @selector(setFrameOrigin:), (IMP)host_set_origin, &o.origin);
    swizzle(c, @selector(setFrameSize:), (IMP)host_set_size, &o.size);
    if (c)
        rexui_log_file([NSString stringWithFormat:@"pane motion: %@ glides", NSStringFromClass(c)]);
}

void motion_watch(NSView* content) {
    if ((g_config.pane_motion != 1 && !g_config.pane_resize) || !content)
        return;
    static CFTimeInterval last;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - last < 2)
        return;
    last = now;
    NSMutableArray<NSView*>* views = [NSMutableArray array];
    collect(content, views, 0);
    for (NSView* v in views)
        if (!host_orig(v))
            hook_host_class(object_getClass(v));
}
