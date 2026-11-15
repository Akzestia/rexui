// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include <objc/runtime.h>
#include <spawn.h>
#include <sys/wait.h>
#include "base/trace.h"
#include "rex/rex.h"
#include "web/web.h"

extern char** environ;

void ui_config_changed(void) {
    scan();
    tabpreview_config_changed();
    shaders_panes_changed();
    shaders_config_changed();
    web_config_changed();
    for (RXDoc* doc in g_docs) {
        if (doc.ctx)
            set_conf(doc);
    }
}

void ui_theme_changed(void) {
    update_theme();
    for (RXDoc* doc in g_docs) {
        if (doc.ctx)
            set_theme(doc);
        if (doc.root)
            refresh_theme(doc.root);
    }
    chrome_relayout();
}

void ui_tabs_changed(int active, NSArray<NSString*>* titles) {
    g_tab = active;
    rexstate_tab_changed(g_session_id, active);
    g_tab_titles = titles;
    for (RXDoc* doc in g_docs) {
        if (doc.ctx)
            set_rex(doc);
    }
}

void ui_tabs_changed_shown(int active, NSArray<NSString*>* titles) {
    g_tab = active;
    g_tab_titles = titles;
    for (RXDoc* doc in g_docs) {
        if (doc.ctx)
            set_rex(doc);
    }
}

void ui_session_changed(NSString* session_id, NSString* label, NSArray<NSDictionary*>* sessions) {
    g_session_id = session_id;
    g_session = label;
    g_sessions = sessions;
    for (RXDoc* doc in g_docs) {
        if (doc.ctx)
            set_rex(doc);
    }
}

NSWindow* ui_dock_window(void) {
    return dock_window();
}

NSColor* ui_accent(void) {
    for (RXDoc* doc in g_docs) {
        if (doc.root && is_elem(doc.root, E::Dock)) {
            if (NSColor* c = parse_color(str(doc.root, P::accent, @"")))
                return c;
        }
    }
    return nil;
}

void memory_pressure_init(void);

bool ui_event(NSEvent* e) {
    if (menu_open_now()
        && (e.type == NSEventTypeLeftMouseDown || e.type == NSEventTypeRightMouseDown
            || e.type == NSEventTypeOtherMouseDown)
        && menu_press(e))
        return true;
    switch (e.type) {
    case NSEventTypeLeftMouseDragged:
    case NSEventTypeLeftMouseUp:
        return bar_carry_event(e) || ui_press_event(e);
    case NSEventTypeKeyDown:
        return bar_carry_event(e);
    case NSEventTypeOtherMouseDown:
        return on_mouse(e) == nil || ui_press_event(e);
    case NSEventTypeMouseMoved:
    case NSEventTypeMouseEntered:
    case NSEventTypeMouseExited:
    case NSEventTypeCursorUpdate:
        float_bar_pointer(e);
        corner_pointer(e);
        return drawer_pointer(e) == nil;
    case NSEventTypeLeftMouseDown:
    case NSEventTypeRightMouseDown:
        drawer_click(e);
        bar_search_click(e);
        outside_click(e);
        return context_right_click(e) || ui_press_event(e);
    case NSEventTypeFlagsChanged:
        debug_flags_changed(e), term_flags_changed();
        return false;
    case NSEventTypeRightMouseUp:
        return context_right_click(e) || ui_press_event(e);
    case NSEventTypeRightMouseDragged:
    case NSEventTypeOtherMouseDragged:
    case NSEventTypeOtherMouseUp:
    case NSEventTypeScrollWheel:
        return ui_press_event(e);
    default:
        return false;
    }
}

void stat_files(NSArray<NSString*>* paths, void (^then)(NSDictionary<NSString*, id>*)) {
    NSArray<NSString*>* list = [paths copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableDictionary<NSString*, id>* out = [NSMutableDictionary dictionaryWithCapacity:list.count];
        for (NSString* p in list)
            if (!out[p])
                out[p] = [NSFileManager.defaultManager attributesOfItemAtPath:p error:nil].fileModificationDate
                    ?: (id)NSNull.null;
        dispatch_async(dispatch_get_main_queue(), ^{
            then(out);
        });
    });
}

