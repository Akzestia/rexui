// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "web/web.h"

#include <algorithm>

template <size_t N>
static constexpr std::array<bool, rx::ui::k_nprops + 1> prefixed(const char (&pre)[N]) {
    std::array<bool, rx::ui::k_nprops + 1> a{};
    for (int i = 0; i < rx::ui::k_nprops; i++)
        a[i] = rx::schema::k_props[i].name.starts_with(std::string_view(pre, N - 1));
    return a;
}
static constexpr auto k_appear = prefixed("appear");
static constexpr auto k_font = prefixed("font.");
static constexpr auto k_border = prefixed("border.");
static inline bool in(const std::array<bool, rx::ui::k_nprops + 1>& a, P p) {
    return a[static_cast<int>(p)];
}

static bool chrome_prop(P p) {
    switch (p) {
    case P::side:
    case P::width:
    case P::height:
    case P::visible:
    case P::group:
    case P::title:
    case P::icon:
    case P::iconColor:
    case P::bar:
    case P::barColor:
    case P::span:
    case P::margin:
    case P::reveal:
        return true;
    default:
        return false;
    }
}
static bool size_prop(P p) {
    return p == P::width || p == P::height || p == P::grow;
}

void apply_radius(RXNode* n) {
    CALayer* l = n.layer;
    if (!l || is_drawer(n) || is_native(n) || !has_prop(n, P::radius))
        return;
    CGFloat r = num(n, P::radius, 0);
    CGSize s = l.bounds.size;
    if (s.width > 0 && s.height > 0)
        r = MIN(r, MIN(s.width, s.height) / 2);
    if (l.cornerRadius != r)
        l.cornerRadius = r;
}

void apply(RXNode* n, NSString* name, id value) {
    P p;
    if (!prop_named(name, &p))
        p = P::count_;
    apply(n, p, name, rx::ui::pval_of(value));
}

void list_scrolled(RXNode* n, CGFloat offset) {
    const bool across = ((RXScrollLayer*)n.layer).horizontal;
    if (engine_scrolled(n.doc, n.uid, across, offset))
        return;
    doc_call(n.doc, @"update", @[@(n.uid), across ? @{@"contentX": @(offset)} : @{@"contentY": @(offset)}]);
    doc_call(n.doc, @"emit", @[@(n.uid), @"scrolled", @[@(across ? offset : 0), @(across ? 0 : offset)]]);
}

static RXNode* placed_vlist_above(RXNode* n) {
    for (__unsafe_unretained RXNode* x = n->up; x; x = x->up)
        if (is_vlist(x))
            return x->_p_valid && x->_m_valid ? x : nil;
    return nil;
}

static bool settle_up(RXNode* n) {
    if (n->in && n->in.layout_pending) {
        invalidate(n);
        return false;
    }
    if (is_elem(n, E::Text) && !has_num(n, P::width)) {
        RXTextLayer* t = (RXTextLayer*)n.layer;
        if (!t.wrap && ceil(text_size(t, CGFLOAT_MAX).width) + 1 > n.m_avail + 0.5) {
            invalidate(n);
            return false;
        }
    }
    for (__unsafe_unretained RXNode* x = n; x; x = x->up) {
        if (is_vlist(x)) {
            for (__unsafe_unretained RXNode* y = n; y && y != x; y = y->up)
                y->_m_valid = y->_p_valid = false;
            vlist_due(x);
            return true;
        }
        const bool stop = !x->_p_valid || !x->up || is_native(x) || is_drawer(x) || is_elem(x, E::Dock) || is_list(x)
            || is_grid(x) || is_pages(x);
        if (stop) {
            invalidate(x);
            for (__unsafe_unretained RXNode* y = n; y && y != x; y = y->up)
                y->_m_valid = y->_p_valid = false;
            return false;
        }
        NSSize was = x.m_size;
        x->_m_valid = false;
        x->_p_valid = false;
        if (NSEqualSizes(measure(x, x.m_avail), was)) {
            place(x, x.p_frame);
            RXDoc* doc = x.doc;
            if (doc.natives.count)
                place_natives(doc);
            if (drawers_open(doc))
                layout_drawers(doc);
            return true;
        }
    }
    return false;
}

