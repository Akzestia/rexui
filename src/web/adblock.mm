// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include <memory>
#include "web/web.h"

@interface RXSelectorCheck : NSObject <WKNavigationDelegate>
@property(nonatomic, strong) WKWebView* web;
@property(nonatomic, strong) NSArray<NSString*>* selectors;
@property(nonatomic, copy) void (^done)(NSIndexSet* valid);
@property(nonatomic, strong) RXSelectorCheck* keep;
@end

struct Filters {
    NSMutableOrderedSet<NSString*>* hosts = [NSMutableOrderedSet orderedSet];
    NSMutableSet<NSString*>* third_party = [NSMutableSet set];
    NSMutableOrderedSet<NSString*>* generic = [NSMutableOrderedSet orderedSet];
    NSMutableDictionary<NSString*, NSMutableArray<NSString*>*>* per_site = [NSMutableDictionary dictionary];
};

static bool is_host(NSString* h) {
    return h.length &&
        [h rangeOfString:@"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$"
                 options:NSRegularExpressionSearch]
            .location
        != NSNotFound;
}

static void read_filters(Filters& f, NSString* home) {
    for (NSString* name in @[@"easylist.txt", @"easyprivacy.txt"]) {
        NSString* text = [NSString stringWithContentsOfFile:[home stringByAppendingPathComponent:name]
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
        for (NSString* raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            NSString* l = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (!l.length || [l hasPrefix:@"!"] || [l hasPrefix:@"["] || [l hasPrefix:@"@@"])
                continue;
            if ([l hasPrefix:@"||"]) {
                bool third = [l hasSuffix:@"^$third-party"];
                NSString* body = third ? [l substringToIndex:l.length - 12] : l;
                if (![body hasSuffix:@"^"])
                    continue;
                NSString* h = [body substringWithRange:NSMakeRange(2, body.length - 3)].lowercaseString;
                if (!is_host(h))
                    continue;
                [f.hosts addObject:h];
                if (third)
                    [f.third_party addObject:h];
                continue;
            }
            if ([l containsString:@"#?#"] || [l containsString:@"#@#"] || [l containsString:@"#$#"] ||
                [l containsString:@"#%#"]) {
                continue;
            }
            NSRange hash = [l rangeOfString:@"##"];
            if (hash.location == NSNotFound)
                continue;
            NSString* sel = [l substringFromIndex:hash.location + 2];
            if (!sel.length || [sel containsString:@":-abp-"] || [sel containsString:@":style("] ||
                [sel containsString:@":remove("]) {
                continue;
            }
            if (hash.location == 0) {
                [f.generic addObject:sel];
                continue;
            }
            for (NSString* d in [[l substringToIndex:hash.location] componentsSeparatedByString:@","]) {
                NSString* dom = d.lowercaseString;
                if ([dom hasPrefix:@"~"] || !is_host(dom))
                    continue;
                if (!f.per_site[dom])
                    f.per_site[dom] = [NSMutableArray array];
                [f.per_site[dom] addObject:sel];
            }
        }
    }
    [f.generic addObjectsFromArray:@[@".adsbygoogle", @"[id^='div-gpt-ad']", @"[id^='google_ads_iframe']"]];
    NSString* pgl = [NSString stringWithContentsOfFile:[home stringByAppendingPathComponent:@"adblock.txt"]
                                              encoding:NSUTF8StringEncoding
                                                 error:nil];
    for (NSString* raw in [pgl componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString* h = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].lowercaseString;
        if (is_host(h)) {
            [f.hosts addObject:h];
            [f.third_party removeObject:h];
        }
    }
}

static NSDictionary* block_rule(NSString* host, bool third) {
    NSString* re = [host stringByReplacingOccurrencesOfString:@"." withString:@"\\."];
    NSMutableDictionary* trigger =
        [@{@"url-filter": [NSString stringWithFormat:@"^[^:]+://+([^:/]+\\.)?%@[:/]", re]} mutableCopy];
    if (third)
        trigger[@"load-type"] = @[@"third-party"];
    return @{@"trigger": trigger, @"action": @{@"type": @"block"}};
}

static NSDictionary* hide_rule(NSArray<NSString*>* selectors, NSArray<NSString*>* domains) {
    NSMutableDictionary* trigger = [@{@"url-filter": @".*"} mutableCopy];
    if (domains) {
        NSMutableArray* d = [NSMutableArray array];
        for (NSString* x in domains)
            [d addObject:[@"*" stringByAppendingString:x]];
        trigger[@"if-domain"] = d;
    }
    return @{
        @"trigger": trigger,
        @"action": @{@"type": @"css-display-none", @"selector": [selectors componentsJoinedByString:@", "]}
    };
}

@implementation RXSelectorCheck
- (void)webView:(WKWebView*)w didFinishNavigation:(WKNavigation*)nav {
    NSData* json = json_data(self.selectors, 0);
    NSString* js = [NSString
        stringWithFormat:
            @"(function (s) { const f = document.createDocumentFragment(), ok = [];"
             " s.forEach((x, i) => { try { f.querySelector(x); ok.push(i); } catch (e) {} }); return ok; })(%@)",
            [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]];
    [w evaluateJavaScript:js
        completionHandler:^(NSArray<NSNumber*>* ok, NSError* error) {
            NSMutableIndexSet* valid = [NSMutableIndexSet indexSet];
            for (NSNumber* i in ok)
                [valid addIndex:i.unsignedIntegerValue];
            if (error)
                rexui_log([NSString stringWithFormat:@"adblock: selector check: %@", error.localizedDescription]);
            self.web.navigationDelegate = nil;
            self.web = nil;
            self.done(valid);
            self.keep = nil;
        }];
}
@end

static void check_selectors(NSArray<NSString*>* selectors, void (^done)(NSIndexSet*)) {
    RXSelectorCheck* c = [RXSelectorCheck new];
    c.selectors = selectors;
    c.done = done;
    c.keep = c;
    WKWebViewConfiguration* cfg = [WKWebViewConfiguration new];
    cfg.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
    c.web = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10) configuration:cfg];
    c.web.navigationDelegate = c;
    [c.web loadHTMLString:@"<!doctype html><title></title>" baseURL:nil];
}

