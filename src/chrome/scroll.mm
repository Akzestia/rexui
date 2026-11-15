// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "base/trace.h"
#include "chrome/chrome.h"
#include "rex/rex.h"

#include <cmath>

static Class surface_class(void) {
    static Class cls = NSClassFromString(RXNS(RXN_164));
    return cls;
}

static void (*orig_surface_scroll)(id, SEL, NSEvent*);
static void (*orig_scroller_scroll)(id, SEL, NSEvent*);
static ptrdiff_t g_smooth_ivar = -1;
static ptrdiff_t g_position_ivar = -1;

@interface RXTermScrollValues : NSObject {
   @public
    double dy;
    NSEventPhase phase;
    NSPoint location;
    __weak NSWindow* window;
    BOOL inverted;
}
@end
@implementation RXTermScrollValues
@end

static char k_values;
static RXTermScrollValues* values_of(NSEvent* e) {
    return objc_getAssociatedObject(e, &k_values);
}

static CGFloat ev_dy(NSEvent* self, SEL) {
    return values_of(self)->dy;
}
static CGFloat ev_zero(NSEvent*, SEL) {
    return 0;
}
static BOOL ev_yes(NSEvent*, SEL) {
    return YES;
}
static NSEventPhase ev_phase(NSEvent* self, SEL) {
    return values_of(self)->phase;
}
static NSEventPhase ev_no_phase(NSEvent*, SEL) {
    return NSEventPhaseNone;
}
static NSPoint ev_location(NSEvent* self, SEL) {
    return values_of(self)->location;
}
static NSWindow* ev_window(NSEvent* self, SEL) {
    return values_of(self)->window;
}
static NSInteger ev_window_number(NSEvent* self, SEL) {
    return values_of(self)->window.windowNumber;
}
static BOOL ev_inverted(NSEvent* self, SEL) {
    return values_of(self)->inverted;
}
static NSEventModifierFlags ev_modifiers(NSEvent*, SEL) {
    return NSEvent.modifierFlags;
}

static Class made_class(Class base) {
    static Class made, made_base;
    if (made && made_base == base)
        return made;
    NSString* name = [@"RXTermScrollEvent_" stringByAppendingString:NSStringFromClass(base)];
    Class cls = objc_getClass(name.UTF8String);
    if (!cls) {
        cls = objc_allocateClassPair(base, name.UTF8String, 0);
        struct {
            SEL sel;
            IMP imp;
        } methods[] = {
            {@selector(scrollingDeltaY), (IMP)ev_dy},
            {@selector(deltaY), (IMP)ev_dy},
            {@selector(scrollingDeltaX), (IMP)ev_zero},
            {@selector(deltaX), (IMP)ev_zero},
            {@selector(deltaZ), (IMP)ev_zero},
            {@selector(hasPreciseScrollingDeltas), (IMP)ev_yes},
            {@selector(phase), (IMP)ev_phase},
            {@selector(momentumPhase), (IMP)ev_no_phase},
            {@selector(locationInWindow), (IMP)ev_location},
            {@selector(window), (IMP)ev_window},
            {@selector(windowNumber), (IMP)ev_window_number},
            {@selector(isDirectionInvertedFromDevice), (IMP)ev_inverted},
            {@selector(modifierFlags), (IMP)ev_modifiers},
        };
        for (auto& m : methods) {
            class_addMethod(cls, m.sel, m.imp, method_getTypeEncoding(class_getInstanceMethod(base, m.sel)));
        }
        objc_registerClassPair(cls);
    }
    made = cls, made_base = base;
    return cls;
}