void ui_init(void) {
    rx::trace::watch_turns();
    power_init();
    memory_pressure_init();
    g_docs = [NSMutableArray array];
    g_slots = [NSMutableDictionary dictionary];
    g_state = [[NSUserDefaults alloc] initWithSuiteName:rexui_suite()];
    rexstate_init();
    debug_init();
    g_webs = [NSHashTable weakObjectsHashTable];
    g_write_queue = dispatch_queue_create("rexui.stdin", DISPATCH_QUEUE_SERIAL);
    update_theme();
    NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:NSWindowDidBecomeMainNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification* note) {
                    NSWindow* w = note.object;
                    if (!is_rex_window(w) || w == g_window)
                        return;
                    g_window = w;
                    chrome_relayout();
                }];
    [nc addObserverForName:NSApplicationWillTerminateNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification*) {
                    for (RXDoc* doc in [g_docs copy])
                        unload(doc);
                    sessions_flush();
                }];
    [nc addObserverForName:NSWindowDidChangeOcclusionStateNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification* note) {
                    NSWindow* w = note.object;
                    if (w != dock_window() || getenv("REXUI_IGNORE_OCCLUSION"))
                        return;
                    const bool hidden = !(w.occlusionState & NSWindowOcclusionStateVisible);
                    if (hidden) {
                        NSMutableArray* over = [NSMutableArray array];
                        NSArray* list = CFBridgingRelease(CGWindowListCopyWindowInfo(
                            kCGWindowListOptionOnScreenAboveWindow, (CGWindowID)w.windowNumber));
                        for (NSDictionary* d in list) {
                            CGRect b = CGRectZero;
                            CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)d[(id)kCGWindowBounds],
                                                                   &b);
                            if (b.size.width < 2 || b.size.height < 2 || [d[(id)kCGWindowLayer] intValue] < 0)
                                continue;
                            [over
                                addObject:[NSString stringWithFormat:@"%@ (layer %@, %.0fx%.0f, alpha %.2f)",
                                                                     d[(id)kCGWindowOwnerName] ?: @"?",
                                                                     d[(id)kCGWindowLayer], b.size.width, b.size.height,
                                                                     [d[(id)kCGWindowAlpha] doubleValue]]];
                        }
                        rexui_log_file([NSString
                            stringWithFormat:@"occlusion: unseen%@; over it: %@",
                                             panes_file_full_in(w)  ? @" (a file over the whole window)"
                                                 : panes_full_in(w) ? @" (an app over the whole window)"
                                                                    : @"",
                                             over.count ? [over componentsJoinedByString:@", "] : @"nothing"]);
                    }
                    ui_clock_occluded(hidden);
                    if (!hidden)
                        shaders_shown(w.contentView.superview.layer ?: w.contentView.layer);
                }];
    loading_start();
    scan();
    watch_config();
    scan_notify_init();
    NSArray<void (^)(void)>* every_second = @[
        ^{
            static int n;
            if (!g_watching || ++n % 120 == 0)
                scan();
            loading_scan();
        },
        ^{
            static int n;
            if (!g_watching || ++n % 60 == 0) {
                check_backends();
                shader_check();
                syntax_check();
            }
            fps_update();
            static int k;
            if (++k % 5 == 0)
                budgets_check();
        },
        ^{
            activity_update();
        },
        ^{
            rex_wrap_closures();
        },
        ^{
            diagnostics_update();
        },
        ^{
            rexstate_layout();
        },
    ];
    static const char* const names[] = {"every_second: scan",        "every_second: backends, shaders, fps",
                                        "every_second: activity",    "every_second: Rex's closures",
                                        "every_second: diagnostics", "every_second: Rex's layout"};
    static_assert(sizeof names / sizeof names[0] == 6);
    for (NSUInteger i = 0; i < every_second.count && i < 6; i++) {
        void (^step)(void) = every_second[i];
        const char* name = names[i];
        NSTimer* t = [[NSTimer alloc] initWithFireDate:[NSDate dateWithTimeIntervalSinceNow:1.0 + 0.1 * i]
                                              interval:1.0
                                               repeats:YES
                                                 block:^(NSTimer*) {
                                                     RX_INTERVAL(timer, name);
                                                     step();
                                                 }];
        t.tolerance = 0.1;
        [NSRunLoop.mainRunLoop addTimer:t forMode:NSDefaultRunLoopMode];
    }
    NSTimer* web = [NSTimer scheduledTimerWithTimeInterval:10.0
                                                   repeats:YES
                                                     block:^(NSTimer*) {
                                                         RX_INTERVAL(timer, "every 10 s: web pages");
                                                         web_visibility();
                                                         suspend_hidden();
                                                         for (RXNode* n in g_webs.allObjects) {
                                                             if (n.doc && on_screen(n) && !n.waiting)
                                                                 session_save(n);
                                                         }
                                                     }];
    web.tolerance = 1;
}

id ui_pane_open(NSString* path, NSString* block, NSArray<NSString*>* args, NSString* program) {
    RXDoc* doc = [RXDoc new];
    doc.path = path;
    doc.pane = true;
    doc.pane_block = block;
    doc.pane_program = program;
    doc.pane_args = args ?: @[];
    doc.mtime = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil].fileModificationDate;
    [g_docs addObject:doc];
    load(doc);
    return doc;
}

