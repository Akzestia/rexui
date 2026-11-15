// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>
#import "base/rexui.h"
#include "base/trace.h"
#import "chrome/chrome.h"
#import "rex/rex.h"
#import "ui/ui.h"

static NSMutableArray<NSMutableDictionary*>* g_list;
static const NSUInteger kKeep = 50;
static NSString* g_rex_badge = @"";
static NSString* g_our_badge;
static NSString* g_glass;

static void (*orig_add)(id, SEL, UNNotificationRequest*, void (^)(NSError*));
static void (*orig_badge)(id, SEL, NSString*);

static bool taking(void) {
    return [g_config.notifications isEqualToString:@"rexui"];
}

static NSDictionary* state(void) {
    return @{
        @"list": [[NSArray alloc] initWithArray:g_list ?: @[] copyItems:YES],
        @"badge": g_rex_badge ?: @"",
        @"taking": @(taking())
    };
}

void notices_doc_loaded(id d) {
    RXDoc* doc = d;
    if (doc.ctx && doc.wants_notices)
        doc_call(doc, @"setNotices", @[state()]);
}

static void push(void) {
    NSDictionary* s = nil;
    for (RXDoc* d in [g_docs copy])
        if (d.ctx && d.wants_notices)
            doc_call(d, @"setNotices", @[s ?: (s = state())]);
}

static NSString* sound_for(NSDictionary* n) {
    if ([n[@"sound"] isKindOfClass:NSString.class])
        return n[@"sound"];
    NSDictionary* v = g_config.values;
    for (NSString* k in @[n[@"status"] ?: @"", n[@"source"] ?: @"", @""]) {
        NSString* key = k.length ? [@"notification-sound-" stringByAppendingString:k] : @"notification-sound";
        if ([v[key] length])
            return v[key];
    }
    return nil;
}

static bool play(NSString* s) {
    if (!s.length || [@[@"none", @"false"] containsObject:s.lowercaseString])
        return false;
    NSSound* sound = nil;
    if ([s containsString:@"/"] || [s containsString:@"."]) {
        NSString* path = s.stringByExpandingTildeInPath;
        if (!path.isAbsolutePath)
            path = [ui_dir() stringByAppendingPathComponent:path];
        sound = [[NSSound alloc] initWithContentsOfFile:path byReference:YES];
    } else {
        sound = [[NSSound soundNamed:s] copy];
    }
    if (!sound) {
        rexui_log([NSString stringWithFormat:@"notices: no sound %@", s]);
        return false;
    }
    static NSMutableSet* playing = [NSMutableSet set];
    [playing addObject:sound];
    [sound play];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((sound.duration + 0.5) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       [playing removeObject:sound];
                   });
    rexui_log_file([@"notices: played " stringByAppendingString:s]);
    return true;
}

static void sync_rex_sounds(void) {
    static NSUserDefaults* ours = [[NSUserDefaults alloc] initWithSuiteName:rexui_suite()];
    NSUserDefaults* rex = NSUserDefaults.standardUserDefaults;
    NSString *key = RXNS(RXN_168), *saved = [@"notices: Rex's " stringByAppendingString:RXNS(RXN_186)];
    if (taking()) {
        if (![ours objectForKey:saved])
            [ours setObject:[rex objectForKey:key] ?: @"default" forKey:saved];
        if (![rex objectForKey:key] || [rex boolForKey:key])
            [rex setBool:NO forKey:key];
    } else if (id was = [ours objectForKey:saved]) {
        if ([was isEqual:@"default"])
            [rex removeObjectForKey:key];
        else
            [rex setObject:was forKey:key];
        [ours removeObjectForKey:saved];
    }
}

