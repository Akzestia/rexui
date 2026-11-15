// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "web/web.h"

WKWebView* make_webview(RXNode* n) {
    WKWebViewConfiguration* cfg = [WKWebViewConfiguration new];
    cfg.websiteDataStore = WKWebsiteDataStore.defaultDataStore;
    cfg.webExtensionController = extensions();
    cfg.applicationNameForUserAgent = @"Version/26.0 Safari/605.1.15";
    WKWebView* w = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:cfg];
    w.navigationDelegate = n;
    w.UIDelegate = n;
    w.allowsBackForwardNavigationGestures = YES;
    w.allowsMagnification = YES;
    w.inspectable = YES;
    w.wantsLayer = YES;
    web_sizes_watch(w);
    for (NSString* k in @[@"title", @"URL", @"loading", @"canGoBack", @"canGoForward"]) {
        [w addObserver:n forKeyPath:k options:0 context:nullptr];
    }
    n.observing = true;
    [g_webs addObject:n];
    apply_page_css(n, w);
    return w;
}

static NSString* const kPageCSS =
    @":where(*)::-webkit-scrollbar { width: 10px; height: 10px; background: transparent }"
    @":where(*)::-webkit-scrollbar-track, :where(*)::-webkit-scrollbar-corner { background: transparent }"
    @":where(*)::-webkit-scrollbar-thumb { background-color: rgba(128, 128, 128, 0.45); border-radius: 5px;"
    @" border: 3px solid transparent; background-clip: padding-box }"
    @":where(*)::-webkit-scrollbar-thumb:hover { background-color: rgba(128, 128, 128, 0.7); border-width: 2px }";

static NSString* const kNoScrollbarsCSS =
    @":where(*)::-webkit-scrollbar { display: none; width: 0; height: 0; background: transparent }"
    @":where(html) { scrollbar-width: none }";

static NSString* const kContextJS = @(R"JS((() => {
  if (window.__rexuiCtx) return;
  window.__rexuiCtx = true;
  const isField = x => x instanceof HTMLInputElement || x instanceof HTMLTextAreaElement;
  const snap = () => {
    const s = document.getSelection(), a = document.activeElement;
    let f = null;
    if (isField(a)) try { if (a.selectionStart !== null) f = [a, a.selectionStart, a.selectionEnd]; } catch (_) {}
    return {at: s && s.rangeCount ? [s.anchorNode, s.anchorOffset, s.focusNode, s.focusOffset] : null, f};
  };
  const same = (x, y) => !!x === !!y && (!x || x.every((v, i) => v === y[i]));
  let last = snap(), press = null, pressAt = -1e9;
  document.addEventListener('selectionchange', () => { last = snap(); }, true);
  window.addEventListener('mousedown', e => { if (e.button === 2 || (e.button === 0 && e.ctrlKey)) press = snap(), pressAt = e.timeStamp; }, true);
  window.addEventListener('contextmenu', e => {
    const was = press && e.timeStamp - pressAt < 1000 ? press : last;
    press = null;
    const t = e.target instanceof Element ? e.target : e.target && e.target.parentElement;
    if (!t) return;
    if (isField(t)) {
      try {
        const a = t.selectionStart, b = t.selectionEnd;
        if (a !== b && !(was.f && same(was.f, [t, a, b]))) t.setSelectionRange(a, a);
      } catch (_) {}
      return;
    }
    const s = document.getSelection();
    if (!s || same(snap().at, was.at)) return;
    const host = t.closest('[contenteditable]:not([contenteditable="false"])');
    try {
      if (host && s.anchorNode && host.contains(s.anchorNode) && !(was.at && host.contains(was.at[0]))) s.collapseToStart();
      else if (was.at) s.setBaseAndExtent(was.at[0], was.at[1], was.at[2], was.at[3]);
      else s.removeAllRanges();
    } catch (_) { s.removeAllRanges(); }
  }, true);
})();)JS");

