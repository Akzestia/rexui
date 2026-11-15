// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "base/rexui.h"

static bool needs_scrub(id v, int depth) {
    if (depth > 64)
        return true;
    if ([v isKindOfClass:NSString.class] || v == NSNull.null)
        return false;
    if ([v isKindOfClass:NSNumber.class]) {
        if (CFGetTypeID((__bridge CFTypeRef)v) == CFBooleanGetTypeID())
            return false;
        double d = [v doubleValue];
        return !isfinite(d);
    }
    if ([v isKindOfClass:NSArray.class]) {
        for (id x in v)
            if (needs_scrub(x, depth + 1))
                return true;
        return false;
    }
    if ([v isKindOfClass:NSDictionary.class]) {
        for (id k in v)
            if (![k isKindOfClass:NSString.class] || needs_scrub([v objectForKey:k], depth + 1))
                return true;
        return false;
    }
    return true;
}

static id scrub(id v, int depth) {
    if (depth > 64)
        return NSNull.null;
    if ([v isKindOfClass:NSString.class] || v == NSNull.null)
        return v;
    if ([v isKindOfClass:NSNumber.class]) {
        if (CFGetTypeID((__bridge CFTypeRef)v) == CFBooleanGetTypeID())
            return v;
        return isfinite([v doubleValue]) ? v : NSNull.null;
    }
    if ([v isKindOfClass:NSArray.class]) {
        NSMutableArray* out = [NSMutableArray arrayWithCapacity:[v count]];
        for (id x in v)
            [out addObject:scrub(x, depth + 1)];
        return out;
    }
    if ([v isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary* out = [NSMutableDictionary dictionaryWithCapacity:[v count]];
        for (id k in v)
            if ([k isKindOfClass:NSString.class])
                out[k] = scrub([v objectForKey:k], depth + 1);
        return out;
    }
    return NSNull.null;
}

NSData* json_data(id obj, NSJSONWritingOptions options) {
    if (!obj)
        obj = NSNull.null;
    if (needs_scrub(obj, 0))
        obj = scrub(obj, 0);
    bool fragment = ![obj isKindOfClass:NSArray.class] && ![obj isKindOfClass:NSDictionary.class];
    if (fragment)
        options |= NSJSONWritingFragmentsAllowed;
    @try {
        return [NSJSONSerialization dataWithJSONObject:obj options:options error:nil];
    } @catch (NSException* e) {
        rexui_log([NSString stringWithFormat:@"json: not written (%@)", e.reason]);
        return nil;
    }
}

NSString* json_string(id obj, NSJSONWritingOptions options) {
    NSData* d = json_data(obj, options);
    return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
}