static void add(NSMutableDictionary* n) {
    if (!g_list)
        g_list = [NSMutableArray array];
    if (!n[@"id"])
        n[@"id"] = NSUUID.UUID.UUIDString;
    n[@"time"] = @(floor(NSDate.date.timeIntervalSince1970 * 1000));
    if (![n[@"status"] length] && [n[@"block"] length])
        n[@"status"] = activity_status_of(n[@"block"]) ?: @"";
    for (NSString* k in @[@"title", @"subtitle", @"body", @"tone", @"session", @"block", @"status"])
        if (!n[k])
            n[k] = [k isEqualToString:@"tone"] ? @"standard" : @"";
    [g_list insertObject:n atIndex:0];
    while (g_list.count > kKeep)
        [g_list removeLastObject];
    rexui_log_file([NSString stringWithFormat:@"notices: %@ \"%@\" %@", n[@"source"], n[@"title"], n[@"body"]]);
    if ([n[@"to"] isEqualToString:@"docks"] || [n[@"source"] isEqualToString:@"rexui"])
        play(sound_for(n));
    else if ([n[@"sound"] isKindOfClass:NSString.class])
        play(n[@"sound"]);
    push();
    NSDictionary* copy = [n copy];
    for (RXDoc* d in [g_docs copy])
        if (d.ctx && d.root)
            doc_call(d, @"emit", @[@(d.root.uid), @"notice", @[copy]]);
}

static NSMutableDictionary* find(NSString* id) {
    for (NSMutableDictionary* n in g_list)
        if ([n[@"id"] isEqualToString:id])
            return n;
    return nil;
}

static bool delegated(void) {
    for (RXDoc* d in g_docs)
        if (d.notice_delegate && d.ctx)
            return true;
    return false;
}

static NSString* default_way(void) {
    return taking() ? @"docks" : @"rex";
}

static NSString* ask(NSMutableDictionary* n, NSDictionary** change) {
    *change = nil;
    if (!NSThread.isMainThread)
        return default_way();
    NSDictionary* copy = [n copy];
    for (RXDoc* d in [g_docs copy]) {
        if (!d.notice_delegate || !d.ctx)
            continue;
        id r = doc_call(d, @"noticeDelegate", @[copy]);
        NSString* way = nil;
        if ([r isKindOfClass:NSString.class] && [@[@"rex", @"docks", @"drop"] containsObject:r])
            way = r;
        else if ([r isKindOfClass:NSDictionary.class])
            *change = r, way = @"change";
        if (!way)
            continue;
        rexui_log_file([NSString stringWithFormat:@"notices: %@ \"%@\" -> %@ (%@)", n[@"source"], n[@"title"], way,
                                                  d.path.lastPathComponent]);
        return way;
    }
    return default_way();
}

static NSString* str(NSDictionary* d, NSString* k) {
    return [d[k] isKindOfClass:NSString.class] ? d[k] : nil;
}

static void apply_change(NSMutableDictionary* n, NSDictionary* c) {
    for (NSString* k in @[@"title", @"subtitle", @"body", @"tone", @"symbol", @"sound"])
        if (NSString* v = str(c, k))
            n[k] = v;
    n[@"changed"] = @YES;
}

static NSString* post_rex(NSDictionary* n, NSDictionary* c) {
    NSString* body = [n[@"body"] length] ? n[@"body"] : [n[@"subtitle"] length] ? n[@"subtitle"] : nil;
    id dismiss = c[@"dismissible"] ?: n[@"dismissible"];
    NSString* rid = (__bridge_transfer NSString*)rex_glass_notice(
        [n[@"title"] ?: @"" UTF8String], body.UTF8String, [n[@"tone"] ?: @"standard" UTF8String],
        [str(n, @"symbol") UTF8String], truthy_of(dismiss, true));
    if (!rid)
        rexui_log(@"notices: Rex's own notice couldn't be posted (shown by the docks only)");
    return rid ? [@"glass:" stringByAppendingString:rid] : nil;
}

static void ids_in(id v, NSMutableDictionary* n, int depth) {
    if (depth > 4)
        return;
    if ([v isKindOfClass:NSString.class]) {
        for (NSString* p in @[@"session", @"block", @"window"]) {
            NSString* key = [p isEqualToString:@"window"] ? @"tab" : p;
            if ([v hasPrefix:[p stringByAppendingString:@":"]] && !n[key])
                n[key] = v;
        }
    } else if ([v isKindOfClass:NSDictionary.class]) {
        for (id k in v)
            ids_in(v[k], n, depth + 1);
    } else if ([v isKindOfClass:NSArray.class]) {
        for (id x in v)
            ids_in(x, n, depth + 1);
    }
}

