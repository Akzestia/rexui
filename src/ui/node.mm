// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "ui/ui.h"

@implementation RXDoc
- (void)setNodes:(NSMutableDictionary<NSNumber*, RXNode*>*)nodes {
    _nodes = nodes;
    index.clear();
    for (NSNumber* k in nodes)
        index.put(k.unsignedIntValue, nodes[k]);
}
- (void)dealloc {
    for (RXNode* n in _nodes.objectEnumerator)
        n->in = nil;
}
@end

NSMutableArray<RXDoc*>* g_docs;
__weak NSWindow* g_window;
__weak NSResponder* g_terminal;
dispatch_queue_t g_write_queue;
NSUserDefaults* g_state;
NSHashTable<RXNode*>* g_webs;
WKWebExtensionContext* g_ubol;

bool is_type(RXNode* n, NSString* t) {
    return [n.type isEqualToString:t];
}
bool is_box(RXNode* n) {
    switch (elem(n)) {
    case E::Dock:
    case E::Column:
    case E::Row:
    case E::Stack:
    case E::Item:
    case E::MouseArea:
    case E::Rectangle:
    case E::List:
    case E::Drawer:
    case E::Grid:
    case E::Pages:
    case E::Scroll:
    case E::Loader:
        return true;
    default:
        return false;
    }
}
bool is_list(RXNode* n) {
    return is_elem(n, E::List) || is_elem(n, E::Scroll);
}
bool is_drawer(RXNode* n) {
    return is_elem(n, E::Drawer);
}
bool is_grid(RXNode* n) {
    return is_elem(n, E::Grid);
}
bool is_column(RXNode* n) {
    E e = elem(n);
    return e == E::Column || e == E::Dock || e == E::List || e == E::Scroll || e == E::Drawer;
}
bool is_row(RXNode* n) {
    return is_elem(n, E::Row);
}
bool is_pages(RXNode* n) {
    return is_elem(n, E::Pages);
}

