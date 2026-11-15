// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "base/clicks.h"
#include "base/rexui.h"
#include "chrome/chrome.h"
#include "core/sync/rmw.h"
#include "panes/lane.h"
#include "rex/rex.h"

#import <GameController/GameController.h>

#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <pthread.h>
#include <sys/sysctl.h>

#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <array>
#include <atomic>
#include <unordered_set>

extern NSString* g_session_id;

@interface CALayerHost : CALayer
@property uint32_t contextId;
@end

@interface CAPortalLayer : CALayer
@property(weak) CALayer* sourceLayer;
@end

@class RXPaneApp;

@interface RXAppPaneLayer : CALayer
@end
@implementation RXAppPaneLayer
- (id<CAAction>)actionForKey:(NSString*)key {
    return nil;
}
@end

@interface RXAppPane : NSObject
@property(weak) RXPaneApp* app;
@property(nonatomic) NSView* surface;
@property(nonatomic, weak) NSView* lastSurface;
@property(nonatomic, strong) RXAppPaneLayer* layer;
@property(nonatomic, strong) NSView* docView;
@property(nonatomic, weak) NSView* fullIn;
@property(nonatomic, strong) NSArray<CALayer*>* hiddenUnder;
@property(nonatomic, strong) RXAppPaneLayer* fullHost;
@property(nonatomic, copy) NSString* fullHole;
@property(readonly, nonatomic) NSView* anchor;
@property(readonly) NSView* superview;
@property(readonly) NSWindow* window;
@property(readonly) BOOL hiddenOrHasHiddenAncestor;
@property(readonly) NSRect bounds;
- (NSPoint)convertPoint:(NSPoint)win fromView:(id)none;
- (NSPoint)convertPoint:(NSPoint)p toView:(id)none;
- (NSRect)convertRect:(NSRect)r toView:(id)none;
- (NSRect)convertRect:(NSRect)win fromView:(id)none;
- (void)layout;
- (void)needsLayout;
- (NSView*)fileView;
- (void)placeIn:(NSView*)surface;
- (void)takeOut;
- (void)press:(NSEvent*)e;
- (void)send:(NSEvent*)e;
- (void)moved:(NSEvent*)e;
- (void)mouseMoved:(NSEvent*)e;
@property(strong) CALayerHost* host;
@property CGFloat fit;
@property NSPoint inset;
@property NSRect aligned;
@property(strong) NSMutableDictionary<NSNumber*, CALayerHost*>* popups;
@property bool layoutQueued;
@end

@interface RXPaneApp : NSObject {
   @public
    std::unique_ptr<rx::panes::Lane> lane;
}
@property(copy) NSString *block, *name;
@property(copy) NSArray<NSDictionary*>* keys;
@property int fd;
@property(strong) dispatch_queue_t writes;
@property(strong) dispatch_source_t reader;
@property(strong) NSMutableData* pending;
@property(strong) RXAppPane* view;
@property NSSize sentSize;
@property NSRect sentScreen;
@property double sentScale;
@property int focused, visible;
@property(copy) NSString *appearance, *cursor;
@property(strong) NSMutableSet<NSNumber*>* keysDown;
@property(strong) id doc;
@property NSRect layout;
@property bool capture;
@property bool live;
@property double quitAt;
@property bool opaque;
@property bool drawn;
@property(strong) CALayer* termMirror;
@property bool full;
@property(nonatomic, strong) id keysNote;
@property bool wantsFull;
@end

static CGFloat fit_host(CALayer* host, NSRect l, NSRect b, NSPoint* in);
static void watch_size(void);
void shape_layer(CALayer* l, NSString* spec, double ms, CGColorRef stroke, CGFloat width, bool* took_border,
                 const double* curve = nullptr);

namespace {

NSMutableDictionary<NSString*, RXPaneApp*>* g_apps;
std::atomic<bool> g_locked;
std::atomic<bool> g_ui_over{false};
bool g_held;
bool g_released;
NSTimer* g_timer;
NSArray<NSDictionary*>* g_keymap;

NSString* program_id(id pid) {
    if (![pid isKindOfClass:NSNumber.class] || [pid intValue] <= 0)
        return nil;
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, [pid intValue]};
    struct kinfo_proc info = {};
    size_t size = sizeof info;
    if (sysctl(mib, 4, &info, &size, nullptr, 0) != 0 || size == 0)
        return nil;
    return [NSString stringWithFormat:@"p%d-%ld", [pid intValue], (long)info.kp_proc.p_starttime.tv_sec];
}

NSString* socket_path(void) {
    NSString* dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/rexui"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"panes.sock"];
}

void send(RXPaneApp* app, NSDictionary* msg) {
    if (app.fd < 0)
        return;
    NSMutableData* d = [json_data(msg, 0) mutableCopy];
    [d appendBytes:"\n" length:1];
    int fd = app.fd;
    dispatch_async(app.writes, ^{
        const char* p = (const char*)d.bytes;
        size_t left = d.length;
        while (left) {
            ssize_t n = write(fd, p, left);
            if (n <= 0)
                return;
            p += n;
            left -= (size_t)n;
        }
    });
}

NSCursor* cursor_named(NSString* n) {
    NSDictionary<NSString*, NSCursor*>* all = @{
        @"iBeam": NSCursor.IBeamCursor,
        @"pointingHand": NSCursor.pointingHandCursor,
        @"crosshair": NSCursor.crosshairCursor,
        @"openHand": NSCursor.openHandCursor,
        @"closedHand": NSCursor.closedHandCursor,
        @"resizeLeftRight": NSCursor.resizeLeftRightCursor,
        @"resizeUpDown": NSCursor.resizeUpDownCursor,
        @"resizeLeft": NSCursor.resizeLeftCursor,
        @"resizeRight": NSCursor.resizeRightCursor,
        @"resizeUp": NSCursor.resizeUpCursor,
        @"resizeDown": NSCursor.resizeDownCursor,
        @"operationNotAllowed": NSCursor.operationNotAllowedCursor,
        @"iBeamVertical": NSCursor.IBeamCursorForVerticalLayout,
    };
    if ([n isEqual:@"none"]) {
        static NSCursor* blank = [[NSCursor alloc] initWithImage:[[NSImage alloc] initWithSize:NSMakeSize(8, 8)]
                                                         hotSpot:NSZeroPoint];
        return blank;
    }
    return all[n] ?: NSCursor.arrowCursor;
}

NSEventModifierFlags kMods =
    NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagShift;

NSDictionary* parse_chord(NSString* chord) {
    NSArray<NSString*>* parts = [chord.lowercaseString componentsSeparatedByString:@"+"];
    if (!parts.count)
        return nil;
    NSString* key = parts.lastObject;
    if (!key.length && parts.count >= 2)
        key = @"+";
    NSEventModifierFlags mods = 0;
    for (NSUInteger i = 0; i + 1 < parts.count; i++) {
        NSString* m = parts[i];
        if ([m isEqual:@"cmd"] || [m isEqual:@"super"])
            mods |= NSEventModifierFlagCommand;
        else if ([m isEqual:@"ctrl"] || [m isEqual:@"control"])
            mods |= NSEventModifierFlagControl;
        else if ([m isEqual:@"alt"] || [m isEqual:@"opt"] || [m isEqual:@"option"])
            mods |= NSEventModifierFlagOption;
        else if ([m isEqual:@"shift"])
            mods |= NSEventModifierFlagShift;
    }
    NSDictionary* names = @{
        @"enter": @"\r",
        @"return": @"\r",
        @"tab": @"\t",
        @"space": @" ",
        @"escape": @"\x1b",
        @"esc": @"\x1b",
        @"backspace": @"\x7f",
        @"left": @"",
        @"right": @"",
        @"up": @"",
        @"down": @""
    };
    return @{@"mods": @(mods), @"key": names[key] ?: key};
}

NSArray<NSDictionary*>* g_bindings = @[];

static void load_keymap_try(int attempt);
void load_keymap(void) {
    load_keymap_try(0);
}
static void load_keymap_try(int attempt) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSData* list = rex_cli(@[@"client", @"ls", @"--json"], nil);
        NSDictionary* clients = list ? [NSJSONSerialization JSONObjectWithData:list options:0 error:nil] : nil;
        NSString* client = nil;
        for (NSDictionary* c in clients[@"clients"]) {
            if (int_of(dict_of(dict_of(c)[@"principal"])[@"pid"]) != getpid())
                continue;
            NSDictionary* info = [c[@"info"] isKindOfClass:NSDictionary.class] ? c[@"info"] : nil;
            if ([info[@"name"] isEqual:@"rexui"])
                continue;
            if ([info[@"kind"] isEqual:@"app"]) {
                client = c[@"client_id"];
                break;
            }
            client = c[@"client_id"];
        }
        if (!client && attempt < 20) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                               load_keymap_try(attempt + 1);
                           });
            return;
        }
        if (!client)
            return rexui_log(@"panes: this app's client not found: Rex's keymap unknown (only cmd keys stay Rex's)");
        NSData* out = rex_cli(@[@"-C", client, @"api", @"call", @"client.keymap", @"{}"], nil);
        NSDictionary* km = out ? [NSJSONSerialization JSONObjectWithData:out options:0 error:nil] : nil;
        NSMutableArray* chords = [NSMutableArray array];
        for (NSDictionary* b in km[@"bindings"]) {
            for (NSString* k in b[@"keys"]) {
                if (NSDictionary* c = parse_chord(k))
                    [chords addObject:c];
            }
        }
        NSArray* bindings = [km[@"bindings"] isKindOfClass:NSArray.class] ? km[@"bindings"] : @[];
        dispatch_async(dispatch_get_main_queue(), ^{
            g_keymap = chords;
            g_bindings = bindings;
            ui_keys_changed();
        });
    });
}

NSArray<NSDictionary*>* g_rex_chords;
NSArray<NSDictionary*>* rex_chords(void) {
    if (g_rex_chords)
        return g_rex_chords;
    NSMutableArray* out = [NSMutableArray array];
    for (NSDictionary* b in (__bridge_transfer NSArray*)rex_keymap() ?: @[]) {
        if (![b isKindOfClass:NSDictionary.class] || [b[@"mode"] length])
            continue;
        for (NSString* k in [b[@"keys"] isKindOfClass:NSArray.class] ? b[@"keys"] : @[]) {
            if (![k isKindOfClass:NSString.class])
                continue;
            NSString* spec = k;
            if (NSRange r = [spec rangeOfString:@"[Digit"]; r.location != NSNotFound && spec.length == r.location + 8)
                spec = [[spec substringToIndex:r.location]
                    stringByAppendingString:[spec substringWithRange:NSMakeRange(r.location + 6, 1)]];
            if (NSDictionary* c = parse_chord(spec))
                [out addObject:c];
        }
    }
    return g_rex_chords = out;
}

bool rex_binds(NSEvent* e) {
    NSEventModifierFlags mods = e.modifierFlags & kMods;
    NSString* key = e.charactersIgnoringModifiers.lowercaseString;
    for (NSArray* list in @[g_keymap ?: @[], rex_chords()]) {
        for (NSDictionary* c in list) {
            if ([c[@"mods"] unsignedLongValue] == mods && [c[@"key"] isEqual:key])
                return true;
        }
    }
    return false;
}

bool app_owns(RXPaneApp* app, NSEvent* e) {
    NSEventModifierFlags mods = e.modifierFlags & kMods;
    NSString* key = e.charactersIgnoringModifiers.lowercaseString;
    for (NSDictionary* c in app.keys) {
        if ([c[@"mods"] unsignedLongValue] == mods && [c[@"key"] isEqual:key])
            return true;
    }
    return false;
}

bool stays_rex(RXPaneApp* app, NSEvent* e) {
    if (app_owns(app, e))
        return false;
    NSEventModifierFlags mods = e.modifierFlags & kMods;
    NSString* k = e.charactersIgnoringModifiers.lowercaseString;
    if (mods & NSEventModifierFlagCommand) {
        bool edit = [@[@"c", @"v", @"x", @"a", @"z"] containsObject:k]
            && (mods == NSEventModifierFlagCommand
                || (mods == (NSEventModifierFlagCommand | NSEventModifierFlagShift) && [k isEqual:@"z"]));
        if (!edit)
            return true;
    }
    return rex_binds(e);
}

Class surface_class(void) {
    static Class c = NSClassFromString(RXNS(RXN_165)) ?: NSClassFromString(RXNS(RXN_164));
    return c;
}

__weak NSView* g_last_surface;
BOOL (*orig_make_first)(NSWindow*, SEL, NSResponder*);
void page_takes_keys(NSWindow* w, NSView* surface);

__weak RXPaneApp* g_keys_app;
bool has_keys(RXPaneApp* app, NSResponder* fr);

