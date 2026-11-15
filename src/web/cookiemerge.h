// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#import <Foundation/Foundation.h>

struct CookieMerge {
    NSMutableArray<NSHTTPCookie*>* take = [NSMutableArray array];
    NSUInteger added = 0, updated = 0, same = 0, kept = 0;
    NSUInteger extended = 0;
};

CookieMerge cookie_merge(NSArray<NSHTTPCookie*>* zen, NSArray<NSHTTPCookie*>* have,
                         NSMutableDictionary<NSString*, NSNumber*>* base);