static NSString* const kFullscreenJS = @(R"JS((() => {
  if (window.__rexuiFS) return;
  window.__rexuiFS = true;
  const ON = 'data-rexui-fs', UP = 'data-rexui-fs-up';
  const CSS = `[${ON}]{position:fixed!important;inset:0!important;width:100vw!important;height:100vh!important;max-width:none!important;max-height:none!important;min-width:0!important;min-height:0!important;margin:0!important;transform:none!important;translate:none!important;scale:none!important;z-index:2147483647!important;box-sizing:border-box!important}
:where([${ON}]){background-color:#000}
video[${ON}]{object-fit:contain!important;padding:0!important;border:0!important}
[${UP}]{transform:none!important;translate:none!important;scale:none!important;filter:none!important;backdrop-filter:none!important;perspective:none!important;contain:none!important;will-change:auto!important;clip-path:none!important;mask:none!important;overflow:visible!important;z-index:2147483647!important}
html[${UP}],html[${UP}]>body{overflow:hidden!important}`;
  let el = null;
  const up = e => e.parentElement || (e.getRootNode() instanceof ShadowRoot ? e.getRootNode().host : null);
  const style = () => {
    if (document.getElementById('__rexui_fs')) return;
    const s = document.createElement('style');
    s.id = '__rexui_fs';
    s.textContent = CSS;
    (document.head || document.documentElement).appendChild(s);
  };
  const fire = t => new Promise(done => requestAnimationFrame(() => {
    window.dispatchEvent(new Event('resize'));
    const at = t && t.isConnected ? t : document;
    for (const name of ['fullscreenchange', 'webkitfullscreenchange']) at.dispatchEvent(new Event(name, {bubbles: true, composed: true}));
    done();
  }));
  const tell = on => { if (window !== window.parent) window.parent.postMessage({__rexuiFS: on}, '*'); };
  const exit = quiet => {
    const was = el;
    if (!was) return Promise.resolve();
    el = null;
    was.removeAttribute(ON);
    for (const a of document.querySelectorAll(`[${UP}]`)) a.removeAttribute(UP);
    if (was.tagName === 'IFRAME') try { was.contentWindow.postMessage({__rexuiFSExit: 1}, '*'); } catch (_) {}
    tell(false);
    return quiet ? Promise.resolve() : fire(was);
  };
  const enter = e => {
    if (!(e instanceof Element)) return Promise.reject(new TypeError('not an element'));
    if (el === e) return Promise.resolve();
    if (el) exit(true);
    style();
    el = e;
    e.setAttribute(ON, '');
    for (let a = up(e); a; a = up(a)) a.setAttribute(UP, '');
    tell(true);
    return fire(e);
  };
  const def = (o, k, get) => { try { Object.defineProperty(o, k, {get, configurable: true}); } catch (_) {} };
  const D = Document.prototype, E = Element.prototype, V = HTMLVideoElement.prototype;
  def(D, 'fullscreenElement', () => el);
  def(D, 'webkitFullscreenElement', () => el);
  def(D, 'webkitCurrentFullScreenElement', () => el);
  def(D, 'fullscreenEnabled', () => true);
  def(D, 'webkitFullscreenEnabled', () => true);
  def(D, 'fullscreen', () => !!el);
  def(D, 'webkitIsFullScreen', () => !!el);
  def(ShadowRoot.prototype, 'fullscreenElement', function () { return el && el.getRootNode() === this ? el : null; });
  E.requestFullscreen = function () { return enter(this); };
  E.webkitRequestFullscreen = E.webkitRequestFullScreen = function () { enter(this); };
  D.exitFullscreen = function () { return exit(); };
  D.webkitExitFullscreen = D.webkitCancelFullScreen = function () { exit(); };
  V.webkitEnterFullscreen = V.webkitEnterFullScreen = function () { enter(this); };
  V.webkitExitFullscreen = V.webkitExitFullScreen = function () { if (el === this) exit(); };
  def(V, 'webkitSupportsFullscreen', () => true);
  def(V, 'webkitDisplayingFullscreen', function () { return el === this; });
  const handlers = new WeakMap();
  for (const P of [D, E])
    for (const name of ['fullscreenchange', 'webkitfullscreenchange', 'fullscreenerror', 'webkitfullscreenerror']) {
      const k = 'on' + name;
      if (k in P) continue;
      Object.defineProperty(P, k, {configurable: true, enumerable: true,
        get() { const h = handlers.get(this); return (h && h[k]) || null; },
        set(f) {
          let h = handlers.get(this);
          if (!h) handlers.set(this, h = {});
          if (!(k in h)) this.addEventListener(name, ev => { const g = h[k]; if (typeof g === 'function') g.call(this, ev); });
          h[k] = f;
        }});
    }
  window.addEventListener('message', m => {
    const d = m.data;
    if (!d || typeof d !== 'object') return;
    if ('__rexuiFSExit' in d && m.source === window.parent) return exit();
    if (!('__rexuiFS' in d)) return;
    const f = [...document.querySelectorAll('iframe')].find(f => f.contentWindow === m.source);
    if (!f) return;
    if (d.__rexuiFS) enter(f);
    else if (el === f) exit();
  });
  window.addEventListener('keydown', k => {
    if (!el || k.key !== 'Escape') return;
    k.preventDefault();
    k.stopImmediatePropagation();
    exit();
  }, true);
})();)JS");

