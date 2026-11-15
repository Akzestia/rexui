// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "base/rexapi.h"
#include "chrome/chrome.h"
#include "rex/rex.h"

static double g_allow_config_until;
static double g_pass_until;
static void (^g_lend)(NSWindow*);
static double g_lend_until;
static __weak NSWindow* g_lent;
static bool g_lending;

static double now(void) {
    return NSProcessInfo.processInfo.systemUptime;
}
static double g_launched = now();
static bool starting(void) {
    return now() - g_launched < 8;
}

static bool lending(void) {
    if (g_lend && now() > g_lend_until) {
        g_lend = nil;
        g_lending = false;
        rexui_log(@"commands: lend: no settings window came up");
    }
    return g_lending;
}

static bool is_settings_window(NSWindow* w) {
    if (!w || [w isKindOfClass:[NSPanel class]])
        return false;
    NSString* settings = RXNS(RXN_166);
    if ([w.identifier containsString:settings] || [w.frameAutosaveName containsString:settings] ||
        [NSStringFromClass(w.class) containsString:settings] || [w.title hasPrefix:settings])
        return true;
    return g_lend && !is_rex_window(w) && w.frame.size.width >= 400 && w.frame.size.height >= 300;
}

static void lend(NSWindow* w);
static BOOL (*orig_send_action)(id, SEL, SEL, id, id);
static BOOL hook_send_action(NSApplication* self, SEL sel, SEL action, id target, id sender);
static void (*orig_send_event)(id, SEL, NSEvent*);
static void hook_send_event(NSApplication* self, SEL sel, NSEvent* e);
static void (*orig_order_window)(id, SEL, NSWindowOrderingMode, NSInteger);

static void send_away(NSWindow* w) {
    w.restorable = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (w.isVisible)
            orig_order_window(w, @selector(orderWindow:relativeTo:), NSWindowOut, 0);
        [w close];
    });
}

static void reopen_one_window(void) {
    NSUserDefaults* d = NSUserDefaults.standardUserDefaults;
    NSData* data = [d dataForKey:RXNS(RXN_167)];
    NSArray* all = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![all isKindOfClass:NSArray.class] || all.count < 2)
        return;
    NSData* last = [d dataForKey:RXNS(RXN_170)];
    NSDictionary* focused = last ? [NSJSONSerialization JSONObjectWithData:last options:0 error:nil] : nil;
    id keep = all.firstObject;
    for (id w in all) {
        if (![w isKindOfClass:NSDictionary.class] || ![focused isKindOfClass:NSDictionary.class])
            continue;
        id session = w[RXNS(RXN_136)];
        if ([session isKindOfClass:NSDictionary.class] && [session[RXNS(RXN_137)] isEqual:focused[RXNS(RXN_137)]])
            keep = w;
    }
    NSData* one = json_data(@[keep], 0);
    if (!one)
        return;
    [d setObject:one forKey:RXNS(RXN_167)];
    rexui_log([NSString stringWithFormat:@"commands: reopening 1 of Rex's %lu windows", (unsigned long)all.count]);
}

static __weak NSWindow* g_the_window;

static bool workspace_window(NSWindow* w) {
    return is_rex_window(w) && chrome_of(w);
}

static bool extra_window(NSWindow* w) {
    if (!g_config.single_window || !workspace_window(w))
        return false;
    NSWindow* k = g_the_window;
    if (!k || k == w || (!k.isVisible && !k.isMiniaturized)) {
        g_the_window = w;
        return false;
    }
    return true;
}

static NSWindow* the_window(void) {
    NSWindow* k = g_the_window;
    if (k && (k.isVisible || k.isMiniaturized))
        return k;
    for (NSWindow* w in NSApp.orderedWindows) {
        if ((w.isVisible || w.isMiniaturized) && workspace_window(w))
            return g_the_window = w;
    }
    return nil;
}

static void bring_the_window(void) {
    NSWindow* k = the_window();
    if (!k)
        return;
    if (k.isMiniaturized)
        [k deminiaturize:nil];
    [k makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

static bool is_new_window_item(id sender) {
    return [sender isKindOfClass:NSMenuItem.class] && [((NSMenuItem*)sender).title isEqualToString:@"New Window"];
}

static NSHashTable<NSWindow*>* g_unsure;

static void hold_unsure(NSWindow* w) {
    NSWindow* k = the_window();
    if (!g_config.single_window || !k || k == w || !is_rex_window(w) || chrome_of(w))
        return;
    if (!g_unsure)
        g_unsure = [NSHashTable weakObjectsHashTable];
    if ([g_unsure containsObject:w])
        return;
    [g_unsure addObject:w];
    w.alphaValue = 0;
    __weak NSWindow* weak = w;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSWindow* w2 = weak;
        if (!w2 || ![g_unsure containsObject:w2])
            return;
        [g_unsure removeObject:w2];
        if (!extra_window(w2))
            w2.alphaValue = 1;
    });
}