static NSString* source_of(NSString* identifier) {
    NSString* i = identifier.lowercaseString;
    if ([i containsString:@"terminal"])
        return @"terminal";
    if ([i containsString:@"activity"] || [i containsString:@"program"])
        return @"activity";
    if ([i containsString:@"tailnet"] || [i containsString:@"remote"])
        return @"remote";
    return @"rex";
}

static bool system_too(bool docks) {
    if (!docks)
        return true;
    if ([g_config.notifications_system isEqualToString:@"always"])
        return true;
    if ([g_config.notifications_system isEqualToString:@"never"])
        return false;
    return !NSApp.isActive;
}

static void hook_add(id self, SEL sel, UNNotificationRequest* req, void (^done)(NSError*)) {
    if ([req.identifier hasPrefix:@"rexui."])
        return orig_add(self, sel, req, done);
    UNNotificationContent* c = req.content;
    NSMutableDictionary* n = [@{
        @"source": source_of(req.identifier ?: @""),
        @"identifier": req.identifier ?: @"",
        @"title": c.title ?: @"",
        @"subtitle": c.subtitle ?: @"",
        @"body": c.body ?: @""
    } mutableCopy];
    ids_in(c.userInfo, n, 0);
    static int described;
    if (described++ < 6)
        rexui_log_file([NSString stringWithFormat:@"notices: request %@ category %@ thread %@ userInfo %@",
                                                  req.identifier, c.categoryIdentifier, c.threadIdentifier,
                                                  c.userInfo]);
    UNNotificationRequest* (^quiet)(UNNotificationContent*) = ^(UNNotificationContent* content) {
        UNMutableNotificationContent* m = [content mutableCopy];
        m.sound = nil;
        return [UNNotificationRequest requestWithIdentifier:req.identifier content:m trigger:req.trigger];
    };
    if (!delegated()) {
        n[@"to"] = default_way();
        bool forward = system_too(taking());
        if (forward && taking() && sound_for(n))
            req = quiet(c);
        dispatch_async(dispatch_get_main_queue(), ^{
            add(n);
        });
        if (forward)
            orig_add(self, sel, req, done);
        else if (done)
            done(nil);
        return;
    }
    n[@"id"] = NSUUID.UUID.UUIDString;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary* change;
        NSString* way = ask(n, &change);
        if ([way isEqualToString:@"drop"]) {
            if (done)
                done(nil);
            return;
        }
        UNNotificationRequest* out = req;
        bool forward = true;
        if ([way isEqualToString:@"docks"]) {
            forward = system_too(true);
            if (forward && sound_for(n))
                out = quiet(c);
        } else if ([way isEqualToString:@"change"]) {
            apply_change(n, change);
            UNMutableNotificationContent* m = [c mutableCopy];
            m.title = n[@"title"], m.subtitle = n[@"subtitle"], m.body = n[@"body"];
            if (str(change, @"sound"))
                m.sound = nil;
            out = [UNNotificationRequest requestWithIdentifier:req.identifier content:m trigger:req.trigger];
            if (truthy_of(change[@"glass"])) {
                if (NSString* gid = post_rex(n, change))
                    n[@"id"] = gid;
                forward = truthy_of(change[@"system"]);
            }
        }
        n[@"to"] = [way isEqualToString:@"docks"] ? @"docks" : @"rex";
        add(n);
        if (forward)
            orig_add(self, sel, out, done);
        else if (done)
            done(nil);
    });
}

static void apply_badge(void) {
    NSString* b = g_our_badge ?: (taking() ? nil : g_rex_badge);
    orig_badge(NSApp.dockTile, @selector(setBadgeLabel:), b.length ? b : nil);
}