namespace {
enum Fresh : uint8_t { f_font, f_button, f_icon, f_shape, f_color, f_expanded, f_count };
__unsafe_unretained RXNode* g_fresh;
uint32_t g_fresh_seq, g_fresh_at[f_count];
bool fresh_noted(RXNode* n, Fresh f) {
    if (n != g_fresh)
        return false;
    g_fresh_at[f] = ++g_fresh_seq;
    return true;
}
}

void apply_fresh_begin(RXNode* n) {
    g_fresh = n, g_fresh_seq = 0;
    for (uint32_t& a : g_fresh_at)
        a = 0;
}

void apply_fresh_end(RXNode* n) {
    g_fresh = nil;
    if (!g_fresh_seq || !n.layer)
        return;
    Fresh order[f_count];
    int k = 0;
    for (int f = 0; f < f_count; f++)
        if (g_fresh_at[f])
            order[k++] = Fresh(f);
    std::sort(order, order + k, [](Fresh a, Fresh b) { return g_fresh_at[a] < g_fresh_at[b]; });
    for (int i = 0; i < k; i++)
        switch (order[i]) {
        case f_font: {
            RXTextLayer* t = (RXTextLayer*)n.layer;
            t.font = font_for(n), t.kern = num(n, P::font_letterSpacing, 0);
            break;
        }
        case f_button:
            apply_button(n);
            break;
        case f_icon:
            apply_icon(n);
            break;
        case f_shape:
            apply_shape(n);
            if (n.fx)
                box_fx_clipped(n);
            break;
        case f_color:
            apply_color(n);
            if (is_elem(n, E::Button))
                [(RXButtonLayer*)n.layer refreshState];
            break;
        case f_expanded:
            apply_expanded(n, true);
            break;
        case f_count:
            break;
        }
}