NSView* ui_pane_view(id d) {
    return pane_root((RXDoc*)d, true);
}

static NSString* pane_tool(void) {
    NSString* home = NSProcessInfo.processInfo.environment[@"REXUI_HOME"];
    NSString* mine = home ? [home stringByAppendingPathComponent:@"../src/cli/rexui"].stringByStandardizingPath : nil;
    if (mine && [NSFileManager.defaultManager isExecutableFileAtPath:mine])
        return mine;
    NSString* bin = [NSHomeDirectory() stringByAppendingPathComponent:@".local/bin/rexui"];
    return [NSFileManager.defaultManager isExecutableFileAtPath:bin] ? bin : nil;
}

void ui_open_pane(NSString* widget, NSDictionary* o, void (^failed)(void)) {
    if (!widget.length || !g_session_id.length)
        return;
    NSURL* web = [widget hasPrefix:@"http://"] || [widget hasPrefix:@"https://"] ? [NSURL URLWithString:widget] : nil;
    NSString* path = web ? widget
        : [widget hasSuffix:@".rui"]
        ? widget.stringByExpandingTildeInPath
        : [[ui_dir() stringByAppendingPathComponent:@"panes"]
              stringByAppendingPathComponent:[widget stringByAppendingPathExtension:@"rui"]];
    if (!web && !path.isAbsolutePath)
        path = [ui_dir() stringByAppendingPathComponent:path];
    if (!web && ![NSFileManager.defaultManager fileExistsAtPath:path]) {
        rexui_log([@"openPane: no widget " stringByAppendingString:path]);
        if (failed)
            failed();
        return;
    }
    NSDictionary* last = panes_last_block();
    if (id in = o[@"in"]; truthy_of(in)) {
        NSString* block = [in isKindOfClass:NSString.class] ? in : string_of(last[@"block"]);
        NSString* session = [in isKindOfClass:NSString.class] ? g_session_id : string_of(last[@"session"]);
        if (![block hasPrefix:@"block:"] || !ui_pane_here(path, block, session ?: g_session_id, nil)) {
            rexui_log([NSString stringWithFormat:@"openPane: nothing shown in %@", block ?: @"no pane"]);
            if (failed)
                failed();
        }
        return;
    }
    NSMutableArray* args = [NSMutableArray array];
    if (truthy_of(o[@"cwd"])) {
        NSString* cwd = nil;
        for (NSDictionary* e in (__bridge_transfer NSArray*)rex_activity())
            if ([e[@"block"] isEqual:last[@"block"]] && [e[@"cwd"] length])
                cwd = e[@"cwd"];
        if (cwd)
            [args addObject:cwd];
    }
    for (id a in [o[@"args"] isKindOfClass:NSArray.class] ? o[@"args"] : @[])
        if ([a isKindOfClass:NSString.class])
            [args addObject:[a stringByExpandingTildeInPath]];
    NSDictionary* block = @{
        @"flavor": @"com.superlogical.terminal.shell",
        @"label": web ? (web.host ?: @"web") : path.lastPathComponent.stringByDeletingPathExtension,
        @"options": @{@"command": [@[pane_tool() ?: @"rexui", @"pane", path] arrayByAddingObjectsFromArray:args]}
    };
    bool focus = truthy_of(o[@"focus"], true);
    NSMutableDictionary* req =
        [@{@"session_id": g_session_id,
           @"focus": @(focus),
           @"layout": @{@"block": block}} mutableCopy];
    NSString* method = @"session.new_split";
    if (truthy_of(o[@"floating"])) {
        method = @"session.new_layer";
        NSArray* bounds = o[@"bounds"];
        req[@"bounds"] =
            [bounds isKindOfClass:NSArray.class] && bounds.count == 4 ? bounds : @[@0.15, @0.12, @0.7, @0.72];
    } else {
        req[@"direction"] = [o[@"direction"] isEqual:@"vertical"] ? @"vertical" : @"horizontal";
        req[@"side"] = [o[@"side"] isEqual:@"before"] ? @"before" : @"after";
        if ([o[@"anchor"] isKindOfClass:NSString.class] && [o[@"anchor"] length])
            req[@"anchor_id"] = o[@"anchor"];
        else if ([last[@"block"] length] && [last[@"session"] isEqual:g_session_id])
            req[@"anchor_id"] = last[@"block"];
    }
    NSString* json = [[NSString alloc] initWithData:json_data(req, 0) encoding:NSUTF8StringEncoding];
    static dispatch_queue_t q = dispatch_queue_create("rexui.open-pane", DISPATCH_QUEUE_SERIAL);
    dispatch_async(q, ^{
        NSString* err = nil;
        if (rex_cli(@[@"api", @"call", method, json], &err))
            return;
        rexui_log([@"openPane: no pane: " stringByAppendingString:err ?: @"?"]);
        if (failed)
            dispatch_async(dispatch_get_main_queue(), failed);
    });
}

