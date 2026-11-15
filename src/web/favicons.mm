// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "web/web.h"

static NSString* favicon_dir(void) {
    NSString* d = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/rexui/favicons"];
    [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

static void set_favicon(RXNode* n, NSString* path) {
    if (n.doc.ctx)
        doc_call(n.doc, @"update", @[@(n.uid), @{@"favicon": path ?: @""}]);
}

static NSData* favicon_png(NSData* data) {
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr);
    if (!src)
        return nil;
    size_t n = CGImageSourceGetCount(src), best = 0;
    double area = -1;
    for (size_t i = 0; i < n; i++) {
        NSDictionary* p = (__bridge_transfer NSDictionary*)CGImageSourceCopyPropertiesAtIndex(src, i, nullptr);
        double a = [p[(id)kCGImagePropertyPixelWidth] doubleValue] * [p[(id)kCGImagePropertyPixelHeight] doubleValue];
        if (a > area)
            area = a, best = i;
    }
    CGImageRef img = n ? CGImageSourceCreateImageAtIndex(src, best, nullptr) : nullptr;
    CFRelease(src);
    if (!img)
        return nil;
    NSMutableData* out = [NSMutableData data];
    CGImageDestinationRef dst =
        CGImageDestinationCreateWithData((__bridge CFMutableDataRef)out, CFSTR("public.png"), 1, nullptr);
    bool ok = false;
    if (dst) {
        CGImageDestinationAddImage(dst, img, nullptr);
        ok = CGImageDestinationFinalize(dst);
        CFRelease(dst);
    }
    CGImageRelease(img);
    return ok ? out : nil;
}

static void fetch_favicon(NSArray<NSString*>* urls, NSUInteger i, NSString* file, void (^done)(NSString*)) {
    if (i >= urls.count)
        return dispatch_async(dispatch_get_main_queue(), ^{
            done(nil);
        });
    NSURL* u = [NSURL URLWithString:urls[i]];
    if (!u
        || !([u.scheme isEqualToString:@"https"] || [u.scheme isEqualToString:@"http"] ||
             [u.scheme isEqualToString:@"data"])) {
        return fetch_favicon(urls, i + 1, file, done);
    }
    [[NSURLSession.sharedSession dataTaskWithURL:u
                               completionHandler:^(NSData* data, NSURLResponse*, NSError*) {
                                   NSData* png = data.length ? favicon_png(data) : nil;
                                   if (png && [png writeToFile:file atomically:YES]) {
                                       dispatch_async(dispatch_get_main_queue(), ^{
                                           done(file);
                                       });
                                   } else {
                                       fetch_favicon(urls, i + 1, file, done);
                                   }
                               }] resume];
}

static NSArray<NSString*>* icon_links(NSString* html, NSURL* page) {
    NSMutableArray<NSDictionary*>* found = [NSMutableArray array];
    NSRegularExpression* link = [NSRegularExpression regularExpressionWithPattern:@"<link\\b[^>]*>"
                                                                          options:NSRegularExpressionCaseInsensitive
                                                                            error:nil];
    auto attr = ^NSString*(NSString* tag, NSString* name) {
        NSString* pat = [NSString stringWithFormat:@"\\b%@\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", name];
        NSRegularExpression* re = [NSRegularExpression regularExpressionWithPattern:pat
                                                                            options:NSRegularExpressionCaseInsensitive
                                                                              error:nil];
        NSTextCheckingResult* m = [re firstMatchInString:tag options:0 range:NSMakeRange(0, tag.length)];
        if (!m)
            return nil;
        for (NSUInteger g = 2; g <= 4; g++) {
            if ([m rangeAtIndex:g].location != NSNotFound)
                return [tag substringWithRange:[m rangeAtIndex:g]];
        }
        return nil;
    };
    for (NSTextCheckingResult* m in [link matchesInString:html options:0 range:NSMakeRange(0, html.length)]) {
        NSString* tag = [html substringWithRange:m.range];
        NSString *rel = attr(tag, @"rel").lowercaseString, *href = attr(tag, @"href");
        if (!href.length || !([rel containsString:@"icon"]))
            continue;
        NSURL* u = [NSURL URLWithString:[href stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"]
                          relativeToURL:page];
        if (!u)
            continue;
        double score = [rel containsString:@"apple-touch"] ? 1000 : 0;
        NSString* sizes = attr(tag, @"sizes");
        if (sizes.length)
            score += sizes.doubleValue;
        if ([u.path.lowercaseString hasSuffix:@".svg"] || [attr(tag, @"type") containsString:@"svg"])
            score -= 500;
        [found addObject:@{@"url": u.absoluteString, @"score": @(score)}];
    }
    [found sortUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
        return [b[@"score"] compare:a[@"score"]];
    }];
    NSMutableArray* out = [NSMutableArray array];
    for (NSDictionary* f in found)
        [out addObject:f[@"url"]];
    [out addObject:[NSString stringWithFormat:@"%@://%@/favicon.ico", page.scheme, page.host]];
    return out;
}

static NSString* favicon_file(NSString* host) {
    return [favicon_dir() stringByAppendingPathComponent:[host stringByAppendingString:@".png"]];
}

void preload_favicon(RXNode* n, NSString* text) {
    NSURL* page = web_url(n, text);
    NSString* host = page.host;
    if (!host.length || ![@[@"http", @"https"] containsObject:page.scheme])
        return;
    NSString* file = favicon_file(host);
    NSDate* m = [NSFileManager.defaultManager attributesOfItemAtPath:file error:nil].fileModificationDate;
    if (m)
        set_favicon(n, file);
    if (m && -m.timeIntervalSinceNow < 7 * 86400)
        return;
    NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:page];
    [req setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
                  @"Version/26.0 Safari/605.1.15"
        forHTTPHeaderField:@"User-Agent"];
    __weak RXNode* weak = n;
    [[NSURLSession.sharedSession
        dataTaskWithRequest:req
          completionHandler:^(NSData* data, NSURLResponse* resp, NSError*) {
              NSData* head = data.length > 512 * 1024 ? [data subdataWithRange:NSMakeRange(0, 512 * 1024)] : data;
              NSString *html = [[NSString alloc] initWithData:head ?: NSData.data encoding:NSUTF8StringEncoding]
                             ?: [[NSString alloc] initWithData:head ?: NSData.data encoding:NSISOLatin1StringEncoding] ?: @"";
              NSArray* urls = icon_links(html, resp.URL ?: page);
              fetch_favicon(urls, 0, file, ^(NSString* path) {
                  RXNode* n2 = weak;
                  if (n2 && path)
                      set_favicon(n2, path);
              });
          }] resume];
}

