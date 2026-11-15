// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "ui/ui.h"

#include <vector>

namespace {

struct Seen {
    NSString* key;
    CGRect frame;
    __weak CALayer* root;
    __weak RXNode* node;
    double at;
};

NSHashTable<RXNode*>* g_movers;
std::vector<Seen> g_departed, g_arrived;
constexpr double kPairWindow = 0.1;
constexpr double kDefaultMs = 350;

CALayer* root_of_layer(CALayer* l) {
    while (l.superlayer)
        l = l.superlayer;
    return l;
}

void prune(std::vector<Seen>& v, double now) {
    size_t kept = 0;
    for (Seen& s : v)
        if (now - s.at <= kPairWindow)
            v[kept++] = s;
    v.resize(kept);
}

bool glide_from(RXNode* n, CGRect from) {
    CALayer* l = n.layer;
    if (!l)
        return false;
    CGRect to = [l convertRect:l.bounds toLayer:root_of_layer(l)];
    if (to.size.width < 1 || to.size.height < 1 || from.size.width < 1 || from.size.height < 1
        || CGRectEqualToRect(from, to))
        return false;
    CGPoint a = l.anchorPoint;
    const double sx = from.size.width / to.size.width, sy = from.size.height / to.size.height;
    const double tx = (from.origin.x + a.x * from.size.width) - (to.origin.x + a.x * to.size.width);
    const double ty = (from.origin.y + a.y * from.size.height) - (to.origin.y + a.y * to.size.height);
    CATransform3D t = CATransform3DMakeTranslation(tx, ty, 0);
    t = CATransform3DScale(t, sx, sy, 1);
    double ms = num(n, P::animate, 0);
    if (ms <= 0)
        ms = kDefaultMs;
    move_animate(n, l, t, ms);
    return true;
}

void pair(const Seen& departed, const Seen& arrived) {
    RXNode* n = arrived.node;
    CALayer *r1 = departed.root, *r2 = arrived.root;
    if (!n || !r1 || r1 != r2)
        return;
    if (glide_from(n, departed.frame))
        move_count_add();
}

void match(std::vector<Seen>& from, std::vector<Seen>& others, const Seen& s, bool is_departure) {
    for (size_t i = others.size(); i-- > 0;) {
        if (![others[i].key isEqualToString:s.key])
            continue;
        if (is_departure)
            pair(s, others[i]);
        else
            pair(others[i], s);
        others.erase(others.begin() + static_cast<std::ptrdiff_t>(i));
        return;
    }
    from.push_back(s);
}

}

void move_key_changed(RXNode* n) {
    NSString* key = str(n, P::moveKey, @"");
    if (!key.length) {
        [g_movers removeObject:n];
        n.move_shown = false;
        return;
    }
    if (!g_movers)
        g_movers = [NSHashTable weakObjectsHashTable];
    [g_movers addObject:n];
}

void moves_after_layout(RXDoc* doc) {
    if (!g_movers.count)
        return;
    const double now = CACurrentMediaTime();
    prune(g_departed, now), prune(g_arrived, now);
    for (RXNode* n in g_movers) {
        if (n.doc != doc)
            continue;
        CALayer* l = n.layer;
        const bool shown = l && node_on_screen(n);
        const bool was = n.move_shown;
        CALayer* root = l ? root_of_layer(l) : nil;
        CGRect frame = shown ? [l convertRect:l.bounds toLayer:root] : CGRectZero;
        if (shown != was) {
            NSString* key = str(n, P::moveKey, @"");
            if (shown)
                match(g_arrived, g_departed, Seen{key, frame, root, n, now}, false);
            else
                match(g_departed, g_arrived, Seen{key, n.move_frame, n.move_root, nil, now}, true);
        }
        n.move_shown = shown;
        if (shown)
            n.move_frame = frame, n.move_root = root;
    }
}

void move_node_gone(RXNode* n) {
    if (!n.move_shown || !g_movers)
        return;
    [g_movers removeObject:n];
    n.move_shown = false;
    const double now = CACurrentMediaTime();
    prune(g_departed, now), prune(g_arrived, now);
    match(g_departed, g_arrived, Seen{str(n, P::moveKey, @""), n.move_frame, n.move_root, nil, now}, true);
}

static uint64_t g_moves;
void move_count_add(void) {
    g_moves++;
}
uint64_t move_count(void) {
    return g_moves;
}