static void send_away_extra(NSWindow* w, NSString* how) {
    [g_unsure removeObject:w];
    rexui_log([NSString stringWithFormat:@"commands: a second window %@ (single-window)", how]);
    send_away(w);
    dispatch_async(dispatch_get_main_queue(), ^{
        bring_the_window();
    });
}

static bool guarding(void) {
    return [g_config.rex_windows isEqualToString:@"rexui"];
}
static NSMutableDictionary<NSString*, NSNumber*>* g_taken;
static NSMapTable<NSWindow*, NSNumber*>* g_let;
static NSHashTable<NSWindow*>* g_deciding;

static bool other_window(NSWindow* w) {
    if (!w || w == g_lent || [w isKindOfClass:NSPanel.class] || w.sheetParent || w.isSheet)
        return false;
    if (![NSStringFromClass(w.class) hasPrefix:@"SwiftUI."])
        return false;
    return ![w.identifier hasPrefix:RXNS(RXN_136)] && !workspace_window(w) && !is_settings_window(w);
}

static NSString* command_of(NSWindow* w) {
    NSString* id = w.identifier.length ? w.identifier : @"window";
    return [id isEqualToString:@"diagnostics"] ? @"client.diagnostics" : [@"window:" stringByAppendingString:id];
}

static bool let_through(NSWindow* w) {
    NSNumber* t = [g_let objectForKey:w];
    return t && now() - t.doubleValue < 2;
}

static bool hold_other(NSWindow* w) {
    if (!other_window(w) || let_through(w))
        return false;
    if (!g_let)
        g_let = [NSMapTable weakToStrongObjectsMapTable];
    if (now() < g_pass_until) {
        [g_let setObject:@(now()) forKey:w];
        return false;
    }
    if (!guarding() && !windows_delegated())
        return false;
    if (!g_deciding)
        g_deciding = [NSHashTable weakObjectsHashTable];
    if ([g_deciding containsObject:w])
        return true;
    [g_deciding addObject:w];
    NSDictionary* info = @{@"id": w.identifier ?: @"", @"title": w.title ?: @"", @"command": command_of(w)};
    __weak NSWindow* weak = w;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSWindow* w2 = weak;
        if (!w2)
            return;
        [g_deciding removeObject:w2];
        NSString* way = windows_ask(info) ?: (guarding() ? @"docks" : @"rex");
        if ([way isEqualToString:@"rex"]) {
            [g_let setObject:@(now()) forKey:w2];
            w2.alphaValue = 1;
            [w2 makeKeyAndOrderFront:nil];
            return;
        }
        send_away(w2);
        if (starting())
            return;
        static NSMutableDictionary<NSString*, NSNumber*>* routed = [NSMutableDictionary dictionary];
        NSString* command = info[@"command"];
        bool again = now() - [routed[command] doubleValue] < 2 || now() - [g_taken[command] doubleValue] < 2;
        routed[command] = @(now());
        if (again)
            return;
        bool taken = ui_command(command);
        rexui_log([NSString stringWithFormat:@"commands: Rex's %@ window held back%@", info[@"id"],
                                             taken ? @"" : @" (no Drawer takes it)"]);
        windows_held(info);
    });
    return true;
}

static bool hold_back(NSWindow* w) {
    if (extra_window(w)) {
        send_away_extra(w, @"held back");
        return true;
    }
    hold_unsure(w);
    if (hold_other(w))
        return true;
    if (!is_settings_window(w))
        return false;
    if (lending() && g_lend) {
        lend(w);
        return true;
    }
    if (w == g_lent)
        return true;
    static double last;
    if (now() - last > 0.5) {
        last = now();
        if (!starting())
            ui_command(@"client.settings");
        send_away(w);
    }
    return true;
}

static void (*orig_make_key_front)(id, SEL, id);
static void hook_make_key_front(NSWindow* self, SEL sel, id sender) {
    if (!self.isVisible && hold_back(self))
        return;
    orig_make_key_front(self, sel, sender);
}

static void (*orig_order_front)(id, SEL, id);
static void hook_order_front(NSWindow* self, SEL sel, id sender) {
    if (!self.isVisible && hold_back(self))
        return;
    orig_order_front(self, sel, sender);
}

static void (*orig_order_regardless)(id, SEL);
static void hook_order_regardless(NSWindow* self, SEL sel) {
    if (!self.isVisible && hold_back(self))
        return;
    orig_order_regardless(self, sel);
}

static void (*orig_set_visible)(id, SEL, BOOL);
static void hook_set_visible(NSWindow* self, SEL sel, BOOL visible) {
    if (visible && !self.isVisible && hold_back(self))
        return;
    orig_set_visible(self, sel, visible);
}

static void (*orig_make_key)(id, SEL);
static void hook_make_key(NSWindow* self, SEL sel) {
    if (!self.isVisible && hold_back(self))
        return;
    orig_make_key(self, sel);
}