static NSString* keys_desc(NSResponder* fr) {
    for (RXPaneApp* app in g_apps.allValues)
        if (app.live
            && (has_keys(app, fr)
                || (app.full && app.doc && [fr isKindOfClass:NSView.class] &&
                    [(NSView*)fr isDescendantOf:app.view.docView])))
            return
                [NSString stringWithFormat:@"%@ %@ (%@)", app.name,
                                           [app.block substringFromIndex:MIN((NSUInteger)14, app.block.length)],
                                           fr == app.view.surface ? @"its terminal view" : NSStringFromClass(fr.class)];
    return NSStringFromClass(fr.class) ?: @"nothing";
}

static double g_keys_trace;
void trace_keys(NSString* why) {
    NSWindow* w = ui_dock_window();
    g_keys_trace = CACurrentMediaTime() + 3;
    rexui_log_file([NSString stringWithFormat:@"keys: %@: %@", why, keys_desc(w.firstResponder)]);
    for (double t : {0.3, 1.0, 2.5})
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(t * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSWindow* w2 = ui_dock_window();
            rexui_log_file(
                [NSString stringWithFormat:@"keys: %.1f s after %@: %@", t, why, keys_desc(w2.firstResponder)]);
        });
}

BOOL hook_make_first(NSWindow* self, SEL sel, NSResponder* r) {
    BOOL ok = orig_make_first(self, sel, r);
    if (g_keys_trace && CACurrentMediaTime() < g_keys_trace) {
        NSArray<NSString*>* stack = NSThread.callStackSymbols;
        NSMutableArray* by = [NSMutableArray array];
        for (NSUInteger i = 1; i < stack.count && by.count < 5; i++) {
            NSString* f = [stack[i] substringFromIndex:MIN((NSUInteger)59, stack[i].length)];
            if ([f containsString:@"hook_make_first"])
                continue;
            [by addObject:[f componentsSeparatedByString:@" + "].firstObject];
        }
        rexui_log_file([NSString stringWithFormat:@"keys: -> %@%@ (by %@)", keys_desc(r), ok ? @"" : @" refused",
                                                  [by componentsJoinedByString:@" < "]]);
    }
    if (ok && r && r != self && g_apps.count) {
        RXPaneApp* in = nil;
        for (RXPaneApp* a in g_apps.allValues)
            if (has_keys(a, r))
                in = a;
        g_keys_app = in;
        if (in.doc && r != in.view.surface)
            in.keysNote = ui_keys_note(r);
    }
    if (ok && surface_class() && [r isKindOfClass:surface_class()]) {
        g_last_surface = (NSView*)r;
        page_takes_keys(self, (NSView*)r);
    }
    if (ok)
        ui_first_responder(self, r);
    return ok;
}

void keys_back(RXPaneApp* app, NSWindow* w, NSView* surface);
void page_takes_keys(NSWindow* w, NSView* surface) {
    if (!g_apps.count)
        return;
    RXPaneApp* app = nil;
    for (RXPaneApp* a in g_apps.allValues)
        if (a.doc && a.live && a.view.superview == surface)
            app = a;
    if (!app)
        return;
    __weak RXPaneApp* weak = app;
    __weak NSView* ws = surface;
    __weak NSWindow* ww = w;
    dispatch_async(dispatch_get_main_queue(), ^{
        RXPaneApp* a = weak;
        NSView* sv = ws;
        NSWindow* win = ww;
        if (!a.doc || !sv || win.firstResponder != sv)
            return;
        NSView* page = g_config.pane_web_focus ? web_pane_page(a.doc) : nil;
        if (page && (page.window != win || ![page isDescendantOf:sv]))
            page = nil;
        if (!a.keysNote && !page)
            return;
        static double since;
        static int times;
        double t = CACurrentMediaTime();
        if (t - since > 1)
            since = t, times = 0;
        if (++times > 5) {
            if (times == 6)
                rexui_log(@"panes: the file and Rex both want the keys; left with Rex for now");
            return;
        }
        if (a.keysNote && ui_keys_restore(a.keysNote, win))
            return;
        if (page)
            [win makeFirstResponder:page];
    });
}

NSView* surface_in(NSView* v, int depth) {
    if (depth > 24)
        return nil;
    if (surface_class() && [v isKindOfClass:surface_class()])
        return v;
    for (NSView* s in v.subviews) {
        if (NSView* f = surface_in(s, depth + 1))
            return f;
    }
    return nil;
}

static bool wraps_surface(NSView* hit, NSView* surface) {
    if (!hit || !surface || hit == surface || ![surface isDescendantOf:hit])
        return false;
    NSRect h = [hit convertRect:hit.bounds toView:nil], s = [surface convertRect:surface.bounds toView:nil];
    return NSContainsRect(NSInsetRect(s, -1, -1), h);
}

bool on_top_at(RXAppPane* v, NSPoint p) {
    NSWindow* w = v.window;
    NSView* frame = w.contentView.superview ?: w.contentView;
    if (!frame || !NSPointInRect([v convertPoint:p fromView:nil], v.bounds))
        return false;
    if (v.fullIn)
        return !g_ui_over;
    NSView *hit = [frame hitTest:p], *surface = v.superview;
    return hit == surface || [hit isDescendantOf:surface] || wraps_surface(hit, surface);
}

static NSView* doc_target(RXPaneApp* app, NSWindow* w, NSPoint p) {
    RXAppPane* v = app.view;
    NSView *surface = v.superview, *dv = v.docView;
    if (!app.doc || !app.live || !surface || !dv.superview || v.window != w || v.fullIn)
        return nil;
    if (!NSPointInRect([v convertPoint:p fromView:nil], v.bounds))
        return nil;
    NSView* frame = w.contentView.superview ?: w.contentView;
    if (!wraps_surface([frame hitTest:p], surface))
        return nil;
    return [dv hitTest:[dv.superview convertPoint:p fromView:nil]];
}

void deliver(NSView* v, NSEvent* e);
void report(RXPaneApp* app);

static NSView* doc_press(NSEvent* e, NSWindow* ew) {
    for (RXPaneApp* app in g_apps.allValues) {
        NSView* target = doc_target(app, ew, e.locationInWindow);
        if (!target)
            continue;
        NSView *surface = app.view.superview, *page = web_pane_page(app.doc);
        NSResponder* had = ew.firstResponder;
        bool on_page = page && (target == page || [target isDescendantOf:page]);
        bool in_file = [had isKindOfClass:NSView.class] && [(NSView*)had isDescendantOf:app.view.docView];
        if (had != surface && !in_file)
            [ew makeFirstResponder:surface];
        if (on_page && had != page)
            [ew makeFirstResponder:page];
        deliver(target, e);
        dispatch_async(dispatch_get_main_queue(), ^{
            for (RXPaneApp* other in g_apps.allValues)
                report(other);
        });
        return target;
    }
    return nil;
}

void deliver(NSView* v, NSEvent* e) {
    switch (e.type) {
    case NSEventTypeLeftMouseDown:
        return [v mouseDown:e];
    case NSEventTypeLeftMouseDragged:
        return [v mouseDragged:e];
    case NSEventTypeLeftMouseUp:
        return [v mouseUp:e];
    case NSEventTypeRightMouseDown:
        return [v rightMouseDown:e];
    case NSEventTypeRightMouseDragged:
        return [v rightMouseDragged:e];
    case NSEventTypeRightMouseUp:
        return [v rightMouseUp:e];
    case NSEventTypeOtherMouseDown:
        return [v otherMouseDown:e];
    case NSEventTypeOtherMouseDragged:
        return [v otherMouseDragged:e];
    case NSEventTypeOtherMouseUp:
        return [v otherMouseUp:e];
    case NSEventTypeScrollWheel:
        return [v scrollWheel:e];
    default:
        return;
    }
}

dispatch_queue_t g_raw_queue;
RXPaneApp* g_raw_app;
__weak RXPaneApp* g_raw_target;
std::atomic<bool> g_raw_seen;

void raw_attach(GCMouse* m) {
    if (!m.mouseInput)
        return;
    m.handlerQueue = g_raw_queue;
    double scale = g_config.pane_raw_mouse_scale;
    m.mouseInput.mouseMovedHandler = ^(GCMouseInput*, float dx, float dy) {
        RXPaneApp* app = g_raw_app;
        if (!app || (dx == 0 && dy == 0))
            return;
        if (!rx::sync::exchange(g_raw_seen, true, std::memory_order_relaxed)) {
            NSString* name = app.name;
            dispatch_async(dispatch_get_main_queue(), ^{
                rexui_log([NSString stringWithFormat:@"panes: %@ gets the raw mouse", name]);
            });
        }
        if (rx::panes::Lane* l = app->lane.get())
            l->move(dx * scale, -dy * scale);
        else
            send(app, @{@"move": @[@(dx * scale), @(-dy * scale)]});
    };
}

void raw_capture(RXPaneApp* app) {
    if (!g_config.pane_raw_mouse)
        app = nil;
    if (app == g_raw_target)
        return;
    g_raw_target = app;
    g_raw_seen = false;
    if (app && !g_raw_queue) {
        g_raw_queue = dispatch_queue_create("rexui.panes.raw", DISPATCH_QUEUE_SERIAL);
        [NSNotificationCenter.defaultCenter addObserverForName:GCMouseDidConnectNotification
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification* n) {
                                                        if (g_raw_target && [n.object isKindOfClass:GCMouse.class])
                                                            raw_attach(n.object);
                                                    }];
    }
    if (!g_raw_queue)
        return;
    for (GCMouse* m in GCMouse.mice) {
        if (app)
            raw_attach(m);
        else
            m.mouseInput.mouseMovedHandler = nil;
    }
    dispatch_async(g_raw_queue, ^{
        g_raw_app = app;
    });
}

bool raw_moves(RXPaneApp* app) {
    return g_locked && app && app == g_raw_target && g_raw_seen;
}

void capture_cursor(void) {
    bool want = false;
    RXPaneApp* target = nil;
    for (RXPaneApp* app in g_apps.allValues) {
        RXAppPane* v = app.view;
        NSWindow* w = v.window;
        if (g_held || g_released || !app.capture || app.focused != 1 || !w.isKeyWindow || !v.superview)
            continue;
        if (on_top_at(v, w.mouseLocationOutsideOfEventStream))
            want = true, target = app;
    }
    if (want == g_locked)
        return;
    g_locked = want;
    CGAssociateMouseAndMouseCursorPosition(!want);
    raw_capture(want ? target : nil);
    rexui_log(want ? @"panes: cursor captured in a pane" : @"panes: cursor let go");
}

void warp(RXPaneApp* app, NSPoint at) {
    RXAppPane* v = app.view;
    NSWindow* w = v.window;
    if (g_held || app.focused != 1 || !w.isKeyWindow || !v.superview)
        return;
    CGFloat s = v.fit > 0 ? v.fit : 1;
    NSPoint p = NSMakePoint(v.inset.x + at.x * s, v.bounds.size.height - (v.inset.y + at.y * s));
    if (!NSPointInRect(p, NSInsetRect(v.bounds, -1, -1)))
        return;
    NSPoint screen = [w convertPointToScreen:[v convertPoint:p toView:nil]];
    CGFloat top = CGDisplayBounds(CGMainDisplayID()).size.height;
    CGWarpMouseCursorPosition(CGPointMake(screen.x, top - screen.y));
    if (!g_locked)
        CGAssociateMouseAndMouseCursorPosition(true);
}

NSRect pixel_bounds(RXAppPane* v) {
    if (!v.window)
        return v.bounds;
    CGFloat s = v.window.backingScaleFactor ?: 1;
    NSRect w = [v convertRect:v.bounds toView:nil];
    NSRect a = NSMakeRect(round(NSMinX(w) * s) / s, round(NSMinY(w) * s) / s, round(w.size.width * s) / s,
                          round(w.size.height * s) / s);
    return [v convertRect:a fromView:nil];
}

void direct_geometry(RXPaneApp* app);

