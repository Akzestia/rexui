// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "web/web.h"

static NSString* sessions_dir(void) {
    NSString* d = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/rexui/sessions"];
    [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

static NSString* pane_stem(RXDoc* doc) {
    NSString* block = [doc.pane_block stringByReplacingOccurrencesOfString:@":" withString:@"-"];
    block = [block stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    return [NSString stringWithFormat:@"%@.%@", doc.path.lastPathComponent, block];
}
static NSString* session_stem(RXDoc* doc) {
    if (!doc.pane || !doc.pane_block.length)
        return doc.path.lastPathComponent;
    NSString* stem = pane_stem(doc);
    return doc.pane_program.length ? [NSString stringWithFormat:@"%@.%@", stem, doc.pane_program] : stem;
}

static uint64_t fnv64(NSString* s) {
    uint64_t h = 1469598103934665603ull;
    for (const char* c = s.UTF8String ?: ""; *c; c++)
        h = (h ^ (uint8_t)*c) * 1099511628211ull;
    return h;
}

static NSString* session_key(RXNode* n) {
    NSString* ident = string_of(obj(n, @"id"));
    if (ident.length) {
        NSCharacterSet* bad = [NSCharacterSet characterSetWithCharactersInString:@"/:"];
        return [@"id-"
            stringByAppendingString:[[ident componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"-"]];
    }
    NSString* url = str(n, P::url, @"");
    if (url.length)
        return [NSString stringWithFormat:@"url-%016llx", fnv64(url)];
    return [NSString stringWithFormat:@"%d", session_index(n)];
}

int session_index(RXNode* n) {
    int index = 0;
    for (RXNode* o in n.doc.nodes.allValues) {
        if (o != n && is_elem(o, E::WebView) && o.uid < n.uid)
            index++;
    }
    return index;
}

static dispatch_queue_t sessions_queue(void);
static NSMutableSet<NSString*>* forgotten(void) {
    static NSMutableSet<NSString*>* set = [NSMutableSet set];
    return set;
}
static bool is_forgotten(NSString* path) {
    NSString* name = path.lastPathComponent;
    for (NSString* stem in forgotten())
        if ([name hasPrefix:stem])
            return true;
    return false;
}

void session_begin(RXNode* n) {
    if (n.session || !n.doc)
        return;
    NSString *dir = sessions_dir(), *stem = session_stem(n.doc);
    n.session = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@.plist", stem, session_key(n)]];
    if (n.doc.pane) {
        NSString* again = [stem stringByAppendingString:@"."];
        NSString* pane = n.doc.pane_block.length && n.doc.pane_program.length
            ? [pane_stem(n.doc) stringByAppendingString:@"."]
            : nil;
        dispatch_async(sessions_queue(), ^{
            [forgotten() removeObject:again];
            for (NSString* f in pane ? [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil] : @[]) {
                if (pane && [f hasPrefix:pane] && ![f hasPrefix:again] && [f hasSuffix:@".plist"])
                    [NSFileManager.defaultManager removeItemAtPath:[dir stringByAppendingPathComponent:f] error:nil];
            }
        });
    }
    NSString* from = n.session;
    NSString* by_place =
        [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%d.plist", stem, session_index(n)]];
    if (![NSFileManager.defaultManager fileExistsAtPath:from] &&
        [NSFileManager.defaultManager fileExistsAtPath:by_place])
        from = by_place;
    if (NSString* page = n.doc.restore_pages[n.session.lastPathComponent]) {
        n.restore = page;
        [n.doc.restore_pages removeObjectForKey:n.session.lastPathComponent];
    }
    NSDictionary* saved = [NSDictionary dictionaryWithContentsOfFile:from];
    if ([saved[@"state"] isKindOfClass:NSData.class] && [saved[@"url"] length]) {
        n.saved_state = saved[@"state"];
        n.waiting = saved[@"url"];
    }
}

static dispatch_queue_t sessions_queue(void) {
    static dispatch_queue_t q = dispatch_queue_create("rexui.sessions", DISPATCH_QUEUE_SERIAL);
    return q;
}
void sessions_flush(void) {
    dispatch_sync(sessions_queue(),
                  ^{
                  });
}

void session_save(RXNode* n) {
    if (!n.session)
        return;
    WKWebView* w = (WKWebView*)n.view;
    id state = n.saved_state ?: (w.URL ? w.interactionState : nil);
    NSString* url = n.saved_state ? n.waiting : w.URL.absoluteString;
    if (![state isKindOfClass:NSData.class] || !url.length)
        return;
    static NSMutableDictionary<NSString*, NSNumber*>* written;
    NSData* d = state;
    uint64_t h = 1469598103934665603ull;
    const uint8_t* b = static_cast<const uint8_t*>(d.bytes);
    for (NSUInteger i = 0; i < d.length; i++)
        h = (h ^ b[i]) * 1099511628211ull;
    for (const char* c = url.UTF8String ?: ""; *c; c++)
        h = (h ^ uint8_t(*c)) * 1099511628211ull;
    if (!written)
        written = [NSMutableDictionary dictionary];
    NSString* path = n.session;
    if ([written[path] unsignedLongLongValue] == h)
        return;
    written[path] = @(h);
    dispatch_queue_t q = sessions_queue();
    NSDictionary* plist = @{@"url": url, @"state": d};
    dispatch_async(q, ^{
        if (!is_forgotten(path))
            [plist writeToFile:path atomically:YES];
    });
}

void session_changed(RXNode* n) {
    if (!n.session)
        session_begin(n);
    if (n.save_pending || !n.session)
        return;
    n.save_pending = true;
    __weak RXNode* weak = n;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        RXNode* n2 = weak;
        if (!n2)
            return;
        n2.save_pending = false;
        if (n2.doc)
            session_save(n2);
    });
}

void sessions_forget_pane(RXDoc* doc) {
    if (!doc.pane || !doc.pane_block.length)
        return;
    NSString *dir = sessions_dir(), *stem = [session_stem(doc) stringByAppendingString:@"."];
    dispatch_async(sessions_queue(), ^{
        [forgotten() addObject:stem];
        for (NSString* f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]) {
            if ([f hasPrefix:stem] && [f hasSuffix:@".plist"])
                [NSFileManager.defaultManager removeItemAtPath:[dir stringByAppendingPathComponent:f] error:nil];
        }
    });
}
