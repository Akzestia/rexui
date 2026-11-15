// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "web/web.h"

#include <sqlite3.h>

static NSString* base_path(void) {
    NSString* d = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/rexui"];
    return [d stringByAppendingPathComponent:@"cookie-base.plist"];
}
static NSMutableDictionary<NSString*, NSNumber*>* base(void) {
    static NSMutableDictionary<NSString*, NSNumber*>* b;
    if (!b) {
        NSDictionary* d = [NSDictionary dictionaryWithContentsOfFile:base_path()];
        b = [d isKindOfClass:NSDictionary.class] ? [d mutableCopy] : [NSMutableDictionary dictionary];
    }
    return b;
}
static void save_base(void) {
    NSDictionary* copy = [base() copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [copy writeToFile:base_path() atomically:YES];
    });
}

void import_cookies(RXNode* n, bool first) {
    NSString* spec = str(n, P::cookies, @"");
    if (!spec.length)
        return;
    NSString* db = cookie_file(spec);
    if (!db) {
        rexui_log([NSString stringWithFormat:@"cookies: no cookies.sqlite for %@", spec]);
        return;
    }
    static NSMutableDictionary<NSString*, NSDate*>* done_at = [NSMutableDictionary dictionary];
    static NSMutableDictionary<NSString*, NSMutableArray*>* running = [NSMutableDictionary dictionary];
    if (first)
        n.preparing++;
    __weak RXNode* weak = n;
    auto release = ^{
        RXNode* n2 = weak;
        if (n2 && first)
            web_prepared(n2);
    };
    if (running[db])
        return (void)[running[db] addObject:release];
    if (done_at[db] && -done_at[db].timeIntervalSinceNow < 60)
        return release();
    running[db] = [NSMutableArray arrayWithObject:release];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSHTTPCookie*>* saved = read_cookies(db);
        NSArray<NSHTTPCookie*>* session = read_session_cookies(db.stringByDeletingLastPathComponent);
        NSArray<NSHTTPCookie*>* cookies = [saved arrayByAddingObjectsFromArray:session];
        dispatch_async(dispatch_get_main_queue(), ^{
            WKHTTPCookieStore* store = WKWebsiteDataStore.defaultDataStore.httpCookieStore;
            [store getAllCookies:^(NSArray<NSHTTPCookie*>* have) {
                CookieMerge m = cookie_merge(cookies, have, base());
                dispatch_group_t g = dispatch_group_create();
                for (NSHTTPCookie* c in m.take) {
                    dispatch_group_enter(g);
                    [store setCookie:c
                        completionHandler:^{
                            dispatch_group_leave(g);
                        }];
                }
                dispatch_group_notify(g, dispatch_get_main_queue(), ^{
                    save_base();
                    rexui_log([NSString
                        stringWithFormat:
                            @"cookies: %lu from %@ (%lu saved, %lu from its open session): %lu new, %lu "
                            @"newer in it, %lu the same (%lu kept longer in it), %lu kept (changed here since)",
                            (unsigned long)cookies.count, spec, (unsigned long)saved.count,
                            (unsigned long)session.count, (unsigned long)m.added, (unsigned long)m.updated,
                            (unsigned long)m.same, (unsigned long)m.extended, (unsigned long)m.kept]);
                    done_at[db] = NSDate.date;
                    NSArray* waiting = running[db];
                    [running removeObjectForKey:db];
                    for (void (^r)(void) in waiting)
                        r();
                });
            }];
        });
    });
}