NSString* prop_ns(P p) {
    static NSString* names[rx::ui::k_nprops + 1];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (int i = 0; i < rx::ui::k_nprops; i++) {
            std::string_view v = rx::schema::k_props[i].name;
            names[i] = [[NSString alloc] initWithBytes:v.data() length:v.size() encoding:NSUTF8StringEncoding];
        }
        names[rx::ui::k_nprops] = @"";
    });
    int i = static_cast<int>(p);
    return names[i >= 0 && i < rx::ui::k_nprops ? i : rx::ui::k_nprops];
}
bool prop_named(NSString* name, P* p) {
    char buf[96];
    const char* c = CFStringGetCStringPtr((__bridge CFStringRef)name, kCFStringEncodingUTF8);
    if (!c) {
        if (![name getCString:buf maxLength:sizeof buf encoding:NSUTF8StringEncoding])
            return false;
        c = buf;
    }
    return rx::schema::prop_of(c, p);
}
id extra_of(RXNode* n, P p) {
    return n.extras[prop_ns(p)];
}
NSString* str_slow(const rx::ui::PVal& v, NSString* def) {
    switch (v.k) {
    case rx::ui::PK::num:
        return [@(v.d) stringValue];
    case rx::ui::PK::yes:
        return @"1";
    case rx::ui::PK::no:
        return @"0";
    default:
        return def;
    }
}
id obj(RXNode* n, P p) {
    rx::ui::PVal v = pv(n, p);
    switch (v.k) {
    case rx::ui::PK::num:
        return @(v.d);
    case rx::ui::PK::yes:
        return @YES;
    case rx::ui::PK::no:
        return @NO;
    case rx::ui::PK::obj:
        return v.o;
    default:
        return nil;
    }
}
static rx::ui::PVal pv_named(RXNode* n, NSString* k) {
    if (!n)
        return {};
    P p;
    if (prop_named(k, &p)) {
        int i = n->ps.slot(p);
        if (i >= 0)
            return n->ps.get(i);
    }
    return rx::ui::pval_of(n.extras[k]);
}
double num(RXNode* n, NSString* k, double def) {
    rx::ui::PVal v = pv_named(n, k);
    switch (v.k) {
    case rx::ui::PK::num:
        return v.d != v.d ? def : v.d;
    case rx::ui::PK::yes:
        return 1;
    case rx::ui::PK::no:
        return 0;
    default:
        return def;
    }
}
bool has_num(RXNode* n, NSString* k) {
    rx::ui::PVal v = pv_named(n, k);
    return v.k == rx::ui::PK::num && v.d == v.d;
}
NSString* str(RXNode* n, NSString* k, NSString* def) {
    rx::ui::PVal v = pv_named(n, k);
    if (v.k == rx::ui::PK::obj)
        return [v.o isKindOfClass:NSString.class] ? v.o : def;
    return str_slow(v, def);
}
bool flag(RXNode* n, NSString* k, bool def) {
    rx::ui::PVal v = pv_named(n, k);
    switch (v.k) {
    case rx::ui::PK::num:
        return v.d != 0;
    case rx::ui::PK::yes:
        return true;
    case rx::ui::PK::no:
        return false;
    case rx::ui::PK::obj:
        return [v.o isKindOfClass:NSString.class] ? [(NSString*)v.o length] > 0 : true;
    default:
        return def;
    }
}
id obj(RXNode* n, NSString* k) {
    P p;
    if (n && prop_named(k, &p) && n->ps.slot(p) >= 0)
        return obj(n, p);
    return n.extras[k];
}
void prop_store(RXNode* n, P p, NSString* name, const rx::ui::PVal& v) {
    if (!n)
        return;
    int i = p == P::count_ ? -1 : n->ps.slot(p);
    if (i >= 0)
        return n->ps.put(i, v);
    if (v.k == rx::ui::PK::none)
        return (void)[n.extras removeObjectForKey:name];
    id o = v.k == rx::ui::PK::num ? @(v.d) : v.k == rx::ui::PK::yes ? @YES : v.k == rx::ui::PK::no ? @NO : v.o;
    if (!n.extras)
        n.extras = [NSMutableDictionary dictionary];
    n.extras[name] = o;
}
NSDictionary<NSString*, id>* props_dict(RXNode* n) {
    if (!n)
        return @{};
    NSMutableDictionary* d = n.extras ? [n.extras mutableCopy] : [NSMutableDictionary dictionary];
    for (int i = 0; i < rx::ui::k_nprops; i++) {
        int s = n->ps.slot(P(i));
        if (s >= 0 && n->ps.kind(s) != rx::ui::PK::none)
            d[prop_ns(P(i))] = obj(n, P(i));
    }
    return d;
}
void prop_put(RXNode* n, NSString* name, id value) {
    P p;
    if (!prop_named(name, &p))
        p = P::count_;
    prop_store(n, p, name, rx::ui::pval_of(value));
}
bool shown(RXNode* n) {
    return n.layer && flag(n, P::visible, true);
}
CGFloat pad_x(RXNode* n) {
    return num(n, P::horizontalPadding, num(n, P::padding, 0));
}
CGFloat pad_y(RXNode* n) {
    return num(n, P::verticalPadding, num(n, P::padding, 0));
}
CALayer* content_layer(RXNode* n) {
    if (is_pages(n))
        return n.layer.sublayers.firstObject;
    return is_list(n) ? ((RXScrollLayer*)n.layer).doc : n.layer;
}
bool is_native(RXNode* n) {
    E e = elem(n);
    return e == E::WebView;
}