void report(RXPaneApp* app) {
    RXAppPane* v = app.view;
    NSWindow* w = v.window;
    int visible = w && v.superview && !v.hiddenOrHasHiddenAncestor;
    if (visible != app.visible) {
        app.visible = visible;
        send(app, @{@"visible": @(visible != 0)});
    }
    if (w && !NSEqualRects(pixel_bounds(v), v.aligned))
        [v needsLayout];
    if (!w || !app.live)
        return;
    NSSize size = v.bounds.size;
    double scale = w.backingScaleFactor;
    if (!NSEqualSizes(size, app.sentSize) || scale != app.sentScale) {
        app.sentSize = size;
        app.sentScale = scale;
        send(app, @{@"size": @[@(size.width), @(size.height)], @"scale": @(scale)});
    }
    NSRect screen = [w convertRectToScreen:[v convertRect:v.bounds toView:nil]];
    if (!NSEqualRects(screen, app.sentScreen)) {
        app.sentScreen = screen;
        send(app, @{@"screen": @[@(screen.origin.x), @(screen.origin.y), @(screen.size.width), @(screen.size.height)]});
    }
    if (app.full)
        direct_geometry(app);
    int focused = w.isKeyWindow && (app.full || w.firstResponder == v.superview);
    if (focused != app.focused) {
        app.focused = focused;
        send(app, @{@"focus": @(focused != 0)});
        capture_cursor();
    }
    NSString* appearance =
        [w.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
    NSString* a = [appearance isEqual:NSAppearanceNameAqua] ? @"light" : @"dark";
    if (![a isEqual:app.appearance]) {
        app.appearance = a;
        send(app, @{@"appearance": a});
    }
}

static NSView* g_season;
static bool seasoned(NSView* doc, id d) {
    NSView* root = ui_pane_view(d);
    return !root || root.layer.superlayer == doc.layer;
}
static void season(NSView* doc, id d, NSSize size) {
    NSView* in = ui_full_root(ui_dock_window());
    if (!in || !doc)
        return;
    if (!g_season || g_season.superview != in) {
        [g_season removeFromSuperview];
        g_season = [[NSView alloc] initWithFrame:NSMakeRect(-40000, -40000, 20000, 20000)];
        g_season.wantsLayer = YES;
        [in addSubview:g_season positioned:NSWindowBelow relativeTo:nil];
    }
    if (doc.superview != g_season) {
        [doc removeFromSuperview];
        [g_season addSubview:doc];
    }
    if (!NSEqualSizes(doc.frame.size, size) || !NSEqualPoints(doc.frame.origin, NSZeroPoint))
        doc.frame = NSMakeRect(0, 0, size.width, size.height);
    ui_pane_layout(d, doc.bounds);
}

void attach_term(RXPaneApp* app, NSView* live) {
    CALayer* clip = term_block_clip(app.block);
    RXAppPane* v = app.view;
    NSView* doc = app.doc && clip && !live && !app.full ? [v fileView] : v.docView;
    if (app.doc && clip && !live && !app.full && !seasoned(doc, app.doc))
        return season(doc, app.doc, clip.bounds.size);
    if (app.doc && app.full) {
        [app.termMirror removeFromSuperlayer];
        app.termMirror = nil;
        return;
    }
    if (!clip) {
        [app.termMirror removeFromSuperlayer];
        app.termMirror = nil;
        if (doc && !doc.superview && doc.layer.superlayer)
            [doc.layer removeFromSuperlayer];
        return;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (app.doc && !live) {
        [app.termMirror removeFromSuperlayer];
        app.termMirror = nil;
        if (doc.superview)
            [doc removeFromSuperview];
        if (doc && doc.layer.superlayer != clip)
            [clip addSublayer:doc.layer];
        if (doc && !NSEqualSizes(doc.frame.size, clip.bounds.size)) {
            [doc setFrameSize:clip.bounds.size];
            doc.layer.frame = clip.bounds;
            ui_pane_layout(app.doc, doc.bounds);
        }
        web_pane_pictures(app.doc, true, term_block_drawn(app.block));
    } else {
        if (app.doc)
            web_pane_pictures(app.doc, false, false);
        bool portal = app.doc != nil;
        if (app.termMirror && portal != [app.termMirror isKindOfClass:CAPortalLayer.class]) {
            [app.termMirror removeFromSuperlayer];
            app.termMirror = nil;
        }
        if (!app.termMirror) {
            if (portal) {
                CAPortalLayer* p = [CAPortalLayer layer];
                p.sourceLayer = doc.layer;
                for (NSString* k in @[@"matchesPosition", @"matchesTransform", @"matchesOpacity"])
                    if ([p respondsToSelector:NSSelectorFromString(k)])
                        [p setValue:@NO forKey:k];
                app.termMirror = p;
            } else {
                app.termMirror = [CALayerHost layer];
            }
            app.termMirror.anchorPoint = CGPointZero;
        }
        if (app.termMirror.superlayer != clip)
            [clip addSublayer:app.termMirror];
        if (CALayerHost* h = (CALayerHost*)app.termMirror; !portal && h.contextId != v.host.contextId)
            h.contextId = v.host.contextId;
        NSPoint in;
        fit_host(app.termMirror, portal ? NSZeroRect : app.layout, NSRectFromCGRect(clip.bounds), &in);
    }
    [CATransaction commit];
}

void set_full(RXPaneApp* app, bool on);

NSResponder* first_responder(NSWindow* w);
void note_file_keys(RXPaneApp* app, NSWindow* w);
void keys_back(RXPaneApp* app, NSWindow* w, NSView* surface);
static bool g_slide_shown;

void attach_all(void) {
    if (!g_apps.count)
        return;
    NSDictionary<NSString*, NSView*>* panes = nil;
    NSView* content = nil;
    for (NSWindow* w in NSApp.windows) {
        NSView* chrome = is_rex_window(w) && w.isVisible ? chrome_of(w) : nil;
        if (!(content = chrome ? chrome_content(chrome) : nil))
            continue;
        void* raw = rex_panes((__bridge const void*)content);
        panes = raw ? (__bridge_transfer NSDictionary*)raw : nil;
        break;
    }
    RXPaneApp* keys_app = g_keys_app;
    for (RXPaneApp* app in g_apps.allValues) {
        NSView* pane = panes[app.block];
        if (!pane && content) {
            const void *p = nullptr, *layer = nullptr;
            if (rex_floating_pane((__bridge const void*)content, app.block.UTF8String, &p, &layer))
                pane = (__bridge NSView*)p;
        }
        NSView* live = pane ? surface_in(pane, 0) : nil;
        if (live && app.doc && !app.view.surface && rex_slide_busy() && !g_slide_shown)
            live = nil;
        attach_term(app, live);
        NSView* surface = live;
        RXAppPane* v = app.view;
        app.live = live != nil || app.full;
        if (app.doc && ui_pane_view(app.doc).superview != v.docView)
            [v needsLayout];
        if (surface && v.surface != surface) {
            NSWindow* w = surface.window;
            NSResponder* fr = w.firstResponder;
            bool keys = w && (has_keys(app, fr) || ((!fr || fr == w) && keys_app == app));
            if (w)
                note_file_keys(app, w);
            [v placeIn:surface];
            if (keys)
                keys_back(app, w, surface);
            rexui_log([NSString stringWithFormat:@"panes: %@ shown in %@", app.name, app.block]);
            if (app.doc && surface.window.firstResponder == surface)
                page_takes_keys(surface.window, surface);
        } else if (!surface && v.surface) {
            [v takeOut];
        }
        if (surface && app.wantsFull && !app.full && !app.doc)
            set_full(app, true);
        report(app);
    }
}

void schedule_attach(void) {
    static bool queued;
    if (queued || !g_apps.count)
        return;
    queued = true;
    dispatch_async(dispatch_get_main_queue(), ^{
        queued = false;
        attach_all();
    });
}

void update_timer(void) {
    if (g_apps.count && !g_timer) {
        g_timer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                  repeats:YES
                                                    block:^(NSTimer*) {
                                                        attach_all();
                                                    }];
    } else if (!g_apps.count && g_timer) {
        [g_timer invalidate];
        g_timer = nil;
    }
}

bool has_keys(RXPaneApp* app, NSResponder* fr);

void drop(RXPaneApp* app) {
    if (app.reader)
        dispatch_source_cancel(app.reader);
    app.reader = nil;
    NSView* surface = app.view.surface ?: app.view.lastSurface;
    NSWindow* w = surface.window;
    NSResponder* had = w.firstResponder;
    bool keys = w && has_keys(app, had);
    if (app.full)
        set_full(app, false);
    [app.view takeOut];
    [app.termMirror removeFromSuperlayer];
    app.termMirror = nil;
    [app.view.docView.layer removeFromSuperlayer];
    if (app.doc)
        ui_pane_close(app.doc);
    app.doc = nil;
    if (keys && surface.window == w)
        [w makeFirstResponder:surface];
    app.capture = false;
    capture_cursor();
    if (g_apps[app.block] == app) {
        [g_apps removeObjectForKey:app.block];
        rexui_log([NSString stringWithFormat:@"panes: %@ left %@", app.name, app.block]);
    }
    update_timer();
}

void show_popups(RXAppPane* v, NSArray* list);

void open_lane(RXPaneApp* app) {
    int seg = -1, bell = -1;
    auto l = rx::panes::Lane::make(&seg, &bell);
    if (!l)
        return rexui_log(
            [NSString stringWithFormat:@"panes: no input lane for %@ (%s): JSON lines", app.name, strerror(errno)]);
    app->lane = std::move(l);
    int fd = app.fd;
    NSString* name = app.name;
    dispatch_async(app.writes, ^{
        if (rx::panes::send_lane(fd, seg, bell))
            dispatch_async(dispatch_get_main_queue(), ^{
                rexui_log([NSString stringWithFormat:@"panes: %@ takes input by its lane", name]);
            });
    });
}

void handle(RXPaneApp* app, NSDictionary* m) {
    if (m[@"hello"]) {
        NSString* block = m[@"block"];
        if (![block isKindOfClass:NSString.class] || ![block hasPrefix:@"block:"])
            return;
        if (RXPaneApp* old = g_apps[block]; old && old != app) {
            if (old.fd >= 0) {
                static const char quit[] = "{\"quit\":true}\n";
                int ofd = old.fd;
                dispatch_sync(old.writes, ^{
                    (void)write(ofd, quit, sizeof quit - 1);
                });
            }
            drop(old);
        }
        app.block = block;
        app.name = [m[@"name"] isKindOfClass:NSString.class] ? m[@"name"] : @"app";
        app.drawn = [m[@"drawn"] isKindOfClass:NSNumber.class] ? [m[@"drawn"] boolValue] : true;
        app.opaque = [m[@"opaque"] isKindOfClass:NSNumber.class] && [m[@"opaque"] boolValue];
        app.wantsFull = [m[@"fullscreen"] isKindOfClass:NSNumber.class] && [m[@"fullscreen"] boolValue];
        NSMutableArray* keys = [NSMutableArray array];
        for (id k in [m[@"keys"] isKindOfClass:NSArray.class] ? m[@"keys"] : @[]) {
            if (NSDictionary* c = [k isKindOfClass:NSString.class] ? parse_chord(k) : nil)
                [keys addObject:c];
        }
        app.keys = keys;
        g_apps[block] = app;
        if ([m[@"lane"] isKindOfClass:NSNumber.class] && [m[@"lane"] intValue] == REXPANE_LANE_VERSION && !app->lane
            && g_config.pane_lane)
            open_lane(app);
        load_keymap();
        NSString* rui = [m[@"rui"] isKindOfClass:NSString.class] ? m[@"rui"] : nil;
        NSMutableArray<NSString*>* args = [NSMutableArray array];
        if (NSString* web = m[@"web"]; [web isKindOfClass:NSString.class] && !rui) {
            rui = ui_web_pane_file();
            if (web.length)
                [args addObject:web];
        }
        for (id a in [m[@"args"] isKindOfClass:NSArray.class] ? m[@"args"] : @[]) {
            if ([a isKindOfClass:NSString.class])
                [args addObject:a];
        }
        if (rui && !app.doc) {
            if (![NSFileManager.defaultManager fileExistsAtPath:rui]) {
                rexui_log([NSString stringWithFormat:@"panes: %@: no such file", rui]);
            } else {
                app.doc = ui_pane_open(rui, block, args, program_id(m[@"pid"]));
                app.name = rui.lastPathComponent;
            }
        }
        rexui_log([NSString
            stringWithFormat:@"panes: %@ (pid %@) for %@, %@", app.name, m[@"pid"], block,
                             app.doc ? @"a .rui file" : [NSString stringWithFormat:@"context %@", m[@"context"]]]);
        attach_all();
        update_timer();
    }
    if (!app.block)
        return;
    if (NSNumber* c = m[@"context"]; [c isKindOfClass:NSNumber.class]) {
        if (!m[@"hello"] && c.unsignedIntValue != app.view.host.contextId)
            rexui_log([NSString
                stringWithFormat:@"panes: %@'s context now %@ (was %u)", app.name, c, app.view.host.contextId]);
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        app.view.host.contextId = c.unsignedIntValue;
        [CATransaction commit];
        attach_all();
    }
    if (NSNumber* d = m[@"drawn"]; [d isKindOfClass:NSNumber.class] && d.boolValue && !app.drawn) {
        app.drawn = true;
        pane_styles_wake();
        rexui_log([NSString stringWithFormat:@"panes: %@ has drawn in %@", app.name, app.block]);
    }
    if (NSNumber* c = m[@"capture"]; [c isKindOfClass:NSNumber.class]) {
        if (app.capture != c.boolValue)
            rexui_log([NSString stringWithFormat:@"panes: %@ %@ the cursor (focused %d)", app.name,
                                                 c.boolValue ? @"captures" : @"lets go of", app.focused]);
        app.capture = c.boolValue;
        capture_cursor();
    }
    if (NSArray* p = m[@"warp"]; [p isKindOfClass:NSArray.class] && p.count == 2)
        warp(app, NSMakePoint(num_of(p[0]), num_of(p[1])));
    if (NSArray* l = m[@"layout"]; [l isKindOfClass:NSArray.class] && l.count == 4) {
        app.layout = NSMakeRect(num_of(l[0]), num_of(l[1]), num_of(l[2]), num_of(l[3]));
        [app.view needsLayout];
    }
    if (NSNumber* f = m[@"fullscreen"]; !m[@"hello"] && [f isKindOfClass:NSNumber.class] && !app.doc) {
        app.wantsFull = f.boolValue;
        if (f.boolValue != app.full && (app.view.surface || !f.boolValue))
            set_full(app, f.boolValue);
    }
    if (NSArray* p = m[@"popups"]; [p isKindOfClass:NSArray.class])
        show_popups(app.view, p);
    if (NSString* c = m[@"cursor"]; [c isKindOfClass:NSString.class]) {
        if (![c isEqual:app.cursor] && ![c isEqual:@"none"] && ![c isEqual:@"arrow"])
            rexui_log_file([NSString stringWithFormat:@"panes: %@ asks for the %@ cursor", app.name, c]);
        app.cursor = c;
        RXAppPane* v = app.view;
        if (v.window && on_top_at(v, v.window.mouseLocationOutsideOfEventStream))
            [cursor_named(c) set];
    }
}

void show_popups(RXAppPane* v, NSArray* list) {
    if (!v)
        return;
    if (!v.popups)
        v.popups = [NSMutableDictionary dictionary];
    NSMutableSet* seen = [NSMutableSet set];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSDictionary* p in list) {
        if (![p isKindOfClass:NSDictionary.class])
            continue;
        NSNumber* c = p[@"context"];
        NSArray* f = p[@"frame"];
        if (![c isKindOfClass:NSNumber.class] || !c.unsignedIntValue || ![f isKindOfClass:NSArray.class]
            || f.count != 4)
            continue;
        [seen addObject:c];
        CALayerHost* h = v.popups[c];
        if (!h) {
            h = [CALayerHost layer];
            h.anchorPoint = CGPointZero;
            h.contextId = c.unsignedIntValue;
            v.popups[c] = h;
        }
        h.frame = CGRectMake(num_of(f[0]), num_of(f[1]), num_of(f[2]), num_of(f[3]));
        [h removeFromSuperlayer];
        [v.host addSublayer:h];
    }
    for (NSNumber* c in v.popups.allKeys) {
        if ([seen containsObject:c])
            continue;
        [v.popups[c] removeFromSuperlayer];
        [v.popups removeObjectForKey:c];
    }
    [CATransaction commit];
}