static void (*orig_show_window)(id, SEL, id);
static void hook_show_window(NSWindowController* self, SEL sel, id sender) {
    NSWindow* w = self.window;
    if (w && !w.isVisible && hold_back(w))
        return;
    orig_show_window(self, sel, sender);
}

static void hook_order_window(NSWindow* self, SEL sel, NSWindowOrderingMode place, NSInteger other) {
    if (place != NSWindowOut && !self.isVisible && hold_back(self))
        return;
    orig_order_window(self, sel, place, other);
}

static void caught_late(NSWindow* w) {
    if (w.isVisible && extra_window(w)) {
        send_away_extra(w, [g_unsure containsObject:w] ? @"sent away unseen" : @"got past the hooks, sent away");
        return;
    }
    if (w.isVisible && other_window(w) && !let_through(w) && hold_other(w)) {
        w.alphaValue = 0;
        return;
    }
    if (!w.isVisible || !is_settings_window(w) || w == g_lent)
        return;
    if (lending() && g_lend) {
        lend(w);
        return;
    }
    rexui_log([NSString
        stringWithFormat:@"commands: settings window got past the hooks (%@), sent away", NSStringFromClass(w.class)]);
    if (!starting())
        ui_command(@"client.settings");
    send_away(w);
}

static bool is_config(NSURL* url) {
    return url.isFileURL && [url.lastPathComponent isEqualToString:@"init.lua"];
}

static bool hold_config(NSArray<NSURL*>* urls) {
    bool config = false;
    for (NSURL* u in urls)
        config = config || is_config(u);
    if (!config || now() < g_allow_config_until)
        return false;
    return ui_command(@"client.config.open");
}

static BOOL (*orig_open_url)(id, SEL, NSURL*);
static BOOL hook_open_url(NSWorkspace* self, SEL sel, NSURL* url) {
    if (url && hold_config(@[url]))
        return YES;
    return orig_open_url(self, sel, url);
}

using OpenDone = void (^)(NSRunningApplication*, NSError*);
static void (*orig_open_url_config)(id, SEL, NSURL*, id, OpenDone);
static void hook_open_url_config(NSWorkspace* self, SEL sel, NSURL* url, id config, OpenDone done) {
    if (url && hold_config(@[url])) {
        if (done)
            done(nil, nil);
        return;
    }
    orig_open_url_config(self, sel, url, config, done);
}

static void (*orig_open_urls_app)(id, SEL, NSArray<NSURL*>*, NSURL*, id, OpenDone);
static void hook_open_urls_app(NSWorkspace* self, SEL sel, NSArray<NSURL*>* urls, NSURL* app, id config,
                               OpenDone done) {
    if (hold_config(urls)) {
        if (done)
            done(nil, nil);
        return;
    }
    orig_open_urls_app(self, sel, urls, app, config, done);
}

static BOOL (*orig_open_file)(id, SEL, NSString*);
static BOOL hook_open_file(NSWorkspace* self, SEL sel, NSString* path) {
    if (path && hold_config(@[[NSURL fileURLWithPath:path]]))
        return YES;
    return orig_open_file(self, sel, path);
}

static void (*orig_activate_ignoring)(id, SEL, BOOL);
static void hook_activate_ignoring(NSApplication* self, SEL sel, BOOL flag) {
    if (lending())
        return;
    orig_activate_ignoring(self, sel, flag);
}

static void (*orig_activate)(id, SEL);
static void hook_activate(NSApplication* self, SEL sel) {
    if (lending())
        return;
    orig_activate(self, sel);
}

static BOOL (*orig_app_activate)(id, SEL, NSApplicationActivationOptions);
static BOOL hook_app_activate(NSRunningApplication* self, SEL sel, NSApplicationActivationOptions o) {
    if (lending() && self.processIdentifier == getpid())
        return NO;
    return orig_app_activate(self, sel, o);
}

void sidebar_watch(void);