template <class T>
static T zero_v() {
    return T{};
}
template <class T>
static bool is_zero(const T& v) {
    if constexpr (std::is_convertible_v<T, id>) {
        return v == nil;
    } else {
        T z{};
        return std::memcmp(&v, &z, sizeof(T)) == 0;
    }
}
@interface RXProcSide : NSObject
@property(nonatomic) int pid;
@property(nonatomic) uint32_t io_id;
@property(nonatomic) int stdin_fd;
@property(nonatomic) bool spawn_due;
@property(nonatomic, strong) NSMutableData* out;
@property(nonatomic, strong) NSMutableData* err;
@property(nonatomic) int failures;
@property(nonatomic, strong) NSDate* started;
@property(nonatomic) int generation;
@property(nonatomic, strong) id proc_box;
@property(nonatomic) bool parked;
@property(nonatomic) bool kept;
@property(nonatomic, copy) NSString* exe;
@property(nonatomic, strong) NSDate* exe_mtime;
@end
@implementation RXProcSide
@end
@interface RXWebSide : NSObject
@property(nonatomic) bool observing;
@property(nonatomic) int preparing;
@property(nonatomic, copy) NSString* deferred;
@property(nonatomic, strong) NSTimer* cookie_timer;
@property(nonatomic, copy) NSString* restore;
@property(nonatomic, copy) NSString* waiting;
@property(nonatomic, strong) id saved_state;
@property(nonatomic, strong) NSDate* hidden_since;
@property(nonatomic, copy) NSString* session;
@property(nonatomic) bool save_pending;
@property(nonatomic) int closed;
@end
@implementation RXWebSide
@end
@interface RXDrawerSide : NSObject
@property(nonatomic) double progress;
@property(nonatomic) double slide_t0;
@property(nonatomic) double slide_from;
@property(nonatomic) double slide_to;
@property(nonatomic) double slide_len;
@property(nonatomic) int slide_gen;
@property(nonatomic, strong) NSArray<CALayer*>* slide_layers;
@property(nonatomic, strong) id slide;
@property(nonatomic) bool over_anchor;
@property(nonatomic) bool hover_armed;
@property(nonatomic) double hover_out;
@property(nonatomic, strong) NSTimer* hover_timer;
@property(nonatomic) NSSize box_from;
@property(nonatomic) NSSize box_to;
@property(nonatomic) NSSize box_now;
@property(nonatomic, strong) id resize;
@property(nonatomic) CGFloat shift_from;
@property(nonatomic) CGFloat shift_to;
@property(nonatomic) CGFloat shift_now;
@property(nonatomic, strong) id shift_glide;
@property(nonatomic, strong) NSValue* moved;
@property(nonatomic, strong) NSValue* sized;
@property(nonatomic) CGFloat held_h;
@property(nonatomic) int drag_mode;
@property(nonatomic) NSPoint drag_mouse;
@property(nonatomic) NSPoint drag_from;
@property(nonatomic) NSSize drag_size;
@property(nonatomic) bool drag_queued;
@property(nonatomic, copy) NSString* commanded;
@property(nonatomic) double outside_closed;
@property(nonatomic) bool reveal_pending;
@property(nonatomic) NSUInteger revealed_of;
@end
@implementation RXDrawerSide
@end
@interface RXMediaSide : NSObject
@property(nonatomic, copy) NSString* loaded;
@property(nonatomic) CGSize image_size;
@property(nonatomic) CGFloat image_px;
@property(nonatomic) CGSize image_native;
@property(nonatomic, strong) id frames;
@property(nonatomic, strong) NSData* frame;
@property(nonatomic) double spin_base;
@property(nonatomic) double spin_t0;
@property(nonatomic) double spin_period;
@property(nonatomic) double shown_value;
@property(nonatomic) double wave_phase;
@property(nonatomic) double last_tick;
@end
@implementation RXMediaSide
@end
@interface RXNode () {
    RXProcSide* _side_proc;
    RXWebSide* _side_web;
    RXDrawerSide* _side_drawer;
    RXMediaSide* _side_media;
}
@end