void accept_one(int listener) {
    int fd = accept(listener, nullptr, nullptr);
    if (fd < 0)
        return;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    RXPaneApp* app = [RXPaneApp new];
    app.fd = fd;
    app.focused = app.visible = -1;
    app.pending = [NSMutableData data];
    app.keysDown = [NSMutableSet set];
    app.writes = dispatch_queue_create("rexui.panes.write", DISPATCH_QUEUE_SERIAL);
    RXAppPane* v = [RXAppPane new];
    v.app = app;
    app.view = v;
    dispatch_source_t r =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, dispatch_get_main_queue());
    __weak RXPaneApp* weak = app;
    __block RXPaneApp* keep = app;
    dispatch_source_set_event_handler(r, ^{
        RXPaneApp* a = weak;
        char buf[16384];
        ssize_t n = read(fd, buf, sizeof buf);
        if (n <= 0 || !a) {
            if (a)
                drop(a);
            dispatch_source_cancel(r);
            return;
        }
        [a.pending appendBytes:buf length:(NSUInteger)n];
        while (true) {
            const char* bytes = (const char*)a.pending.bytes;
            const char* nl = (const char*)memchr(bytes, '\n', a.pending.length);
            if (!nl)
                break;
            NSData* line = [a.pending subdataWithRange:NSMakeRange(0, (NSUInteger)(nl - bytes))];
            [a.pending replaceBytesInRange:NSMakeRange(0, (NSUInteger)(nl - bytes) + 1) withBytes:nullptr length:0];
            id m = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
            if ([m isKindOfClass:NSDictionary.class])
                handle(a, m);
        }
        if (a.pending.length > (1 << 20)) {
            drop(a);
            dispatch_source_cancel(r);
        }
    });
    dispatch_source_set_cancel_handler(r, ^{
        close(fd);
        keep = nil;
    });
    app.reader = r;
    dispatch_resume(r);
}

void listen_for_apps(void) {
    NSString* path = socket_path();
    struct sockaddr_un addr = {};
    addr.sun_family = AF_UNIX;
    if (path.length >= sizeof addr.sun_path)
        return rexui_log(@"panes: socket path too long: off");
    strlcpy(addr.sun_path, path.fileSystemRepresentation, sizeof addr.sun_path);
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    unlink(addr.sun_path);
    if (s < 0 || bind(s, (struct sockaddr*)&addr, sizeof addr) != 0 || listen(s, 16) != 0) {
        rexui_log([NSString stringWithFormat:@"panes: can't listen on %@ (%s): off", path, strerror(errno)]);
        if (s >= 0)
            close(s);
        return;
    }
    chmod(addr.sun_path, 0600);
    dispatch_source_t src =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)s, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(src, ^{
        accept_one(s);
    });
    dispatch_resume(src);
    [[maybe_unused]] static dispatch_source_t keep;
    keep = src;
}

void (*orig_surface_did_move)(id, SEL);
void attach_all(void);

void hook_surface_did_move(NSView* self, SEL sel) {
    orig_surface_did_move(self, sel);
    if (self.window)
        for (RXPaneApp* app in g_apps.allValues)
            if (app.doc && !app.view.surface && app.view.lastSurface == self) {
                attach_all();
                break;
            }
    schedule_attach();
}

double g_tap_double_click = 0.5;
std::atomic<rx::panes::Lane*> g_direct{nullptr};
void forward(RXPaneApp* app, NSEvent* e, NSPoint at) {
    if (rx::panes::Lane* l = app->lane.get(); l && !l->broken() && g_direct.load(std::memory_order_acquire) != l) {
        NSEventType t = e.type;
        bool press = t == NSEventTypeLeftMouseDown || t == NSEventTypeLeftMouseUp || t == NSEventTypeRightMouseDown
            || t == NSEventTypeRightMouseUp || t == NSEventTypeOtherMouseDown || t == NSEventTypeOtherMouseUp;
        bool move = t == NSEventTypeMouseMoved || t == NSEventTypeLeftMouseDragged || t == NSEventTypeRightMouseDragged
            || t == NSEventTypeOtherMouseDragged;
        if (press || move) {
            rexpane_mouse m{};
            m.type = (uint32_t)t;
            m.button = (uint32_t)e.buttonNumber;
            m.flags = (uint64_t)e.modifierFlags;
            m.x = at.x, m.y = at.y;
            m.dx = e.deltaX, m.dy = e.deltaY;
            m.clicks = press ? (int32_t)ui_clicks(e) : 0;
            m.number = (uint32_t)e.eventNumber;
            m.sent = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            if (l->mouse(m))
                return;
        } else if (CGEventRef cg = e.CGEvent) {
            if (CFDataRef data = CGEventCreateData(kCFAllocatorDefault, cg)) {
                bool put = l->event(at.x, at.y, CFDataGetBytePtr(data), (uint32_t)CFDataGetLength(data));
                CFRelease(data);
                if (put)
                    return;
            }
        }
    }
    CGEventRef cg = e.CGEvent;
    if (!cg)
        return;
    CFDataRef data = CGEventCreateData(kCFAllocatorDefault, cg);
    if (!data)
        return;
    send(app, @{@"event": [(__bridge NSData*)data base64EncodedStringWithOptions:0], @"x": @(at.x), @"y": @(at.y)});
    CFRelease(data);
}

RXPaneApp* __weak g_full;

struct DirectGeometry {
    double x = 0, top = 0, inset_x = 0, inset_y = 0, fit = 1, width = 0, height = 0;
};
DirectGeometry g_geo[2];
std::atomic<int> g_geo_at{0};
std::atomic<bool> g_direct_key{false};
CFMachPortRef g_tap;
CFRunLoopRef g_tap_loop;
int g_tap_buttons;
double g_tap_told;

void direct_geometry(RXPaneApp* app) {
    RXAppPane* v = app.view;
    NSWindow* w = v.window;
    if (!w)
        return;
    NSRect f = [w convertRectToScreen:[v convertRect:v.bounds toView:nil]];
    int next = !g_geo_at.load(std::memory_order_relaxed);
    g_geo[next] =
        DirectGeometry{f.origin.x, NSMaxY(f), v.inset.x, v.inset.y, v.fit > 0 ? v.fit : 1, f.size.width, f.size.height};
    g_geo_at.store(next, std::memory_order_release);
    g_direct_key.store(w.isKeyWindow && !g_ui_over.load(std::memory_order_relaxed), std::memory_order_release);
}

bool tap_put_event(rx::panes::Lane* l, double x, double y, CGEventRef e) {
    CFDataRef data = CGEventCreateData(kCFAllocatorDefault, e);
    if (!data)
        return false;
    bool put = l->event(x, y, CFDataGetBytePtr(data), (uint32_t)CFDataGetLength(data));
    CFRelease(data);
    return put;
}

void lane_key(CGEventRef e) {
    CFRunLoopPerformBlock(g_tap_loop, kCFRunLoopCommonModes, ^{
        if (rx::panes::Lane* l = g_direct.load(std::memory_order_acquire))
            tap_put_event(l, 0, 0, e);
        CFRelease(e);
    });
    CFRunLoopWakeUp(g_tap_loop);
}

void tap_tell_main(void) {
    double now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9;
    if (now - g_tap_told < 0.1)
        return;
    g_tap_told = now;
    dispatch_async(dispatch_get_main_queue(), ^{
        RXPaneApp* app = g_full;
        if (!app)
            return;
        if (app.cursor)
            [cursor_named(app.cursor) set];
        if (app.capture && !g_locked)
            capture_cursor();
    });
}

