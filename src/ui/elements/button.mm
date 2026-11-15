// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "ui/ui.h"

static NSFontWeight weight_of(RXNode* n) {
    return flag(n, P::font_bold, false) ? NSFontWeightBold : NSFontWeightRegular;
}

@implementation RXIconLayer {
    CALayer* _glyph;
}
- (instancetype)init {
    if (!(self = [super init]))
        return nil;
    _glyph = [RXLayer layer];
    [self addSublayer:_glyph];
    return self;
}
- (void)setImage:(NSImage*)image {
    _image = image;
    [self setNeedsLayout];
}
- (void)layoutSublayers {
    put_symbol(_glyph, _image, self.bounds);
}
@end

void apply_icon(RXNode* n) {
    NSString* name = str(n, P::name, @"");
    NSImage* image =
        symbol(name, num(n, P::font_size, 13), weight_of(n), parse_color(obj_of(n, P::color)) ?: g_theme.fg);
    if (name.length && !image)
        rexui_log([NSString stringWithFormat:@"no SF Symbol named %@", name]);
    NSSize was = n.image_size;
    n.image_size = image ? image.alignmentRect.size : NSZeroSize;
    ((RXIconLayer*)n.layer).image = image;
    if (!NSEqualSizes(was, n.image_size))
        invalidate(n);
}

static NSColor* button_ink(RXNode* n) {
    NSColor* c = parse_color(obj_of(n, P::color)) ?: g_theme.fg;
    return flag(n, P::enabled, true) ? c : [c colorWithAlphaComponent:c.alphaComponent * 0.4];
}

void symbol_warm(RXNode* n) {
    if (is_elem(n, E::Icon)) {
        (void)symbol(str(n, P::name, @""), num(n, P::font_size, 13), weight_of(n),
                     parse_color(obj_of(n, P::color)) ?: g_theme.fg);
    } else if (is_elem(n, E::Button)) {
        NSString* icon = str(n, P::icon, @"");
        if (icon.length)
            (void)symbol(icon, num(n, P::font_size, 13), weight_of(n), button_ink(n));
    }
}

void apply_button(RXNode* n) {
    RXButtonLayer* b = (RXButtonLayer*)n.layer;
    NSString* style = str(n, P::style, @"");
    bool bordered = [style isEqualToString:@"bordered"]
        || (style.length == 0 && str(n, P::icon, @"").length == 0 && str(n, P::text, @"").length > 0);
    if (bordered && !b.bezel) {
        b.bezel = [RXLayer layer];
        b.bezel.cornerRadius = 6;
        b.bezel.cornerCurve = kCACornerCurveContinuous;
        [b insertSublayer:b.bezel atIndex:0];
    } else if (!bordered && b.bezel) {
        [b.bezel removeFromSuperlayer];
        b.bezel = nil;
    }
    NSColor* ink = button_ink(n);
    b.title.text = str(n, P::text, @"");
    b.title.font = font_for(n);
    b.title.kern = num(n, P::font_letterSpacing, 0);
    b.title.color = ink;
    NSString* icon = str(n, P::icon, @"");
    NSImage* image = icon.length ? symbol(icon, num(n, P::font_size, 13), weight_of(n), ink) : nil;
    if (icon.length && !image)
        rexui_log([NSString stringWithFormat:@"no SF Symbol named %@", icon]);
    b.iconImage = image;
    b.iconSize = image ? image.alignmentRect.size : NSZeroSize;
    b.icon.hidden = !image;
    [b setNeedsLayout];
    [b refreshState];
    invalidate(n);
}
