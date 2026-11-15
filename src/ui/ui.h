// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include "base/rexui.h"

#import <QuartzCore/QuartzCore.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#include "core/keys/keys.h"

#include <vector>

#include "engine/core/doc.h"
#include "ui/propstore.h"

using P = rx::schema::Prop;
using E = rx::schema::Elem;

@class RXDoc, RXSlot, RXDrawerView, RXExtDelegate;

struct Theme {
    NSColor *bg = NSColor.blackColor, *fg = [NSColor colorWithWhite:1 alpha:0.92];
    bool dark = true;
};

@class RXDockView, RXEditor, RXTermInput;
@interface RXNode : NSObject <WKNavigationDelegate, WKUIDelegate, WKWebExtensionTab> {
   @public
    rx::ui::PropStore ps;
    __unsafe_unretained RXNode* up;
    __unsafe_unretained RXDoc* in;
    bool _m_valid, _p_valid;
    uint32_t _row, _placed_row;
    uint64_t _z_epoch;
    NSArray<RXNode*>* _z_order;
}
@property(nonatomic) int uid;
@property(nonatomic, copy) NSString* type;
@property(nonatomic, strong) NSMutableDictionary<NSString*, id>* extras;
@property(nonatomic, strong) CALayer* layer;
@property(nonatomic, strong) NSView* view;
@property(nonatomic, strong) RXDockView* host;
@property(nonatomic, strong) RXEditor* editor;
@property(nonatomic, strong) NSView* clip;
@property(nonatomic, strong) NSMutableArray<RXNode*>* children;
@property(nonatomic) RXNode* parent;
@property(nonatomic) RXDoc* doc;
@property(nonatomic) int pid;
@property(nonatomic) uint32_t io_id;
@property(nonatomic) int stdin_fd;
@property(nonatomic) bool dormant;
@property(nonatomic) bool spawn_due;
@property(nonatomic, strong) NSMutableData *out, *err;
@property(nonatomic) int failures;
@property(nonatomic, strong) NSDate* started;
@property(nonatomic) int generation;
@property(nonatomic, strong) id proc_box;
@property(nonatomic) bool parked;
@property(nonatomic) bool kept;
@property(nonatomic, copy) NSString* loaded;
@property(nonatomic) CGSize image_size;
@property(nonatomic, strong) NSArray<RXNode*>* kids_shown;
@property(nonatomic, strong) id vlist;
@property(nonatomic) uint64_t kids_epoch;
@property(nonatomic) double slide_t0, slide_from, slide_to, slide_len;
@property(nonatomic) int slide_gen;
@property(nonatomic, strong) NSArray<CALayer*>* slide_layers;
@property(nonatomic) CGFloat image_px;
@property(nonatomic) CGSize image_native;
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
@property(nonatomic) double ended_since;
@property(nonatomic) int ended_times;
@property(nonatomic) double progress;
@property(nonatomic, strong) id slide;
@property(nonatomic) bool over_anchor, hover_armed;
@property(nonatomic) double hover_out;
@property(nonatomic, strong) NSTimer* hover_timer;
@property(nonatomic, copy) NSString* exe;
@property(nonatomic, strong) NSDate* exe_mtime;
@property(nonatomic) double spin_base, spin_t0, spin_period;
@property(nonatomic) double shown_value, wave_phase, last_tick;
@property(nonatomic) double seen_at;
@property(nonatomic) CGFloat m_avail;
@property(nonatomic) NSSize m_size;
@property(nonatomic) bool m_valid;
@property(nonatomic) NSRect p_frame;
@property(nonatomic, weak) RXNode* focus_before;
@property(nonatomic, strong) id fx;
@property(nonatomic) bool has_gradient;
@property(nonatomic) CGSize gradient_at;
@property(nonatomic) bool leaving;
@property(nonatomic) bool wants_layout;
@property(nonatomic) bool wants_scroll;
@property(nonatomic) bool transformed;
@property(nonatomic) bool z_kids;
@property(nonatomic) bool p_valid;
@property(nonatomic, strong) NSArray<NSNumber*>* order;
@property(nonatomic) uint32_t ticker;
@property(nonatomic) NSSize box_from, box_to, box_now;
@property(nonatomic, strong) id resize;
@property(nonatomic) NSInteger page_shown;
@property(nonatomic) CGFloat shift_from, shift_to, shift_now;
@property(nonatomic, strong) id shift_glide;
@property(nonatomic, strong) NSValue *moved, *sized;
@property(nonatomic) CGFloat held_h;
@property(nonatomic) int drag_mode;
@property(nonatomic) NSPoint drag_mouse, drag_from;
@property(nonatomic) NSSize drag_size;
@property(nonatomic) bool drag_queued;
@property(nonatomic, copy) NSString* commanded;
@property(nonatomic) double outside_closed;
@property(nonatomic) bool reveal_pending;
@property(nonatomic) NSUInteger revealed_of;
@property(nonatomic, strong) id frames;
@property(nonatomic, strong) NSData* frame;
@property(nonatomic) bool hovered, pressed;
@property(nonatomic) bool appear_due;
@property(nonatomic) bool move_shown;
@property(nonatomic) CGRect move_frame;
@property(nonatomic, weak) CALayer* move_root;
- (void)clicked:(id)sender;
@end

NSString* prop_ns(P p);
id extra_of(RXNode* n, P p);
bool prop_named(NSString* name, P* p);