static NSEvent* made_event(NSView* view, double dy, NSEventPhase phase, BOOL inverted) {
    CGEventRef cg = CGEventCreateScrollWheelEvent2(NULL, kCGScrollEventUnitPixel, 1, 0, 0, 0);
    if (!cg)
        return nil;
    NSEvent* e = [NSEvent eventWithCGEvent:cg];
    CFRelease(cg);
    if (!e)
        return nil;
    object_setClass(e, made_class(object_getClass(e)));
    RXTermScrollValues* v = [RXTermScrollValues new];
    v->dy = dy;
    v->phase = phase;
    v->window = view.window;
    v->inverted = inverted;
    NSPoint p = [view convertPoint:view.window.mouseLocationOutsideOfEventStream fromView:nil];
    NSRect b = view.bounds;
    p.x = std::clamp(p.x, NSMinX(b), std::max(NSMinX(b), NSMaxX(b) - 1));
    p.y = std::clamp(p.y, NSMinY(b), std::max(NSMinY(b), NSMaxY(b) - 1));
    v->location = [view convertPoint:p toView:nil];
    objc_setAssociatedObject(e, &k_values, v, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return e;
}

struct ScrollPosition {
    double position;
    long applied;
    bool tracking;
};

static double send(NSView* view, double dy, NSEventPhase phase, BOOL inverted, double cell) {
    NSEvent* e = made_event(view, dy, phase, inverted);
    if (!e)
        return 0;
    uint8_t* flag = g_smooth_ivar >= 0 ? (uint8_t*)(__bridge void*)view + g_smooth_ivar : nullptr;
    auto* pos = g_position_ivar >= 0 ? (ScrollPosition*)((uint8_t*)(__bridge void*)view + g_position_ivar) : nullptr;
    uint8_t was = flag ? *flag : 0;
    double before = pos ? pos->position : 0;
    if (flag)
        *flag = 1;
    orig_surface_scroll(view, @selector(scrollWheel:), e);
    if (flag)
        *flag = was;
    if (!pos || !pos->tracking || dy == 0)
        return 0;
    double left = dy - (pos->position - before) * cell;
    return left * dy > 0 && fabs(left) >= std::max(0.5, 0.05 * fabs(dy)) ? left : 0;
}

@interface RXTermScroll : NSObject {
   @public
    __weak NSView* view;
    __weak NSView* clip;
    uint32_t tick;
    double remaining;
    double tau;
    CFTimeInterval last;
    bool began;
    bool touching, coasting;
    CFTimeInterval grace;
    double cell;
    BOOL inverted;
    double x, v;
    bool hit;
    BOOL masked;
}
- (void)frame:(const RXFrame*)f;
@end
static void term_scroll_tick(id owner, const RXFrame* f) {
    [(RXTermScroll*)owner frame:f];
}

@implementation RXTermScroll
- (void)stop {
    ui_clock_remove(tick);
    tick = 0;
    last = 0;
    began = false;
    hit = false;
}

- (void)place {
    NSView* c = clip;
    if (!c) {
        NSView* surface = view;
        for (NSView* sub in surface.subviews) {
            if ([sub isKindOfClass:NSScrollView.class])
                c = clip = ((NSScrollView*)sub).contentView;
        }
    }
    CALayer* l = c.layer;
    if (!l)
        return;
    bool on = x != 0;
    bool was_on = !CATransform3DIsIdentity(l.sublayerTransform);
    if (!on && !was_on)
        return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (on && !was_on)
        masked = l.masksToBounds, l.masksToBounds = YES;
    l.sublayerTransform =
        on ? CATransform3DMakeTranslation(0, l.contentsAreFlipped ? x : -x, 0) : CATransform3DIdentity;
    if (!on && was_on)
        l.masksToBounds = masked;
    [CATransaction commit];
}

- (void)frame:(const RXFrame*)l {
    NSView* view_ = view;
    if (!view_.window) {
        x = v = 0;
        [self place];
        return [self stop];
    }
    double dt = last ? l->target - last : l->duration;
    dt = std::clamp(dt, 0.001, 0.05);
    last = l->target;
    bool holding = touching || coasting || CACurrentMediaTime() < grace;
    double step = tau > 0 ? remaining * (1 - exp(-dt / tau)) : remaining;
    if (!holding && fabs(remaining - step) < 0.5)
        step = remaining;
    double max = g_config.pane_scroll_bounce_size;
    double omega = g_config.pane_scroll_bounce_spring[0], zeta = g_config.pane_scroll_bounce_spring[1];
    if (touching && x != 0 && step * x < 0) {
        double back = fabs(step) < fabs(x) ? step : -x;
        x += back, step -= back, remaining -= back;
    }
    if (fabs(step) >= 0.01 || (step != 0 && step == remaining)) {
        remaining -= step;
        double left = send(view_, step, began ? NSEventPhaseChanged : NSEventPhaseBegan, inverted, cell);
        began = true;
        if (left != 0 && g_config.pane_scroll_bounce && max > 0) {
            if (touching) {
                double give = 1 - std::min(fabs(x) / max, 1.0);
                x = std::clamp(x + left * give * give, -max, max);
                v = 0;
            } else if (!hit) {
                double vmax = max * omega * M_E;
                v = std::clamp(v + left / dt, -vmax, vmax);
                hit = true;
                remaining = 0;
            }
        }
    }
    if (!touching && (x != 0 || v != 0)) {
        for (double t = dt; t > 0; t -= 1.0 / 480) {
            double h = std::min(t, 1.0 / 480);
            v += (-omega * omega * x - 2 * zeta * omega * v) * h;
            x += v * h;
        }
        x = std::clamp(x, -max, max);
        if (fabs(x) < 0.2 && fabs(v) < 8)
            x = v = 0;
    }
    [self place];
    if (remaining == 0 && !holding && x == 0 && v == 0) {
        if (began)
            send(view_, 0, NSEventPhaseEnded, inverted, cell);
        [self stop];
    }
}
@end

static char k_state;

static RXTermScroll* state_of(NSView* surface) {
    RXTermScroll* s = objc_getAssociatedObject(surface, &k_state);
    if (!s) {
        s = [RXTermScroll new];
        s->view = surface;
        objc_setAssociatedObject(surface, &k_state, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return s;
}

static bool take(NSView* surface, NSEvent* e) {
    RXTermScroll* s = state_of(surface);
    double dy = e.scrollingDeltaY, dx = e.scrollingDeltaX;
    NSEventModifierFlags held = e.modifierFlags
        & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption
           | NSEventModifierFlagShift);
    if (!s->touching && !s->coasting && (held || fabs(dx) > fabs(dy)))
        return false;
    if (!s->tick || s->cell <= 0) {
        s->cell = rex_cell_height((__bridge void*)surface);
        if (s->cell <= 0)
            s->cell = 16;
    }
    if (e.hasPreciseScrollingDeltas) {
        NSEventPhase p = e.phase, m = e.momentumPhase;
        CFTimeInterval now = CACurrentMediaTime();
        if (p & (NSEventPhaseMayBegin | NSEventPhaseBegan))
            s->hit = false, s->v = 0;
        if (p & (NSEventPhaseMayBegin | NSEventPhaseBegan | NSEventPhaseChanged | NSEventPhaseStationary))
            s->touching = true;
        if (p & (NSEventPhaseEnded | NSEventPhaseCancelled)) {
            s->touching = false, s->grace = now + 0.1;
            if (s->x != 0)
                s->hit = true;
        }
        if (m & (NSEventPhaseBegan | NSEventPhaseChanged))
            s->coasting = true;
        if (m & (NSEventPhaseEnded | NSEventPhaseCancelled))
            s->coasting = false, s->grace = 0;
        s->remaining += dy * g_config.pane_scroll_speed;
        s->tau = g_config.pane_scroll_trackpad_ms / 3000;
    } else {
        if (dy == 0)
            return true;
        double rows = copysign(std::max(fabs(dy), 1.0), dy) * g_config.pane_scroll_lines;
        if (s->remaining * rows < 0)
            s->remaining = 0;
        s->hit = false;
        s->remaining += rows * s->cell;
        s->tau = g_config.pane_scroll_ms / 3000;
    }
    s->inverted = e.isDirectionInvertedFromDevice;
    if (!s->tick)
        s->tick = ui_clock_add(RX_TICK_SCROLL, 120, surface, s, term_scroll_tick);
    return true;
}

static void hook_surface_scroll(NSView* self, SEL sel, NSEvent* e) {
    if (g_config.pane_scroll_smooth && take(self, e))
        return;
    orig_surface_scroll(self, sel, e);
}

static void hook_scroller_scroll(NSView* self, SEL sel, NSEvent* e) {
    if (g_config.pane_scroll_smooth) {
        NSView* surface = self.superview;
        while (surface && ![surface isKindOfClass:surface_class()])
            surface = surface.superview;
        if (surface && take(surface, e))
            return;
    }
    orig_scroller_scroll(self, sel, e);
}

void scroll_install(void) {
    Class surface = surface_class();
    if (!surface || !class_getInstanceMethod(surface, @selector(scrollWheel:))) {
        rexui_log(@"scroll: no terminal view class (pane-scroll has no effect)");
        return;
    }
    swizzle(surface, @selector(scrollWheel:), (IMP)hook_surface_scroll, (IMP*)&orig_surface_scroll);
    if (Class scroller = term_scroll_class()) {
        swizzle(scroller, @selector(scrollWheel:), (IMP)hook_scroller_scroll, (IMP*)&orig_scroller_scroll);
    }
    if (Ivar iv = class_getInstanceVariable(
            surface, RX_NAME_X("\111\306\303\111\333\113\111\022\036\376\061\135\161\120\333"))) {
        g_smooth_ivar = ivar_getOffset(iv);
    } else {
        rexui_log(@"scroll: no smooth scrolling field: pane-scroll moves by whole rows");
    }
    if (Ivar iv = class_getInstanceVariable(surface, RX_NAME_X("\111\306\303\111\333\113\111\022\036\376\061\135"))) {
        g_position_ivar = ivar_getOffset(iv);
    } else {
        rexui_log(@"scroll: no smooth scroll position field: no bounce at the scrollback's ends");
    }
}