void web_config_changed(void) {
    static int was = -1;
    if (was == (int)g_config.web_scrollbars)
        return;
    bool first = was < 0;
    was = g_config.web_scrollbars;
    if (first)
        return;
    for (RXNode* n in [g_webs copy])
        if ([n.view isKindOfClass:WKWebView.class])
            apply_page_css(n, (WKWebView*)n.view);
}

void apply_page_css(RXNode* n, WKWebView* w) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [NSNotificationCenter.defaultCenter addObserverForName:NSPreferredScrollerStyleDidChangeNotification
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification*) {
                                                        for (RXNode* n2 in [g_webs copy]) {
                                                            if ([n2.view isKindOfClass:WKWebView.class])
                                                                apply_page_css(n2, (WKWebView*)n2.view);
                                                        }
                                                    }];
    });
    bool legacy = NSScroller.preferredScrollerStyle == NSScrollerStyleLegacy;
    NSString* bars = !g_config.web_scrollbars ? kNoScrollbarsCSS : legacy ? kPageCSS : @"";
    NSString* css = [bars stringByAppendingFormat:@"\n%@", str(n, P::css, @"")];
    NSData* json = json_data(@[css], 0);
    NSString* js = [NSString stringWithFormat:@"(() => { const css = %@[0];"
                                              @" let s = document.getElementById('__rexui_css');"
                                              @" if (!s) { s = document.createElement('style'); s.id = '__rexui_css'; "
                                              @"(document.head || document.documentElement).appendChild(s); }"
                                              @" s.textContent = css; })();",
                                              [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]];
    WKUserContentController* ucc = w.configuration.userContentController;
    [ucc removeAllUserScripts];
    [ucc addUserScript:[[WKUserScript alloc] initWithSource:kFullscreenJS
                                              injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                           forMainFrameOnly:NO
                                             inContentWorld:WKContentWorld.pageWorld]];
    [ucc addUserScript:[[WKUserScript alloc] initWithSource:js
                                              injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                           forMainFrameOnly:NO
                                             inContentWorld:WKContentWorld.defaultClientWorld]];
    [ucc addUserScript:[[WKUserScript alloc] initWithSource:kContextJS
                                              injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                           forMainFrameOnly:NO
                                             inContentWorld:WKContentWorld.defaultClientWorld]];
    [ucc addUserScript:web_sizes_script()];
    web_site_scripts(n, ucc, w);
    if (w.URL) {
        [w evaluateJavaScript:kFullscreenJS inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:nil];
        [w evaluateJavaScript:js inFrame:nil inContentWorld:WKContentWorld.defaultClientWorld completionHandler:nil];
        [w evaluateJavaScript:kContextJS
                      inFrame:nil
               inContentWorld:WKContentWorld.defaultClientWorld
            completionHandler:nil];
        [w evaluateJavaScript:web_sizes_script().source
                      inFrame:nil
               inContentWorld:WKContentWorld.defaultClientWorld
            completionHandler:nil];
    }
}

NSURL* web_url(RXNode* n, NSString* text) {
    return web_url_with(text, str(n, P::search, @""));
}