static bool g_replay;
static bool apply_look(RXNode* n, P p, NSString* name, CALayer* l) {
    const E e = n->ps.elem();
    const bool canvas = e == E::Visualiser || e == E::Arc;
    if (g_replay && p == P::visible) {
        if (e != E::Dock && e != E::Drawer)
            l.hidden = !flag(n, P::visible, true);
        if (n.fx)
            box_fx_sync(n);
        return true;
    }
    if (in(k_appear, p))
        return true;
    if (p == P::transform_x || p == P::transform_y || p == P::transform_scale || p == P::transform_rotation) {
        apply_transform(n);
        return true;
    }
    if (p == P::z) {
        l.zPosition = num(n, P::z, 0);
        if (RXNode* up = n.parent)
            up.z_kids = true;
        kids_changed();
        return true;
    }
    if (p == P::gradient || p == P::gradientAngle || p == P::shadow_color || p == P::shadow_radius || p == P::shadow_x
        || p == P::shadow_y || p == P::backdropBlur) {
        box_fx_apply(n, p);
        return true;
    }
    if (p == P::disappear || p == P::disappearDuration)
        return true;
    if (p == P::clips) {
        if (e != E::List && e != E::Scroll)
            l.masksToBounds = flag(n, P::clips, false) || l.cornerRadius > 0;
        if (n.fx)
            box_fx_clipped(n);
        return true;
    }
    if (p == P::contentX || p == P::contentY) {
        if (!is_list(n))
            return true;
        RXScrollLayer* sv = (RXScrollLayer*)l;
        if ((p == P::contentX) == sv.horizontal)
            sv.offset = num(n, p, 0);
        return true;
    }
    if (p == P::visible) {
        kids_changed();
        if (e != E::Dock && e != E::Drawer) {
            bool was = !l.hidden;
            const bool show = flag(n, P::visible, true);
            if (!show && was && !n.leaving && has_prop(n, P::disappear)) {
                __weak RXNode* weak = n;
                n.leaving = disappear_play(n, ^{
                    RXNode* m = weak;
                    if (!m || !m.leaving)
                        return;
                    m.leaving = false;
                    if (!flag(m, P::visible, true))
                        m.layer.hidden = YES;
                    disappear_stop(m);
                });
            }
            if (show) {
                if (n.leaving) {
                    n.leaving = false;
                    disappear_stop(n);
                }
            }
            if (!n.leaving)
                l.hidden = !show;
            if (n.fx)
                box_fx_sync(n);
            if (!was && !l.hidden) {
                unplace(n);
                appear_hold(n);
                shaders_shown(l);
            }
        }
        if (n.doc.natives.count) {
            __weak RXDoc* doc = n.doc;
            dispatch_async(dispatch_get_main_queue(), ^{
                place_natives(doc);
            });
        }
    } else if (p == P::opacity) {
        const bool was_clear = l.opacity <= 0;
        if (e != E::Drawer)
            set_alpha(n, l, num(n, P::opacity, 1));
        if (was_clear && l.opacity > 0)
            shaders_shown(l);
    } else if (p == P::expanded || p == P::expandFrom) {
        if (!fresh_noted(n, f_expanded))
            apply_expanded(n, true);
    } else if (e == E::Drawer && p == P::open) {
        drawer_slide(n);
        return true;
    } else if (canvas && !size_prop(p)) {
        apply_canvas(n, name);
        return true;
    } else if (e == E::Shapes && !size_prop(p)) {
        shapes_apply(n, name);
        return true;
    } else if (e == E::Graph && !size_prop(p)) {
        graph_apply(n, name);
        return true;
    } else if (e == E::Canvas && !size_prop(p)) {
        canvas_el_apply(n, name);
        return true;
    } else if (e == E::Path && !size_prop(p) && p != P::visible && p != P::opacity) {
        path_apply(n);
        return true;
    } else if (e == E::PanePreview && (p == P::block || p == P::radius || p == P::fit)) {
        pane_preview_update(n);
    } else if (e == E::Video && p == P::blur) {
        layer_blur(n.layer, num(n, P::blur, 0));
        return true;
    } else if (e == E::Video
               && (p == P::source || p == P::loop || p == P::fit || p == P::playing || p == P::muted || p == P::rate)) {
        video_apply(n, name);
        return true;
    } else if (e == E::Shader && !size_prop(p) && p != P::radius && p != P::shape) {
        shader_apply(n, name);
        return true;
    } else if (p == P::color) {
        if (!fresh_noted(n, f_color)) {
            apply_color(n);
            if (e == E::Button)
                [(RXButtonLayer*)l refreshState];
        }
    } else if (p == P::radius && e != E::Drawer && !is_native(n)) {
        apply_radius(n);
        l.cornerCurve = kCACornerCurveContinuous;
        if ((is_box(n) && e != E::List && e != E::Scroll) || e == E::Shader)
            l.masksToBounds = l.cornerRadius > 0 || flag(n, P::clips, false);
        if (n.fx)
            box_fx_clipped(n);
    } else if (p == P::border_color || p == P::border_width) {
        CALayer* shown = (CALayer*)l.presentationLayer ?: l;
        CGColorRef was = shown.borderColor;
        CGFloat was_w = shown.borderWidth;
        CGColorRef to = parse_color(obj_of(n, P::border_color)).CGColor ?: g_theme.fg.CGColor;
        CGFloat to_w = num(n, P::border_width, 0);
        l.borderColor = to;
        l.borderWidth = to_w;
        double ms = num(n, P::colorAnimation, 0);
        if (ms > 0 && l.superlayer) {
            CAMediaTimingFunction* curve = [CAMediaTimingFunction functionWithControlPoints:0.2:0:0:1];
            if (was && !CGColorEqualToColor(was, to)) {
                CABasicAnimation* a = [CABasicAnimation animationWithKeyPath:@"borderColor"];
                a.fromValue = (__bridge id)was, a.toValue = (__bridge id)to, a.duration = ms / 1000,
                a.timingFunction = curve;
                [l addAnimation:a forKey:@"rexui.borderColor"];
            }
            if (was_w != to_w) {
                CABasicAnimation* a = [CABasicAnimation animationWithKeyPath:@"borderWidth"];
                a.fromValue = @(was_w), a.toValue = @(to_w), a.duration = ms / 1000, a.timingFunction = curve;
                [l addAnimation:a forKey:@"rexui.borderWidth"];
            }
        }
    } else if (e == E::Text) {
        RXTextLayer* t = (RXTextLayer*)l;
        if (p == P::font_underline)
            t.underline = flag(n, P::font_underline, false);
        else if (p == P::font_strikeout)
            t.strikeout = flag(n, P::font_strikeout, false);
        else if (p == P::lineHeight)
            t.lineHeight = num(n, P::lineHeight, 0);
        else if (p == P::spans) {
            id list = obj_of(n, P::spans);
            NSArray* sp = [list isKindOfClass:NSArray.class] ? list : nil;
            NSMutableString* all = [NSMutableString string];
            for (NSDictionary* one in sp)
                if ([one isKindOfClass:NSDictionary.class] && [one[@"text"] isKindOfClass:NSString.class])
                    [all appendString:one[@"text"]];
            t.spans = sp;
            t.text = sp ? all : str(n, P::text, @"");
        } else if ((p == P::text || p == P::syntax || p == P::syntaxColors) && has_prop(n, P::spans))
            return true;
        else if (p == P::text || p == P::syntax || p == P::syntaxColors) {
            NSString* s = str(n, P::text, @"");
            bool changed = t.text && ![s isEqualToString:t.text];
            bool decodes = changed && num(n, P::scramble, 0) > 0;
            if (changed && !decodes)
                fade_contents(n);
            t.text = s;
            syntax_text(n, t, s, parse_color(obj_of(n, P::color)) ?: g_theme.fg);
            if (decodes)
                text_scramble(n);
        } else if (p == P::glow || p == P::glowRadius || p == P::outline || p == P::outlineColor) {
            text_effects(n);
            return true;
        } else if (p == P::scramble || p == P::scrambleSet) {
            return true;
        } else if (in(k_font, p)) {
            if (!fresh_noted(n, f_font))
                t.font = font_for(n), t.kern = num(n, P::font_letterSpacing, 0);
        } else if (p == P::wrap || p == P::maxLines) {
            t.wrap = flag(n, P::wrap, false);
            t.maxLines = t.wrap ? NSInteger(num(n, P::maxLines, 0)) : 1;
        } else if (p == P::align) {
            NSString* a = str(n, P::align, @"left");
            t.align = [a isEqualToString:@"center"] ? NSTextAlignmentCenter
                : [a isEqualToString:@"right"]      ? NSTextAlignmentRight
                                                    : NSTextAlignmentLeft;
        }
    } else if (e == E::Image) {
        if (p == P::source)
            apply_image_source(n);
        else if (p == P::fit)
            apply_fit(n);
        else if (p == P::shape || p == P::spin) {
            if (p == P::spin)
                spin_set(n);
            apply_image_shape(n);
            node_link(n, true);
            return true;
        } else if (p == P::playing || p == P::speed) {
            apply_gif_rate(n);
            return true;
        } else if (p == P::blur) {
            layer_blur(n.layer, num(n, P::blur, 0));
            return true;
        }
    } else if (e == E::Button) {
        if (!fresh_noted(n, f_button))
            apply_button(n);
    } else if (e == E::Icon) {
        if (p != P::color && !fresh_noted(n, f_icon))
            apply_icon(n);
    } else if (e == E::TextArea) {
        apply_textarea(n, name);
    } else if (e == E::TextField) {
        if (p == P::text) {
            if (n.editor)
                apply_textarea(n, @"text");
            if (!fresh_noted(n, f_color))
                apply_color(n);
        } else if (in(k_font, p) || p == P::placeholder || p == P::syntax || p == P::syntaxColors) {
            if (!fresh_noted(n, f_color))
                apply_color(n);
        } else if (p == P::readOnly || p == P::secure || p == P::maxLength) {
            if (!fresh_noted(n, f_color))
                apply_color(n);
            if (n.editor)
                apply_textarea(n, @"enabled");
        } else if (p == P::enabled) {
            if (!flag(n, P::enabled, true))
                field_done(n);
            else if (n.editor)
                apply_textarea(n, @"enabled");
        }
    } else if (e == E::TabPreview) {
        apply_tabpreview(n, name);
    } else if (e == E::WebView) {
        WKWebView* w = (WKWebView*)n.view;
        if (p == P::url) {
            NSString* u = str(n, P::url, @"");
            if (u.length && !n.session)
                session_begin(n);
            if (n.saved_state) {
                n.restore = nil;
                if (u.length)
                    preload_favicon(n, n.waiting);
                return true;
            }
            if (n.restore.length && u.length) {
                u = n.restore;
                n.restore = nil;
                rexui_log([NSString stringWithFormat:@"%@: back to %@", n.doc.path.lastPathComponent, u]);
            }
            __weak RXNode* weak = n;
            dispatch_async(dispatch_get_main_queue(), ^{
                RXNode* n2 = weak;
                WKWebView* w2 = (WKWebView*)n2.view;
                if (n2 && u.length && ![w2.URL.absoluteString isEqualToString:u])
                    web_load(n2, u);
            });
        } else if (p == P::cookies) {
            if (!str(n, P::cookies, @"").length)
                return true;
            bool first = !n.cookie_timer;
            import_cookies(n, first);
            [n.cookie_timer invalidate];
            __weak RXNode* weak = n;
            n.cookie_timer = [NSTimer scheduledTimerWithTimeInterval:30 * 60
                                                             repeats:YES
                                                               block:^(NSTimer*) {
                                                                   if (RXNode* n2 = weak)
                                                                       import_cookies(n2, false);
                                                               }];
        } else if (p == P::storage) {
            id sites = obj_of(n, P::storage);
            if ([sites isKindOfClass:NSArray.class] && [sites count]) {
                n.preparing++;
                __weak RXNode* weak = n;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (RXNode* n2 = weak)
                        import_storage(n2);
                });
            }
        } else if (p == P::adblock) {
            static char k_adblock_seen;
            bool first = !objc_getAssociatedObject(n, &k_adblock_seen);
            objc_setAssociatedObject(n, &k_adblock_seen, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            apply_adblock(n, first);
        } else if (p == P::zoom) {
            w.pageZoom = num(n, P::zoom, 1);
        } else if (p == P::css) {
            apply_page_css(n, w);
        }
        return true;
    } else if (e == E::Slider) {
        RXSliderLayer* s = (RXSliderLayer*)l;
        if (p == P::enabled)
            s.enabled = flag(n, P::enabled, true);
        else if (p == P::step)
            s.step = num(n, P::step, 0);
        else if (p == P::color || p == P::trackColor || p == P::knobColor) {
            s.fillColor = (__bridge id)parse_color(obj_of(n, P::color)).CGColor;
            s.trackColor = (__bridge id)parse_color(obj_of(n, P::trackColor)).CGColor;
            s.knobColor = (__bridge id)parse_color(obj_of(n, P::knobColor)).CGColor;
            [s setNeedsLayout];
        } else if (!s.dragging) {
            s.minValue = num(n, P::from, 0);
            s.maxValue = num(n, P::to, 1);
            s.value = num(n, P::value, 0);
        } else if (p == P::from || p == P::to || p == P::value) {
            s.behind = true;
        }
    }
    if ((p == P::shape || in(k_border, p) || p == P::radius) && !fresh_noted(n, f_shape)) {
        apply_shape(n);
        if (n.fx)
            box_fx_clipped(n);
    }
    return false;
}