static void hook_badge(NSDockTile* self, SEL sel, NSString* label) {
    if (self != NSApp.dockTile)
        return orig_badge(self, sel, label);
    NSString* was = g_rex_badge;
    g_rex_badge = label ?: @"";
    if (![was isEqualToString:g_rex_badge])
        dispatch_async(dispatch_get_main_queue(), ^{
            push();
        });
    if (!g_our_badge && !taking())
        orig_badge(self, sel, label);
    else
        apply_badge();
}

static bool g_host_wanted;
static bool g_showing_ours;
static bool g_glass_pending;
static NSMutableDictionary<NSString*, NSString*>* g_way;
static void (*orig_host_hidden)(id, SEL, BOOL);
static void decide_glass(void);
static void glass_every(double s);

static bool host_shows(void) {
    if (!g_host_wanted)
        return false;
    if (g_showing_ours)
        return true;
    if (!delegated())
        return !taking();
    if (g_glass_pending || !g_glass)
        return false;
    return [g_way[g_glass] isEqualToString:@"rex"];
}

static void schedule_decide(void) {
    static bool scheduled;
    if (scheduled)
        return;
    scheduled = true;
    dispatch_async(dispatch_get_main_queue(), ^{
        scheduled = false;
        decide_glass();
    });
}

static bool undecided(NSString* id) {
    if (!id)
        return false;
    if (rex_notice_is_ours(id.UTF8String)) {
        g_showing_ours = true;
        return false;
    }
    g_showing_ours = false;
    return !g_way[id] || ![id isEqualToString:g_glass];
}

static void watch_host(void);

static void hook_host_hidden(NSView* self, SEL sel, BOOL hidden) {
    bool host = (__bridge const void*)self == rex_notice_host();
    if (host) {
        if (!hidden && !g_host_wanted)
            dispatch_async(dispatch_get_main_queue(), ^{
                glass_every(0.25);
            });
        g_host_wanted = !hidden;
        if (!hidden && delegated()) {
            NSDictionary* p = (__bridge_transfer NSDictionary*)rex_notice_presentation();
            if (undecided(p[@"id"]) || !p)
                g_glass_pending = true, schedule_decide();
            watch_host();
        }
    }
    orig_host_hidden(self, sel, host ? !host_shows() : hidden);
}

static bool host_wanted(void) {
    return g_host_wanted;
}

static void hold_host(void) {
    NSView* h = (__bridge NSView*)rex_notice_host();
    if (!h)
        return;
    static bool hooked;
    if (!hooked) {
        hooked = true;
        g_host_wanted = !h.isHidden;
        swizzle(h.class, @selector(setHidden:), (IMP)hook_host_hidden, (IMP*)&orig_host_hidden);
        rex_notice_set_wanted(host_wanted);
        rexui_log_file([@"notices: Rex's notice host is a " stringByAppendingString:NSStringFromClass(h.class)]);
    }
    bool hide = !host_shows();
    if (h.isHidden != hide)
        orig_host_hidden(h, @selector(setHidden:), hide);
}

static void watch_host(void) {
    static bool watching;
    if (watching)
        return;
    watching = true;
    each_commit(^bool {
        if (!g_host_wanted || !delegated())
            return watching = false;
        if (g_glass_pending)
            return true;
        NSDictionary* p = (__bridge_transfer NSDictionary*)rex_notice_presentation();
        if (undecided(p[@"id"])) {
            g_glass_pending = true;
            schedule_decide();
        }
        hold_host();
        return true;
    });
}

static void remote_tick(void) {
    static NSString* last;
    NSString* text = (__bridge_transfer NSString*)rex_remote_notice();
    if (!text || [text isEqual:last]) {
        if (!text)
            last = nil;
        return;
    }
    last = text;
    if (NSDictionary* g = g_glass ? find([@"glass:" stringByAppendingString:g_glass]) : nil)
        if ([g[@"title"] isEqualToString:text] || [g[@"body"] isEqualToString:text])
            return;
    if ([g_way[g_glass ?: @""] isEqualToString:@"drop"])
        return;
    add([@{@"source": @"remote", @"title": text, @"body": @"", @"to": g_way[g_glass ?: @""] ?: default_way()}
        mutableCopy]);
}