void install_command_hooks(void) {
    reopen_one_window();
    sidebar_watch();
    Class w = [NSWindow class], ws = [NSWorkspace class];
    swizzle(w, @selector(makeKeyAndOrderFront:), (IMP)hook_make_key_front, (IMP*)&orig_make_key_front);
    swizzle(w, @selector(orderFront:), (IMP)hook_order_front, (IMP*)&orig_order_front);
    swizzle(w, @selector(orderFrontRegardless), (IMP)hook_order_regardless, (IMP*)&orig_order_regardless);
    swizzle(w, @selector(orderWindow:relativeTo:), (IMP)hook_order_window, (IMP*)&orig_order_window);
    swizzle(w, @selector(setIsVisible:), (IMP)hook_set_visible, (IMP*)&orig_set_visible);
    swizzle(w, @selector(makeKeyWindow), (IMP)hook_make_key, (IMP*)&orig_make_key);
    swizzle([NSWindowController class], @selector(showWindow:), (IMP)hook_show_window, (IMP*)&orig_show_window);
    swizzle([NSApplication class], @selector(sendAction:to:from:), (IMP)hook_send_action, (IMP*)&orig_send_action);
    swizzle([NSApplication class], @selector(sendEvent:), (IMP)hook_send_event, (IMP*)&orig_send_event);
    swizzle(ws, @selector(openURL:), (IMP)hook_open_url, (IMP*)&orig_open_url);
    swizzle(ws, @selector(openURL:configuration:completionHandler:), (IMP)hook_open_url_config,
            (IMP*)&orig_open_url_config);
    swizzle(ws, @selector(openURLs:withApplicationAtURL:configuration:completionHandler:), (IMP)hook_open_urls_app,
            (IMP*)&orig_open_urls_app);
    swizzle(ws, @selector(openFile:), (IMP)hook_open_file, (IMP*)&orig_open_file);
    swizzle([NSApplication class], @selector(activateIgnoringOtherApps:), (IMP)hook_activate_ignoring,
            (IMP*)&orig_activate_ignoring);
    swizzle([NSRunningApplication class], @selector(activateWithOptions:), (IMP)hook_app_activate,
            (IMP*)&orig_app_activate);
    if ([NSApplication instancesRespondToSelector:@selector(activate)]) {
        swizzle([NSApplication class], @selector(activate), (IMP)hook_activate, (IMP*)&orig_activate);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSNotificationName name in @[
                 NSWindowDidBecomeKeyNotification, NSWindowDidBecomeMainNotification,
                 NSWindowDidChangeOcclusionStateNotification, NSWindowDidUpdateNotification
             ]) {
            [NSNotificationCenter.defaultCenter addObserverForName:name
                                                            object:nil
                                                             queue:nil
                                                        usingBlock:^(NSNotification* note) {
                                                            caught_late(note.object);
                                                        }];
        }
    });
}

static NSData* rex_direct(NSArray<NSString*>* args, NSString** error, bool* handled) {
    *handled = false;
    NSString* method = nil;
    NSMutableDictionary* payload = [NSMutableDictionary dictionary];
    auto parse = [](NSString* json) -> NSDictionary* {
        id o = json.length
            ? [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil]
            : @{};
        return [o isKindOfClass:NSDictionary.class] ? o : nil;
    };
    NSUInteger n = args.count;
    if (n >= 3 && [args[0] isEqualToString:@"api"] && [args[1] isEqualToString:@"call"]) {
        NSUInteger at = 2;
        NSString* session = nil;
        if (n >= 5 && [args[2] isEqualToString:@"-s"])
            session = args[3], at = 4;
        if (at >= n || at + 2 < n || !rex_method_ok(args[at]))
            return nil;
        method = args[at];
        NSDictionary* p = parse(at + 1 < n ? args[at + 1] : @"");
        if (!p)
            return nil;
        [payload addEntriesFromDictionary:p];
        if (session) {
            if (![session hasPrefix:@"session:"])
                return nil;
            if (!payload[@"session_id"])
                payload[@"session_id"] = session;
        }
    } else if (n == 3 && [args[1] isEqualToString:@"ls"] && [args[2] isEqualToString:@"--json"]
               && ([args[0] isEqualToString:@"client"] || [args[0] isEqualToString:@"session"])) {
        method = [args[0] stringByAppendingString:@".list"];
    } else if (n >= 4 && [args[0] isEqualToString:@"-C"] && [args[2] isEqualToString:@"do"] &&
               [args[1] hasPrefix:@"client:"]) {
        method = @"client.perform";
        NSMutableDictionary* a = [NSMutableDictionary dictionary];
        for (NSUInteger i = 4; i < n; i++) {
            NSRange eq = [args[i] rangeOfString:@"="];
            if (eq.location == NSNotFound)
                return nil;
            NSString *k = [args[i] substringToIndex:eq.location], *v = [args[i] substringFromIndex:eq.location + 1];
            id j = [NSJSONSerialization JSONObjectWithData:[v dataUsingEncoding:NSUTF8StringEncoding]
                                                   options:NSJSONReadingFragmentsAllowed
                                                     error:nil];
            a[k] = [j isKindOfClass:NSNumber.class] ? j : v;
        }
        [payload addEntriesFromDictionary:@{@"client_id": args[1], @"action": args[3], @"origin": @"cli"}];
        if (a.count)
            payload[@"args"] = a;
    } else {
        return nil;
    }
    NSData* body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!body)
        return nil;
    rx::rexapi::Result r =
        rx::rexapi::call(method.UTF8String, std::string_view(static_cast<const char*>(body.bytes), body.length));
    if (!r.ok && r.code.empty()) {
        static bool told;
        if (!told)
            rexui_log([NSString stringWithFormat:@"rexapi: %s; the rex CLI instead", r.error.c_str()]);
        told = true;
        return nil;
    }
    if (!r.ok && [method isEqualToString:@"client.perform"] && r.code == "bad_request")
        return nil;
    *handled = true;
    if (!r.ok) {
        if (error)
            *error = [NSString stringWithFormat:@"%s (%s)", r.error.c_str(), r.code.c_str()];
        return nil;
    }
    return [NSData dataWithBytes:r.payload.data() length:r.payload.size()];
}

