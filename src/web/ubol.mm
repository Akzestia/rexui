// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "web/web.h"

@implementation RXExtWindow
- (NSArray<id<WKWebExtensionTab>>*)tabsForWebExtensionContext:(WKWebExtensionContext*)c {
    return g_webs.allObjects;
}
- (id<WKWebExtensionTab>)activeTabForWebExtensionContext:(WKWebExtensionContext*)c {
    for (RXNode* n in g_webs) {
        if (n.view.window && !n.view.hiddenOrHasHiddenAncestor)
            return n;
    }
    return g_webs.anyObject;
}
- (WKWebExtensionWindowType)windowTypeForWebExtensionContext:(WKWebExtensionContext*)c {
    return WKWebExtensionWindowTypeNormal;
}
- (WKWebExtensionWindowState)windowStateForWebExtensionContext:(WKWebExtensionContext*)c {
    return WKWebExtensionWindowStateNormal;
}
@end
@implementation RXExtDelegate
- (NSArray<id<WKWebExtensionWindow>>*)webExtensionController:(WKWebExtensionController*)c
                              openWindowsForExtensionContext:(WKWebExtensionContext*)x {
    return @[self.window];
}
- (id<WKWebExtensionWindow>)webExtensionController:(WKWebExtensionController*)c
                  focusedWindowForExtensionContext:(WKWebExtensionContext*)x {
    return self.window;
}
- (void)webExtensionController:(WKWebExtensionController*)c
          promptForPermissions:(NSSet<WKWebExtensionPermission>*)perms
                         inTab:(id<WKWebExtensionTab>)tab
           forExtensionContext:(WKWebExtensionContext*)x
             completionHandler:(void (^)(NSSet<WKWebExtensionPermission>*, NSDate*))done {
    done(perms, nil);
}
- (void)webExtensionController:(WKWebExtensionController*)c
    promptForPermissionMatchPatterns:(NSSet<WKWebExtensionMatchPattern*>*)patterns
                               inTab:(id<WKWebExtensionTab>)tab
                 forExtensionContext:(WKWebExtensionContext*)x
                   completionHandler:(void (^)(NSSet<WKWebExtensionMatchPattern*>*, NSDate*))done {
    done(patterns, nil);
}
- (void)webExtensionController:(WKWebExtensionController*)c
    promptForPermissionToAccessURLs:(NSSet<NSURL*>*)urls
                              inTab:(id<WKWebExtensionTab>)tab
                forExtensionContext:(WKWebExtensionContext*)x
                  completionHandler:(void (^)(NSSet<NSURL*>*, NSDate*))done {
    done(urls, nil);
}
@end

RXExtDelegate* g_ext_delegate;

WKWebExtensionController* extensions(void) {
    static WKWebExtensionController* c = [] {
        NSUUID* id = [[NSUUID alloc] initWithUUIDString:@"5E1C9A2B-7D4F-4C1E-9B3A-1F2E3D4C5B6A"];
        WKWebExtensionController* c = [[WKWebExtensionController alloc]
            initWithConfiguration:[WKWebExtensionControllerConfiguration configurationWithIdentifier:id]];
        g_ext_delegate = [RXExtDelegate new];
        g_ext_delegate.window = [RXExtWindow new];
        c.delegate = g_ext_delegate;
        return c;
    }();
    return c;
}

static NSString* ubol_dir(void) {
    NSString* home = NSProcessInfo.processInfo.environment[@"REXUI_HOME"]
        ?: [NSHomeDirectory() stringByAppendingPathComponent:@"rexui/build"];
    return [home stringByAppendingPathComponent:@"ubol/current"];
}

static void with_ubol(void (^done)(WKWebExtensionContext*)) {
    if (getenv("REXUI_NO_WEB"))
        return done(nil);
    static bool tried;
    static NSMutableArray* waiting;
    if (tried && !waiting)
        return done(g_ubol);
    if (waiting)
        return (void)[waiting addObject:done];
    tried = true;
    waiting = [NSMutableArray arrayWithObject:done];
    auto finish = ^(WKWebExtensionContext* ctx) {
        g_ubol = ctx;
        for (void (^d)(WKWebExtensionContext*) in waiting)
            d(ctx);
        waiting = nil;
    };
    NSString* dir = ubol_dir();
    if (![NSFileManager.defaultManager fileExistsAtPath:[dir stringByAppendingPathComponent:@"manifest.json"]]) {
        return finish(nil);
    }
    [WKWebExtension
        extensionWithResourceBaseURL:[NSURL fileURLWithPath:dir isDirectory:YES]
                   completionHandler:^(WKWebExtension* ext, NSError* error) {
                       dispatch_async(dispatch_get_main_queue(), ^{
                           if (!ext) {
                               rexui_log([NSString stringWithFormat:@"ublock: %@", error.localizedDescription]);
                               return finish(nil);
                           }
                           WKWebExtensionContext* ctx = [WKWebExtensionContext contextForExtension:ext];
                           ctx.uniqueIdentifier = @"rexui.ubol";
                           for (WKWebExtensionPermission p in
                                [ext.requestedPermissions setByAddingObjectsFromSet:ext.optionalPermissions]) {
                               [ctx setPermissionStatus:WKWebExtensionContextPermissionStatusGrantedExplicitly
                                          forPermission:p];
                           }
                           [ctx setPermissionStatus:WKWebExtensionContextPermissionStatusGrantedExplicitly
                                    forMatchPattern:WKWebExtensionMatchPattern.allURLsMatchPattern];
                           NSError* err = nil;
                           if (![extensions() loadExtensionContext:ctx error:&err]) {
                               rexui_log([NSString stringWithFormat:@"ublock: %@", err.localizedDescription]);
                               return finish(nil);
                           }
                           for (NSError* e in ext.errors)
                               rexui_log([NSString stringWithFormat:@"ublock: manifest: %@", e.localizedDescription]);
                           rexui_log([NSString stringWithFormat:@"ublock: uBlock Origin Lite %@ loaded", ext.version]);
                           for (RXNode* n in g_webs)
                               [extensions() didOpenTab:n];
                           finish(ctx);
                       });
                   }];
}

void apply_adblock(RXNode* n, bool first) {
    WKUserContentController* ucc = ((WKWebView*)n.view).configuration.userContentController;
    if (!flag(n, P::adblock, true)) {
        [ucc removeAllContentRuleLists];
        return;
    }
    if (first)
        n.preparing++;
    __weak RXNode* weak = n;
    with_ubol(^(WKWebExtensionContext* ubol) {
        RXNode* n2 = weak;
        if (!n2)
            return;
        if (ubol) {
            [extensions() didOpenTab:n2];
            if (first)
                web_prepared(n2);
            return;
        }
        with_blocker(^(NSArray<WKContentRuleList*>* lists) {
            RXNode* held = weak;
            if (!held)
                return;
            if (flag(held, P::adblock, true)) {
                for (WKContentRuleList* list in lists)
                    [ucc addContentRuleList:list];
            }
            if (first)
                web_prepared(held);
        });
    });
}
