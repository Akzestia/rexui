// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "ui/ui.h"

Theme g_theme;

NSString* hex(NSColor* c) {
    NSColor* s = [c colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    return [NSString stringWithFormat:@"#%02x%02x%02x", int(round(s.redComponent * 255)),
                                      int(round(s.greenComponent * 255)), int(round(s.blueComponent * 255))];
}

void update_theme(void) {
    double rgb[3];
    if (!chrome_theme(rgb))
        return;
    double lum = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2];
    g_theme.dark = lum < 0.5;
    g_theme.bg = [NSColor colorWithSRGBRed:rgb[0] green:rgb[1] blue:rgb[2] alpha:1];
    g_theme.fg = g_theme.dark ? [NSColor colorWithSRGBRed:0.93 green:0.93 blue:0.95 alpha:1]
                              : [NSColor colorWithSRGBRed:0.1 green:0.1 blue:0.12 alpha:1];
}

static NSColor* parse_color_text(NSString* value, bool* themed);

NSColor* parse_color(id value) {
    if (![value isKindOfClass:NSString.class])
        return nil;
    struct Seen {
        id key;
        NSColor* color;
    };
    static Seen seen[64];
    Seen& one = seen[(reinterpret_cast<uintptr_t>((__bridge void*)value) >> 4) & 63];
    if (one.key == value)
        return one.color;
    static NSMutableDictionary<NSString*, id>* kept;
    if (id c = kept[value]) {
        NSColor* col = c == NSNull.null ? nil : c;
        one.key = [value copy], one.color = col;
        return col;
    }
    bool themed = false;
    NSColor* c = parse_color_text(value, &themed);
    if (themed)
        return c;
    one.key = [value copy], one.color = c;
    if (!kept)
        kept = [NSMutableDictionary dictionaryWithCapacity:256];
    if (kept.count >= 1024)
        [kept removeAllObjects];
    kept[[value copy]] = c ?: NSNull.null;
    return c;
}

static NSColor* parse_color_text(NSString* value, bool* themed) {
    NSString* s = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].lowercaseString;
    if (s.length == 0)
        return nil;
    if ([s hasPrefix:@"#"]) {
        unsigned v = 0;
        NSString* digits = [s substringFromIndex:1];
        if (![[NSScanner scannerWithString:digits] scanHexInt:&v])
            return nil;
        double a = 1, r, g, b;
        if (digits.length == 3) {
            r = ((v >> 8) & 15) / 15.0, g = ((v >> 4) & 15) / 15.0, b = (v & 15) / 15.0;
        } else if (digits.length == 6) {
            r = ((v >> 16) & 255) / 255.0, g = ((v >> 8) & 255) / 255.0, b = (v & 255) / 255.0;
        } else if (digits.length == 8) {
            a = ((v >> 24) & 255) / 255.0;
            r = ((v >> 16) & 255) / 255.0, g = ((v >> 8) & 255) / 255.0, b = (v & 255) / 255.0;
        } else {
            return nil;
        }
        return [NSColor colorWithSRGBRed:r green:g blue:b alpha:a];
    }
    if ([s hasPrefix:@"rgba("] || [s hasPrefix:@"rgb("]) {
        NSRange open = [s rangeOfString:@"("];
        NSString* inner = [[s substringFromIndex:open.location + 1]
            stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@") "]];
        NSArray<NSString*>* parts = [inner componentsSeparatedByString:@","];
        if (parts.count < 3)
            return nil;
        double a = parts.count > 3 ? parts[3].doubleValue : 1;
        return [NSColor colorWithSRGBRed:parts[0].doubleValue / 255
                                   green:parts[1].doubleValue / 255
                                    blue:parts[2].doubleValue / 255
                                   alpha:a];
    }
    NSDictionary<NSString*, NSColor*>* names = @{
        @"transparent": NSColor.clearColor,
        @"white": NSColor.whiteColor,
        @"black": NSColor.blackColor,
        @"red": NSColor.systemRedColor,
        @"green": NSColor.systemGreenColor,
        @"blue": NSColor.systemBlueColor,
        @"orange": NSColor.systemOrangeColor,
        @"yellow": NSColor.systemYellowColor,
        @"pink": NSColor.systemPinkColor,
        @"purple": NSColor.systemPurpleColor,
        @"gray": NSColor.systemGrayColor,
        @"grey": NSColor.systemGrayColor,
        @"accent": NSColor.controlAccentColor,
    };
    if (NSColor* c = names[s])
        return c;
    if ([s isEqualToString:@"foreground"])
        return *themed = true, g_theme.fg;
    if ([s isEqualToString:@"background"])
        return *themed = true, g_theme.bg;
    return nil;
}

void refresh_theme(RXNode* n) {
    if (n.layer && (is_drawer(n) || !is_box(n)))
        apply_color(n);
    if (is_elem(n, E::Slider))
        [n.layer setNeedsLayout];
    if (is_box(n) && has_prop(n, P::border_width))
        apply(n, P::border_width, prop_ns(P::border_width), pv(n, P::border_width));
    for (RXNode* c in n.children)
        refresh_theme(c);
}