NSData* rex_cli(NSArray<NSString*>* args, NSString** error) {
    bool handled;
    NSData* direct = rex_direct(args, error, &handled);
    if (handled)
        return direct;
    {
        static NSMutableSet* told = [NSMutableSet set];
        NSString* kind =
            [[args subarrayWithRange:NSMakeRange(0, MIN(args.count, (NSUInteger)2))] componentsJoinedByString:@" "];
        @synchronized(told) {
            if (![told containsObject:kind]) {
                [told addObject:kind];
                rexui_log_file([NSString stringWithFormat:@"rexapi: `rex %@ ...` by the CLI", kind]);
            }
        }
    }

    static NSString* cli = [NSBundle.mainBundle.bundlePath
        stringByAppendingPathComponent:@"Contents/Helpers/Rex Server.rex/Contents/MacOS/rex"];
    static NSDictionary* env = ^{
        NSMutableDictionary* e = [NSProcessInfo.processInfo.environment mutableCopy];
        [e removeObjectForKey:@"DYLD_INSERT_LIBRARIES"];
        return e;
    }();
    NSTask* task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:cli];
    task.arguments = args;
    task.environment = env;
    NSPipe *out = [NSPipe pipe], *err = [NSPipe pipe];
    task.standardOutput = out;
    task.standardError = err;
    if (![task launchAndReturnError:nil])
        return nil;
    NSData* data = [out.fileHandleForReading readDataToEndOfFile];
    NSData* e = [err.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus == 0)
        return data;
    if (error)
        *error = [[NSString alloc] initWithData:e encoding:NSUTF8StringEncoding];
    return nil;
}

static NSString* g_client;
static dispatch_queue_t g_actions = dispatch_queue_create("rexui.actions", DISPATCH_QUEUE_SERIAL);

static NSString* app_client(void) {
    if (g_client)
        return g_client;
    NSData* data = rex_cli(@[@"client", @"ls", @"--json"], nil);
    NSDictionary* all = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSString* client = nil;
    for (NSDictionary* c in [all isKindOfClass:NSDictionary.class] ? all[@"clients"] : nil) {
        if (int_of(dict_of(dict_of(c)[@"principal"])[@"pid"]) != getpid())
            continue;
        if ([c[@"info"] isKindOfClass:NSDictionary.class] && [c[@"info"][@"name"] isEqual:@"rexui"])
            continue;
        bool app = [c[@"info"] isKindOfClass:NSDictionary.class] && [c[@"info"][@"kind"] isEqual:@"app"];
        if (app || !client)
            client = c[@"client_id"];
        if (app)
            break;
    }
    return g_client = client;
}

