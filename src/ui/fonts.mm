// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "ui/ui.h"

#import <CoreText/CoreText.h>

static NSArray<NSURL*>* font_files(NSString* dir) {
    NSMutableArray<NSURL*>* out = [NSMutableArray array];
    NSFileManager* fm = NSFileManager.defaultManager;
    NSSet* kinds = [NSSet setWithArray:@[@"ttf", @"otf", @"ttc", @"otc"]];
    NSString* root = [dir stringByAppendingPathComponent:@"fonts"];
    NSDirectoryEnumerator* e = [fm enumeratorAtPath:root];
    for (NSString* rel in e) {
        if (e.level > 2)
            [e skipDescendants];
        if ([rel.lastPathComponent hasPrefix:@"."])
            continue;
        if ([kinds containsObject:rel.pathExtension.lowercaseString])
            [out addObject:[NSURL fileURLWithPath:[root stringByAppendingPathComponent:rel]]];
    }
    return [out sortedArrayUsingComparator:^NSComparisonResult(NSURL* a, NSURL* b) {
        return [a.path compare:b.path];
    }];
}

void ui_fonts_for(NSString* dir) {
    static NSArray<NSURL*>* registered = @[];
    NSArray<NSURL*>* want = dir.length ? font_files(dir) : @[];
    if ([want isEqualToArray:registered])
        return;
    for (NSURL* u in registered) {
        if (![want containsObject:u])
            CTFontManagerUnregisterFontsForURL((__bridge CFURLRef)u, kCTFontManagerScopeProcess, nullptr);
    }
    int ok = 0;
    for (NSURL* u in want) {
        if ([registered containsObject:u]) {
            ok++;
            continue;
        }
        CFErrorRef err = nullptr;
        if (CTFontManagerRegisterFontsForURL((__bridge CFURLRef)u, kCTFontManagerScopeProcess, &err))
            ok++;
        else {
            NSError* e = (__bridge_transfer NSError*)err;
            if (e.code == kCTFontManagerErrorAlreadyRegistered)
                ok++;
            else
                rexui_log([NSString stringWithFormat:@"fonts: %@: %@", u.lastPathComponent, e.localizedDescription]);
        }
    }
    if (want.count || registered.count)
        rexui_log([NSString
            stringWithFormat:@"fonts: %d of %lu from %@", ok, (unsigned long)want.count, dir.lastPathComponent]);
    registered = want;
    font_cache_clear();
}
