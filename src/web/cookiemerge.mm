// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "web/cookiemerge.h"

static uint64_t fnv(NSString* s, uint64_t h = 1469598103934665603ull) {
    for (const char* c = s.UTF8String ?: ""; *c; c++)
        h = (h ^ uint8_t(*c)) * 1099511628211ull;
    return h;
}
static NSString* cookie_key(NSHTTPCookie* c) {
    NSString* domain = [c.domain hasPrefix:@"."] ? [c.domain substringFromIndex:1] : c.domain;
    return [NSString
        stringWithFormat:@"%016llx", fnv(c.path ?: @"/", fnv(domain.lowercaseString ?: @"", fnv(c.name ?: @"")))];
}
static bool lasts_longer(NSHTTPCookie* zen, NSHTTPCookie* ours) {
    if (!ours)
        return false;
    if (zen.sessionOnly)
        return false;
    if (ours.sessionOnly)
        return true;
    return zen.expiresDate && ours.expiresDate && [zen.expiresDate timeIntervalSinceDate:ours.expiresDate] > 60;
}

CookieMerge cookie_merge(NSArray<NSHTTPCookie*>* zen, NSArray<NSHTTPCookie*>* have,
                         NSMutableDictionary<NSString*, NSNumber*>* b) {
    CookieMerge m;
    NSMutableDictionary<NSString*, NSNumber*>* now = [NSMutableDictionary dictionaryWithCapacity:have.count];
    NSMutableDictionary<NSString*, NSHTTPCookie*>* mine = [NSMutableDictionary dictionaryWithCapacity:have.count];
    for (NSHTTPCookie* c in have) {
        NSString* k = cookie_key(c);
        now[k] = @(fnv(c.value ?: @""));
        mine[k] = c;
    }
    for (NSHTTPCookie* c in zen) {
        NSString *k = cookie_key(c), *zk = [@"z" stringByAppendingString:k], *ok = [@"o" stringByAppendingString:k];
        NSNumber *theirs = @(fnv(c.value ?: @"")), *ours = now[k], *zen_was = b[zk], *ours_was = b[ok];
        bool zen_moved = zen_was && ![zen_was isEqualToNumber:theirs];
        bool ours_moved = !ours_was || (ours && ![ours_was isEqualToNumber:ours]);
        if (!ours) {
            [m.take addObject:c], m.added++;
            ours = theirs;
        } else if ([ours isEqualToNumber:theirs]) {
            m.same++;
            if (lasts_longer(c, mine[k]))
                [m.take addObject:c], m.extended++;
        } else if (zen_moved && !ours_moved) {
            [m.take addObject:c], m.updated++;
            ours = theirs;
        } else {
            m.kept++;
        }
        b[zk] = theirs;
        b[ok] = ours;
    }
    return m;
}