static void run_rex_action(NSString* action, NSDictionary* args = nil) {
    const bool block_action = [action hasPrefix:@"com."];
    NSString* block = nil;
    if (block_action) {
        id b = args[@"block"];
        block = [b isKindOfClass:NSString.class] && [b length] ? b : panes_last_block()[@"block"];
    }
    dispatch_async(g_actions, ^{
        NSString* client = block_action ? nil : app_client();
        if (!block_action && !client) {
            rexui_log([NSString stringWithFormat:@"commands: %@: this app isn't a client of the server", action]);
            return;
        }
        NSMutableArray* a = block_action ? [NSMutableArray arrayWithArray:@[@"do", action]]
                                         : [NSMutableArray arrayWithArray:@[@"-C", client, @"do", action]];
        if (block.length)
            [a addObjectsFromArray:@[@"-b", block]];
        for (NSString* k in [args.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            if (block_action && [k isEqualToString:@"block"])
                continue;
            [a addObject:[NSString stringWithFormat:@"%@=%@", k, args[k]]];
        }
        NSString* error = nil;
        if (!rex_cli(a, &error)) {
            g_client = nil;
            rexui_log([NSString stringWithFormat:@"commands: rex do %@: %@", action, error]);
        }
        if ([action hasPrefix:@"session."])
            dispatch_async(dispatch_get_main_queue(), ^{
                sessions_changed();
            });
    });
}

void rex_close_session(NSString* session_id) {
    if (!session_id.length)
        return;
    if ([session_id isEqualToString:current_session_id()])
        return run_rex_action(@"session.close");
    dispatch_async(g_actions, ^{
        NSString* error = nil;
        if (!rex_cli(@[@"session", @"kill", session_id], &error))
            rexui_log([NSString stringWithFormat:@"commands: rex session kill %@: %@", session_id, error]);
        dispatch_async(dispatch_get_main_queue(), ^{
            sessions_changed();
        });
    });
}

void rex_run(NSString* action, NSDictionary* args) {
    if (!args.count && ui_command(action))
        return;
    if ([@[@"client.tab.goto", @"client.tab.next", @"client.tab.previous", @"client.tab.new", @"session.select"]
            containsObject:action])
        panes_leave_full(nil, action);
    if ([action isEqualToString:@"pane.zoom"])
        pointer_still_hold();
    run_rex_action(action, args);
}

static NSMenuItem* menu_item(NSArray* path) {
    NSMenu* m = NSApp.mainMenu;
    NSMenuItem* it = nil;
    for (id t in path) {
        if (!m || ![t isKindOfClass:NSString.class])
            return nil;
        [m update];
        it = [m itemWithTitle:t];
        if (!it)
            return nil;
        m = it.submenu;
    }
    return it;
}

bool rex_menu(NSArray* path) {
    NSMenuItem* it = menu_item(path);
    if (!it || it.submenu || !it.isEnabled) {
        rexui_log([NSString stringWithFormat:@"commands: no menu item %@", [path componentsJoinedByString:@" > "]]);
        return false;
    }
    [it.menu performActionForItemAtIndex:[it.menu indexOfItem:it]];
    return true;
}

NSArray<NSString*>* rex_menu_checked(NSArray* path) {
    NSMenu* m = menu_item(path).submenu;
    if (!m)
        return nil;
    [m update];
    NSMutableArray* on = [NSMutableArray array];
    for (NSMenuItem* it in m.itemArray) {
        if (it.state == NSControlStateValueOn)
            [on addObject:it.title];
    }
    return on;
}

static NSDictionary<NSString*, NSString*>* menu_commands(void) {
    if (now() < g_pass_until)
        return @{};
    static NSDictionary* d;
    if (!d) {
        NSString* app = NSRunningApplication.currentApplication.localizedName ?: @"Rex UI";
        d = @{
            @"Settings…": @"client.settings",
            @"Command Palette…": @"client.palette.toggle",
            [app stringByAppendingString:@" Diagnostics"]: @"client.diagnostics",
            @"Rex UI Diagnostics": @"client.diagnostics",
            @"Rex Diagnostics": @"client.diagnostics",
            @"Show Sidebar": @"client.sidebar.toggle",
            @"Hide Sidebar": @"client.sidebar.toggle",
            @"Toggle Sidebar": @"client.sidebar.toggle"
        };
    }
    return d;
}

static void each_menu_item(NSMenu* m, void (^f)(NSMenuItem*)) {
    for (NSMenuItem* it in m.itemArray) {
        f(it);
        if (it.submenu)
            each_menu_item(it.submenu, f);
    }
}

static bool key_is(NSMenuItem* it, NSEvent* e) {
    if (!it.keyEquivalent.length)
        return false;
    NSEventModifierFlags mask =
        NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagOption | NSEventModifierFlagControl;
    NSEventModifierFlags want = it.keyEquivalentModifierMask & mask;
    NSString* key = it.keyEquivalent;
    if (![key isEqualToString:key.lowercaseString])
        want |= NSEventModifierFlagShift;
    return (e.modifierFlags & mask) == want &&
        [e.charactersIgnoringModifiers.lowercaseString isEqualToString:key.lowercaseString];
}

static NSMapTable<NSString*, NSMenuItem*>* g_command_items;
static NSMenuItem* command_item(NSString* title) {
    if (!g_command_items)
        g_command_items = [NSMapTable strongToWeakObjectsMapTable];
    NSMenuItem* it = [g_command_items objectForKey:title];
    if (it && it.menu && [it.title isEqualToString:title])
        return it;
    __block NSMenuItem* found = nil;
    each_menu_item(NSApp.mainMenu, ^(NSMenuItem* i) {
        if (!found && [i.title isEqualToString:title])
            found = i;
    });
    if (found)
        [g_command_items setObject:found forKey:title];
    return found;
}

static void taken_now(NSString* command) {
    if (!g_taken)
        g_taken = [NSMutableDictionary dictionary];
    g_taken[command] = @(now());
}

static NSString* menu_command_for_key(NSEvent* e) {
    if (!(e.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl)))
        return nil;
    NSDictionary<NSString*, NSString*>* commands = menu_commands();
    for (NSString* title in commands) {
        if (key_is(command_item(title), e))
            return commands[title];
    }
    return nil;
}

static double g_still_until;
static NSPoint g_still_at;
void pointer_still_hold(void) {
    g_still_until = CACurrentMediaTime() + 1.5;
    g_still_at = NSEvent.mouseLocation;
}

static bool g_sidebar_putting_back;
static bool sidebar_refused(NSString* command) {
    if (g_config.rex_sidebar || g_sidebar_putting_back || ![command isEqualToString:@"client.sidebar.toggle"])
        return false;
    rexui_log(@"commands: client.sidebar.toggle: Rex's sidebar is off (rex_sidebar = false)");
    return true;
}