static void decide_glass(void) {
    g_glass_pending = false;
    NSDictionary* p = (__bridge_transfer NSDictionary*)rex_notice_presentation();
    NSString* id = p[@"id"];
    g_showing_ours = id && rex_notice_is_ours(id.UTF8String);
    if (g_showing_ours || !id) {
        if (!id)
            g_glass = nil;
        return hold_host();
    }
    NSString* nid = [@"glass:" stringByAppendingString:id];
    if (NSString* way = g_way[id]) {
        g_glass = id;
        NSMutableDictionary* n = find(nid);
        bool changed = false;
        if (![way isEqualToString:@"change"])
            for (NSString* k in @[@"title", @"body", @"progress", @"tone", @"actions"])
                if (p[k] && n && ![n[k] isEqual:p[k]])
                    n[k] = p[k], changed = true;
        if (changed)
            push();
        return hold_host();
    }
    NSMutableDictionary* n = [p mutableCopy];
    n[@"id"] = nid;
    n[@"source"] = @"notice";
    if (![n[@"body"] length] && n[@"scrolling"])
        n[@"body"] = n[@"scrolling"];
    NSString* remote = (__bridge_transfer NSString*)rex_remote_notice();
    if (remote && ([remote isEqualToString:n[@"title"]] || [remote isEqualToString:n[@"body"]]))
        n[@"source"] = @"remote";
    NSDictionary* change;
    NSString* way = ask(n, &change);
    if (!g_way)
        g_way = [NSMutableDictionary dictionary];
    if (g_way.count > 64)
        [g_way removeAllObjects];
    g_way[id] = way;
    g_glass = id;
    hold_host();
    if ([way isEqualToString:@"drop"])
        return;
    if ([way isEqualToString:@"change"]) {
        apply_change(n, change);
        if (NSString* gid = post_rex(n, change))
            n[@"id"] = gid, n[@"replaces"] = nid, schedule_decide();
        else
            g_way[id] = @"rex", hold_host();
    }
    n[@"to"] = [way isEqualToString:@"docks"] ? @"docks" : @"rex";
    if (NSMutableDictionary* old = find(n[@"id"]))
        [g_list removeObject:old];
    add(n);
}

static NSTimer* g_glass_timer;
static void glass_tick(void);
static void glass_every(double s) {
    if (g_glass_timer && g_glass_timer.timeInterval == s)
        return;
    [g_glass_timer invalidate];
    g_glass_timer = [NSTimer timerWithTimeInterval:s
                                           repeats:YES
                                             block:^(NSTimer*) {
                                                 glass_tick();
                                             }];
    g_glass_timer.tolerance = s / 5;
    [NSRunLoop.mainRunLoop addTimer:g_glass_timer forMode:NSRunLoopCommonModes];
}

static void glass_tick(void) {
    RX_INTERVAL(timer, "glass_tick");
    decide_glass();
    remote_tick();
    glass_every(g_host_wanted || !orig_host_hidden ? 0.25 : 5);
}

static void reveal(NSDictionary* n) {
    NSString *session = n[@"session"], *block = n[@"block"];
    if (![block length])
        return;
    if (![session length])
        session = g_session_id;
    if (![session isEqualToString:g_session_id])
        rex_run(@"session.select", @{@"session_id": session});
    NSData* json = json_data(@{@"session_id": session, @"block_id": block}, 0);
    NSString* arg = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString* err = nil;
        if (!rex_cli(@[@"api", @"call", @"session.focus_block", arg], &err))
            rexui_log([NSString stringWithFormat:@"notices: can't show %@: %@", block, err ?: @"?"]);
    });
}