inline rx::ui::PVal pv(RXNode* n, P p) {
    if (!n)
        return {};
    int i = n->ps.slot(p);
    if (i >= 0)
        return n->ps.get(i);
    if (n.extras)
        return rx::ui::pval_of(extra_of(n, p));
    return {};
}
inline double num(RXNode* n, P p, double def) {
    rx::ui::PVal v = pv(n, p);
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
inline bool has_num(RXNode* n, P p) {
    rx::ui::PVal v = pv(n, p);
    return v.k == rx::ui::PK::num && v.d == v.d;
}
NSString* str_slow(const rx::ui::PVal& v, NSString* def);
inline NSString* str(RXNode* n, P p, NSString* def) {
    rx::ui::PVal v = pv(n, p);
    if (v.k == rx::ui::PK::obj && [v.o isKindOfClass:NSString.class])
        return v.o;
    return v.k == rx::ui::PK::none ? def : str_slow(v, def);
}
inline bool flag(RXNode* n, P p, bool def) {
    rx::ui::PVal v = pv(n, p);
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
id obj(RXNode* n, P p);
inline id obj_of(RXNode* n, P p) {
    rx::ui::PVal v = pv(n, p);
    return v.k == rx::ui::PK::obj ? v.o : nil;
}
inline bool has_prop(RXNode* n, P p) {
    return pv(n, p).k != rx::ui::PK::none;
}
inline E elem(RXNode* n) {
    return n ? n->ps.elem() : E::count_;
}
inline bool is_elem(RXNode* n, E e) {
    return elem(n) == e;
}

void prop_put(RXNode* n, NSString* name, id value);
NSDictionary<NSString*, id>* props_dict(RXNode* n);
void prop_store(RXNode* n, P p, NSString* name, const rx::ui::PVal& v);

NSString* default_ui_dir(void);
void ui_fonts_for(NSString* dir);

@interface RXDoc : NSObject {
   @public
    rx::ui::UidMap<__unsafe_unretained RXNode*> index;
}
@property(nonatomic, copy) NSString* path;
@property(nonatomic, strong) NSDate* mtime;
@property(nonatomic, strong) id ctx;
@property(nonatomic) void* engine;
@property(nonatomic) bool has_areas;
@property(nonatomic) bool has_tips;
@property(nonatomic) bool reloading;
@property(nonatomic, copy) NSString* restore_state;
@property(nonatomic, strong) NSMutableDictionary<NSNumber*, RXNode*>* nodes;
@property(nonatomic, strong) RXNode* root;
@property(nonatomic, strong) NSHashTable<RXNode*>* natives;
@property(nonatomic) bool layout_pending, relayout_chrome;
@property(nonatomic, strong) NSMutableDictionary<NSString*, NSString*>* restore_pages;
@property(nonatomic) bool wants_rexstate;
@property(nonatomic) bool wants_hover;
@property(nonatomic) bool wants_fps_panes;
@property(nonatomic) bool wants_hints;
@property(nonatomic) bool wants_notices;
@property(nonatomic) bool takes_links;
@property(nonatomic) bool window_delegate;
@property(nonatomic) bool wants_diagnostics;
@property(nonatomic) bool notice_delegate;
@property(nonatomic) bool activity_delegate;
@property(nonatomic) bool takes_paste;
@property(nonatomic) bool wants_activity;
@property(nonatomic) bool wants_fps;
@property(nonatomic) bool pane;
@property(nonatomic, copy) NSString* pane_block;
@property(nonatomic, copy) NSString* pane_program;
@property(nonatomic, copy) NSArray<NSString*>* pane_args;
@property(nonatomic) bool wants_debug;
@property(nonatomic) bool devtools;
@property(nonatomic, copy) NSString* error;
@property(nonatomic, strong) NSDictionary<NSString*, NSDate*>* uses;
@end

@interface RXLayer : CALayer
@end

@class RXRuns;
@interface RXTextLayer : RXLayer
@property(nonatomic) bool owed;
@property(nonatomic, copy) NSString* text;
@property(nonatomic, strong) NSFont* font;
@property(nonatomic, strong) NSColor* color;
@property(nonatomic) bool wrap;
@property(nonatomic) NSInteger maxLines;
@property(nonatomic) NSTextAlignment align;
@property(nonatomic) bool head;
@property(nonatomic) CGFloat kern;
@property(nonatomic) bool underline, strikeout;
@property(nonatomic) CGFloat lineHeight;
@property(nonatomic, copy) NSArray* spans;
- (NSString*)linkAt:(CGPoint)p;
@property(nonatomic, strong) RXRuns* runs;
- (void)syntaxChanged:(bool)style;
@property(nonatomic, strong) NSColor *glow, *outlineColor;
@property(nonatomic) CGFloat glowRadius, outline;
@property(nonatomic, copy) NSString* shownText;
@property(nonatomic) bool hideText;
@property(nonatomic) CGFloat top;
@end

@interface RXEditor : NSObject
@property(nonatomic) RXNode* node;
@property(nonatomic) id host;
@property(nonatomic, readonly) CALayer* layer;
@property(nonatomic, readonly) bool multiline;
@property(nonatomic, strong) NSFont* font;
@property(nonatomic, strong) NSColor* color;
@property(nonatomic, copy) NSString* placeholder;
@property(nonatomic) bool editable;
@property(nonatomic) NSSize inset;
@property(nonatomic) bool focused;
@property(nonatomic) bool wrap;
@property(nonatomic) bool follow;
@property(nonatomic) bool secure;
@property(nonatomic) NSUInteger max_length;
@property(nonatomic) bool from_file;
@property(nonatomic) int press_unit;
@property(nonatomic) NSRange press_from;
@property(nonatomic, copy) const void* (^lang)(void);
@property(nonatomic, copy) NSArray<NSColor*>* (^token_colors)(void);
@property(nonatomic, copy) void (^changed)(NSString* text);
@property(nonatomic, copy) bool (^command)(SEL sel);
@property(nonatomic, copy) void (^ended)(void);
- (instancetype)initMultiline:(bool)multi;
- (NSString*)text;
- (void)setText:(NSString*)t;
- (NSRange)selection;
- (NSRange)marked;
- (NSString*)substring:(NSRange)r;
- (void)noteSent:(NSString*)t;
- (bool)isEcho:(NSString*)t;
- (NSString*)checkLayout;
- (NSColor*)colorAt:(NSUInteger)i;
- (bool)scanDone;
- (bool)findNext:(NSString*)s backwards:(bool)back;
- (void)appendText:(NSString*)s;
- (void)adoptRope:(void*)rope highlighter:(void*)hl lang:(const void*)lang;
- (CGFloat)maxScroll;
- (void)styleChanged;
- (void)refresh;
- (void)select:(NSUInteger)anchor to:(NSUInteger)caret;
- (void)insert:(NSString*)s;
- (bool)typePair:(NSString*)s;
- (void)setMarked:(NSString*)s selected:(NSRange)sr replacing:(NSRange)rr;
- (void)unmark;
- (bool)perform:(SEL)sel;
- (void)copySelection;
- (void)cut;
- (void)paste;
- (void)undo:(bool)redo;
- (void)pressAt:(CGPoint)p clicks:(NSInteger)clicks extend:(bool)extend;
- (void)dragTo:(CGPoint)p;
- (bool)scrollBy:(NSEvent*)e;
- (NSRect)windowRectFor:(NSRange)r;
- (NSUInteger)indexAtWindowPoint:(NSPoint)win;
- (void)handleKey:(NSEvent*)ev;
- (void)handleKeyUp:(NSEvent*)ev;
- (void)releaseAt:(CGPoint)p;
- (void)otherPress:(NSEvent*)e at:(CGPoint)p up:(bool)up;
@end
@interface RXTermInput : RXEditor
@end
RXTermInput* term_input_open(RXNode* n, NSString* window, NSString* session);
void term_input_fit(RXTermInput* i, CGSize size);
NSString* term_input_window(RXTermInput* i);
void term_input_close(RXTermInput* i);
void term_input_hover(id host, RXTermInput* i, CGPoint q);
void term_flags_changed(void);
NSCursor* term_input_cursor(RXTermInput* i);
NSString* term_hovered_link(void);
void term_session_find(NSString* label, void (^done)(NSString* session, NSString* window));
void focus_node(RXNode* n, bool by_keyboard);
void focus_release(RXNode* n);
void focus_gone(RXNode* n);
void focus_move(RXNode* from, int dir);
void focus_key(RXNode* n, NSEvent* e);
void focus_key_up(RXNode* n, NSEvent* e);
void focus_changed(RXNode* n, bool on);
NSPasteboard* ui_pasteboard(void);
void focus_ring(RXNode* n, bool on);
RXNode* focus_in_window(NSWindow* w);
NSString* key_base(NSEvent* e);
NSString* key_text(NSEvent* e);
NSString* key_mods(NSEventModifierFlags m);
void text_press(RXNode* n, CGPoint q, NSInteger clicks, bool extend);
void text_drag(RXNode* n, CGPoint q);
void text_release(RXNode* n);
void text_select_clear(void);
bool text_select_key(NSEvent* e);
void text_gone(RXNode* n);
NSString* text_selected_string(void);
bool text_selection_rows(RXNode* list, uint32_t* lo, uint32_t* hi);
bool data_drag_cancel(void);
void editor_save(RXNode* n);
bool editor_focus(RXEditor* e);
void editor_blur(RXEditor* e);
RXEditor* editor_in(NSWindow* w);

id menu_open(NSWindow* w, NSArray<NSDictionary*>* items, NSPoint at);
void menu_close(void);
bool menu_open_now(void);
bool menu_press(NSEvent* e);
bool menu_key(NSEvent* e);
void picker_unloaded(RXDoc* doc);
bool picker_key(NSEvent* e);
long picker_listed(void);
NSString* drop_shell_words(NSArray<NSString*>* paths);
bool keys_rex_plain(void);
NSString* secure_dots(NSString* text, bool keep_length);
uint64_t hit_visits(void);
uint64_t text_typesets(void);
size_t fonts_kept(void);
size_t symbols_kept(void);
RXEditor* node_editor(RXNode* n, bool make);
void editor_layout(RXNode* n);

@interface RXIconLayer : RXLayer
@property(nonatomic, strong) NSImage* image;
@end

@interface RXScrollLayer : RXLayer
@property(nonatomic, readonly) RXLayer* doc;
@property(nonatomic) RXNode* node;
@property(nonatomic) CGFloat offset;
@property(nonatomic) bool horizontal;
@property(nonatomic) CGFloat base;
@property(nonatomic, readonly) CGFloat maxOffset;
@property(nonatomic) double fade;
@property(nonatomic) bool guttered;
- (void)setContentHeight:(CGFloat)h;
- (void)reveal:(NSRect)r;
- (bool)shows:(CALayer*)l;
- (void)owe:(RXTextLayer*)l;
- (void)payOwed;
- (NSUInteger)owedCount;
- (void)glideTo:(CGFloat)y ms:(double)ms;
- (void)scrollWheel:(NSEvent*)e;
- (bool)onKnobStrip:(CGPoint)q;
- (void)dragKnob:(CGPoint)q;
@end

@interface RXSliderLayer : RXLayer
@property(nonatomic) double step;
@property(nonatomic, strong) id fillColor, trackColor, knobColor;
@property(nonatomic) double value, minValue, maxValue;
@property(nonatomic) bool dragging, enabled;
@property(nonatomic) bool behind;
- (double)valueAt:(CGFloat)x;
@end

@interface RXButtonLayer : RXLayer
@property(nonatomic) RXNode* node;
@property(nonatomic, strong) CALayer *bezel, *icon, *state;
@property(nonatomic, strong) RXTextLayer* title;
@property(nonatomic, strong) NSImage* iconImage;
@property(nonatomic) NSSize iconSize;
- (void)refreshState;
- (NSSize)measure;
@end

@class RXRoot;

@interface RXLayerHost : NSResponder
@property(nonatomic, readonly) CALayer* layer;
@property(nonatomic) NSRect frame;
@property(nonatomic, readonly) NSRect bounds;
@property(nonatomic, readonly) NSRect visibleRect;
@property(nonatomic, getter=isHidden) BOOL hidden;
@property(nonatomic) CGFloat alphaValue;
@property(nonatomic, readonly, getter=isHiddenOrHasHiddenAncestor) BOOL hiddenOrHasHiddenAncestor;
@property(nonatomic, readonly) NSWindow* window;
@property(nonatomic, readonly) RXRoot* rootView;
@property(nonatomic, readonly) id superview;
@property(nonatomic, readonly) NSArray<RXLayerHost*>* subhosts;
- (instancetype)initWithFrame:(NSRect)f;
- (BOOL)isFlipped;
- (void)addSubhost:(RXLayerHost*)h;
- (void)removeFromSuperview;
- (void)detach;
- (NSView*)carrier;
- (BOOL)hasCarrier;
- (BOOL)isDescendantOf:(id)v;
- (void)attachTo:(id)parent;
- (NSPoint)windowPoint:(NSPoint)p;
- (NSPoint)pointFromWindow:(NSPoint)win;
- (NSPoint)convertPoint:(NSPoint)p fromView:(id)v;
- (NSPoint)convertPoint:(NSPoint)p toView:(id)v;
- (NSRect)convertRect:(NSRect)r fromView:(id)v;
- (NSRect)convertRect:(NSRect)r toView:(id)v;
- (NSPoint)convertPointToLayer:(NSPoint)p;
- (NSPoint)convertPointFromLayer:(NSPoint)p;
- (NSRect)convertRectToLayer:(NSRect)r;
- (NSRect)convertRectFromLayer:(NSRect)r;
- (id)hitTest:(NSPoint)p;
- (void)viewDidMoveToWindow;
- (void)viewDidHide;
- (void)viewDidUnhide;
@end

enum : int {
    kBandDocks = -40,
    kBandDrawers = -10,
    kBandDocksRaised = -7,
    kBandFloatBar = -5,
    kBandSearch = 10,
    kBandMenu = 20
};
@interface RXRoot : NSView
@property(nonatomic, strong) RXEditor* editor;
@property(nonatomic) RXNode* focus;
- (CALayer*)band:(int)z;
- (void)addHost:(RXLayerHost*)h band:(int)z;
- (void)forgetHost:(RXLayerHost*)h;
- (int)bandOf:(RXLayerHost*)h;
- (CALayer*)cover:(bool)on;
- (bool)coversBand:(int)z;
- (void)revealCovered:(bool)on;
- (id)topAt:(NSPoint)win owner:(RXLayerHost**)owner;
- (RXLayerHost*)hostAt:(NSPoint)win;
@end

@interface RXCarrier : NSView
@property(nonatomic) RXLayerHost* host;
@end

@interface RXTwinShape : CAShapeLayer
@property(nonatomic, strong) CAShapeLayer* twin;
@end
RXRoot* ui_root(NSView* chrome);
RXRoot* root_of(NSWindow* w);
RXRoot* pane_root(RXDoc* doc, bool make);
RXLayerHost* pane_host_at(NSWindow* w, NSPoint win);

@interface RXDockView : RXLayerHost
@property(nonatomic) RXNode* node;
@property(nonatomic) RXSlot* slot;
- (void)pointer:(NSPoint)p;
- (void)pointerLeft:(NSPoint)p;
- (void)pointerEntered;
- (NSCursor*)pointerCursor;
@end

@interface RXDrawerView : RXDockView
@property(nonatomic) NSRect shown;
@property(nonatomic, strong) CAShapeLayer* fill;
@property(nonatomic, strong) RXDockView* body;
@end

@interface RXAnim : NSObject
@property(nonatomic) const double* curve;
@property(nonatomic) double start, duration;
@property(nonatomic, copy) void (^step)(double);
@property(nonatomic, copy) void (^done)(void);
@property(nonatomic) uint32_t tick;
- (void)cancel;
@end

@interface RXTile : NSObject
@property(nonatomic, copy) NSString* path;
@property(nonatomic, copy) NSString* title;
@property(nonatomic) int kind;
@property(nonatomic) NSRect frame;
@property(nonatomic, strong) CALayer* layer;
@property(nonatomic, strong) CALayer* tile;
@property(nonatomic, strong) CALayer* dot;
@property(nonatomic, strong) CALayer* glyph;
@property(nonatomic, strong) CALayer* glyph_lit;
@property(nonatomic, strong) CALayer* lit;
@end

@interface RXAppBar : NSObject
@property(nonatomic) RXSlot* slot;
@property(nonatomic, strong) RXLayer* layer;
@property(nonatomic) NSRect frame;
@property(nonatomic, strong) CALayer* pill;
@property(nonatomic) CGFloat pill_radius;
@property(nonatomic, copy) NSString* pill_shape;
@property(nonatomic, strong) CAShapeLayer* pill_fill;
@property(nonatomic, strong) NSMutableArray<RXTile*>* tiles;
@property(nonatomic) uint64_t signature;
@property(nonatomic, copy) NSString* laid_out;
@property(nonatomic) CGFloat mouse_x;
@property(nonatomic) CGFloat base;
@property(nonatomic, weak) RXTile* pressed;
@property(nonatomic) CGFloat press_x;
@property(nonatomic) bool dragging;
@property(nonatomic) NSInteger drop_at;
@property(nonatomic) bool torn;
@property(nonatomic, strong) CALayer* carried;
@property(nonatomic) id host;
@end

@interface RXSlot : NSObject
@property(nonatomic, copy) NSString* key;
@property(nonatomic, strong) RXDockView* view;
@property(nonatomic, strong) RXAppBar* bar;
@property(nonatomic, strong) RXLayerHost* floating;
@property(nonatomic) NSRect edge;
@property(nonatomic) bool raised;
@property(nonatomic) NSUInteger raise_gen;
@property(nonatomic) bool resizing;
@property(nonatomic) NSPoint resize_mouse;
@property(nonatomic) CGFloat resize_from;
@property(nonatomic, strong) NSArray<RXDoc*>* members;
@property(nonatomic, weak) RXDoc* lead;
@property(nonatomic) bool searching;
@property(nonatomic, copy) NSString* active;
@property(nonatomic) bool shown;
@property(nonatomic) double progress, target;
@property(nonatomic) CGFloat travel;
@property(nonatomic) double slide_from;
@property(nonatomic) double slide_ms, slide_until;
@property(nonatomic) bool slide_due;
@property(nonatomic) CGFloat size;
@property(nonatomic) CGFloat dragged;
@property(nonatomic) CGFloat dragged_across;
@property(nonatomic) int axis;
@property(nonatomic, strong) RXAnim *slide, *resize;
@property(nonatomic, copy) NSString* fading;
@property(nonatomic) bool near;
@property(nonatomic) double flying_until;
@end

extern Theme g_theme;
extern NSMutableArray<RXDoc*>* g_docs;
extern __weak NSWindow* g_window;
extern __weak NSResponder* g_terminal;
extern dispatch_queue_t g_write_queue;
extern NSUserDefaults* g_state;
static constexpr double kSpatial[4] = {0.38, 1.21, 0.22, 1.0};
static constexpr double kStandard[4] = {0.2, 0.0, 0.0, 1.0};
static constexpr double kExpo[4] = {0.16, 1.0, 0.3, 1.0};
static constexpr CGFloat kTile = 40, kTileGap = 10, kPillPad = 10, kBarHeight = 72;
static constexpr CGFloat kSeparator = 9;
enum { kTileDock, kTileSeparator, kTileSearch };
extern NSMutableDictionary<NSString*, RXSlot*>* g_slots;
extern int g_tab;
extern int g_fps;
extern NSArray<NSString*>* g_tab_titles;
extern NSString *g_session, *g_session_id;
extern NSArray<NSDictionary*>* g_sessions;

NSString* hex(NSColor* c);
void update_theme(void);
NSColor* parse_color(id value);
void refresh_theme(RXNode* n);

void set_lang(RXDoc* doc);
void lang_check(void);
void lang_misses_install(void);
NSString* tr(NSString* text);

bool is_type(RXNode* n, NSString* t);
bool is_box(RXNode* n);
bool is_list(RXNode* n);
CGRect layer_frame(RXNode* n, CALayer* l);
void apply_transform(RXNode* n);
bool focus_key_heard(RXNode* n, NSEvent* e);
bool focus_key_first(RXNode* n, NSEvent* e);
void focus_back(RXNode* drawer, NSWindow* w);
void editor_call(RXNode* n, NSString* method, NSString* arg);
bool disappear_play(RXNode* n, void (^done)(void));
void disappear_stop(RXNode* n);
bool mask_passing(CALayer* m);
void mask_set_own(CALayer* l, CALayer* own);
void box_fx_apply(RXNode* n, P p);
void layer_blur(CALayer* l, double r);
void box_fx_clipped(RXNode* n);
void box_fx_sync(RXNode* n);
void box_fx_follow(RXNode* n, NSString* key);
void box_fx_fade(RXNode* n, NSString* key, float from, float to, double seconds, CFTimeInterval begin,
                 CAMediaTimingFunction* f);
void box_fx_placed(RXNode* n, CGRect f);
void box_fx_gone(RXNode* n);
void list_scrolled(RXNode* n, CGFloat offset);
bool is_vlist(RXNode* n);
NSArray<RXNode*>* laid_out(RXNode* n);
void vlist_rows(RXNode* n, uint32_t count);
void vlist_row(RXNode* row, uint32_t index);
void vlist_shift(RXNode* n, int64_t d);
void vlist_due(RXNode* n);
void vlists_due(void);
void vlist_place(RXNode* n, NSRect frame);
void vlist_ask(RXNode* n);
CGFloat vlist_content_height(RXNode* n);
extern bool g_row_recycled;
void engine_list_window(RXDoc* doc, int uid, uint32_t first, uint32_t count);
bool is_drawer(RXNode* n);
bool is_grid(RXNode* n);
bool is_column(RXNode* n);
bool is_row(RXNode* n);
bool is_pages(RXNode* n);
double num(RXNode* n, NSString* k, double def);
bool has_num(RXNode* n, NSString* k);
NSString* str(RXNode* n, NSString* k, NSString* def);
bool flag(RXNode* n, NSString* k, bool def);
id obj(RXNode* n, NSString* k);
bool shown(RXNode* n);
CGFloat pad_x(RXNode* n);
CGFloat pad_y(RXNode* n);
CALayer* content_layer(RXNode* n);
bool is_native(RXNode* n);

RXDockView* drawer_body(RXNode* n);
NSArray<RXNode*>* all_drawers(void);
void drawer_register(RXNode* n);
void place_drawers(NSView* chrome);
void layout_drawers(RXDoc* doc);
bool drawers_open(RXDoc* doc);
void drawer_slide(RXNode* n);
void drawer_set_open(RXNode* n, bool open);
void drawer_open_again(RXNode* n);
bool drawer_open_of(RXDoc* doc, bool pointer_too);
void text_selectable_changed(RXNode* n);
NSEvent* drawer_pointer(NSEvent* e);
void corner_pointer(NSEvent* e);
NSView* pane_style_host(void);
void pane_styles_changed(bool relayout);
void pane_styles_layout(void);
void pane_styles_focus(void);
void pane_styles_new_doc(void);
void pane_data_set(NSString* bid, NSString* key, id value);
CF_RETURNS_RETAINED CGPathRef box_path(NSString* spec, CGSize size);
bool shape_intact(CALayer* l);
CALayer* make_path(RXNode* n);
void path_apply(RXNode* n);
CALayer* make_video(RXNode* n);
void video_apply(RXNode* n, NSString* name);
void video_placed(RXNode* n);
void video_wants_status(RXNode* n);
void video_seek(RXNode* n, double seconds);
void video_stop(RXNode* n);
void shape_layer(CALayer* l, NSString* spec, double ms, CGColorRef stroke, CGFloat width, bool* took_border,
                 const double* curve = nullptr);
void apply_shape(RXNode* n);
extern NSPoint g_context_at;
bool context_right_click(NSEvent* e);
bool context_terminal(NSString* what);
bool slot_reachable(RXSlot* slot);
void drawer_click(NSEvent* e);

NSArray<RXNode*>* in_order(RXNode* n, NSArray<RXNode*>* kids);
bool reorder_hold(RXNode* n, NSRect* frame);
RXNode* reorder_item(RXDockView* host, NSPoint p);
bool reorder_press(RXDockView* host, RXNode* item, NSPoint p);
bool reorder_drag(RXDockView* host, NSPoint p);
bool reorder_release(void);
bool reorder_active(void);

void set_frame(RXNode* n, CALayer* l, NSRect f);
void set_alpha(RXNode* n, CALayer* l, CGFloat a);
void deco_retargeted(RXNode* n);
bool deco_lands(RXNode* n);
void apply_expanded(RXNode* n, bool animated);
void appear_when_shown(RXNode* n);
void move_key_changed(RXNode* n);
void moves_after_layout(RXDoc* doc);
void move_node_gone(RXNode* n);
void move_animate(RXNode* n, CALayer* l, CATransform3D from, double ms);
void move_count_add(void);
uint64_t move_count(void);
void appear_hold(RXNode* n);
void appear_play(RXNode* n);
const double* easing_curve(RXNode* n);
RXAnim* animate(id host, double ms, void (^step)(double), void (^done)(void));
void ca_glide(CALayer* l, NSString* keyPath, id from, double ms, const double* curve, void (^done)(void));
double curve_at(const double c[4], double x);
void fade_layer(CALayer* l, float to, double ms, void (^done)(void));

NSFont* font_for(RXNode* n);
void font_cache_clear(void);
CALayer* make_layer(RXNode* n);
bool lazy_layers_wanted(void);
bool lazy_layers(void);
void scrolls_pay_owed(RXDoc* doc);
void lazy_warm(RXNode* n);
void symbol_warm(RXNode* n);
bool lazy_layer_kind(RXNode* n);
CALayer* ensure_layer(RXNode* n);
void layer_wake(RXNode* n, CALayer* prev, CALayer* below);
void apply_color(RXNode* n);
void apply_radius(RXNode* n);
void fade_contents(RXNode* n);
CGFloat backing_scale(void);
NSImage* symbol(NSString* name, CGFloat size, NSFontWeight weight, NSColor* color);
void put_symbol(CALayer* l, NSImage* image, NSRect box);

NSSize text_size(RXTextLayer* t, CGFloat width);
NSColor* text_color_at(RXTextLayer* t, NSUInteger i, CGFloat width);
void text_effects(RXNode* n);
void text_scramble(RXNode* n);
CGFloat line_height(NSFont* f);

@protocol RXHost <NSObject>
@property(readonly) NSWindow* window;
@property(readonly, getter=isHiddenOrHasHiddenAncestor) BOOL hiddenOrHasHiddenAncestor;
@property(readonly) NSRect bounds;
@property(readonly) NSRect visibleRect;
@property(readonly) CALayer* layer;
- (NSPoint)convertPoint:(NSPoint)p fromView:(id)v;
- (NSPoint)convertPoint:(NSPoint)p toView:(id)v;
- (NSRect)convertRect:(NSRect)r toView:(id)v;
- (NSRect)convertRectFromLayer:(NSRect)r;
- (BOOL)isDescendantOf:(id)v;
@end
id<RXHost> host_of(RXNode* n);
RXDockView* dock_host_of(RXNode* n);
bool node_on_screen(RXNode* n);
bool node_attached(RXNode* n);
bool node_covered(RXNode* n);
bool node_clipped_away(RXNode* n);
NSRect node_window_rect(RXNode* n);
void outside_watch(RXNode* n, bool on);
void outside_click(NSEvent* e);
void place_natives(RXDoc* doc);
RXNode* node_at_window_point(RXDockView* host, NSPoint p);
void host_pointer(RXDockView* host, NSPoint in_window);
void ui_pointer_again(NSWindow* w, NSPoint win);
void field_edit(RXNode* n);
void field_done(RXNode* n);
void use_cursor(NSCursor* c);
void syntax_text(RXNode* n, RXTextLayer* t, NSString* s, NSColor* base);
void syntax_paint(RXRuns* r, NSMutableAttributedString* a, NSUInteger from, NSUInteger to);
uint64_t syntax_hash(RXRuns* r, NSUInteger from, NSUInteger to, size_t* cursor, uint64_t h);
NSUInteger syntax_painted(RXRuns* r);
const void* syntax_lang(RXNode* n);
NSArray<NSColor*>* syntax_token_colors(RXNode* n, NSColor* base);
bool term_gpu_diff(CALayer* root, int out[4], const char* dir);
void term_bytes(size_t out[6]);
int term_banded_diff(CALayer* root);
void term_hover_given_mods(NSEventModifierFlags m);
bool term_cell_point(RXNode* n, int col, int row, CGPoint* out);
void stat_files(NSArray<NSString*>* paths, void (^then)(NSDictionary<NSString*, id>*));
void syntax_check(void);
void syntax_check_now(void);
void syntax_field(RXNode* n);

void apply_icon(RXNode* n);
void apply_button(RXNode* n);

void apply_image_source(RXNode* n);
void image_resized(RXNode* n);
void apply_fit(RXNode* n);
void apply_image_shape(RXNode* n);
void apply_gif_rate(RXNode* n);

double shape_radius(NSString* shape, double r, double angle, double turn);
CF_RETURNS_RETAINED CGPathRef shape_path(NSString* shape, CGPoint c, double r, double turn, CGAffineTransform* t);
CGAffineTransform layer_flip(CALayer* layer, CGFloat h);
double spin_angle(RXNode* n);
void spin_set(RXNode* n);
void node_link(RXNode* n, bool on);
void node_link_rate(RXNode* n);
void node_hosts_shown(id host);
CALayer* still(CALayer* layer);

bool is_canvas(RXNode* n);
CALayer* make_shapes(RXNode* n);
void shapes_apply(RXNode* n, NSString* name);
bool shapes_moving(RXNode* n);
void shapes_tick(RXNode* n, double dt);
void shapes_stop(RXNode* n);
double shapes_clock_fps(RXNode* n);
uint64_t shapes_frames(void);
void draw_visualiser(RXNode* n);
CALayer* make_shader(RXNode* n);
void shader_apply(RXNode* n, NSString* name);
void shader_resized(RXNode* n);
bool shader_moving(RXNode* n);
bool shader_settled(RXNode* n);
double shader_drawable_wait_ms(void);
uint64_t shader_drawable_bytes(CALayer* l);
double shader_fps(RXNode* n);
double shader_clock_fps(RXNode* n);
bool ui_gpu_clock(void);
CALayer* make_visualiser(RXNode* n);
CALayer* make_graph(RXNode* n);
void graph_apply(RXNode* n, NSString* name);
void graph_stop(RXNode* n);
double graph_clock_fps(RXNode* n);
bool graph_moving(RXNode* n);
uint64_t graph_frames(void);
CALayer* make_canvas(RXNode* n);
void canvas_el_apply(RXNode* n, NSString* name);
void canvas_el_stop(RXNode* n);
double canvas_el_clock_fps(RXNode* n);
bool canvas_el_moving(RXNode* n);
uint64_t canvas_el_frames(void);
CALayer* make_arc(RXNode* n);
void arc_stop(RXNode* n);
void arc_watch(RXNode* n);
double arc_clock_fps(RXNode* n);
uint64_t arc_frames(void);
void visualiser_stop(RXNode* n);
double visualiser_clock_fps(RXNode* n);
int shape_scallops(NSString* shape);
uint64_t visualiser_frames(void);
void shader_unlink(RXNode* n);
void shader_link_rate(RXNode* n);
void shaders_pointer(NSWindow* w, NSPoint win, bool out);
void shaders_config_changed(void);
uint64_t shader_frames_read(void);
void shader_image_frames(uint64_t out[3]);
CGSize shader_image_size(CALayer* layer);
uint64_t shader_last_copies(void);
CGSize shader_last_size(CALayer* layer);
uint64_t shader_passes_drawn(void);
NSUInteger shader_pass_count(CALayer* layer);
void shaders_unlink_all(void);
uint64_t shader_link_frames(void);
void shader_tick(RXNode* n, double dt);
void shaders_moved(CALayer* root);
void power_init(void);
void set_power(RXDoc* doc);
bool power_saving_now(void);
double power_shader_scale(void);
void shaders_power_changed(void);
void power_pretend(bool low, bool battery, int thermal);
void ui_clock_occluded(bool occluded);
bool ui_clock_paused(void);
int ui_clock_count(RXTickOrder order);
bool ui_clock_occluded_now(void);
void engine_clock_stopped(void);
void shaders_panes_changed(void);
NSString* panes_focused_block(void);
void shaders_shown(CALayer* root);
void shader_check(void);
bool take_frame(RXNode* n);
void draw_arc(RXNode* n);
bool arc_hit(RXNode* n, NSPoint p);
void arc_track(RXNode* n, NSPoint p, int phase);
void apply_canvas(RXNode* n, NSString* name);

NSString* doc_dir(RXNode* n);
void build_backends(NSString* dir);
void spawn(RXNode* n);
void stop(RXNode* n);
void process_park(RXDoc* doc);
void process_adopt(RXDoc* doc);
void send_line(RXNode* n, NSString* line);
@class RXPromise;
RXPromise* process_call(RXNode* n, NSString* json);

extern NSRect g_pane_rect;

CALayer* make_tabpreview(RXNode* n);
void tabpreview_update(RXNode* n);
void tabpreview_gone(RXNode* n);
void apply_tabpreview(RXNode* n, NSString* name);
NSSize measure_tabpreview(RXNode* n, CGFloat width);
void tabpreview_shown(RXNode* n);
void tabpreview_config_changed(void);

RXRoot* drawer_host(NSView* chrome);
CF_RETURNS_RETAINED CGPathRef drawer_path(NSRect s, CGFloat r, bool up, CGFloat H);
CF_RETURNS_RETAINED CGPathRef drawer_path_flared(NSRect s, CGFloat r, bool up, CGFloat H, NSString* flare);

void open_file_dialog(RXNode* n);

void apply_textarea(RXNode* n, NSString* name);

void apply(RXNode* n, P p, NSString* name, const rx::ui::PVal& v);
void apply_fresh_begin(RXNode* n);
void apply_fresh_end(RXNode* n);
void apply_replay(RXNode* n);
void apply(RXNode* n, NSString* name, id value);

NSSize measure(RXNode* n, CGFloat avail);
void invalidate(RXNode* n);
void unplace(RXNode* n);
void place(RXNode* n, NSRect frame);
void schedule_layout(RXDoc* doc, bool chrome);
extern uint64_t g_kids_epoch;
inline void kids_changed(void) {
    g_kids_epoch++;
}
void layouts_due(void);
bool layouts_waiting(void);
NSString* engine_rgba_text(NSString* colour);
void engine_record_counts(uint64_t n[3], uint64_t bytes[3]);
bool engine_scrolled(RXDoc* doc, int uid, bool across, double offset);
void engine_urgent(void);
bool engine_job_open(RXDoc* doc);
bool engine_draining(void);
void layout_now(RXDoc* doc);

bool is_float_bar(RXSlot* slot);
void place_float_bar(RXSlot* slot, NSView* chrome);
void float_bar_pointer(NSEvent* e);
bool is_float_bar_view(id v);
RXLayerHost* float_bar_under(NSWindow* w, NSPoint win);
NSArray<NSDictionary*>* float_bar_menu(id v, NSPoint win);
void float_bar_toggle(RXSlot* slot);
void float_bar_grow(RXSlot* slot, CGFloat grown, double seconds);
void float_bar_refresh(RXSlot* slot);

void save_slot(RXSlot* slot);
RXSlot* slot_named(NSString* key);
NSString* group_of(RXDoc* doc);
bool dock_key(NSString* file, bool show_only = false);
RXDoc* active_member(RXSlot* slot);
NSString* side_of(RXSlot* slot);
bool vertical(NSString* side);
CGFloat wanted_size(RXSlot* slot);
void slot_switch(RXSlot* slot, NSString* path);
void slot_show(RXSlot* slot, NSString* path);
void slot_hide(RXSlot* slot);
void save_bar_order(RXSlot* slot, NSArray<NSString*>* names);
NSWindow* dock_window(void);

void build_bar(RXSlot* slot);
void layout_bar(RXSlot* slot, id host, NSRect frame);
CGFloat bar_width(RXSlot* slot);
void bar_moved(RXAppBar* bar, NSPoint p);
void bar_down(RXAppBar* bar, NSPoint p);
void bar_dragged(RXAppBar* bar, NSPoint p);
void bar_up(RXAppBar* bar, NSPoint p);
NSArray<NSDictionary*>* bar_menu(RXAppBar* bar, NSPoint p);

NSString* tabs_dir(void);
bool is_web_doc(RXDoc* doc);
bool web_parked(RXNode* n);
void web_parked_place(RXNode* n, NSRect inner);
bool is_tab_doc(RXDoc* doc);
int bar_part(RXDoc* doc);
NSString* bar_search_engine(RXSlot* slot);
void bar_search(RXSlot* slot);
bool bar_search_key(NSEvent* e);
void bar_search_click(NSEvent* e);
void close_web_doc(RXSlot* slot, RXDoc* doc);
bool web_open_tab(RXDoc* from, NSURL* url, bool show);

RXNode* autofocus_field(RXNode* n);
void record_key(RXNode* n, bool on);
bool focus_in(id view);
void focus_terminal(NSWindow* w);
NSEvent* on_mouse(NSEvent* e);
bool bar_carry_event(NSEvent* e);
void set_keys(RXDoc* doc);

void fps_update(void);

void loading_start(void);
bool loading_staging(void);
bool loading_is_cover(NSString* path);
void loading_scanned(NSUInteger have, NSUInteger total, NSString* last, bool more);
void loading_scan(void);
void loading_place(NSView* chrome);
void loading_doc_loaded(id doc);
id loading_native(NSString* op);

void unload(RXDoc* doc);
void native_create(RXDoc* doc, int uid, NSString* type, int parent);
void native_set(RXDoc* doc, int uid, P p, NSString* name, const rx::ui::PVal& v);
void native_call(RXDoc* doc, int uid, NSString* method, NSString* arg);
NSString* native_source(RXDoc* doc, NSString* path);
void native_log(NSString* file, NSString* msg, NSString* level);
id native_api(RXDoc* doc, NSString* fn, NSArray* args);

@interface RXPromise : NSObject
@property(nonatomic, copy) void (^then)(id value, NSString* error);
- (void)resolve:(id)value;
- (void)reject:(NSString*)error;
@end
RXPromise* rx_promise(dispatch_queue_t q, id (^work)(NSString** error));
id doc_call(RXDoc* doc, NSString* method, NSArray* args);
bool engine_attach(RXDoc* doc);
void engine_detach(RXDoc* doc);
id engine_call(RXDoc* doc, NSString* method, NSArray* args);
void engine_load_async(RXDoc* doc, NSString* src, NSString* name, NSString* path, void (^done)(NSString* error));
void engine_pace(bool on);
const char* engine_file_name(RXDoc* doc);
void engine_pace_slice(double seconds);
NSString* engine_snapshot(RXDoc* doc);
unsigned engine_restore(RXDoc* doc, NSString* state);
NSString* engine_value(RXDoc* doc, int uid, NSString* name);
void engine_trial_async(NSString* path, NSString* src, void (^done)(NSString* error));
bool engine_take_io(void);
void engine_route(RXDoc* doc, int uid, uint32_t io_id);
#ifdef __cplusplus
#include <string_view>
void process_io_event(uint32_t id, int kind, int code, std::string_view text);
#include <vector>
std::vector<double> engine_bench_sets(RXDoc* doc, NSArray<NSArray*>* sets, int count);
#endif
void set_rex(RXDoc* doc);
void set_theme(RXDoc* doc);
void set_conf(RXDoc* doc);
void load(RXDoc* doc);
void scan(void);
void scan_then(void (^then)(void));

void debug_init(void);
NSString* debug_ui_dir(void);
bool debug_file_loads(NSString* name);
void set_debug(RXDoc* doc);
extern const void* g_debug_sel_doc;
extern int g_debug_sel_uid;
void debug_selected_changed(void);
void debug_changed(RXDoc* doc);
void debug_console_add(NSString* file, NSString* level, NSString* text);
void doc_wants_text(RXDoc* doc, NSString* text);
void budgets_check(void);
int budgets_said(void);
NSString* debug_session_id(void);
void debug_agents_changed(void);
void pane_spotlight(NSString* block);
void debug_pane_focused(NSString* block);
NSArray* agent_list(void);
bool agent_finding(void);
bool agent_running(void);
void agent_find(void (^done)(void));
void agent_send(NSString* session, NSString* block, NSString* text, bool submit, bool focus);
void agent_new(NSString* text, NSString* cwd, NSString* program);
void agent_run(NSString* text, NSString* cwd);
void agent_stop(void);
void agent_listen(void);
NSString* agent_latest_session(double* when);
bool agent_push(NSString* key, NSString* text);
id debug_native(NSString* op, id arg);
id debug_tree_rows(NSString* file);
id engine_tree_rows(RXDoc* target, const rx::engine::core::TreeRow* rows, size_t count);
bool debug_picking(void);
void debug_pick_hover(RXNode* n);
void debug_pick_click(RXNode* n);
void debug_pick_host(RXDockView* host, NSPoint p);
void debug_flags_changed(NSEvent* e);
bool debug_key(NSEvent* e);
bool debug_pointer_in_devtools(NSEvent* e);
bool debug_pointer_near_devtools(NSEvent* e);
bool key_matches(NSString* spec, NSEvent* e);
uint8_t key_mods(NSEvent* e);
std::expected<rx::keys::Chord, rx::keys::Error> key_parse(NSString* spec);
bool chord_matches(const rx::keys::Chord& c, NSEvent* e);
void keys_dirty(void);
void check_backends(void);
void watch_config(void);

void rexstate_layout(void);
NSString* rexstate_zoomed(void);
void rexstate_tab_changed(NSString* session, int tab);
id rexstate_native(NSString* op, NSDictionary* args);
void rexstate_init(void);
void rexstate_docs_changed(void);
extern bool g_watching;
void scan_notify_init(void);
NSString* distro_backends_bin(NSString* dir);
void shader_gpu_timing(double seconds);
void shader_gpu_totals(RXDoc* doc, double* ns, double* passes);

void tips_pointer(RXDockView* host, RXNode* under);
void tips_hide(void);
void tips_at(id subject, NSString* tip, NSWindow* w, NSRect in_window);
NSDictionary<NSString*, NSView*>* pane_views_now(void);
CALayer* make_pane_preview(RXNode* n);
void pane_preview_update(RXNode* n);
CGFloat pane_preview_aspect(RXNode* n);
void melt(CALayer* host, CALayer* src, CGRect frame, bool out, double ms, void (^done)(void));
RXNode* slot_lead(RXSlot* slot);
void panes_doc_loaded(RXDoc* doc);

id diagnostics_native(RXDoc* doc, NSString* op, NSDictionary* args);
id files_native(RXDoc* doc, NSString* op, NSDictionary* args);
void ui_open_pane(NSString* widget, NSDictionary* opts, void (^failed)(void) = nil);
pid_t ui_pane_here(NSString* path, NSString* block, NSString* session, void (^ended)(void));