CGEventRef tapped(CGEventTapProxy, CGEventType t, CGEventRef e, void*) {
    if (t == kCGEventTapDisabledByTimeout || t == kCGEventTapDisabledByUserInput) {
        if (g_tap)
            CGEventTapEnable(g_tap, true);
        return e;
    }
    rx::panes::Lane* l = g_direct.load(std::memory_order_acquire);
    if (!l || l->broken() || !g_direct_key.load(std::memory_order_acquire))
        return e;
    const DirectGeometry g = g_geo[g_geo_at.load(std::memory_order_acquire)];
    CGPoint at = CGEventGetUnflippedLocation(e);
    double wx = at.x - g.x, wy = g.top - at.y;
    bool press = t == kCGEventLeftMouseDown || t == kCGEventRightMouseDown || t == kCGEventOtherMouseDown;
    bool release = t == kCGEventLeftMouseUp || t == kCGEventRightMouseUp || t == kCGEventOtherMouseUp;
    bool inside = wx >= 0 && wy >= 0 && wx < g.width && wy < g.height;
    if (!inside && !g_tap_buttons && !release)
        return e;
    double x = (wx - g.inset_x) / g.fit, y = (wy - g.inset_y) / g.fit;
    if (t == kCGEventScrollWheel) {
        tap_put_event(l, x, y, e);
        return e;
    }
    if (press)
        g_tap_buttons++;
    if (release && g_tap_buttons)
        g_tap_buttons--;
    bool drag = t == kCGEventLeftMouseDragged || t == kCGEventRightMouseDragged || t == kCGEventOtherMouseDragged;
    if ((t == kCGEventMouseMoved || drag) && g_locked.load(std::memory_order_relaxed)
        && g_raw_seen.load(std::memory_order_relaxed))
        return e;
    if (press || t == kCGEventMouseMoved)
        tap_tell_main();
    rexpane_mouse m{};
    m.type = (uint32_t)t;
    m.button = (uint32_t)CGEventGetIntegerValueField(e, kCGMouseEventButtonNumber);
    m.flags = (uint64_t)CGEventGetFlags(e);
    m.x = x, m.y = y;
    m.dx = (double)CGEventGetIntegerValueField(e, kCGMouseEventDeltaX),
    m.dy = (double)CGEventGetIntegerValueField(e, kCGMouseEventDeltaY);
    static ClickCounter clicks;
    if (press) {
        CGPoint g0 = CGEventGetLocation(e);
        clicks.press((int)m.button, (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9, g0.x, g0.y,
                     g_tap_double_click);
    }
    m.clicks = press || release ? (int32_t)(press ? clicks.count : clicks.release((int)m.button)) : 0;
    m.number = (uint32_t)CGEventGetIntegerValueField(e, kCGMouseEventNumber);
    m.sent = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    l->mouse(m);
    return e;
}

constexpr std::array<int16_t, 232> make_usage_vk() {
    std::array<int16_t, 232> t{};
    for (auto& v : t)
        v = -1;
    constexpr int16_t letters[26] = {0,  11, 8,  2,  14, 3, 5,  4,  34, 38, 40, 37, 46,
                                     45, 31, 35, 12, 15, 1, 17, 32, 9,  13, 7,  16, 6};
    for (int i = 0; i < 26; i++)
        t[size_t(4 + i)] = letters[i];
    constexpr int16_t rest[][2] = {
        {30, 18},   {31, 19},   {32, 20},  {33, 21},  {34, 23},  {35, 22},   {36, 26},  {37, 28},   {38, 25},
        {39, 29},   {40, 36},   {41, 53},  {42, 51},  {43, 48},  {44, 49},   {45, 27},  {46, 24},   {47, 33},
        {48, 30},   {49, 42},   {50, 42},  {51, 41},  {52, 39},  {53, 50},   {54, 43},  {55, 47},   {56, 44},
        {57, 57},   {58, 122},  {59, 120}, {60, 99},  {61, 118}, {62, 96},   {63, 97},  {64, 98},   {65, 100},
        {66, 101},  {67, 109},  {68, 103}, {69, 111}, {73, 114}, {74, 115},  {75, 116}, {76, 117},  {77, 119},
        {78, 121},  {79, 124},  {80, 123}, {81, 125}, {82, 126}, {83, 71},   {84, 75},  {85, 67},   {86, 78},
        {87, 69},   {88, 76},   {89, 83},  {90, 84},  {91, 85},  {92, 86},   {93, 87},  {94, 88},   {95, 89},
        {96, 91},   {97, 92},   {98, 82},  {99, 65},  {100, 10}, {101, 110}, {103, 81}, {104, 105}, {105, 107},
        {106, 113}, {107, 106}, {108, 64}, {109, 79}, {110, 80}, {111, 90},  {224, 59}, {225, 56},  {226, 58},
        {227, 55},  {228, 62},  {229, 60}, {230, 61}, {231, 54},
    };
    for (auto& r : rest)
        t[size_t(r[0])] = r[1];
    return t;
}
constexpr auto kUsageVk = make_usage_vk();

bool g_key_cmd_held[128];
bool g_key_down[128];
std::atomic<uint8_t> g_key_heard[128];
std::atomic<bool> g_keys_on{false};
dispatch_queue_t g_keys_queue;
GCKeyboard* g_keys_from;
std::atomic<uint64_t> g_keys_sent, g_keys_late;

CGEventFlags modifier_bit(int vk) {
    switch (vk) {
    case 56:
    case 60:
        return kCGEventFlagMaskShift;
    case 59:
    case 62:
        return kCGEventFlagMaskControl;
    case 58:
    case 61:
        return kCGEventFlagMaskAlternate;
    case 55:
    case 54:
        return kCGEventFlagMaskCommand;
    default:
        return 0;
    }
}

void heard_key(CFIndex usage, BOOL pressed) {
    int vk = usage >= 0 && usage < (CFIndex)kUsageVk.size() ? kUsageVk[size_t(usage)] : -1;
    if (vk < 0 || vk >= 128 || !g_direct.load(std::memory_order_acquire)
        || !g_direct_key.load(std::memory_order_acquire))
        return;
    if (vk == 57 && !pressed)
        return;
    CGEventFlags flags = CGEventSourceFlagsState(kCGEventSourceStateHIDSystemState)
        & (kCGEventFlagMaskShift | kCGEventFlagMaskControl | kCGEventFlagMaskAlternate | kCGEventFlagMaskCommand
           | kCGEventFlagMaskAlphaShift);
    CGEventFlags bit = modifier_bit(vk);
    CGEventRef e = nullptr;
    if (bit || vk == 57) {
        if (bit)
            flags = pressed ? flags | bit : flags & ~bit;
        e = CGEventCreate(nullptr);
        if (!e)
            return;
        CGEventSetType(e, kCGEventFlagsChanged);
        CGEventSetIntegerValueField(e, kCGKeyboardEventKeycode, vk);
    } else {
        if (pressed && (flags & kCGEventFlagMaskCommand)) {
            g_key_cmd_held[vk] = true;
            return;
        }
        if (!pressed && g_key_cmd_held[vk]) {
            g_key_cmd_held[vk] = false;
            return;
        }
        if (pressed)
            g_key_heard[vk].store(1, std::memory_order_release);
        g_key_down[vk] = pressed;
        e = CGEventCreateKeyboardEvent(nullptr, CGKeyCode(vk), pressed);
        if (!e)
            return;
    }
    CGEventSetFlags(e, flags);
    rx::sync::fetch_add(g_keys_sent, decltype(g_keys_sent.load()){1}, std::memory_order_relaxed);
    lane_key(e);
}

void keys_release(void) {
    if (!g_keys_queue)
        return;
    dispatch_async(g_keys_queue, ^{
        for (int vk = 0; vk < 128; vk++) {
            if (!g_key_down[vk])
                continue;
            g_key_down[vk] = false;
            if (CGEventRef e = CGEventCreateKeyboardEvent(nullptr, CGKeyCode(vk), false))
                lane_key(e);
        }
        if (CGEventRef e = CGEventCreate(nullptr)) {
            CGEventSetType(e, kCGEventFlagsChanged);
            CGEventSetFlags(e, 0);
            lane_key(e);
        }
    });
}

void attach_keys(GCKeyboard* k) {
    if (!k || k == g_keys_from)
        return;
    g_keys_from = k;
    k.handlerQueue = g_keys_queue;
    k.keyboardInput.keyChangedHandler = ^(GCKeyboardInput*, GCControllerButtonInput*, GCKeyCode code, BOOL pressed) {
        heard_key(code, pressed);
    };
    g_keys_on.store(true, std::memory_order_release);
    rexui_log(@"panes: keys heard by GameController");
}

void keys_start(void) {
    static bool watching;
    if (!g_keys_queue)
        g_keys_queue = dispatch_queue_create(
            "rexui.panes.keys",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    if (!watching) {
        watching = true;
        [NSNotificationCenter.defaultCenter
            addObserverForName:GCKeyboardDidConnectNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification* n) {
                        if (g_direct.load(std::memory_order_acquire) && [n.object isKindOfClass:GCKeyboard.class])
                            attach_keys(n.object);
                    }];
    }
    g_keys_from = nil;
    attach_keys(GCKeyboard.coalescedKeyboard);
}

void keys_stop(void) {
    g_keys_on.store(false, std::memory_order_release);
    g_keys_from.keyboardInput.keyChangedHandler = nil;
    g_keys_from = nil;
    dispatch_sync(g_keys_queue, ^{
        memset(g_key_cmd_held, 0, sizeof g_key_cmd_held);
        memset(g_key_down, 0, sizeof g_key_down);
    });
    for (auto& h : g_key_heard)
        h.store(0, std::memory_order_relaxed);
}

bool tap_start(void) {
    g_tap_double_click = NSEvent.doubleClickInterval;
    if (g_tap)
        return (CGEventTapEnable(g_tap, true), true);
    CGEventMask mask = CGEventMaskBit(kCGEventMouseMoved) | CGEventMaskBit(kCGEventLeftMouseDown)
        | CGEventMaskBit(kCGEventLeftMouseUp) | CGEventMaskBit(kCGEventLeftMouseDragged)
        | CGEventMaskBit(kCGEventRightMouseDown) | CGEventMaskBit(kCGEventRightMouseUp)
        | CGEventMaskBit(kCGEventRightMouseDragged) | CGEventMaskBit(kCGEventOtherMouseDown)
        | CGEventMaskBit(kCGEventOtherMouseUp) | CGEventMaskBit(kCGEventOtherMouseDragged)
        | CGEventMaskBit(kCGEventScrollWheel);
    g_tap = CGEventTapCreateForPid(getpid(), kCGHeadInsertEventTap, kCGEventTapOptionListenOnly, mask, tapped, nullptr);
    if (!g_tap) {
        rexui_log(@"panes: no event tap for this process: a full window's input goes through the main thread");
        return false;
    }
    dispatch_semaphore_t up = dispatch_semaphore_create(0);
    NSThread* th = [[NSThread alloc] initWithBlock:^{
        pthread_setname_np("rexui.panes.tap");
        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        auto ticks = [&](uint64_t ns) { return uint32_t(ns * tb.denom / tb.numer); };
        thread_time_constraint_policy_data_t rt{ticks(1000000), ticks(200000), ticks(1000000), 1};
        thread_policy_set(pthread_mach_thread_np(pthread_self()), THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&rt,
                          THREAD_TIME_CONSTRAINT_POLICY_COUNT);
        CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(nullptr, g_tap, 0);
        g_tap_loop = CFRunLoopGetCurrent();
        CFRunLoopAddSource(g_tap_loop, src, kCFRunLoopCommonModes);
        CFRelease(src);
        CGEventTapEnable(g_tap, true);
        dispatch_semaphore_signal(up);
        CFRunLoopRun();
    }];
    th.qualityOfService = NSQualityOfServiceUserInteractive;
    [th start];
    dispatch_semaphore_wait(up, DISPATCH_TIME_FOREVER);
    rexui_log(@"panes: input tap on its own thread");
    return true;
}

void direct_off(void) {
    g_direct.store(nullptr, std::memory_order_release);
    if (!g_tap_loop)
        return;
    keys_stop();
    rexui_log([NSString stringWithFormat:@"panes: off main meanwhile: %llu keys by GameController, %llu late from main",
                                         g_keys_sent.exchange(0), g_keys_late.exchange(0)]);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    CFRunLoopPerformBlock(g_tap_loop, kCFRunLoopCommonModes, ^{
        CGEventTapEnable(g_tap, false);
        g_tap_buttons = 0;
        dispatch_semaphore_signal(done);
    });
    CFRunLoopWakeUp(g_tap_loop);
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10));
}

static void full_clear(RXPaneApp* app) {
    if (g_full != app)
        return;
    g_full = nil;
    term_full_block(nil);
}
NSResponder* first_responder(NSWindow* w) {
    return w.firstResponder;
}

void note_file_keys(RXPaneApp* app, NSWindow* w) {
    NSResponder* fr = w.firstResponder;
    NSView* dv = app.view.docView;
    if (app.doc && dv && [fr isKindOfClass:NSView.class] && [(NSView*)fr isDescendantOf:dv])
        app.keysNote = ui_keys_note(fr);
}
void keys_back(RXPaneApp* app, NSWindow* w, NSView* surface) {
    if (app.doc && app.keysNote && ui_keys_restore(app.keysNote, w))
        return;
    NSResponder* now = w.firstResponder;
    if (surface && surface.window == w && now != surface && !has_keys(app, now))
        [w makeFirstResponder:surface];
}