void apply_replay(RXNode* n) {
    CALayer* l = n.layer;
    if (!l)
        return;
    g_replay = true;
    apply_fresh_begin(n);
    const E e = n->ps.elem();
    if (e == E::Text || e == E::Button || e == E::TextField || e == E::Icon)
        (void)fresh_noted(n, f_color);
    for (int i = 0; i < rx::ui::k_nprops; i++) {
        const int s = n->ps.slot(P(i));
        if (s >= 0 && n->ps.kind(s) != rx::ui::PK::none)
            (void)apply_look(n, P(i), prop_ns(P(i)), l);
    }
    for (NSString* k in n.extras.allKeys) {
        if ([k hasPrefix:@"wants"] || [k isEqualToString:@"pressedOutside"])
            continue;
        P p;
        if (!prop_named(k, &p))
            p = P::count_;
        (void)apply_look(n, p, k, l);
    }
    apply_fresh_end(n);
    g_replay = false;
}

void apply(RXNode* n, P p, NSString* name, const rx::ui::PVal& v) {
    if (!n)
        return;
    prop_store(n, p, name, v);
    const E e = n->ps.elem();
    if (p == P::key || p == P::barKey || p == P::searchKey || p == P::groupKey)
        keys_dirty();
    if (p == P::count_ && [name isEqualToString:@"pressedOutside"])
        return outside_watch(n, flag(n, @"pressedOutside", false));
    if (p == P::count_ && [name isEqualToString:@"wantsLayout"]) {
        n.wants_layout = true;
        if (n.p_valid)
            doc_call(
                n.doc, @"update",
                @[@(n.uid),
                  @{@"layoutWidth": @(n.p_frame.size.width),
                    @"layoutHeight": @(n.p_frame.size.height)}]);
        return;
    }
    if (p == P::count_ && [name isEqualToString:@"wantsScroll"]) {
        n.wants_scroll = true;
        return;
    }
    if (p == P::count_ && [name isEqualToString:@"wantsStatus"]) {
        if (e == E::Video)
            video_wants_status(n);
        return;
    }
    if (p == P::count_ && [name hasPrefix:@"wants"])
        return;
    if ((p == P::tip || p == P::tipKeys) && n->in && str(n, p, @"").length)
        n->in.has_tips = true;
    if ((p == P::selectable || p == P::selectionGroup) && is_elem(n, E::Text))
        text_selectable_changed(n);
    if (p == P::moveKey)
        move_key_changed(n);
    const bool canvas = e == E::Visualiser || e == E::Arc;
    bool looks = (canvas && (p == P::values || p == P::frames))
        || (e == E::Shader && (p == P::params || p == P::colors)) || p == P::tip || p == P::tipKeys || in(k_appear, p)
        || (e == E::Text
            && (p == P::glow || p == P::glowRadius || p == P::outline || p == P::outlineColor || p == P::scramble
                || p == P::scrambleSet));
    const bool styles = n->in && is_elem(n->in.root, E::Panes);
    const bool paint = rx::schema::paint_only(e, p) && e != E::Drawer && !styles;
    const bool local = !looks && !paint && !styles && n->_p_valid && n->_m_valid && n->up && !is_native(n)
        && e != E::Drawer && e != E::Dock && p != P::visible;
    __unsafe_unretained RXNode* in_row =
        !looks && !paint && !styles && !is_native(n) && e != E::Drawer ? placed_vlist_above(n) : nil;
    if (in_row)
        for (__unsafe_unretained RXNode* y = n; y && y != in_row; y = y->up)
            y->_m_valid = y->_p_valid = false;
    else if (!local && !looks && !paint)
        invalidate(n);
    if (e == E::List && p == P::reveal)
        n.reveal_pending = true;
    if (e == E::Process) {
        if ((p == P::command || p == P::running) && !n.spawn_due) {
            n.spawn_due = true;
            __weak RXNode* weak = n;
            dispatch_async(dispatch_get_main_queue(), ^{
                RXNode* m = weak;
                if (!m)
                    return;
                m.spawn_due = false;
                if (m.kept) {
                    m.kept = false;
                    return;
                }
                if (m.doc)
                    spawn(m);
            });
        }
        return;
    }
    if (e == E::Timer)
        return;
    __unsafe_unretained CALayer* l = n.layer;
    if (!l) {
        if (n.dormant) {
            if (p == P::visible)
                kids_changed();
            if (in_row)
                return vlist_due(in_row);
            if (!looks && !paint)
                if (__unsafe_unretained RXDoc* d = n->in)
                    schedule_layout(d, false);
        }
        return;
    }
    if (apply_look(n, p, name, l))
        return;
    if (paint)
        return;
    const bool parents = p == P::grow || p == P::shrink || p == P::columnSpan;
    if (in_row)
        return vlist_due(in_row);
    if (local && settle_up(parents ? n->up : n))
        return;
    if (__unsafe_unretained RXDoc* d = n->in)
        schedule_layout(d, e == E::Dock && chrome_prop(p));
}
