// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "web/web.h"

#include <sqlite3.h>

@interface RXStorageImport : NSObject <WKNavigationDelegate>
@property(nonatomic, strong) WKWebView* web;
@property(nonatomic, strong) NSMutableArray<NSDictionary*>* todo;
@property(nonatomic, copy) void (^done)(void);
@property(nonatomic, strong) RXStorageImport* keep;
@end

@implementation RXStorageImport
- (void)next {
    NSDictionary* job = self.todo.firstObject;
    if (!job) {
        self.web.navigationDelegate = nil;
        self.web = nil;
        if (self.done)
            self.done();
        self.keep = nil;
        return;
    }
    [self.web loadHTMLString:@"<!doctype html><title></title>" baseURL:job[@"origin"]];
}
- (void)webView:(WKWebView*)w didFinishNavigation:(WKNavigation*)nav {
    NSDictionary* job = self.todo.firstObject;
    NSData* json = json_data(job[@"items"], 0);
    NSString* js =
        [NSString stringWithFormat:@"(function (items) { let n = 0; for (const k in items) { try { "
                                   @"localStorage.setItem(k, items[k]); n++; } catch (e) {} } return n; })(%@)",
                                   [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]];
    [w evaluateJavaScript:js
        completionHandler:^(id n, NSError* error) {
            NSURL* origin = job[@"origin"];
            if (error) {
                rexui_log([NSString stringWithFormat:@"storage: %@: %@", origin.host, error.localizedDescription]);
            } else {
                rexui_log([NSString stringWithFormat:@"storage: %@ keys for %@", n, origin.host]);
                NSMutableDictionary* stamps =
                    [[g_state dictionaryForKey:@"storage"] mutableCopy] ?: [NSMutableDictionary dictionary];
                stamps[origin.absoluteString] = job[@"stamp"];
                [g_state setObject:stamps forKey:@"storage"];
            }
            [self.todo removeObjectAtIndex:0];
            [self next];
        }];
}
- (void)webView:(WKWebView*)w didFailNavigation:(WKNavigation*)nav withError:(NSError*)e {
    [self.todo removeObjectAtIndex:0];
    [self next];
}
- (void)webView:(WKWebView*)w didFailProvisionalNavigation:(WKNavigation*)nav withError:(NSError*)e {
    [self.todo removeObjectAtIndex:0];
    [self next];
}
@end

void import_storage(RXNode* n) {
    id sites = obj(n, P::storage);
    NSString* spec = str(n, P::cookies, @"");
    NSString* file = spec.length ? cookie_file(spec) : nil;
    if (![sites isKindOfClass:NSArray.class] || ![sites count] || !file) {
        if ([sites count])
            rexui_log(@"storage: set cookies to the browser to read it from");
        return web_prepared(n);
    }
    NSString* profile = file.stringByDeletingLastPathComponent;
    __weak RXNode* weak = n;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray* todo = [NSMutableArray array];
        NSDictionary* stamps = [g_state dictionaryForKey:@"storage"];
        for (id site in sites) {
            NSURL* origin = [site isKindOfClass:NSString.class] ? origin_url(site) : nil;
            NSDictionary* items = origin ? read_storage(profile, origin) : nil;
            if (!items.count) {
                rexui_log([NSString stringWithFormat:@"storage: nothing for %@ in %@", site, spec]);
                continue;
            }
            NSData* json = json_data(items, NSJSONWritingSortedKeys);
            uint64_t h = 0xcbf29ce484222325;
            for (NSUInteger i = 0; i < json.length; i++)
                h = (h ^ ((const uint8_t*)json.bytes)[i]) * 0x100000001b3;
            NSString* stamp = [NSString stringWithFormat:@"%llx", (unsigned long long)h];
            if ([stamps[origin.absoluteString] isEqualToString:stamp])
                continue;
            [todo addObject:@{@"origin": origin, @"items": items, @"stamp": stamp}];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            RXNode* n2 = weak;
            if (!n2)
                return;
            WKWebView* mine = (WKWebView*)n2.view;
            RXStorageImport* imp = [RXStorageImport new];
            WKWebViewConfiguration* cfg = [WKWebViewConfiguration new];
            cfg.websiteDataStore = mine.configuration.websiteDataStore;
            imp.web = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10) configuration:cfg];
            imp.web.navigationDelegate = imp;
            imp.todo = todo;
            imp.keep = imp;
            imp.done = ^{
                if (RXNode* held = weak)
                    web_prepared(held);
            };
            [imp next];
        });
    });
}