void update_favicon(RXNode* n) {
    WKWebView* w = (WKWebView*)n.view;
    NSString* host = w.URL.host;
    if (!host.length)
        return set_favicon(n, nil);
    NSString* file = favicon_file(host);
    NSDate* m = [NSFileManager.defaultManager attributesOfItemAtPath:file error:nil].fileModificationDate;
    if (m)
        set_favicon(n, file);
    if (m && -m.timeIntervalSinceNow < 7 * 86400)
        return;
    NSString* js =
        @"(() => {"
         " const score = (e) => { let s = 0; const r = (e.rel || '').toLowerCase();"
         "  if (r.includes('apple-touch')) s += 1000;"
         "  const m = /(\\d+)x(\\d+)/.exec(e.sizes && e.sizes.value || ''); if (m) s += +m[1];"
         "  if (/\\.svg(\\?|$)/.test(e.href) || e.type === 'image/svg+xml') s -= 500; return s; };"
         " const links = [...document.querySelectorAll('link[rel~=\"icon\"], link[rel^=\"apple-touch-icon\"]')];"
         " return links.sort((a, b) => score(b) - score(a)).map((e) => e.href).concat([location.origin + "
         "'/favicon.ico']);"
         "})()";
    __weak RXNode* weak = n;
    [w evaluateJavaScript:js
        completionHandler:^(NSArray* urls, NSError*) {
            if (![urls isKindOfClass:NSArray.class])
                return;
            fetch_favicon(urls, 0, file, ^(NSString* path) {
                RXNode* n2 = weak;
                WKWebView* w2 = (WKWebView*)n2.view;
                if (n2 && path && [w2.URL.host isEqualToString:host])
                    set_favicon(n2, path);
            });
        }];
}