static void compile_chunks(NSArray<NSArray*>* chunks, NSUInteger i, NSMutableArray<WKContentRuleList*>* out,
                           void (^done)(NSArray<WKContentRuleList*>*)) {
    if (i >= chunks.count)
        return done(out);
    NSData* data = json_data(chunks[i], 0);
    NSString* json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    uint64_t fnv = 0xcbf29ce484222325;
    for (NSUInteger k = 0; k < data.length; k++)
        fnv = (fnv ^ ((const uint8_t*)data.bytes)[k]) * 0x100000001b3;
    NSString* ident = [NSString stringWithFormat:@"rexui-adblock-%lu-%llx", (unsigned long)i, (unsigned long long)fnv];
    WKContentRuleListStore* store = WKContentRuleListStore.defaultStore;
    auto next = ^(WKContentRuleList* list) {
        if (list)
            [out addObject:list];
        compile_chunks(chunks, i + 1, out, done);
    };
    [store
        lookUpContentRuleListForIdentifier:ident
                         completionHandler:^(WKContentRuleList* list, NSError*) {
                             if (list)
                                 return next(list);
                             NSDate* t0 = NSDate.date;
                             [store
                                 compileContentRuleListForIdentifier:ident
                                              encodedContentRuleList:json
                                                   completionHandler:^(WKContentRuleList* list2, NSError* error) {
                                                       if (list2) {
                                                           rexui_log([NSString
                                                               stringWithFormat:
                                                                   @"adblock: chunk %lu: %lu rules compiled in %.1f s",
                                                                   (unsigned long)i, (unsigned long)[chunks[i] count],
                                                                   -t0.timeIntervalSinceNow]);
                                                           return next(list2);
                                                       }
                                                       rexui_log([NSString
                                                           stringWithFormat:@"adblock: chunk %lu: %@", (unsigned long)i,
                                                                            error.localizedDescription]);
                                                       NSMutableArray* blocks = [NSMutableArray array];
                                                       for (NSDictionary* r in chunks[i]) {
                                                           if ([r[@"action"][@"type"] isEqualToString:@"block"])
                                                               [blocks addObject:r];
                                                       }
                                                       if (blocks.count == [chunks[i] count] || !blocks.count)
                                                           return next(nil);
                                                       NSMutableArray* rest = [chunks mutableCopy];
                                                       rest[i] = blocks;
                                                       compile_chunks(rest, i, out, done);
                                                   }];
                         }];
}