pid_t ui_pane_here(NSString* path, NSString* block, NSString* session, void (^ended)(void)) {
    if (!path.length || ![block hasPrefix:@"block:"])
        return 0;
    NSString* tool = pane_tool();
    if (!tool) {
        rexui_log(@"the rexui command isn't installed (just cli::install)");
        return 0;
    }
    NSMutableArray<NSString*>* env = [NSMutableArray array];
    for (char** e = environ; *e; e++) {
        NSString* kv = @(*e);
        if (![kv hasPrefix:@"DYLD_INSERT_LIBRARIES="] && ![kv hasPrefix:@"REX_BLOCK="]
            && ![kv hasPrefix:@"REX_SESSION="])
            [env addObject:kv];
    }
    [env addObject:[@"REX_BLOCK=" stringByAppendingString:block]];
    if (session.length)
        [env addObject:[@"REX_SESSION=" stringByAppendingString:session]];
    std::vector<char*> argv = {strdup(tool.fileSystemRepresentation), strdup("pane"),
                               strdup(path.fileSystemRepresentation), nullptr};
    std::vector<char*> envp;
    for (NSString* kv in env)
        envp.push_back(strdup(kv.UTF8String));
    envp.push_back(nullptr);
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);
    pid_t pid = 0;
    int rc = posix_spawn(&pid, argv[0], &fa, &attr, argv.data(), envp.data());
    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&attr);
    for (char* a : argv)
        free(a);
    for (char* e : envp)
        free(e);
    if (rc != 0) {
        rexui_log([NSString stringWithFormat:@"rexui pane didn't start: %s", strerror(rc)]);
        return 0;
    }
    dispatch_source_t src =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, pid, DISPATCH_PROC_EXIT, dispatch_get_main_queue());
    dispatch_source_set_event_handler(src, ^{
        int status;
        waitpid(pid, &status, WNOHANG);
        dispatch_source_cancel(src);
        if (ended)
            ended();
    });
    dispatch_resume(src);
    return pid;
}

void ui_pane_layout(id d, NSRect bounds) {
    RXDoc* doc = d;
    RXRoot* v = pane_root(doc, false);
    if (!v.superview)
        return;
    NSAppearance* look = [NSAppearance appearanceNamed:g_theme.dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
    if (![v.appearance.name isEqualToString:look.name])
        v.appearance = look;
    if (NSWindow* win = v.superview.window) {
        CGFloat s = win.backingScaleFactor ?: 1;
        NSRect w = [v.superview convertRect:bounds toView:nil];
        CGFloat x0 = floor(NSMinX(w) * s) / s, y0 = floor(NSMinY(w) * s) / s, x1 = ceil(NSMaxX(w) * s) / s,
                y1 = ceil(NSMaxY(w) * s) / s;
        bounds = [v.superview convertRect:NSMakeRect(x0, y0, x1 - x0, y1 - y0) fromView:nil];
    }
    if (!NSEqualRects(v.frame, bounds))
        v.frame = bounds;
    place(doc.root, NSMakeRect(0, 0, bounds.size.width, bounds.size.height));
    place_natives(doc);
    NSSize size = bounds.size;
    NSValue* was = objc_getAssociatedObject(doc, "rexui.pane.size");
    if (doc.ctx && (!was || !NSEqualSizes(was.sizeValue, size))) {
        objc_setAssociatedObject(doc, "rexui.pane.size", [NSValue valueWithSize:size],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        doc_call(doc, @"setPane", @[@{@"width": @(size.width), @"height": @(size.height)}]);
    }
}

void ui_pane_close(id d) {
    RXDoc* doc = d;
    unload(doc);
    [g_docs removeObject:doc];
    sessions_forget_pane(doc);
}

NSString* ui_web_pane_file(void) {
    NSString* own = [ui_dir() stringByAppendingPathComponent:@"panes/web.rui"];
    if ([NSFileManager.defaultManager fileExistsAtPath:own])
        return own;
    NSString* home = NSProcessInfo.processInfo.environment[@"REXUI_HOME"]
        ?: [NSHomeDirectory() stringByAppendingPathComponent:@"rexui/build"];
    return [home.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"src/ui/panes/web.rui"];
}
