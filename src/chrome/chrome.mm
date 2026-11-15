// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "chrome/chrome.h"
#include "base/trace.h"
#include "rex/rex.h"

#include <dlfcn.h>
#include <string.h>

extern bool g_watching;

static NSString* debug_home(void) {
    static NSString* home = NSProcessInfo.processInfo.environment[@"REXUI_HOME"]
        ?: [NSHomeDirectory() stringByAppendingPathComponent:@"rexui/build"];
    return home;
}

NSString* debug_path(NSString* name) {
    return [debug_home() stringByAppendingPathComponent:name];
}

static void redisplay(NSView* view) {
    view.needsDisplay = YES;
    for (NSView* sub in view.subviews)
        redisplay(sub);
}

static bool chrome_differs(const Config& a, const Config& b) {
    return a.transparency != b.transparency || a.traffic_lights != b.traffic_lights || a.tab_bar != b.tab_bar
        || a.pane_buttons != b.pane_buttons || a.ui != b.ui || a.left != b.left || a.right != b.right || a.top != b.top
        || a.bottom != b.bottom || !(a.gif == b.gif || [a.gif isEqualToString:b.gif]) || a.gif_height != b.gif_height
        || a.gif_margin != b.gif_margin || a.gif_opacity != b.gif_opacity || a.gif_corner != b.gif_corner
        || a.gif_visible != b.gif_visible;
}

static void reload_config(void) {
    bool was_transparent = transparent();
    Config was = g_config;
    if (!load_config())
        return;
    bool relayout = chrome_differs(was, g_config);
    motion_config();
    if (relayout)
        chrome_glide_panes(g_config.pane_glide_ms, g_config.pane_glide_curve);
    update_window_bg();
    if (was_transparent && !transparent()) {
        restore_backgrounds();
        restore_shadows();
    }
    apply_all();
    for (NSWindow* w in NSApp.windows) {
        if (!is_rex_window(w))
            continue;
        if (NSView* chrome = chrome_of(w); chrome && relayout)
            chrome.needsLayout = YES;
        if (was_transparent != transparent() && w.contentView)
            redisplay(w.contentView);
    }
    ui_config_changed();
    panes_config_changed();
    notices_config_changed();
    windows_config_changed();
    cursor_config_changed();
    icon_config_changed();
    if (was.rex_sidebar && !g_config.rex_sidebar)
        sidebar_off();
}

void chrome_reload_config(void) {
    reload_config();
}