static void post_system(NSDictionary* n) {
    Class cls = NSClassFromString(@"UNUserNotificationCenter");
    if (!cls)
        return;
    UNMutableNotificationContent* c = [UNMutableNotificationContent new];
    c.title = n[@"title"] ?: @"";
    c.subtitle = n[@"subtitle"] ?: @"";
    c.body = n[@"body"] ?: @"";
    UNNotificationRequest* req =
        [UNNotificationRequest requestWithIdentifier:[@"rexui." stringByAppendingString:n[@"id"]]
                                             content:c
                                             trigger:nil];
    [[cls currentNotificationCenter] addNotificationRequest:req withCompletionHandler:nil];
}

void notices_post(NSString* title, NSString* body) {
    NSMutableDictionary* n = [@{@"source": @"rexui", @"title": title ?: @"", @"body": body ?: @""} mutableCopy];
    dispatch_async(dispatch_get_main_queue(), ^{
        add(n);
    });
}

id notices_native(NSString* op, NSDictionary* a) {
    if ([op isEqualToString:@"dismiss"]) {
        if (NSMutableDictionary* n = find(a[@"id"]))
            [g_list removeObject:n], push();
    } else if ([op isEqualToString:@"clear"]) {
        [g_list removeAllObjects];
        push();
    } else if ([op isEqualToString:@"reveal"]) {
        if (NSDictionary* n = find(a[@"id"]))
            reveal(n);
    } else if ([op isEqualToString:@"play"]) {
        return @(play(a[@"sound"]));
    } else if ([op isEqualToString:@"badge"]) {
        id t = a[@"text"];
        g_our_badge = [t isKindOfClass:NSString.class] ? t : nil;
        apply_badge();
    } else if ([op isEqualToString:@"delegate"]) {
        if (g_glass)
            [g_way removeObjectForKey:g_glass];
        g_glass = nil;
        if (delegated() && g_host_wanted)
            watch_host();
        decide_glass();
    } else if ([op isEqualToString:@"post"]) {
        NSMutableDictionary* n = [NSMutableDictionary dictionary];
        for (NSString* k in @[@"title", @"subtitle", @"body", @"tone", @"status", @"session", @"block"])
            if ([a[k] isKindOfClass:NSString.class])
                n[k] = a[k];
        n[@"source"] = @"rexui";
        if ([a[@"sound"] isKindOfClass:NSString.class])
            n[@"sound"] = a[@"sound"];
        if (truthy_of(a[@"rex"])) {
            NSString *body = [n[@"body"] length] ? n[@"body"] : nil,
                     *symbol = [a[@"symbol"] isKindOfClass:NSString.class] ? a[@"symbol"] : nil;
            NSString* rid = (__bridge_transfer NSString*)rex_glass_notice(
                [n[@"title"] ?: @"" UTF8String], body.UTF8String, [n[@"tone"] ?: @"standard" UTF8String],
                symbol.UTF8String, truthy_of(a[@"dismissible"], true));
            if (!rid)
                rexui_log(@"notices: Rex's own notice couldn't be posted (shown by the docks only)");
            else
                n[@"id"] = [@"glass:" stringByAppendingString:rid];
        }
        add(n);
        if (num_of(a[@"system"]) != 0 || ([a[@"system"] isEqual:@"inactive"] && !NSApp.isActive))
            post_system(n);
        return n[@"id"];
    }
    return nil;
}

void notices_config_changed(void) {
    static NSString* was;
    sync_rex_sounds();
    if (!was || ![was isEqualToString:g_config.notifications]) {
        if (was)
            rexui_log([NSString
                stringWithFormat:@"notices: %@",
                                 taking() ? @"rexui shows Rex's notifications" : @"Rex shows its own notifications"]);
        was = g_config.notifications;
        if (orig_badge)
            apply_badge();
        hold_host();
        push();
    }
}

void notices_init(void) {
    if (Class un = NSClassFromString(@"UNUserNotificationCenter"))
        swizzle(un, @selector(addNotificationRequest:withCompletionHandler:), (IMP)hook_add, (IMP*)&orig_add);
    swizzle([NSDockTile class], @selector(setBadgeLabel:), (IMP)hook_badge, (IMP*)&orig_badge);
    dispatch_async(dispatch_get_main_queue(), ^{
        glass_every(0.25);
    });
}