static NSMenuItem* view_item(NSArray<NSString*>* titles) {
    NSMenu* view = [NSApp.mainMenu itemWithTitle:@"View"].submenu;
    [view update];
    for (NSString* t in titles)
        if (NSMenuItem* it = [view itemWithTitle:t]; it.isEnabled && !it.submenu)
            return it;
    return nil;
}
void sidebar_off(void) {
    if (g_config.rex_sidebar || g_sidebar_putting_back)
        return;
    NSUserDefaults* d = NSUserDefaults.standardUserDefaults;
    if (![[d stringForKey:RXNS(RXN_179)] isEqualToString:@"vertical"])
        return;
    static double failed_at = -1e9;
    if (now() - failed_at < 5)
        return;
    g_sidebar_putting_back = true;
    if (![d boolForKey:RXNS(RXN_180)])
        if (NSMenuItem* it = view_item(@[@"Hide Sidebar", @"Toggle Sidebar"]))
            [it.menu performActionForItemAtIndex:[it.menu indexOfItem:it]];
    bool above = rex_menu(@[@"View", @"Customize View", @"Toolbar Layout", @"Above"])
        || rex_menu(@[@"View", @"Customize View", @"Tab Style", @"Above"]);
    g_sidebar_putting_back = false;
    if (!above)
        failed_at = now();
    rexui_log(
        [NSString stringWithFormat:@"commands: Rex's sidebar is off (rex_sidebar = false): put back, its tabs above%@",
                                   above ? @"" : @" (no menu item for it)"]);
}
void sidebar_watch(void) {
    static bool once;
    if (once)
        return;
    once = true;
    static bool due;
    [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification*) {
                                                    if (due || g_config.rex_sidebar || g_sidebar_putting_back)
                                                        return;
                                                    due = true;
                                                    dispatch_async(dispatch_get_main_queue(), ^{
                                                        due = false;
                                                        sidebar_off();
                                                    });
                                                }];
    dispatch_async(dispatch_get_main_queue(), ^{
        sidebar_off();
    });
}

static void hook_send_event(NSApplication* self, SEL sel, NSEvent* e) {
    NSWindow* ew = e.window;
    if (e.type == NSEventTypeLeftMouseDown || e.type == NSEventTypeRightMouseDown
        || e.type == NSEventTypeOtherMouseDown)
        (void)ui_clicks(e);
    if (e.type == NSEventTypeKeyDown && g_config.quit_key.length && ui_key_matches(g_config.quit_key, e)) {
        if (!e.isARepeat) {
            rexui_log([NSString stringWithFormat:@"commands: %@: Rex UI quits", g_config.quit_key]);
            [NSApp terminate:nil];
        }
        return;
    }
    if (g_still_until > 0) {
        const NSPoint at = NSEvent.mouseLocation;
        if (CACurrentMediaTime() > g_still_until
            || ((e.type == NSEventTypeMouseMoved || e.type == NSEventTypeLeftMouseDown)
                && !NSEqualPoints(at, g_still_at)))
            g_still_until = 0;
        else if (e.type == NSEventTypeMouseEntered && is_rex_window(ew) && NSEqualPoints(at, g_still_at))
            return;
    }
    if (e.type == NSEventTypeKeyDown && !e.isARepeat && tabs_zoom_key(e))
        pointer_still_hold(), keys_trace(@"Rex's zoom key");
    if (panes_full_input(e))
        return;
    if (e.type == NSEventTypeKeyDown && !e.isARepeat
        && (panes_full_in(ew) || panes_file_full_in(ew) || term_full_in(ew)) && tabs_key_switches(e))
        panes_leave_full(ew, @"a tab key");
    bool full = panes_full_in(ew), over = full && panes_ui_over();
    if (!full) {
        if (pane_drag_event(e))
            return;
        if (pane_resize_event(e))
            return;
    }
    if (!full || over)
        ui_pointer_event(e);
    bool rex_key = panes_rex_key(e);
    if (!rex_key && e.type == NSEventTypeKeyDown && (!full || over || (e.modifierFlags & NSEventModifierFlagCommand))
        && ui_key(e))
        return;
    if (!rex_key && panes_event(e))
        return;
    if ((e.type == NSEventTypeKeyDown || e.type == NSEventTypeLeftMouseDown) && is_rex_window(ew))
        rex_wrap_closures();
    if (e.type == NSEventTypeKeyDown && is_rex_window(ew)) {
        if (NSString* command = menu_command_for_key(e)) {
            if (ui_command(command))
                return taken_now(command);
            if (sidebar_refused(command))
                return taken_now(command);
            rexui_log([NSString stringWithFormat:@"commands: %@: no Drawer takes it", command]);
        }
        if (sessions_key(e))
            return;
        tabs_key(e);
    }
    if (ui_event(e))
        return;
    orig_send_event(self, sel, links_event(e));
}

void send_event_on(NSEvent* e) {
    orig_send_event(NSApp, @selector(sendEvent:), e);
}