static void debug_triggers(void) {
    NSString* trigger = debug_path(@"dump-now");
    if ([NSFileManager.defaultManager fileExistsAtPath:trigger]) {
        [NSFileManager.defaultManager removeItemAtPath:trigger error:nil];
        g_debug_clears = true;
        g_dump = [NSMutableString string];
        NSWindow* key = NSApp.keyWindow;
        NSResponder* first = key.firstResponder;
        [g_dump appendFormat:@"key window %@, first responder %@\n", key.title, first.className];
        [g_dump appendFormat:@"%@\n", cursor_describe()];
        if ([first isKindOfClass:NSView.class]) {
            NSMutableArray* up = [NSMutableArray array];
            for (NSView* v = (NSView*)first; v; v = v.superview)
                [up addObject:NSStringFromClass(v.class)];
            [g_dump appendFormat:@"first responder in %@\n", [up componentsJoinedByString:@" < "]];
        }
        for (NSString* c in g_clears)
            [g_dump appendFormat:@"clear %@\n", c];
        apply_all();
    }
    NSString* probe = debug_path(@"probe-now");
    if (NSString* path = [NSString stringWithContentsOfFile:probe encoding:NSUTF8StringEncoding error:nil]) {
        [NSFileManager.defaultManager removeItemAtPath:probe error:nil];
        path = [path stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        void* h = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        void (*run)(void) = h ? (void (*)(void))dlsym(h, "rexui_probe") : nullptr;
        rexui_log([NSString stringWithFormat:@"probe: %@ %s", path.lastPathComponent,
                                             run     ? "runs"
                                                 : h ? "has no rexui_probe"
                                                     : dlerror()]);
        if (run)
            run();
    }
    NSString* stats = debug_path(@"stats-now");
    if ([NSFileManager.defaultManager fileExistsAtPath:stats]) {
        [NSFileManager.defaultManager removeItemAtPath:stats error:nil];
        bool ok = rx::trace::write_json(debug_path(@"stats.json").fileSystemRepresentation);
        rexui_log(ok ? @"stats: build/stats.json" : @"stats: build/stats.json not written");
    }
}

static bool g_triggers_watched;
static void watch_triggers(void) {
    NSString* home = debug_home().stringByResolvingSymlinksInPath;
    if (!home.length)
        return;
    FSEventStreamContext ctx = {};
    FSEventStreamRef stream = FSEventStreamCreate(
        nullptr,
        [](ConstFSEventStreamRef, void*, size_t n, void* paths, const FSEventStreamEventFlags*,
           const FSEventStreamEventId*) {
            bool hit = false;
            for (size_t i = 0; i < n && !hit; i++) {
                const char *p = ((char**)paths)[i], *slash = strrchr(p, '/');
                const char* base = slash ? slash + 1 : p;
                hit = !strcmp(base, "dump-now") || !strcmp(base, "probe-now") || !strcmp(base, "stats-now");
            }
            if (hit)
                dispatch_async(dispatch_get_main_queue(), ^{
                    debug_triggers();
                });
        },
        &ctx, (__bridge CFArrayRef) @[home], kFSEventStreamEventIdSinceNow, 0.1,
        kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents);
    if (!stream)
        return;
    FSEventStreamSetDispatchQueue(stream, dispatch_get_main_queue());
    g_triggers_watched = FSEventStreamStart(stream);
    if (!g_triggers_watched)
        rexui_log(@"debug: FSEvents didn't start: build/*-now looked for every 3 s");
}

__attribute__((constructor)) static void rexui_init(void) {
    if (const char* off = getenv("REXUI_OFF"); off && off[0] == '1')
        return;
    rex_cache_prefetch();
    load_config();
    motion_config();
    rexui_watchdog_start();
    const char* dump = getenv("REX_TRANSPARENT_DUMP");
    g_debug = dump && dump[0] == '1';
    g_backgrounds = [NSHashTable weakObjectsHashTable];
    g_pane_area = [NSMapTable weakToStrongObjectsMapTable];
    g_saved_bg = [NSMapTable weakToStrongObjectsMapTable];
    g_saved_fill = [NSMapTable weakToStrongObjectsMapTable];

    swizzle([CALayer class], @selector(setBackgroundColor:), (IMP)hook_set_background, (IMP*)&orig_set_background);
    swizzle([CAShapeLayer class], @selector(setFillColor:), (IMP)hook_set_fill, (IMP*)&orig_set_fill);
    swizzle([CALayer class], @selector(setBounds:), (IMP)hook_set_bounds, (IMP*)&orig_set_bounds);
    swizzle([CALayer class], @selector(setShadowOpacity:), (IMP)hook_set_shadow_opacity,
            (IMP*)&orig_set_shadow_opacity);
    swizzle([CALayer class], @selector(setFrame:), (IMP)hook_set_frame, (IMP*)&orig_set_frame);
    swizzle([CAShapeLayer class], @selector(setPath:), (IMP)hook_set_path, (IMP*)&orig_set_path);
    swizzle([CALayer class], @selector(setMask:), (IMP)hook_set_mask, (IMP*)&orig_set_mask);
    swizzle([CALayer class], @selector(setTransform:), (IMP)hook_set_transform, (IMP*)&orig_set_transform);
    swizzle([CALayer class], @selector(setSublayerTransform:), (IMP)hook_set_sublayer_transform,
            (IMP*)&orig_set_sublayer_transform);
    swizzle([CALayer class], @selector(setAffineTransform:), (IMP)hook_set_affine_transform,
            (IMP*)&orig_set_affine_transform);
    swizzle([NSCursor class], @selector(set), (IMP)hook_cursor_set, (IMP*)&orig_cursor_set);
    if (Class section = NSClassFromString(@"NSWindowSectionController")) {
        SEL sel = NSSelectorFromString(@"_updatePendingRegistrations");
        if (class_getInstanceMethod(section, sel))
            swizzle(section, sel, (IMP)hook_section_pending, (IMP*)&orig_section_pending);
    }
    swizzle([CALayer class], @selector(addAnimation:forKey:), (IMP)hook_add_animation, (IMP*)&orig_add_animation);
    swizzle([CALayer class], @selector(setOpaque:), (IMP)hook_set_opaque, (IMP*)&orig_set_opaque);
    swizzle([CALayer class], @selector(addSublayer:), (IMP)hook_add_sublayer, (IMP*)&orig_add_sublayer);
    swizzle([CALayer class], @selector(insertSublayer:atIndex:), (IMP)hook_insert_at, (IMP*)&orig_insert_at);
    swizzle([CALayer class], @selector(insertSublayer:below:), (IMP)hook_insert_below, (IMP*)&orig_insert_below);
    swizzle([CALayer class], @selector(insertSublayer:above:), (IMP)hook_insert_above, (IMP*)&orig_insert_above);
    swizzle([CALayer class], @selector(replaceSublayer:with:), (IMP)hook_replace_sublayer,
            (IMP*)&orig_replace_sublayer);
    if (backdrop_class()) {
        swizzle(backdrop_class(), @selector(setHidden:), (IMP)hook_backdrop_set_hidden,
                (IMP*)&orig_backdrop_set_hidden);
    }
    if (tabbar_class()) {
        swizzle(tabbar_class(), @selector(setHidden:), (IMP)hook_tabbar_set_hidden, (IMP*)&orig_tabbar_set_hidden);
    }
    if (chrome_class())
        swizzle(chrome_class(), @selector(layout), (IMP)hook_chrome_layout, (IMP*)&orig_chrome_layout);
    if (actions_class()) {
        swizzle(actions_class(), @selector(setHidden:), (IMP)hook_actions_set_hidden, (IMP*)&orig_actions_set_hidden);
        swizzle(actions_class(), @selector(viewDidMoveToWindow), (IMP)hook_actions_did_move,
                (IMP*)&orig_actions_did_move);
    }
    if (term_scroll_class()) {
        swizzle(term_scroll_class(), @selector(setHasVerticalScroller:), (IMP)hook_set_has_scroller,
                (IMP*)&orig_set_has_scroller);
    } else {
        rexui_log(@"hooks: no terminal scroller class (pane-scrollbars has no effect)");
    }
    scroll_install();
    swizzle([NSWindow class], @selector(setBackgroundColor:), (IMP)hook_window_set_background,
            (IMP*)&orig_window_set_background);
    install_command_hooks();
    notices_init();
    files_init();
    icon_init();
    links_init();
    Class attachment = [[MTLRenderPassDescriptor renderPassDescriptor].colorAttachments[0] class];
    swizzle(attachment, @selector(setClearColor:), (IMP)hook_set_clear, (IMP*)&orig_set_clear);
    hook_other_clear_classes(attachment);

    dispatch_async(dispatch_get_main_queue(), ^{
        rex_tabs_start();
        cursor_config_changed();
        icon_config_changed();
        g_dirty = [NSMutableSet set];
        CFRunLoopObserverRef obs =
            CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, kCFRunLoopBeforeWaiting | kCFRunLoopExit, true,
                                               1999000, ^(CFRunLoopObserverRef, CFRunLoopActivity) {
                                                   process_dirty(watched_due());
                                               });
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, kCFRunLoopCommonModes);

        NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
        for (NSNotificationName n in @[NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification]) {
            [nc addObserverForName:n
                            object:nil
                             queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification*) {
                            apply_all();
                            dispatch_async(dispatch_get_main_queue(), ^{
                                apply_all();
                            });
                        }];
        }
        ui_init();
        panes_init();
        tabs_poll_start();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (g_debug)
                g_dump = [NSMutableString string];
            apply_all();
            chrome_relayout();
            watch_triggers();
            NSTimer* safety = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                              repeats:YES
                                                                block:^(NSTimer*) {
                                                                    RX_INTERVAL(timer, "safety_pass");
                                                                    static int n;
                                                                    n++;
                                                                    if (!g_watching || n % 10 == 0)
                                                                        reload_config();
                                                                    if (!g_triggers_watched)
                                                                        debug_triggers();
                                                                    if (n % 100 == 0) {
                                                                        g_log_misses = true;
                                                                        apply_all();
                                                                        g_log_misses = false;
                                                                    }
                                                                }];
            safety.tolerance = 0.3;
        });
    });
}