void set_full(RXPaneApp* app, bool on) {
    if (on == app.full)
        return;
    trace_keys([NSString stringWithFormat:@"%@ %@ the full window", app.name, on ? @"takes" : @"gives back"]);
    RXAppPane* v = app.view;
    NSWindow* w = on ? v.surface.window : v.window;
    NSView* root = ui_full_root(w);
    if (on && (!w || !root))
        return;
    NSResponder* keysWere = on ? nil : first_responder(w);
    bool keys = !on && (has_keys(app, keysWere) || !keysWere || keysWere == w);
    if (w)
        note_file_keys(app, w);
    if (on) {
        for (RXPaneApp* other in g_apps.allValues)
            if (other != app && other.full)
                set_full(other, false);
    } else {
        direct_off();
        pointer_still_hold();
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (on) {
        NSMutableArray* hid = [NSMutableArray array];
        CALayer* frameLayer = (w.contentView.superview ?: w.contentView).layer;
        for (CALayer* keep = root.layer; keep && keep != frameLayer; keep = keep.superlayer) {
            for (CALayer* l in keep.superlayer.sublayers) {
                if (l == keep || l.hidden)
                    continue;
                l.hidden = YES;
                [hid addObject:l];
            }
        }
        v.hiddenUnder = hid;
        v.fullIn = root;
        if (app.doc) {
            ui_full_cover(w, true);
            bool inFile = app.keysNote && [first_responder(w) isKindOfClass:NSView.class] &&
                [(NSView*)first_responder(w) isDescendantOf:v.docView];
            NSView* dv = v.docView;
            [dv removeFromSuperview];
            dv.frame = root.bounds;
            [root addSubview:dv];
            dv.layer.zPosition = -15;
            dv.layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
            app.full = true;
            g_full = app;
            term_full_block(app.block);
            [CATransaction commit];
            watch_size();
            [v layout];
            NSResponder* had = first_responder(w);
            NSView* surface = v.surface;
            if (inFile)
                keys_back(app, w, surface);
            else if (NSView* page = g_config.pane_web_focus ? web_pane_page(app.doc) : nil)
                [w makeFirstResponder:page];
            else if (surface && had != surface && ![had isKindOfClass:NSView.class])
                [w makeFirstResponder:surface];
            apply_all();
            report(app);
            pane_styles_wake();
            rexui_log([NSString stringWithFormat:@"panes: %@ takes the full window", app.name]);
            return;
        }
        v.layer.zPosition = 0;
        v.layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
        v.fullHost = [RXAppPaneLayer layer];
        v.fullHost.frame = root.bounds;
        [v.fullHost addSublayer:v.layer];
        [ui_full_cover(w, true) addSublayer:v.fullHost];
        app.full = true;
        g_full = app;
        term_full_block(app.block);
    } else {
        for (CALayer* l in v.hiddenUnder)
            l.hidden = NO;
        v.hiddenUnder = nil;
        ui_full_cover(w, false);
        [v.fullHost removeFromSuperlayer];
        v.fullHost = nil;
        v.fullHole = nil;
        v.fullIn = nil;
        if (NSView* dv = app.doc ? v.docView : nil) {
            [dv removeFromSuperview];
            shape_layer(dv.layer, nil, 0, nullptr, 0, nullptr);
            dv.layer.zPosition = 0;
            dv.layer.backgroundColor = nil;
        }
        v.layer.backgroundColor = nil;
        v.layer.zPosition = 1000;
        [v.layer removeFromSuperlayer];
        if (v.surface)
            [v.surface.layer addSublayer:v.layer];
        app.full = false;
        full_clear(app);
    }
    [CATransaction commit];
    watch_size();
    [v layout];
    if (on) {
        if (v.surface && w.firstResponder != v.surface)
            [w makeFirstResponder:v.surface];
        direct_geometry(app);
        if (rx::panes::Lane* l = app->lane.get(); l && tap_start()) {
            g_direct.store(l, std::memory_order_release);
            keys_start();
        }
        if (app.cursor)
            [cursor_named(app.cursor) set];
    } else if (keys) {
        keys_back(app, w, v.surface);
    }
    apply_all();
    report(app);
    capture_cursor();
    pane_styles_wake();
    rexui_log(
        [NSString stringWithFormat:@"panes: %@ %@ the full window%@", app.name, on ? @"takes" : @"gives back",
                                   on && g_ui_over ? @" (a Drawer's open over it: its input till it closes)" : @""]);
}

bool has_keys(RXPaneApp* app, NSResponder* fr) {
    NSView *surface = app.view.surface, *dv = app.view.docView;
    return fr && (fr == surface || (dv && [fr isKindOfClass:NSView.class] && [(NSView*)fr isDescendantOf:dv]));
}

bool is_full_key(NSEvent* e) {
    static NSString* parsed;
    static NSDictionary* chord;
    if (![parsed isEqual:g_config.pane_fullscreen_key]) {
        parsed = g_config.pane_fullscreen_key;
        chord = parsed.length ? parse_chord(parsed) : nil;
    }
    if (!chord)
        return false;
    return [chord[@"mods"] unsignedLongValue] == (e.modifierFlags & kMods) &&
        [chord[@"key"] isEqual:e.charactersIgnoringModifiers.lowercaseString];
}

}

void keys_trace(NSString* why) {
    trace_keys(why);
}

bool panes_file_full_in(NSWindow* w) {
    RXPaneApp* app = g_full;
    return app && app.doc && w && app.view.window == w;
}

bool panes_full_in(NSWindow* w) {
    RXPaneApp* app = g_full;
    return app && !app.doc && w && app.view.window == w;
}

bool panes_full_opaque(NSWindow* w) {
    RXPaneApp* app = g_full;
    return app && w && app.view.window == w && !app.view.fullHole;
}

void panes_full_hole(NSString* spec) {
    RXPaneApp* app = g_full;
    if (!app)
        return;
    RXAppPane* v = app.view;
    NSString* now = spec.length ? spec : nil;
    if (now == v.fullHole || [now isEqualToString:v.fullHole])
        return;
    bool was = v.fullHole != nil;
    v.fullHole = now;
    NSWindow* w = v.window;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    shape_layer(app.doc ? v.docView.layer : v.fullHost, spec, 0, nullptr, 0, nullptr);
    if (NSView* dv = app.doc ? v.docView : nil; dv && !dv.isFlipped && dv.layer.mask)
        dv.layer.mask.transform = CATransform3DMakeScale(1, -1, 1);
    if (was != (now != nil)) {
        for (CALayer* l in v.hiddenUnder)
            l.hidden = now == nil;
        ui_full_reveal(w, now != nil);
    }
    [CATransaction commit];
    if (was != (now != nil))
        apply_all();
}

bool panes_ui_over(void) {
    return g_ui_over.load(std::memory_order_relaxed);
}

void panes_drawers_changed(bool any_open) {
    if (any_open == g_ui_over.load(std::memory_order_relaxed))
        return;
    g_ui_over.store(any_open, std::memory_order_relaxed);
    RXPaneApp* app = g_full;
    if (!app)
        return;
    direct_geometry(app);
    if (any_open)
        keys_release();
    capture_cursor();
    if (!any_open && app.cursor)
        [cursor_named(app.cursor) set];
    rexui_log([NSString stringWithFormat:@"panes: %@",
                                         any_open ? @"a Drawer over the full window has the input"
                                                  : @"the input back to the full window"]);
}

bool panes_full_input(NSEvent* e) {
    NSWindow* ew = e.window;
    RXPaneApp* app = g_full;
    if (g_ui_over.load(std::memory_order_relaxed))
        return false;
    if (!app || !g_direct.load(std::memory_order_acquire) || ew != app.view.window || !ew.isKeyWindow)
        return false;
    NSEventType t = e.type;
    if (t == NSEventTypeKeyDown || t == NSEventTypeKeyUp) {
        if (e.modifierFlags & NSEventModifierFlagCommand)
            return false;
        int vk = e.keyCode;
        if (vk >= 128)
            return true;
        static bool from_main[128];
        auto post = [](NSEvent* ev) {
            if (CGEventRef cg = ev.CGEvent)
                lane_key(CGEventCreateCopy(cg));
        };
        if (t == NSEventTypeKeyUp) {
            if (from_main[vk] || !g_keys_on.load(std::memory_order_acquire))
                post(e);
            from_main[vk] = false;
            return true;
        }
        if (e.isARepeat || !g_keys_on.load(std::memory_order_acquire)) {
            post(e);
            return true;
        }
        if (rx::sync::exchange(g_key_heard[vk], decltype(g_key_heard[vk].load()){0}, std::memory_order_acq_rel))
            return true;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (rx::sync::exchange(g_key_heard[vk], decltype(g_key_heard[vk].load()){0}, std::memory_order_acq_rel)
                || !g_direct.load(std::memory_order_acquire))
                return;
            rx::sync::fetch_add(g_keys_late, decltype(g_keys_late.load()){1}, std::memory_order_relaxed);
            from_main[vk] = true;
            if (CGEventRef cg = e.CGEvent)
                lane_key(CGEventCreateCopy(cg));
        });
        return true;
    }
    if (t == NSEventTypeFlagsChanged) {
        if (!g_keys_on.load(std::memory_order_acquire)) {
            if (CGEventRef cg = e.CGEvent)
                lane_key(CGEventCreateCopy(cg));
        }
        return true;
    }
    bool mouse = t == NSEventTypeMouseMoved || t == NSEventTypeLeftMouseDown || t == NSEventTypeRightMouseDown
        || t == NSEventTypeOtherMouseDown || t == NSEventTypeLeftMouseUp || t == NSEventTypeRightMouseUp
        || t == NSEventTypeOtherMouseUp || t == NSEventTypeLeftMouseDragged || t == NSEventTypeRightMouseDragged
        || t == NSEventTypeOtherMouseDragged || t == NSEventTypeScrollWheel;
    if (!mouse)
        return false;
    NSPoint p = e.locationInWindow;
    NSSize size = ew.frame.size;
    bool outside = p.x < 0 || p.y < 0 || p.x >= size.width || p.y >= size.height;
    bool held = t == NSEventTypeLeftMouseUp || t == NSEventTypeRightMouseUp || t == NSEventTypeOtherMouseUp
        || t == NSEventTypeLeftMouseDragged || t == NSEventTypeRightMouseDragged || t == NSEventTypeOtherMouseDragged;
    return !outside || held;
}

bool panes_set_full(NSString* block, int on) {
    RXPaneApp* app = block.length ? g_apps[block] : g_full;
    if (!app && !block.length) {
        NSWindow* kw = NSApp.keyWindow;
        NSResponder* fr = kw.firstResponder;
        for (RXPaneApp* a in g_apps.allValues)
            if (a.live && a.view.window == kw && has_keys(a, fr))
                app = a;
    }
    if (!app && !block.length) {
        NSWindow* kw = NSApp.keyWindow;
        bool now = term_full_in(kw);
        if ((on < 0 || (on != 0) != now)
            && (now || (surface_class() && [kw.firstResponder isKindOfClass:surface_class()])))
            term_full_toggle(kw);
        return term_full_in(kw);
    }
    if (!app)
        return false;
    app.wantsFull = on < 0 ? !app.full : on != 0;
    set_full(app, app.wantsFull);
    return app.full;
}

void panes_leave_full(NSWindow* w, NSString* why) {
    term_full_leave(w, why, true);
    RXPaneApp* app = g_full;
    if (!app || (w && app.view.window != w))
        return;
    rexui_log([NSString stringWithFormat:@"panes: %@: %@ gives the window back first", why, app.name]);
    app.wantsFull = false;
    set_full(app, false);
}

extern "C" void panes_tab_switched(void) {
    if (!g_full && !term_full_in(nil))
        return;
    dispatch_async(dispatch_get_main_queue(), ^{
        panes_leave_full(nil, @"Rex switched tabs");
    });
}

bool panes_app_full(NSString* block) {
    RXPaneApp* app = block ? g_apps[block] : nil;
    return app && app.full;
}

id panes_doc_of_block(NSString* block) {
    return block ? g_apps[block].doc : nil;
}

bool panes_file_in(NSView* surface) {
    if (!surface)
        return false;
    for (RXPaneApp* app in g_apps.allValues)
        if (app.doc && app.view.superview == surface)
            return true;
    return false;
}

NSString* panes_block_of_doc(id doc) {
    for (NSString* b in g_apps) {
        if (g_apps[b].doc == doc)
            return b;
    }
    return nil;
}

NSArray<NSDictionary*>* panes_rex_bindings(void) {
    return g_bindings;
}

@implementation RXPaneApp
@end

static CGFloat fit_host(CALayer* host, NSRect l, NSRect b, NSPoint* in) {
    CGFloat s = 1;
    *in = NSZeroPoint;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (l.size.width > 0) {
        CGFloat cw = l.size.width - l.origin.x, ch = l.size.height - l.origin.y;
        if (cw > b.size.width + 1 || ch > b.size.height + 1) {
            s = MIN(b.size.width / cw, b.size.height / ch);
            *in = NSMakePoint(round((b.size.width - cw * s) / 2), round((b.size.height - ch * s) / 2));
        }
        host.bounds = CGRectMake(0, 0, l.size.width, l.size.height);
        host.position = CGPointMake(b.origin.x + in->x - l.origin.x * s,
                                    b.origin.y + b.size.height - in->y - (l.size.height - l.origin.y) * s);
        host.affineTransform = CGAffineTransformMakeScale(s, s);
    } else {
        host.affineTransform = CGAffineTransformIdentity;
        host.frame = b;
    }
    [CATransaction commit];
    return s;
}

static std::unordered_set<const void*> g_anchors;
static void watch_size(void) {
    g_anchors.clear();
    for (RXPaneApp* app in g_apps.allValues)
        if (NSView* a = app.view.anchor; a.layer)
            g_anchors.insert((__bridge const void*)a.layer);
}

