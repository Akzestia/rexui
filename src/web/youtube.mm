// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "web/web.h"

static NSString* const kYouTubeJS = @R"JS((() => {
  if (window.__rexuiYouTube) return;
  window.__rexuiYouTube = true;
  if (!/(^|\.)youtube(-nocookie)?\.com$/.test(location.hostname)) return;

  const KEYS = ADS ? ['adPlacements', 'adSlots', 'playerAds'] : [];
  const QUOTED = KEYS.concat(['streamingData']).map(k => '"' + k + '"');
  const isVideo = x => x && typeof x.mimeType === 'string' && x.mimeType.startsWith('video/');
  const isAv1 = x => isVideo(x) && x.mimeType.includes('av01');
  const top = list => list.reduce((h, x) => Math.max(h, x.height || 0), 0);
  const oneCodec = sd => {
    const f = sd && sd.adaptiveFormats;
    if (!Array.isArray(f)) return;
    const av1 = f.filter(isAv1), others = f.filter(x => isVideo(x) && !isAv1(x));
    if (!av1.length || !others.length || top(av1) < top(others)) return;
    sd.adaptiveFormats = f.filter(x => !isVideo(x) || isAv1(x));
  };
  const fix = (o, depth) => {
    if (!o || typeof o !== 'object' || depth > 8) return o;
    if (Array.isArray(o)) {
      for (const x of o) fix(x, depth + 1);
      return o;
    }
    for (const k of KEYS) if (k in o) delete o[k];
    if (o.streamingData) oneCodec(o.streamingData);
    for (const k in o) {
      const v = o[k];
      if (v && typeof v === 'object') fix(v, depth + 1);
    }
    return o;
  };
  const mentions = text => typeof text === 'string' && QUOTED.some(q => text.includes(q));
  const fixed = text => {
    try { return JSON.stringify(fix(JSON.parse(text), 0)); } catch (_) { return null; }
  };
  const api = url => {
    try { return new URL(url, location.href).pathname.includes('/youtubei/'); } catch (_) { return false; }
  };

  const fetch0 = window.fetch;
  window.fetch = function (input, init) {
    const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input && input.url;
    const p = fetch0.apply(this, arguments);
    if (!api(url)) return p;
    return p.then(r => r.clone().text().then(text => {
      if (!mentions(text)) return r;
      const body = fixed(text);
      if (body === null) return r;
      const out = new Response(body, {status: r.status, statusText: r.statusText, headers: r.headers});
      for (const k of ['url', 'redirected', 'type']) {
        try { Object.defineProperty(out, k, {value: r[k]}); } catch (_) {}
      }
      return out;
    }, () => r));
  };

  const xhrUrl = new WeakMap();
  const open0 = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url) {
    xhrUrl.set(this, String(url));
    return open0.apply(this, arguments);
  };
  const cache = new WeakMap();
  const wrap = name => {
    const d = Object.getOwnPropertyDescriptor(XMLHttpRequest.prototype, name);
    if (!d || !d.get) return;
    Object.defineProperty(XMLHttpRequest.prototype, name, {
      configurable: true, enumerable: d.enumerable,
      get() {
        const v = d.get.call(this);
        if (this.readyState !== 4 || !api(xhrUrl.get(this))) return v;
        if (typeof v === 'string') {
          if (!mentions(v)) return v;
          if (!cache.has(this)) cache.set(this, fixed(v));
          return cache.get(this) ?? v;
        }
        if (v && typeof v === 'object' && this.responseType === 'json') return fix(v, 0);
        return v;
      },
    });
  };
  wrap('responseText');
  wrap('response');

  for (const name of ['ytInitialPlayerResponse']) {
    let value;
    try {
      Object.defineProperty(window, name, {configurable: true, get: () => value, set: v => { value = fix(v, 0); }});
    } catch (_) {}
  }

  const parse0 = JSON.parse;
  JSON.parse = function (text, reviver) {
    const r = parse0.apply(this, arguments);
    if (r && typeof r === 'object' && !Array.isArray(r) && ('playerResponse' in r || 'streamingData' in r || KEYS.some(k => k in r))) fix(r, 0);
    return r;
  };

  const keep = () => {
    const p = document.getElementById('movie_player');
    if (!p || !p.getStatsForNerds || p.classList.contains('ad-showing')) return;
    const v = p.querySelector('video');
    if (!v || v.muted || v.paused) return;
    let s, id;
    try {
      s = p.getStatsForNerds();
      id = p.getVideoData && p.getVideoData().video_id;
    } catch (_) { return; }
    const m = s && /^(\d+)%\/(\d+)%/.exec(s.volume || '');
    if (!m || !id || !String(s.video_id_and_cpn || '').startsWith(id)) return;
    if (p.getVolume && Number(m[1]) !== p.getVolume()) return;
    const want = Number(m[2]) / 100;
    if (want > 0 && v.volume > want + 0.01) v.volume = want;
  };
  for (const e of ['playing', 'volumechange', 'loadeddata', 'seeked']) document.addEventListener(e, keep, true);
  setInterval(keep, 500);
})())JS";

void web_site_scripts(RXNode* n, WKUserContentController* ucc, WKWebView* w) {
    NSString* js = [kYouTubeJS stringByReplacingOccurrencesOfString:@"ADS ?"
                                                         withString:flag(n, P::adblock, true) ? @"true ?" : @"false ?"];
    [ucc addUserScript:[[WKUserScript alloc] initWithSource:js
                                              injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                           forMainFrameOnly:NO
                                             inContentWorld:WKContentWorld.pageWorld]];
    if (w.URL)
        [w evaluateJavaScript:js inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:nil];
}
