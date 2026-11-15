// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include "ui/ui.h"
#include "web/cookiemerge.h"
#include "web/profile.h"

@interface RXExtWindow : NSObject <WKWebExtensionWindow>
@end
struct Filters;

@interface RXExtDelegate : NSObject <WKWebExtensionControllerDelegate>
@property(nonatomic, strong) RXExtWindow* window;
@end

extern NSHashTable<RXNode*>* g_webs;
extern WKWebExtensionContext* g_ubol;
extern RXExtDelegate* g_ext_delegate;

void session_begin(RXNode* n);
int session_index(RXNode* n);
void session_save(RXNode* n);
void sessions_flush(void);
void session_changed(RXNode* n);
void sessions_forget_pane(RXDoc* doc);

void web_place(RXNode* n, WKWebView* w, NSView* clip, NSRect f, NSRect c);
void web_sizes_watch(WKWebView* w);
WKUserScript* web_sizes_script(void);

WKWebView* make_webview(RXNode* n);
NSURL* web_url(RXNode* n, NSString* text);
NSURL* web_url_with(NSString* text, NSString* search);
bool on_screen(RXNode* n);
void web_load(RXNode* n, NSString* text);
void web_adblock_settings(RXNode* n);
void web_prepared(RXNode* n);
void close_web(RXNode* n);
RXNode* web_at(NSView* v);
bool web_key(NSEvent* e);
RXNode* web_key_target(NSEvent* e);
void web_reload(RXNode* n, bool from_origin);

void import_cookies(RXNode* n, bool first);

void apply_page_css(RXNode* n, WKWebView* w);
void web_config_changed(void);

void web_site_scripts(RXNode* n, WKUserContentController* ucc, WKWebView* w);

void import_storage(RXNode* n);

void with_blocker(void (^done)(NSArray<WKContentRuleList*>*));

WKWebExtensionController* extensions(void);
void apply_adblock(RXNode* n, bool first);

void web_visibility(void);
void suspend_hidden(void);
bool web_kept_awake(RXDoc* doc);
void web_keep_awake(RXDoc* doc, bool on);
bool web_can_suspend(RXDoc* doc);
bool web_lent_to_pane(RXNode* n);
void web_unpark(RXNode* n);
void web_suspend_doc(RXDoc* doc);
void web_close_pages(RXDoc* doc);

void preload_favicon(RXNode* n, NSString* text);
void update_favicon(RXNode* n);