void panes_pane_framed(NSView* pane) {
    for (RXPaneApp* app in g_apps.allValues) {
        NSView *hosted = nil, *surface = app.view.surface;
        if (!surface || ![surface isDescendantOf:pane])
            continue;
        for (NSView* v = surface.superview; v && v != pane; v = v.superview)
            if ([NSStringFromClass(v.class) containsString:@"NSHostingView"])
                hosted = v;
        if (hosted && !NSEqualSizes(hosted.frame.size, pane.frame.size))
            [hosted setFrameSize:pane.frame.size];
    }
}

extern "C" void panes_layer_resized(CALayer* l) {
    if (g_anchors.empty() || !pthread_main_np() || !g_anchors.count((__bridge const void*)l))
        return;
    if (CGRectIsEmpty(l.bounds))
        return;
    for (RXPaneApp* app in g_apps.allValues)
        if (app.view.anchor.layer == l)
            [app.view layout];
}

@interface RXAppPane () {
    __weak NSView* _w_surface;
}
@end
@implementation RXAppPane

- (NSView*)surface {
    return _w_surface;
}
- (void)setSurface:(NSView*)v {
    _w_surface = v;
}
- (instancetype)init {
    if ((self = [super init])) {
        _layer = [RXAppPaneLayer layer];
        _layer.masksToBounds = YES;
        _layer.zPosition = 1000;
        _host = [CALayerHost layer];
        _host.anchorPoint = CGPointZero;
        [_layer addSublayer:_host];
    }
    return self;
}

- (NSView*)anchor {
    return self.fullIn ?: self.surface;
}
- (NSView*)superview {
    return self.surface;
}
- (NSWindow*)window {
    return self.anchor.window;
}
- (BOOL)hiddenOrHasHiddenAncestor {
    return !self.anchor || self.anchor.hiddenOrHasHiddenAncestor;
}
- (NSRect)bounds {
    NSView* a = self.anchor;
    return a ? NSMakeRect(0, 0, a.bounds.size.width, a.bounds.size.height) : NSZeroRect;
}
- (NSPoint)convertPoint:(NSPoint)win fromView:(id)none {
    NSView* a = self.anchor;
    NSPoint p = [a convertPoint:win fromView:nil];
    return NSMakePoint(p.x - a.bounds.origin.x,
                       a.isFlipped ? a.bounds.size.height - (p.y - a.bounds.origin.y) : p.y - a.bounds.origin.y);
}
- (NSPoint)convertPoint:(NSPoint)p toView:(id)none {
    NSView* a = self.anchor;
    return [a convertPoint:NSMakePoint(p.x + a.bounds.origin.x,
                                       (a.isFlipped ? a.bounds.size.height - p.y : p.y) + a.bounds.origin.y)
                    toView:nil];
}
- (NSRect)convertRect:(NSRect)r toView:(id)none {
    NSPoint a = [self convertPoint:r.origin toView:nil],
            b = [self convertPoint:NSMakePoint(NSMaxX(r), NSMaxY(r)) toView:nil];
    return NSMakeRect(MIN(a.x, b.x), MIN(a.y, b.y), fabs(b.x - a.x), fabs(b.y - a.y));
}
- (NSRect)convertRect:(NSRect)win fromView:(id)none {
    NSPoint a = [self convertPoint:win.origin fromView:nil],
            b = [self convertPoint:NSMakePoint(NSMaxX(win), NSMaxY(win)) fromView:nil];
    return NSMakeRect(MIN(a.x, b.x), MIN(a.y, b.y), fabs(b.x - a.x), fabs(b.y - a.y));
}

- (void)layout {
    NSView* a = self.anchor;
    if (a) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        if (_fullHost)
            _fullHost.frame = a.bounds;
        _layer.geometryFlipped = a.isFlipped;
        _layer.frame = a.bounds;
        [CATransaction commit];
    }
    NSPoint in = NSZeroPoint;
    NSRect px = pixel_bounds(self);
    _aligned = px;
    RXPaneApp* held = self.app;
    _fit = fit_host(_host, held.layout, px, &in);
    _inset = NSMakePoint(in.x + px.origin.x, in.y);
    if (id doc = held.doc) {
        [self fileView];
        NSView* holder = self.fullIn ?: self.surface;
        if (holder && _docView.superview != holder) {
            _docView.frame = holder.bounds;
            [holder addSubview:_docView];
        }
        if (holder && !NSEqualRects(_docView.frame, holder.bounds))
            _docView.frame = holder.bounds;
        ui_pane_layout(doc, _docView.bounds);
    }
    if (held)
        report(held);
}

- (NSView*)fileView {
    id doc = self.app.doc;
    if (!doc)
        return _docView;
    if (!_docView) {
        _docView = [[NSView alloc] initWithFrame:self.bounds];
        _docView.wantsLayer = YES;
        _docView.layer.masksToBounds = YES;
        _docView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    }
    NSView* dv = ui_pane_view(doc);
    if (dv && dv.superview != _docView) {
        [dv removeFromSuperview];
        [_docView addSubview:dv];
    }
    return _docView;
}

- (void)needsLayout {
    if (_layoutQueued)
        return;
    _layoutQueued = true;
    dispatch_async(dispatch_get_main_queue(), ^{
        _layoutQueued = false;
        [self layout];
    });
}

- (void)placeIn:(NSView*)surface {
    [self takeOut];
    self.surface = surface;
    self.lastSurface = surface;
    surface.wantsLayer = YES;
    if (!self.fullIn)
        [surface.layer addSublayer:_layer];
    watch_size();
    [self layout];
}

- (void)takeOut {
    NSView* full = self.fullIn;
    if (!full)
        [_layer removeFromSuperlayer];
    if (!full)
        [_docView removeFromSuperview];
    self.surface = nil;
    watch_size();
}

- (void)press:(NSEvent*)e {
    if (g_released) {
        g_released = false;
        dispatch_async(dispatch_get_main_queue(), ^{
            capture_cursor();
        });
    }
    NSWindow* w = self.window;
    NSView* surface = self.surface;
    if (surface && w.firstResponder != surface)
        [w makeFirstResponder:surface];
    if (RXPaneApp* held = self.app)
        report(held);
    [self send:e];
}

- (void)send:(NSEvent*)e {
    RXPaneApp* app = self.app;
    if (!app)
        return;
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    CGFloat s = _fit > 0 ? _fit : 1;
    forward(app, e, NSMakePoint((p.x - _inset.x) / s, (self.bounds.size.height - p.y - _inset.y) / s));
}

- (void)moved:(NSEvent*)e {
    if (!raw_moves(self.app))
        [self send:e];
}

- (void)mouseMoved:(NSEvent*)e {
    if (!on_top_at(self, e.locationInWindow))
        return;
    [self moved:e];
    RXPaneApp* held = self.app;
    if (held.cursor)
        [cursor_named(held.cursor) set];
    if (held.capture && !g_locked)
        capture_cursor();
}

@end

NSDictionary* panes_last_block(void) {
    NSView* surface = g_last_surface;
    if (!surface.window) {
        for (NSWindow* w in NSApp.windows) {
            if (is_rex_window(w) && surface_class() && [w.firstResponder isKindOfClass:surface_class()])
                surface = (NSView*)w.firstResponder;
        }
    }
    if (!surface.window)
        return nil;
    NSView* chrome = is_rex_window(surface.window) ? chrome_of(surface.window) : nil;
    NSView* content = chrome ? chrome_content(chrome) : nil;
    void* raw = content ? rex_panes((__bridge const void*)content) : nullptr;
    NSDictionary<NSString*, NSView*>* panes = raw ? (__bridge_transfer NSDictionary*)raw : nil;
    for (NSString* block in panes) {
        if ([surface isDescendantOf:panes[block]])
            return @{@"block": block, @"session": g_session_id ?: @""};
    }
    return nil;
}

void panes_init(void) {
    g_apps = [NSMutableDictionary dictionary];
    Method mf = class_getInstanceMethod(NSWindow.class, @selector(makeFirstResponder:));
    orig_make_first = (BOOL(*)(NSWindow*, SEL, NSResponder*))method_setImplementation(mf, (IMP)hook_make_first);
    listen_for_apps();
    load_keymap();
    if (Class c = surface_class()) {
        Method m = class_getInstanceMethod(c, @selector(viewDidMoveToWindow));
        IMP mine = (IMP)hook_surface_did_move;
        if (!class_addMethod(c, @selector(viewDidMoveToWindow), mine, method_getTypeEncoding(m))) {
            orig_surface_did_move = (void (*)(id, SEL))method_setImplementation(m, mine);
        } else {
            orig_surface_did_move = (void (*)(id, SEL))method_getImplementation(m);
        }
    } else {
        rexui_log(@"panes: the terminal view class not found (a Rex update?): apps can't find their panes");
    }
    for (NSNotificationName n in @[NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification]) {
        [NSNotificationCenter.defaultCenter addObserverForName:n
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification*) {
                                                        for (RXPaneApp* app in g_apps.allValues)
                                                            report(app);
                                                        capture_cursor();
                                                    }];
    }
    [NSNotificationCenter.defaultCenter
        addObserverForName:NSApplicationWillTerminateNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification*) {
                    CGAssociateMouseAndMouseCursorPosition(true);
                    if (g_config.pane_keep) {
                        if (g_apps.count)
                            rexui_log(
                                [NSString stringWithFormat:@"panes: Rex UI quits: %lu apps kept running (pane_keep)",
                                                           (unsigned long)g_apps.count]);
                        return;
                    }
                    for (RXPaneApp* app in g_apps.allValues) {
                        if (app.fd < 0)
                            continue;
                        static const char quit[] = "{\"quit\":true}\n";
                        dispatch_sync(app.writes, ^{
                            (void)write(app.fd, quit, sizeof quit - 1);
                        });
                    }
                    if (g_apps.count)
                        rexui_log([NSString stringWithFormat:@"panes: Rex UI quits: %lu apps asked to quit",
                                                             (unsigned long)g_apps.count]);
                }];
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidResignActiveNotification
                                                    object:nil
                                                     queue:nil
                                                usingBlock:^(NSNotification*) {
                                                    g_locked = false;
                                                    CGAssociateMouseAndMouseCursorPosition(true);
                                                    raw_capture(nil);
                                                }];
}

void panes_config_changed(void) {
    load_keymap();
}

NSCursor* panes_cursor_here(void) {
    for (RXPaneApp* app in g_apps.allValues) {
        RXAppPane* v = app.view;
        NSWindow* w = v.window;
        if (app.doc || !app.live || !w || !v.superview || v.hiddenOrHasHiddenAncestor)
            continue;
        if (on_top_at(v, w.mouseLocationOutsideOfEventStream))
            return cursor_named(app.cursor ?: @"arrow");
    }
    return nil;
}

void panes_hold_pointer(bool hold) {
    if (hold == g_held)
        return;
    g_held = hold;
    capture_cursor();
}

bool panes_has_pointer(NSWindow* w, NSPoint p) {
    if (g_locked)
        return true;
    for (RXPaneApp* app in g_apps.allValues) {
        RXAppPane* v = app.view;
        if (!app.live || app.focused != 1 || v.window != w || !v.superview || v.hiddenOrHasHiddenAncestor)
            continue;
        NSRect r = [v convertRect:v.bounds toView:nil];
        r.size.height += r.origin.y, r.origin.y = 0;
        if (NSPointInRect(p, r))
            return true;
    }
    return false;
}

static void hover_focus(NSEvent* e) {
    static __weak RXPaneApp* inside;
    static bool done;
    static double tried;
    NSWindow* w = e.window;
    NSPoint p = e.locationInWindow;
    RXPaneApp* now = nil;
    for (RXPaneApp* app in g_apps.allValues) {
        RXAppPane* v = app.view;
        if (app.live && v.superview && v.window == w && NSPointInRect([v convertPoint:p fromView:nil], v.bounds))
            now = app;
    }
    if (now != inside)
        inside = now, done = false, tried = 0;
    if (!now || done)
        return;
    double t = CACurrentMediaTime();
    if (t - tried < 0.05)
        return;
    tried = t;
    RXAppPane* v = now.view;
    NSView* surface = v.superview;
    if (!w.isKeyWindow || NSEvent.pressedMouseButtons || v.hiddenOrHasHiddenAncestor || !on_top_at(v, p))
        return;
    done = true;
    if (now.full)
        return;
    NSResponder* fr = w.firstResponder;
    if (fr != surface && [fr isKindOfClass:NSView.class] && [(NSView*)fr isDescendantOf:surface])
        return;
    NSView* target = surface;
    if (now.doc && g_config.pane_web_focus) {
        NSView* frame = w.contentView.superview ?: w.contentView;
        static Class web = NSClassFromString(@"WKWebView");
        for (NSView* h = [frame hitTest:p]; h && h != surface; h = h.superview)
            if ([h isKindOfClass:web]) {
                target = h;
                break;
            }
    }
    if (fr == target)
        return;
    if (fr != surface)
        [w makeFirstResponder:surface];
    if (target != surface)
        [w makeFirstResponder:target];
    dispatch_async(dispatch_get_main_queue(), ^{
        for (RXPaneApp* app in g_apps.allValues)
            report(app);
    });
}