NSURL* web_url_with(NSString* text, NSString* search) {
    text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length)
        return nil;
    if ([text containsString:@"://"] || [text hasPrefix:@"about:"] || [text hasPrefix:@"data:"])
        return [NSURL URLWithString:text];
    if ([text hasPrefix:@"/"] || [text hasPrefix:@"~"])
        return [NSURL fileURLWithPath:text.stringByExpandingTildeInPath];
    NSString* host = [text componentsSeparatedByString:@"/"][0];
    bool spaces = [text rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet].location != NSNotFound;
    bool local = [host hasPrefix:@"localhost"] || [host hasPrefix:@"127."] || [host hasPrefix:@"0.0.0.0"] ||
        [host hasPrefix:@"["] ||
        [host rangeOfString:@"^[0-9.]+(:[0-9]+)?$" options:NSRegularExpressionSearch].location != NSNotFound;
    if (!spaces && (local || [host containsString:@"."])) {
        return [NSURL URLWithString:[(local ? @"http://" : @"https://") stringByAppendingString:text]];
    }
    if (!search.length)
        return nil;
    NSString* q = [text stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    q = [q stringByReplacingOccurrencesOfString:@"&" withString:@"%26"];
    q = [q stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"];
    if ([search containsString:@"%s"])
        return [NSURL URLWithString:[search stringByReplacingOccurrencesOfString:@"%s" withString:q]];
    return [NSURL URLWithString:[search stringByAppendingString:q]];
}

bool on_screen(RXNode* n) {
    return n.view.window && !n.view.hiddenOrHasHiddenAncestor;
}

void web_load(RXNode* n, NSString* text) {
    if (n.preparing > 0) {
        n.deferred = text;
        return;
    }
    if (flag(n, P::lazy, true) && !on_screen(n) && !web_lent_to_pane(n)) {
        n.waiting = text;
        n.saved_state = nil;
        preload_favicon(n, text);
        return;
    }
    WKWebView* w = (WKWebView*)n.view;
    if (getenv("REXUI_NO_WEB") && ![text hasPrefix:@"data:"])
        return;
    if (NSURL* url = web_url(n, text)) {
        static NSMapTable<RXNode*, NSString*>* last = [NSMapTable weakToStrongObjectsMapTable];
        if (![[last objectForKey:n] isEqualToString:url.absoluteString]) {
            [last setObject:url.absoluteString forKey:n];
            rexui_log([NSString stringWithFormat:@"%@: opening %@%@", n.doc.path.lastPathComponent,
                                                 url.host ?: url.absoluteString,
                                                 on_screen(n) ? @"" : @" (off screen)"]);
        }
        if (url.isFileURL)
            [w loadFileURL:url allowingReadAccessToURL:url.URLByDeletingLastPathComponent];
        else
            [w loadRequest:[NSURLRequest requestWithURL:url]];
    }
}

void web_adblock_settings(RXNode* n) {
    if (!g_ubol)
        return rexui_log([NSString stringWithFormat:@"%@: no uBlock Origin Lite loaded", n.doc.path.lastPathComponent]);
    if (n.view)
        [(WKWebView*)n.view loadRequest:[NSURLRequest requestWithURL:g_ubol.optionsPageURL]];
}

void web_prepared(RXNode* n) {
    if (--n.preparing > 0)
        return;
    if (!n.deferred)
        return web_visibility();
    NSString* url = n.deferred;
    n.deferred = nil;
    web_load(n, url);
}

static void web_update(RXNode* n) {
    WKWebView* w = (WKWebView*)n.view;
    if (!n.doc.ctx)
        return;
    doc_call(n.doc, @"update", @[
        @(n.uid), @{
            @"title": w.title ?: @"",
            @"currentUrl": w.URL.absoluteString ?: @"",
            @"loading": @(w.loading),
            @"canGoBack": @(w.canGoBack),
            @"canGoForward": @(w.canGoForward),
        }
    ]);
}

void close_web(RXNode* n) {
    if (!is_elem(n, E::WebView) || !n.observing)
        return;
    web_unpark(n);
    WKWebView* w = (WKWebView*)n.view;
    for (NSString* k in @[@"title", @"URL", @"loading", @"canGoBack", @"canGoForward"])
        [w removeObserver:n forKeyPath:k];
    n.observing = false;
    [w stopLoading];
    w.navigationDelegate = nil;
    w.UIDelegate = nil;
    [w pauseAllMediaPlaybackWithCompletionHandler:nil];
    [w closeAllMediaPresentationsWithCompletionHandler:nil];
    [w loadHTMLString:@"" baseURL:nil];
    if (g_ubol && [g_webs containsObject:n])
        [extensions() didCloseTab:n windowIsClosing:NO];
    [g_webs removeObject:n];
}

RXNode* web_at(NSView* v) {
    for (RXNode* n in g_webs) {
        if (n.view && v && (v == n.view || [v isDescendantOf:n.view]))
            return n;
    }
    return nil;
}

void web_reload(RXNode* n, bool from_origin) {
    WKWebView* w = (WKWebView*)n.view;
    if (!w.URL)
        return web_load(n, str(n, P::url, @""));
    if (from_origin)
        [w reloadFromOrigin];
    else
        [w reload];
}

RXNode* web_key_target(NSEvent* e) {
    if (!(e.modifierFlags & NSEventModifierFlagCommand))
        return nil;
    NSResponder* r = e.window.firstResponder;
    RXNode* n = [r isKindOfClass:NSView.class] ? web_at((NSView*)r) : nil;
    if (!n)
        return nil;
    NSEventModifierFlags mods = e.modifierFlags
        & (NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagOption
           | NSEventModifierFlagControl);
    NSString* k = e.charactersIgnoringModifiers.lowercaseString;
    bool cmd = mods == NSEventModifierFlagCommand,
         cmd_shift = mods == (NSEventModifierFlagCommand | NSEventModifierFlagShift);
    bool takes = (cmd && [@[@"l", @"r", @"[", @"]", @"=", @"-", @"0"] containsObject:k])
        || (cmd_shift && ([k isEqualToString:@"r"] || [k isEqualToString:@"="] || [k isEqualToString:@"+"]));
    return takes ? n : nil;
}

bool web_takes_key(NSEvent* e) {
    return web_key_target(e) != nil;
}

bool web_key(NSEvent* e) {
    RXNode* n = web_key_target(e);
    if (!n)
        return false;
    WKWebView* w = (WKWebView*)n.view;
    NSEventModifierFlags mods = e.modifierFlags
        & (NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagOption
           | NSEventModifierFlagControl);
    NSString* k = e.charactersIgnoringModifiers.lowercaseString;
    bool cmd = mods == NSEventModifierFlagCommand,
         cmd_shift = mods == (NSEventModifierFlagCommand | NSEventModifierFlagShift);
    if (cmd && [k isEqualToString:@"l"]) {
        if (n.doc.ctx)
            doc_call(n.doc, @"emit", @[@(n.uid), @"command", @[@"address"]]);
    } else if (cmd && [k isEqualToString:@"r"])
        web_reload(n, false);
    else if (cmd_shift && [k isEqualToString:@"r"])
        web_reload(n, true);
    else if (cmd && [k isEqualToString:@"["])
        [w goBack];
    else if (cmd && [k isEqualToString:@"]"])
        [w goForward];
    else if ((cmd || cmd_shift) && ([k isEqualToString:@"="] || [k isEqualToString:@"+"]))
        w.pageZoom = MIN(3.0, w.pageZoom + 0.1);
    else if (cmd && [k isEqualToString:@"-"])
        w.pageZoom = MAX(0.3, w.pageZoom - 0.1);
    else if (cmd && [k isEqualToString:@"0"])
        w.pageZoom = num(n, P::zoom, 1);
    else
        return false;
    return true;
}

@implementation RXNode (Web)
- (void)observeValueForKeyPath:(NSString*)path ofObject:(id)o change:(NSDictionary*)change context:(void*)ctx {
    web_update(self);
    if ([path isEqualToString:@"URL"] && ((WKWebView*)self.view).URL)
        session_changed(self);
}
- (void)failed:(NSError*)e {
    if (e.code == NSURLErrorCancelled)
        return;
    NSString* msg = e.localizedDescription ?: @"failed";
    if (self.doc.ctx) {
        doc_call(self.doc, @"update", @[@(self.uid), @{@"error": msg}]);
        doc_call(self.doc, @"emit", @[@(self.uid), @"failed", @[msg]]);
    }
}
- (void)webView:(WKWebView*)w didFailProvisionalNavigation:(WKNavigation*)nav withError:(NSError*)e {
    [self failed:e];
}
- (void)webView:(WKWebView*)w didFailNavigation:(WKNavigation*)nav withError:(NSError*)e {
    [self failed:e];
}
static void ended_again(RXNode* n, NSString* url, NSString* name, NSString* host) {
    const double t = CACurrentMediaTime();
    if (t - n.ended_since > 60)
        n.ended_since = t, n.ended_times = 0;
    if (++n.ended_times > 3) {
        if (n.ended_times > 4)
            return;
        const double wait = MAX(1, n.ended_since + 60 - t);
        rexui_log([NSString stringWithFormat:@"%@: %@'s process ended again (3 times this minute): reloaded in %.0f s",
                                             name, host, wait]);
        __weak RXNode* weak = n;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            RXNode* m = weak;
            WKWebView* w = [m.view isKindOfClass:WKWebView.class] ? (WKWebView*)m.view : nil;
            if (!m.doc || !w || m.ended_times <= 3)
                return;
            if (on_screen(m))
                [w loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:url]]];
            else
                m.waiting = url;
        });
        return;
    }
    bool shown = on_screen(n);
    rexui_log([NSString stringWithFormat:@"%@: %@'s process ended (WebKit let it go or it crashed); reloaded %@", name,
                                         host, shown ? @"now" : @"when it's shown"]);
    WKWebView* w = (WKWebView*)n.view;
    if (shown)
        [w reload];
    else
        n.waiting = url;
}
- (void)webViewWebContentProcessDidTerminate:(WKWebView*)w {
    NSString* url = w.URL.absoluteString;
    NSString* name = self.doc.path.lastPathComponent;
    NSString* host = w.URL.host ?: url ?: @"(no page)";
    if (!url.length) {
        rexui_log([NSString stringWithFormat:@"%@: %@'s process ended, no page to open again", name, host]);
        return;
    }
    ended_again(self, url, name, host);
}
- (void)webView:(WKWebView*)w didCommitNavigation:(WKNavigation*)nav {
    if (self.doc.ctx)
        doc_call(self.doc, @"update", @[@(self.uid), @{@"error": @""}]);
}
- (void)webView:(WKWebView*)w didFinishNavigation:(WKNavigation*)nav {
    if (self.ended_times > 3)
        self.ended_times = 3;
    web_update(self);
    update_favicon(self);
    session_changed(self);
    if (self.doc.ctx)
        doc_call(self.doc, @"emit", @[@(self.uid), @"loaded", @[]]);
}
- (WKWebView*)webView:(WKWebView*)w
    createWebViewWithConfiguration:(WKWebViewConfiguration*)cfg
               forNavigationAction:(WKNavigationAction*)action
                    windowFeatures:(WKWindowFeatures*)features {
    if (!web_open_tab(self.doc, action.request.URL, true))
        [w loadRequest:action.request];
    return nil;
}
- (void)webView:(WKWebView*)w
    decidePolicyForNavigationAction:(WKNavigationAction*)action
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decide {
    bool aside = action.buttonNumber == 2 || (action.modifierFlags & NSEventModifierFlagCommand);
    if (action.navigationType == WKNavigationTypeLinkActivated && aside
        && web_open_tab(self.doc, action.request.URL, false)) {
        decide(WKNavigationActionPolicyCancel);
        return;
    }
    decide(WKNavigationActionPolicyAllow);
}
- (id<WKWebExtensionWindow>)windowForWebExtensionContext:(WKWebExtensionContext*)c {
    return g_ext_delegate.window;
}
- (WKWebView*)webViewForWebExtensionContext:(WKWebExtensionContext*)c {
    return [self.view isKindOfClass:WKWebView.class] ? (WKWebView*)self.view : nil;
}
- (NSURL*)urlForWebExtensionContext:(WKWebExtensionContext*)c {
    return [self webViewForWebExtensionContext:c].URL;
}
- (NSString*)titleForWebExtensionContext:(WKWebExtensionContext*)c {
    return [self webViewForWebExtensionContext:c].title;
}
- (BOOL)isSelectedForWebExtensionContext:(WKWebExtensionContext*)c {
    return !self.view.hiddenOrHasHiddenAncestor;
}
@end