@interface RXNode () {
    __weak RXNode* _w_parent;
}
@end
@interface RXNode () {
    __weak RXDoc* _w_doc;
}
@end
@implementation RXNode
- (RXDoc*)doc {
    return _w_doc;
}
- (RXNode*)parent {
    return _w_parent;
}
- (int)pid {
    return _side_proc ? _side_proc.pid : zero_v<int>();
}
- (void)setPid:(int)v {
    if (!_side_proc) {
        if (is_zero(v))
            return;
        _side_proc = [RXProcSide new];
    }
    _side_proc.pid = v;
}
- (uint32_t)io_id {
    return _side_proc ? _side_proc.io_id : zero_v<uint32_t>();
}
- (void)setIo_id:(uint32_t)v {
    if (!_side_proc) {
        if (is_zero(v))
            return;
        _side_proc = [RXProcSide new];
    }
    _side_proc.io_id = v;
}
- (int)stdin_fd {
    return _side_proc ? _side_proc.stdin_fd : zero_v<int>();
}
- (void)setStdin_fd:(int)v {
    if (!_side_proc) {
        if (is_zero(v))
            return;
        _side_proc = [RXProcSide new];
    }
    _side_proc.stdin_fd = v;
}
- (bool)spawn_due {
    return _side_proc ? _side_proc.spawn_due : zero_v<bool>();
}
- (void)setSpawn_due:(bool)v {
    if (!_side_proc) {
        if (is_zero(v))
            return;
        _side_proc = [RXProcSide new];
    }
    _side_proc.spawn_due = v;
}
- (NSMutableData*)out {
    return _side_proc ? _side_proc.out : zero_v<NSMutableData*>();
}
- (void)setOut:(NSMutableData*)v {
    if (!_side_proc) {
        if (is_zero(v))
            return;
        _side_proc = [RXProcSide new];
    }
    _side_proc.out = v;
}
- (NSMutableData*)err {
    return _side_proc ? _side_proc.err : zero_v<NSMutableData*>();
}
- (void)setErr:(NSMutableData*)v {
    if (!_side_proc) {
        if (is_zero(v))
            return;
        _side_proc = [RXProcSide new];
    }
    _side_proc.err = v;
}
- (int)failures {
    return _side_proc ? _side_proc.failures : zero_v<int>();
}
- (void)setFailures:(int)v {
    if (!_side_proc) {
        if (is_zero(v))
            return;
        _side_proc = [RXProcSide new];
    }
    _side_proc.failures = v;
}
- (NSDate*)started {
    return _side_proc ? _side_proc.started : zero_v<NSDate*>();
}
- (void)setStarted:(NSDate*)v {
    if (!_side_proc) {
        if (is_zero(v))
            return;
        _side_proc = [RXProcSide new];
    }
    _side_proc.started = v;
}
- (int)generation {
    return _side_proc ? _side_proc.generation : zero_v<int>();
}
- (void)setGeneration:(int)v {
    if (!_side_proc) {
        if (is_zero(v))
            return;
        _side_proc = [RXProcSide new];
    }
    _side_proc.generation = v;
}
- (id)proc_box {
    return _side_proc ? _side_proc.proc_box : zero_v<id>();
}
- (void)setProc_box:(id)v {
    if (!_side_proc) {
        if (is_zero(v))
            return;
        _side_proc = [RXProcSide new];
    }
    _side_proc.proc_box = v;
}
- (bool)parked {
    return _side_proc ? _side_proc.parked : zero_v<bool>();
}
- (void)setParked:(bool)v {
    if (!_side_proc) {
        if (is_zero(v))
            return;
        _side_proc = [RXProcSide new];
    }
    _side_proc.parked = v;
}
- (bool)kept {
    return _side_proc ? _side_proc.kept : zero_v<bool>();
}
- (void)setKept:(bool)v {
    if (!_side_proc) {
        if (is_zero(v))
            return;
        _side_proc = [RXProcSide new];
    }
    _side_proc.kept = v;
}
- (NSString*)exe {
    return _side_proc ? _side_proc.exe : zero_v<NSString*>();
}
- (void)setExe:(NSString*)v {
    if (!_side_proc) {
        if (is_zero(v))
            return;
        _side_proc = [RXProcSide new];
    }
    _side_proc.exe = v;
}
- (NSDate*)exe_mtime {
    return _side_proc ? _side_proc.exe_mtime : zero_v<NSDate*>();
}
- (void)setExe_mtime:(NSDate*)v {
    if (!_side_proc) {
        if (is_zero(v))
            return;
        _side_proc = [RXProcSide new];
    }
    _side_proc.exe_mtime = v;
}
- (bool)observing {
    return _side_web ? _side_web.observing : zero_v<bool>();
}
- (void)setObserving:(bool)v {
    if (!_side_web) {
        if (is_zero(v))
            return;
        _side_web = [RXWebSide new];
    }
    _side_web.observing = v;
}
- (int)preparing {
    return _side_web ? _side_web.preparing : zero_v<int>();
}
- (void)setPreparing:(int)v {
    if (!_side_web) {
        if (is_zero(v))
            return;
        _side_web = [RXWebSide new];
    }
    _side_web.preparing = v;
}
- (NSString*)deferred {
    return _side_web ? _side_web.deferred : zero_v<NSString*>();
}
- (void)setDeferred:(NSString*)v {
    if (!_side_web) {
        if (is_zero(v))
            return;
        _side_web = [RXWebSide new];
    }
    _side_web.deferred = v;
}
- (NSTimer*)cookie_timer {
    return _side_web ? _side_web.cookie_timer : zero_v<NSTimer*>();
}
- (void)setCookie_timer:(NSTimer*)v {
    if (!_side_web) {
        if (is_zero(v))
            return;
        _side_web = [RXWebSide new];
    }
    _side_web.cookie_timer = v;
}
- (NSString*)restore {
    return _side_web ? _side_web.restore : zero_v<NSString*>();
}
- (void)setRestore:(NSString*)v {
    if (!_side_web) {
        if (is_zero(v))
            return;
        _side_web = [RXWebSide new];
    }
    _side_web.restore = v;
}
- (NSString*)waiting {
    return _side_web ? _side_web.waiting : zero_v<NSString*>();
}
- (void)setWaiting:(NSString*)v {
    if (!_side_web) {
        if (is_zero(v))
            return;
        _side_web = [RXWebSide new];
    }
    _side_web.waiting = v;
}
- (id)saved_state {
    return _side_web ? _side_web.saved_state : zero_v<id>();
}
- (void)setSaved_state:(id)v {
    if (!_side_web) {
        if (is_zero(v))
            return;
        _side_web = [RXWebSide new];
    }
    _side_web.saved_state = v;
}
- (NSDate*)hidden_since {
    return _side_web ? _side_web.hidden_since : zero_v<NSDate*>();
}
- (void)setHidden_since:(NSDate*)v {
    if (!_side_web) {
        if (is_zero(v))
            return;
        _side_web = [RXWebSide new];
    }
    _side_web.hidden_since = v;
}
- (NSString*)session {
    return _side_web ? _side_web.session : zero_v<NSString*>();
}
- (void)setSession:(NSString*)v {
    if (!_side_web) {
        if (is_zero(v))
            return;
        _side_web = [RXWebSide new];
    }
    _side_web.session = v;
}
- (bool)save_pending {
    return _side_web ? _side_web.save_pending : zero_v<bool>();
}
- (void)setSave_pending:(bool)v {
    if (!_side_web) {
        if (is_zero(v))
            return;
        _side_web = [RXWebSide new];
    }
    _side_web.save_pending = v;
}
- (int)closed {
    return _side_web ? _side_web.closed : zero_v<int>();
}
- (void)setClosed:(int)v {
    if (!_side_web) {
        if (is_zero(v))
            return;
        _side_web = [RXWebSide new];
    }
    _side_web.closed = v;
}
- (double)progress {
    return _side_drawer ? _side_drawer.progress : zero_v<double>();
}
- (void)setProgress:(double)v {
    if (!_side_drawer) {
        if (is_zero(v))
            return;
        _side_drawer = [RXDrawerSide new];
    }
    _side_drawer.progress = v;
}
- (double)slide_t0 {
    return _side_drawer ? _side_drawer.slide_t0 : zero_v<double>();
}
- (void)setSlide_t0:(double)v {
    if (!_side_drawer) {
        if (is_zero(v))
            return;
        _side_drawer = [RXDrawerSide new];
    }
    _side_drawer.slide_t0 = v;
}
- (double)slide_from {
    return _side_drawer ? _side_drawer.slide_from : zero_v<double>();
}
- (void)setSlide_from:(double)v {
    if (!_side_drawer) {
        if (is_zero(v))
            return;
        _side_drawer = [RXDrawerSide new];
    }
    _side_drawer.slide_from = v;
}
- (double)slide_to {
    return _side_drawer ? _side_drawer.slide_to : zero_v<double>();
}
- (void)setSlide_to:(double)v {
    if (!_side_drawer) {
        if (is_zero(v))
            return;
        _side_drawer = [RXDrawerSide new];
    }
    _side_drawer.slide_to = v;
}
- (double)slide_len {
    return _side_drawer ? _side_drawer.slide_len : zero_v<double>();
}
- (void)setSlide_len:(double)v {
    if (!_side_drawer) {
        if (is_zero(v))
            return;
        _side_drawer = [RXDrawerSide new];
    }
    _side_drawer.slide_len = v;
}
- (int)slide_gen {
    return _side_drawer ? _side_drawer.slide_gen : zero_v<int>();
}
- (void)setSlide_gen:(int)v {
    if (!_side_drawer) {
        if (is_zero(v))
            return;
        _side_drawer = [RXDrawerSide new];
    }
    _side_drawer.slide_gen = v;
}
- (NSArray<CALayer*>*)slide_layers {
    return _side_drawer ? _side_drawer.slide_layers : zero_v<NSArray<CALayer*>*>();
}
- (void)setSlide_layers:(NSArray<CALayer*>*)v {
    if (!_side_drawer) {
        if (is_zero(v))
            return;
        _side_drawer = [RXDrawerSide new];
    }
    _side_drawer.slide_layers = v;
}
- (id)slide {
    return _side_drawer ? _side_drawer.slide : zero_v<id>();
}
- (void)setSlide:(id)v {
    if (!_side_drawer) {
        if (is_zero(v))
            return;
        _side_drawer = [RXDrawerSide new];
    }
    _side_drawer.slide = v;
}
- (bool)over_anchor {
    return _side_drawer ? _side_drawer.over_anchor : zero_v<bool>();
}
- (void)setOver_anchor:(bool)v {
    if (!_side_drawer) {
        if (is_zero(v))
            return;
        _side_drawer = [RXDrawerSide new];
    }
    _side_drawer.over_anchor = v;
}
- (bool)hover_armed {
    return _side_drawer ? _side_drawer.hover_armed : zero_v<bool>();
}
- (void)setHover_armed:(bool)v {
    if (!_side_drawer) {
        if (is_zero(v))
            return;
        _side_drawer = [RXDrawerSide new];
    }
    _side_drawer.hover_armed = v;
}
- (double)hover_out {
    return _side_drawer ? _side_drawer.hover_out : zero_v<double>();
}
- (void)setHover_out:(double)v {
    if (!_side_drawer) {
        if (is_zero(v))
            return;
        _side_drawer = [RXDrawerSide new];
    }
    _side_drawer.hover_out = v;
}
- (NSTimer*)hover_timer {
    return _side_drawer ? _side_drawer.hover_timer : zero_v<NSTimer*>();
}
- (void)setHover_timer:(NSTimer*)v {
    if (!_side_drawer) {
        if (is_zero(v))
            return;
        _side_drawer = [RXDrawerSide new];
    }
    _side_drawer.hover_timer = v;
}
- (NSSize)box_from {
    return _side_drawer ? _side_drawer.box_from : zero_v<NSSize>();
}
- (void)setBox_from:(NSSize)v {
    if (!_side_drawer) {
        if (is_zero(v))
            return;
        _side_drawer = [RXDrawerSide new];
    }
    _side_drawer.box_from = v;
}
- (NSSize)box_to {
    return _side_drawer ? _side_drawer.box_to : zero_v<NSSize>();
}
- (void)setBox_to:(NSSize)v {
    if (!_side_drawer) {
        if (is_zero(v))
            return;
        _side_drawer = [RXDrawerSide new];
    }
    _side_drawer.box_to = v;
}
- (NSSize)box_now {
    return _side_drawer ? _side_drawer.box_now : zero_v<NSSize>();
}
- (void)setBox_now:(NSSize)v {
    if (!_side_drawer) {
        if (is_zero(v))
            return;
        _side_drawer = [RXDrawerSide new];
    }
    _side_drawer.box_now = v;
}
- (id)resize {
    return _side_drawer ? _side_drawer.resize : zero_v<id>();
}
- (void)setResize:(id)v {
    if (!_side_drawer) {
        if (is_zero(v))
            return;
        _side_drawer = [RXDrawerSide new];
    }
    _side_drawer.resize = v;
}
- (CGFloat)shift_from {
    return _side_drawer ? _side_drawer.shift_from : zero_v<CGFloat>();
}
- (void)setShift_from:(CGFloat)v {
    if (!_side_drawer) {
        if (is_zero(v))
            return;
        _side_drawer = [RXDrawerSide new];
    }
    _side_drawer.shift_from = v;
}
- (CGFloat)shift_to {
    return _side_drawer ? _side_drawer.shift_to : zero_v<CGFloat>();
}
- (void)setShift_to:(CGFloat)v {
    if (!_side_drawer) {
        if (is_zero(v))
            return;
        _side_drawer = [RXDrawerSide new];
    }
    _side_drawer.shift_to = v;
}
- (CGFloat)shift_now {
    return _side_drawer ? _side_drawer.shift_now : zero_v<CGFloat>();
}
- (void)setShift_now:(CGFloat)v {
    if (!_side_drawer) {
        if (is_zero(v))
            return;
        _side_drawer = [RXDrawerSide new];
    }
    _side_drawer.shift_now = v;
}
- (id)shift_glide {
    return _side_drawer ? _side_drawer.shift_glide : zero_v<id>();
}
- (void)setShift_glide:(id)v {
    if (!_side_drawer) {
        if (is_zero(v))
            return;
        _side_drawer = [RXDrawerSide new];
    }
    _side_drawer.shift_glide = v;
}
- (NSValue*)moved {
    return _side_drawer ? _side_drawer.moved : zero_v<NSValue*>();
}
- (void)setMoved:(NSValue*)v {
    if (!_side_drawer) {
        if (is_zero(v))
            return;
        _side_drawer = [RXDrawerSide new];
    }
    _side_drawer.moved = v;
}
- (NSValue*)sized {
    return _side_drawer ? _side_drawer.sized : zero_v<NSValue*>();
}
- (void)setSized:(NSValue*)v {
    if (!_side_drawer) {
        if (is_zero(v))
            return;
        _side_drawer = [RXDrawerSide new];
    }
    _side_drawer.sized = v;
}
- (CGFloat)held_h {
    return _side_drawer ? _side_drawer.held_h : zero_v<CGFloat>();
}
- (void)setHeld_h:(CGFloat)v {
    if (!_side_drawer) {
        if (is_zero(v))
            return;
        _side_drawer = [RXDrawerSide new];
    }
    _side_drawer.held_h = v;
}
- (int)drag_mode {
    return _side_drawer ? _side_drawer.drag_mode : zero_v<int>();
}
- (void)setDrag_mode:(int)v {
    if (!_side_drawer) {
        if (is_zero(v))
            return;
        _side_drawer = [RXDrawerSide new];
    }
    _side_drawer.drag_mode = v;
}
- (NSPoint)drag_mouse {
    return _side_drawer ? _side_drawer.drag_mouse : zero_v<NSPoint>();
}
- (void)setDrag_mouse:(NSPoint)v {
    if (!_side_drawer) {
        if (is_zero(v))
            return;
        _side_drawer = [RXDrawerSide new];
    }
    _side_drawer.drag_mouse = v;
}
- (NSPoint)drag_from {
    return _side_drawer ? _side_drawer.drag_from : zero_v<NSPoint>();
}
- (void)setDrag_from:(NSPoint)v {
    if (!_side_drawer) {
        if (is_zero(v))
            return;
        _side_drawer = [RXDrawerSide new];
    }
    _side_drawer.drag_from = v;
}
- (NSSize)drag_size {
    return _side_drawer ? _side_drawer.drag_size : zero_v<NSSize>();
}
- (void)setDrag_size:(NSSize)v {
    if (!_side_drawer) {
        if (is_zero(v))
            return;
        _side_drawer = [RXDrawerSide new];
    }
    _side_drawer.drag_size = v;
}
- (bool)drag_queued {
    return _side_drawer ? _side_drawer.drag_queued : zero_v<bool>();
}
- (void)setDrag_queued:(bool)v {
    if (!_side_drawer) {
        if (is_zero(v))
            return;
        _side_drawer = [RXDrawerSide new];
    }
    _side_drawer.drag_queued = v;
}
- (NSString*)commanded {
    return _side_drawer ? _side_drawer.commanded : zero_v<NSString*>();
}
- (void)setCommanded:(NSString*)v {
    if (!_side_drawer) {
        if (is_zero(v))
            return;
        _side_drawer = [RXDrawerSide new];
    }
    _side_drawer.commanded = v;
}
- (double)outside_closed {
    return _side_drawer ? _side_drawer.outside_closed : zero_v<double>();
}
- (void)setOutside_closed:(double)v {
    if (!_side_drawer) {
        if (is_zero(v))
            return;
        _side_drawer = [RXDrawerSide new];
    }
    _side_drawer.outside_closed = v;
}
- (bool)reveal_pending {
    return _side_drawer ? _side_drawer.reveal_pending : zero_v<bool>();
}
- (void)setReveal_pending:(bool)v {
    if (!_side_drawer) {
        if (is_zero(v))
            return;
        _side_drawer = [RXDrawerSide new];
    }
    _side_drawer.reveal_pending = v;
}
- (NSUInteger)revealed_of {
    return _side_drawer ? _side_drawer.revealed_of : zero_v<NSUInteger>();
}
- (void)setRevealed_of:(NSUInteger)v {
    if (!_side_drawer) {
        if (is_zero(v))
            return;
        _side_drawer = [RXDrawerSide new];
    }
    _side_drawer.revealed_of = v;
}
- (NSString*)loaded {
    return _side_media ? _side_media.loaded : zero_v<NSString*>();
}
- (void)setLoaded:(NSString*)v {
    if (!_side_media) {
        if (is_zero(v))
            return;
        _side_media = [RXMediaSide new];
    }
    _side_media.loaded = v;
}
- (CGSize)image_size {
    return _side_media ? _side_media.image_size : zero_v<CGSize>();
}
- (void)setImage_size:(CGSize)v {
    if (!_side_media) {
        if (is_zero(v))
            return;
        _side_media = [RXMediaSide new];
    }
    _side_media.image_size = v;
}
- (CGFloat)image_px {
    return _side_media ? _side_media.image_px : zero_v<CGFloat>();
}
- (void)setImage_px:(CGFloat)v {
    if (!_side_media) {
        if (is_zero(v))
            return;
        _side_media = [RXMediaSide new];
    }
    _side_media.image_px = v;
}
- (CGSize)image_native {
    return _side_media ? _side_media.image_native : zero_v<CGSize>();
}
- (void)setImage_native:(CGSize)v {
    if (!_side_media) {
        if (is_zero(v))
            return;
        _side_media = [RXMediaSide new];
    }
    _side_media.image_native = v;
}
- (id)frames {
    return _side_media ? _side_media.frames : zero_v<id>();
}
- (void)setFrames:(id)v {
    if (!_side_media) {
        if (is_zero(v))
            return;
        _side_media = [RXMediaSide new];
    }
    _side_media.frames = v;
}
- (NSData*)frame {
    return _side_media ? _side_media.frame : zero_v<NSData*>();
}
- (void)setFrame:(NSData*)v {
    if (!_side_media) {
        if (is_zero(v))
            return;
        _side_media = [RXMediaSide new];
    }
    _side_media.frame = v;
}
- (double)spin_base {
    return _side_media ? _side_media.spin_base : zero_v<double>();
}
- (void)setSpin_base:(double)v {
    if (!_side_media) {
        if (is_zero(v))
            return;
        _side_media = [RXMediaSide new];
    }
    _side_media.spin_base = v;
}
- (double)spin_t0 {
    return _side_media ? _side_media.spin_t0 : zero_v<double>();
}
- (void)setSpin_t0:(double)v {
    if (!_side_media) {
        if (is_zero(v))
            return;
        _side_media = [RXMediaSide new];
    }
    _side_media.spin_t0 = v;
}
- (double)spin_period {
    return _side_media ? _side_media.spin_period : zero_v<double>();
}
- (void)setSpin_period:(double)v {
    if (!_side_media) {
        if (is_zero(v))
            return;
        _side_media = [RXMediaSide new];
    }
    _side_media.spin_period = v;
}
- (double)shown_value {
    return _side_media ? _side_media.shown_value : zero_v<double>();
}
- (void)setShown_value:(double)v {
    if (!_side_media) {
        if (is_zero(v))
            return;
        _side_media = [RXMediaSide new];
    }
    _side_media.shown_value = v;
}
- (double)wave_phase {
    return _side_media ? _side_media.wave_phase : zero_v<double>();
}
- (void)setWave_phase:(double)v {
    if (!_side_media) {
        if (is_zero(v))
            return;
        _side_media = [RXMediaSide new];
    }
    _side_media.wave_phase = v;
}
- (double)last_tick {
    return _side_media ? _side_media.last_tick : zero_v<double>();
}
- (void)setLast_tick:(double)v {
    if (!_side_media) {
        if (is_zero(v))
            return;
        _side_media = [RXMediaSide new];
    }
    _side_media.last_tick = v;
}
- (void)setParent:(RXNode*)parent {
    _w_parent = parent;
    up = parent;
}
- (void)setDoc:(RXDoc*)doc {
    _w_doc = doc;
    in = doc;
}
- (void)setType:(NSString*)type {
    _type = [type copy];
    E e;
    std::string_view v = type.UTF8String ?: "";
    ps.init(rx::schema::elem_of(v, &e) ? e : E::count_);
}
- (void)clicked:(id)sender {
    if (self.doc.ctx)
        doc_call(self.doc, @"emit", @[@(self.uid), @"clicked", @[]]);
}
- (void)dealloc {
    for (RXNode* c in _children)
        c->up = nil;
    if (self.observing) {
        for (NSString* k in @[@"title", @"URL", @"loading", @"canGoBack", @"canGoForward"]) {
            [self.view removeObserver:self forKeyPath:k];
        }
    }
}
@end