static void remove_stale_compiles(void) {
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* tmp = NSTemporaryDirectory();
    NSDate* cut = [NSDate dateWithTimeIntervalSinceNow:-3600];
    for (NSString* name in [fm contentsOfDirectoryAtPath:tmp error:nil]) {
        if (![name hasPrefix:@"ContentRuleList"])
            continue;
        NSString* path = [tmp stringByAppendingPathComponent:name];
        NSDate* at = [fm attributesOfItemAtPath:path error:nil].fileModificationDate;
        if (at && [at compare:cut] == NSOrderedAscending)
            [fm removeItemAtPath:path error:nil];
    }
}

void with_blocker(void (^done)(NSArray<WKContentRuleList*>*)) {
    static NSArray<WKContentRuleList*>* ready;
    static NSMutableArray* waiting;
    if (ready)
        return done(ready);
    if (waiting)
        return (void)[waiting addObject:done];
    waiting = [NSMutableArray arrayWithObject:done];
    auto finish = ^(NSArray<WKContentRuleList*>* lists) {
        ready = lists;
        for (void (^d)(NSArray<WKContentRuleList*>*) in waiting)
            d(lists);
        waiting = nil;
    };
    if (getenv("REXUI_NO_WEB"))
        return finish(@[]);
    NSString* home = NSProcessInfo.processInfo.environment[@"REXUI_HOME"]
        ?: [NSHomeDirectory() stringByAppendingPathComponent:@"rexui/build"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        remove_stale_compiles();
    });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        auto f = std::make_shared<Filters>();
        read_filters(*f, home);
        NSMutableOrderedSet<NSString*>* all = [f->generic mutableCopy];
        for (NSArray* sels in f->per_site.allValues)
            [all addObjectsFromArray:sels];
        NSArray<NSString*>* selectors = all.array;
        dispatch_async(dispatch_get_main_queue(), ^{
            check_selectors(selectors, ^(NSIndexSet* valid) {
                NSMutableSet<NSString*>* good = [NSMutableSet set];
                [valid enumerateIndexesUsingBlock:^(NSUInteger i, BOOL*) {
                    if (i < selectors.count)
                        [good addObject:selectors[i]];
                }];
                NSMutableArray* rules = [NSMutableArray array];
                for (NSString* h in f->hosts)
                    [rules addObject:block_rule(h, [f->third_party containsObject:h])];
                NSMutableArray<NSString*>* generic = [NSMutableArray array];
                for (NSString* s in f->generic) {
                    if ([good containsObject:s])
                        [generic addObject:s];
                }
                for (NSUInteger i = 0; i < generic.count; i += 250) {
                    [rules addObject:hide_rule([generic subarrayWithRange:NSMakeRange(i, MIN(250, generic.count - i))],
                                               nil)];
                }
                NSMutableDictionary<NSString*, NSMutableArray<NSString*>*>* by_selectors =
                    [NSMutableDictionary dictionary];
                for (NSString* dom in f->per_site) {
                    NSMutableArray* sels = [NSMutableArray array];
                    for (NSString* s in f->per_site[dom]) {
                        if ([good containsObject:s])
                            [sels addObject:s];
                    }
                    if (!sels.count)
                        continue;
                    NSString* key = [sels componentsJoinedByString:@"\n"];
                    if (!by_selectors[key])
                        by_selectors[key] = [NSMutableArray array];
                    [by_selectors[key] addObject:dom];
                }
                for (NSString* key in by_selectors) {
                    [rules addObject:hide_rule([key componentsSeparatedByString:@"\n"], by_selectors[key])];
                }
                rexui_log([NSString
                    stringWithFormat:@"adblock: %lu servers, %lu hiding rules on every site, %lu per site, "
                                      "%lu selectors WebKit wouldn't take",
                                     (unsigned long)f->hosts.count, (unsigned long)generic.count,
                                     (unsigned long)by_selectors.count, (unsigned long)(selectors.count - good.count)]);
                NSMutableArray<NSArray*>* chunks = [NSMutableArray array];
                for (NSUInteger i = 0; i < rules.count; i += 30000) {
                    [chunks addObject:[rules subarrayWithRange:NSMakeRange(i, MIN(30000, rules.count - i))]];
                }
                compile_chunks(chunks, 0, [NSMutableArray array], finish);
            });
        });
    });
}