static BOOL hook_send_action(NSApplication* self, SEL sel, SEL action, id target, id sender) {
    if (g_config.single_window && is_new_window_item(sender) && the_window()) {
        bring_the_window();
        return YES;
    }
    if ([sender isKindOfClass:NSMenuItem.class]) {
        NSString* command = menu_commands()[((NSMenuItem*)sender).title];
        if (command && now() - [g_taken[command] doubleValue] < 0.3)
            return YES;
        if (command && ui_command(command))
            return taken_now(command), YES;
        if (command && sidebar_refused(command))
            return taken_now(command), YES;
    }
    return orig_send_action(self, sel, action, target, sender);
}

NSDictionary<NSString*, NSString*>* menu_shortcuts(void) {
    NSMutableDictionary* out = [NSMutableDictionary dictionary];
    each_menu_item(NSApp.mainMenu, ^(NSMenuItem* it) {
        if (!it.keyEquivalent.length || !it.title.length || out[it.title])
            return;
        NSEventModifierFlags m = it.keyEquivalentModifierMask;
        NSString* k = it.keyEquivalent;
        if (![k isEqualToString:k.lowercaseString])
            m |= NSEventModifierFlagShift;
        NSDictionary* names = @{@"\r": @"↩", @"\t": @"⇥", @" ": @"Space", @"\x1b": @"⎋", @"\x7f": @"⌫"};
        unichar c = [k characterAtIndex:0];
        NSString* key = names[k];
        if (!key && c >= 0xF700 && c <= 0xF703)
            key = @[@"↑", @"↓", @"←", @"→"][c - 0xF700];
        if (!key && c >= 0xF704 && c <= 0xF70F)
            key = [NSString stringWithFormat:@"F%d", c - 0xF704 + 1];
        if (!key)
            key = k.uppercaseString;
        out[it.title] = [NSString stringWithFormat:@"%@%@%@%@%@", (m & NSEventModifierFlagControl) ? @"⌃" : @"",
                                                   (m & NSEventModifierFlagOption) ? @"⌥" : @"",
                                                   (m & NSEventModifierFlagShift) ? @"⇧" : @"",
                                                   (m & NSEventModifierFlagCommand) ? @"⌘" : @"", key];
    });
    return out;
}

bool rex_window_open(NSString* id) {
    if ([id isEqualToString:@"diagnostics"] || [id isEqualToString:@"client.diagnostics"]) {
        rex_original(@"client.diagnostics");
        return true;
    }
    for (NSWindow* w in NSApp.windows) {
        if (![w.identifier isEqualToString:id] || !other_window(w))
            continue;
        if (!g_let)
            g_let = [NSMapTable weakToStrongObjectsMapTable];
        [g_let setObject:@(now()) forKey:w];
        w.alphaValue = 1;
        [w makeKeyAndOrderFront:nil];
        return true;
    }
    return false;
}

void rex_original(NSString* what) {
    if ([what isEqualToString:@"client.diagnostics"]) {
        for (NSString* title in @[
                 [(NSRunningApplication.currentApplication.localizedName
                       ?: @"Rex UI") stringByAppendingString:@" Diagnostics"],
                 @"Rex UI Diagnostics", @"Rex Diagnostics"
             ]) {
            NSMenuItem* it = command_item(title);
            if (!it)
                continue;
            g_pass_until = now() + 1;
            [it.menu performActionForItemAtIndex:[it.menu indexOfItem:it]];
            return;
        }
        return rexui_log(@"commands: Rex's Diagnostics menu item not found");
    }
    if (![what isEqualToString:@"client.config.open"])
        return;
    g_allow_config_until = now() + 2;
    NSString* path = [NSHomeDirectory() stringByAppendingPathComponent:@".config/rex/init.lua"];
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:path]];
}

static void lend(NSWindow* w) {
    void (^take)(NSWindow*) = g_lend;
    g_lend = nil;
    g_lent = w;
    w.alphaValue = 0;
    w.ignoresMouseEvents = YES;
    [w setFrameOrigin:NSMakePoint(-20000, -20000)];
    orig_order_window(w, @selector(orderWindow:relativeTo:), NSWindowBelow, 0);
    rexui_log(@"commands: lend: settings window lent");
    take(w);
}

extern "C" void rexui_lend_settings(double seconds, void (^take)(NSWindow* w)) {
    if (lending() || !take)
        return;
    g_lend = [take copy];
    g_lend_until = now() + seconds;
    g_lending = true;
    rexui_log([NSString stringWithFormat:@"commands: lend: armed for %g s", seconds]);
}

extern "C" void rexui_settings_back(void) {
    if (NSWindow* w = g_lent)
        orig_order_window(w, @selector(orderWindow:relativeTo:), NSWindowOut, 0);
    g_lent = nil;
    g_lend = nil;
    g_lending = false;
    rexui_log(@"commands: lend: settings window given back");
}

extern "C" void rexui_rex_run(const char* action) {
    rex_run(@(action), nil);
}