static bool term_key(NSEvent* e) {
    NSWindow* ew = e.window;
    NSResponder* fr = ew.firstResponder;
    if (!term_full_in(ew) && !(surface_class() && [fr isKindOfClass:surface_class()]))
        return false;
    if (!e.isARepeat)
        term_full_toggle(ew);
    return true;
}

bool panes_event(NSEvent* e) {
    NSWindow* ew = e.window;
    if (!g_apps.count)
        return e.type == NSEventTypeKeyDown && is_full_key(e) && term_key(e);
    NSEventType t = e.type;
    if (t == NSEventTypeMouseMoved) {
        static __weak RXAppPane* over;
        RXAppPane* now = nil;
        for (RXPaneApp* app in g_apps.allValues) {
            RXAppPane* v = app.view;
            if (v.superview && !app.doc && v.window == ew && !v.hiddenOrHasHiddenAncestor
                && on_top_at(v, e.locationInWindow))
                now = v;
        }
        if (now != over) {
            over = now;
            capture_cursor();
        }
        if (now)
            [now mouseMoved:e];
        hover_focus(e);
        return false;
    }
    static __weak RXAppPane* held;
    bool down = t == NSEventTypeLeftMouseDown || t == NSEventTypeRightMouseDown || t == NSEventTypeOtherMouseDown;
    if (down) {
        for (RXPaneApp* app in g_apps.allValues) {
            RXAppPane* v = app.view;
            if (app.doc || !app.live || v.window != ew || !on_top_at(v, e.locationInWindow))
                continue;
            if (!ew.isKeyWindow) {
                [NSApp activateIgnoringOtherApps:YES];
                [ew makeKeyAndOrderFront:nil];
            }
            held = v;
            [v press:e];
            dispatch_async(dispatch_get_main_queue(), ^{
                for (RXPaneApp* other in g_apps.allValues)
                    report(other);
            });
            return true;
        }
    }
    if (RXAppPane* v = held) {
        if (t == NSEventTypeLeftMouseDragged || t == NSEventTypeRightMouseDragged
            || t == NSEventTypeOtherMouseDragged) {
            [v moved:e];
            return true;
        }
        if (t == NSEventTypeLeftMouseUp || t == NSEventTypeRightMouseUp || t == NSEventTypeOtherMouseUp) {
            [v send:e];
            held = nil;
            return true;
        }
    }
    static __weak NSView* doc_held;
    if (down) {
        if (NSView* target = doc_press(e, ew)) {
            doc_held = target;
            return true;
        }
    }
    if (NSView* target = doc_held) {
        if (t == NSEventTypeLeftMouseDragged || t == NSEventTypeRightMouseDragged
            || t == NSEventTypeOtherMouseDragged) {
            deliver(target, e);
            return true;
        }
        if (t == NSEventTypeLeftMouseUp || t == NSEventTypeRightMouseUp || t == NSEventTypeOtherMouseUp) {
            deliver(target, e);
            doc_held = nil;
            return true;
        }
    }
    if (t == NSEventTypeScrollWheel) {
        for (RXPaneApp* app in g_apps.allValues) {
            RXAppPane* v = app.view;
            if (app.doc) {
                if (NSView* target = doc_target(app, ew, e.locationInWindow)) {
                    deliver(target, e);
                    return true;
                }
                continue;
            }
            if (!app.live || v.window != ew || !on_top_at(v, e.locationInWindow))
                continue;
            [v send:e];
            return true;
        }
        return false;
    }
    if (down) {
        for (RXPaneApp* app in g_apps.allValues) {
            RXAppPane* v = app.view;
            NSView* surface = v.superview;
            NSResponder* had = ew.firstResponder;
            if (!app.doc || !app.live || !surface || v.window != ew || had == surface)
                continue;
            if ([had isKindOfClass:NSView.class] && [(NSView*)had isDescendantOf:v.docView])
                continue;
            if (on_top_at(v, e.locationInWindow))
                [ew makeFirstResponder:surface];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            for (RXPaneApp* app in g_apps.allValues)
                report(app);
        });
        return false;
    }
    if (t != NSEventTypeKeyDown && t != NSEventTypeKeyUp && t != NSEventTypeFlagsChanged)
        return false;
    if (t == NSEventTypeKeyDown && e.keyCode == 53 && (e.modifierFlags & kMods) == NSEventModifierFlagCommand) {
        bool any = g_locked;
        for (RXPaneApp* app in g_apps.allValues)
            any = any || app.capture;
        if (any) {
            if (!e.isARepeat) {
                g_released = true;
                capture_cursor();
                rexui_log(@"panes: cmd+esc: the cursor let go (a press in the pane captures it again)");
            }
            return true;
        }
    }
    NSResponder* fr = ew.firstResponder;
    if (t == NSEventTypeKeyDown && is_full_key(e)) {
        for (RXPaneApp* app in g_apps.allValues) {
            if (!app.live || app.view.window != ew || (!app.full && !has_keys(app, fr)))
                continue;
            if (!e.isARepeat) {
                app.wantsFull = !app.full;
                set_full(app, app.wantsFull);
            }
            return true;
        }
        if (term_key(e))
            return true;
    }
    if (t == NSEventTypeKeyDown && tabs_zoom_key(e)) {
        for (RXPaneApp* app in g_apps.allValues) {
            if (!app.live || !app.full || app.view.window != ew)
                continue;
            if (!e.isARepeat) {
                app.wantsFull = false;
                set_full(app, false);
                rexui_log([NSString stringWithFormat:@"panes: Rex's zoom key: %@ back into its pane", app.name]);
            }
            return true;
        }
    }
    if (t == NSEventTypeKeyDown && (e.modifierFlags & kMods) == NSEventModifierFlagCommand &&
        [e.charactersIgnoringModifiers.lowercaseString isEqual:@"q"]) {
        for (RXPaneApp* app in g_apps.allValues) {
            NSView* surface = app.view.superview;
            if (!app.live || app.view.window != ew)
                continue;
            if (!app.full
                && (!surface
                    || (fr != surface
                        && !([fr isKindOfClass:NSView.class] && app.view.docView &&
                             [(NSView*)fr isDescendantOf:app.view.docView]))))
                continue;
            if (!e.isARepeat) {
                send(app, @{@"quit": @YES});
                if (!app.quitAt)
                    app.quitAt = NSDate.date.timeIntervalSince1970 * 1000, pane_styles_wake();
                rexui_log([NSString stringWithFormat:@"panes: cmd+q: %@ asked to quit", app.name]);
            }
            return true;
        }
    }
    for (RXPaneApp* app in g_apps.allValues) {
        RXAppPane* v = app.view;
        if (app.doc || !app.live || v.window != ew || (!app.full && (!v.superview || fr != v.superview)))
            continue;
        if (app.full && g_ui_over.load(std::memory_order_relaxed))
            continue;
        if (t == NSEventTypeFlagsChanged) {
            forward(app, e, NSZeroPoint);
            return false;
        }
        if (t == NSEventTypeKeyUp) {
            if (![app.keysDown containsObject:@(e.keyCode)])
                return false;
            [app.keysDown removeObject:@(e.keyCode)];
            forward(app, e, NSZeroPoint);
            return true;
        }
        if (stays_rex(app, e))
            return false;
        report(app);
        [app.keysDown addObject:@(e.keyCode)];
        forward(app, e, NSZeroPoint);
        return true;
    }
    return false;
}

void panes_attach_soon(void) {
    schedule_attach();
}
void panes_keys_changed(void) {
    g_rex_chords = nil;
}

bool panes_rex_key(NSEvent* e) {
    if (e.type != NSEventTypeKeyDown || !g_apps.count)
        return false;
    NSWindow* w = e.window;
    NSResponder* fr = w.firstResponder;
    NSEventModifierFlags mods = e.modifierFlags & kMods;
    NSString* k = e.charactersIgnoringModifiers.lowercaseString;
    bool edit = [@[@"c", @"v", @"x", @"a", @"z"] containsObject:k]
        && (mods == NSEventModifierFlagCommand
            || (mods == (NSEventModifierFlagCommand | NSEventModifierFlagShift) && [k isEqual:@"z"]));
    if (edit || is_full_key(e) || web_takes_key(e) || !rex_binds(e))
        return false;
    for (RXPaneApp* app in g_apps.allValues) {
        NSView* surface = app.view.surface;
        if (!app.doc || !app.live || app.full || !surface || surface.window != w || !has_keys(app, fr))
            continue;
        if (fr != surface)
            [w makeFirstResponder:surface];
        return true;
    }
    return false;
}

extern "C" void panes_attach_now(void) {
    g_slide_shown = true;
    attach_all();
    g_slide_shown = false;
}

bool panes_owns_layer(CALayer* layer) {
    for (CALayer* l = layer; l; l = l.superlayer) {
        if ([l isKindOfClass:CALayerHost.class] || [l isKindOfClass:CAPortalLayer.class] ||
            [l isKindOfClass:RXAppPaneLayer.class])
            return true;
    }
    return false;
}

double panes_app_quitting(NSString* block) {
    RXPaneApp* app = block ? g_apps[block] : nil;
    return app && !app.doc ? app.quitAt : 0;
}

bool panes_app_drawn(NSString* block) {
    RXPaneApp* app = block ? g_apps[block] : nil;
    return app && !app.doc && app.view.host.contextId && app.drawn;
}

bool panes_app_covers(NSString* block) {
    RXPaneApp* app = block ? g_apps[block] : nil;
    return app && !app.doc && app.opaque && app.drawn && app.live && app.view.host.contextId && app.view.anchor
        && !app.view.hiddenOrHasHiddenAncestor;
}

NSString* panes_app_of_block(NSString* block) {
    RXPaneApp* app = block ? g_apps[block] : nil;
    return app && !app.doc && app.view.host.contextId ? app.name : nil;
}

bool panes_app_at(NSWindow* w, NSPoint win, NSArray<NSString*>* drop) {
    for (RXPaneApp* app in g_apps.allValues) {
        RXAppPane* v = app.view;
        if (app.doc || !app.live || !v.superview || v.window != w || v.hiddenOrHasHiddenAncestor)
            continue;
        NSPoint p = [v convertPoint:win fromView:nil];
        if (!NSPointInRect(p, v.bounds))
            continue;
        if (drop) {
            CGFloat s = v.fit > 0 ? v.fit : 1;
            send(
                app, @{
                    @"drop": drop,
                    @"x": @((p.x - v.inset.x) / s),
                    @"y": @((v.bounds.size.height - p.y - v.inset.y) / s)
                });
            rexui_log(
                [NSString stringWithFormat:@"panes: %lu files dropped on %@", (unsigned long)drop.count, app.name]);
        }
        return true;
    }
    return false;
}

extern "C" int rexui_pane_full_toggle(void) {
    NSWindow* w = ui_dock_window();
    NSResponder* fr = w.firstResponder;
    for (RXPaneApp* app in g_apps.allValues) {
        if (!app.live || app.view.window != w || (!app.full && !has_keys(app, fr)))
            continue;
        app.wantsFull = !app.full;
        set_full(app, app.wantsFull);
        return 1;
    }
    return term_full_toggle(w) ? 2 : 0;
}

extern "C" const char* rexui_pane_keys(void) {
    static std::string out;
    NSWindow* w = ui_dock_window();
    NSResponder* fr = w.firstResponder;
    out.clear();
    for (RXPaneApp* app in g_apps.allValues)
        if (app.live
            && (has_keys(app, fr)
                || (app.full && app.doc && [fr isKindOfClass:NSView.class] &&
                    [(NSView*)fr isDescendantOf:app.view.docView])))
            out = std::string(app.name.UTF8String ?: "?") + " " + app.block.UTF8String
                + (fr == app.view.surface ? " (its terminal view)" : " (in it)");
    if (out.empty())
        out = std::string("none: ") + NSStringFromClass([fr class]).UTF8String;
    return out.c_str();
}
extern "C" bool rexui_pane_focus(const char* block) {
    RXPaneApp* app = g_apps[@(block)];
    NSView* surface = app.view.surface;
    if (!surface.window)
        return false;
    [surface.window makeFirstResponder:surface];
    NSView* root = app.doc ? ui_pane_view(app.doc) : nil;
    if (root.window && root.acceptsFirstResponder)
        [surface.window makeFirstResponder:root];
    return true;
}
