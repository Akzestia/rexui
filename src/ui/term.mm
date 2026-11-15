// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "ui/ui.h"

#include <type_traits>
#include "base/trace.h"

#include "base/rexapi.h"
#include "core/term/contrast.h"
#include "core/term/link.h"
#include "core/term/vt.h"
#include "gpu/cells.h"
#include "gpu/gpu.h"
#include "rex/rex.h"

#include <Carbon/Carbon.h>
#include <ImageIO/ImageIO.h>
#include <compression.h>
#include <sys/socket.h>
#include <unistd.h>
#include <cerrno>
#include <memory>
#include <unordered_map>
#include <vector>

using TermCell = rx::term::Cell;
using rx::term::Terminal;

namespace {

struct Face {
    CTFontRef font = nullptr;
    bool stroke = false;
    CGGlyph ascii[128] = {};
};

struct Fonts {
    Face face[4];
    CGFloat ascent = 0, descent = 0;
    std::unordered_map<char32_t, std::pair<CTFontRef, CGGlyph>> fallback;
};

void fill_ascii(Face& f) {
    UniChar u[128];
    for (int i = 0; i < 128; i++)
        u[i] = UniChar(i);
    CTFontGetGlyphsForCharacters(f.font, u, f.ascii, 128);
}

Fonts* fonts_at(NSString* name, CGFloat px) {
    static auto& cache = *new std::unordered_map<uint64_t, Fonts*>;
    uint64_t key = (uint64_t(name.hash) << 16) ^ uint64_t(px * 64);
    if (auto it = cache.find(key); it != cache.end())
        return it->second;
    auto* F = new Fonts;
    CTFontRef base = CTFontCreateWithName((__bridge CFStringRef)name, px, nullptr);
    F->ascent = CTFontGetAscent(base), F->descent = CTFontGetDescent(base);
    static const CGAffineTransform shear = {1, 0, 0.2, 1, 0, 0};
    for (int i = 0; i < 4; i++) {
        CTFontSymbolicTraits want = ((i & 1) ? kCTFontBoldTrait : 0) | ((i & 2) ? kCTFontItalicTrait : 0);
        CTFontRef f =
            want ? CTFontCreateCopyWithSymbolicTraits(base, px, nullptr, want, want) : (CTFontRef)CFRetain(base);
        if (!f && i == 3)
            f = CTFontCreateCopyWithSymbolicTraits(base, px, nullptr, kCTFontItalicTrait, kCTFontItalicTrait);
        if (!f && (i & 2)) {
            CGFontRef cg = CTFontCopyGraphicsFont(base, nullptr);
            f = CTFontCreateWithGraphicsFont(cg, px, &shear, nullptr);
            CGFontRelease(cg);
        }
        if (!f)
            f = (CTFontRef)CFRetain(base);
        F->face[i].font = f;
        F->face[i].stroke = (i & 1) && !(CTFontGetSymbolicTraits(f) & kCTFontBoldTrait);
        fill_ascii(F->face[i]);
    }
    CFRelease(base);
    cache[key] = F;
    return F;
}

constexpr uint16_t kBox[128] = {
    0x0011, 0x0022, 0x1100, 0x2200, 0x0011, 0x0022, 0x1100, 0x2200, 0x0011, 0x0022, 0x1100, 0x2200, 0x0101,
    0x0102, 0x0201, 0x0202, 0x0110, 0x0120, 0x0210, 0x0220, 0x1001, 0x1002, 0x2001, 0x2002, 0x1010, 0x1020,
    0x2010, 0x2020, 0x1101, 0x1102, 0x2101, 0x1201, 0x2201, 0x2102, 0x1202, 0x2202, 0x1110, 0x1120, 0x2110,
    0x1210, 0x2210, 0x2120, 0x1220, 0x2220, 0x0111, 0x0121, 0x0112, 0x0122, 0x0211, 0x0221, 0x0212, 0x0222,
    0x1011, 0x1021, 0x1012, 0x1022, 0x2011, 0x2021, 0x2012, 0x2022, 0x1111, 0x1121, 0x1112, 0x1122, 0x2111,
    0x1211, 0x2211, 0x2121, 0x2112, 0x1221, 0x1212, 0x2122, 0x1222, 0x2221, 0x2212, 0x2222, 0x0011, 0x0022,
    0x1100, 0x2200, 0x0033, 0x3300, 0x0103, 0x0301, 0x0303, 0x0130, 0x0310, 0x0330, 0x1003, 0x3001, 0x3003,
    0x1030, 0x3010, 0x3030, 0x1103, 0x3301, 0x3303, 0x1130, 0x3310, 0x3330, 0x0133, 0x0311, 0x0333, 0x1033,
    0x3011, 0x3033, 0x1133, 0x3311, 0x3333, 0x0101, 0x0110, 0x1010, 0x1001, 0,      0,      0,      0x0010,
    0x1000, 0x0001, 0x0100, 0x0020, 0x2000, 0x0002, 0x0200, 0x0012, 0x1200, 0x0021, 0x2100,
};
static_assert(kBox[0x4b] == 0x2222 && kBox[0x6c] == 0x3333 && kBox[0x6d] == 0x0101 && kBox[0x7f] == 0x2100);

using Rect = CGRect;

void draw_box(CGContextRef c, uint16_t b, CGFloat x, CGFloat y, CGFloat w, CGFloat h) {
    CGFloat light = MAX(1, round(w / 8)), heavy = light * 2;
    CGFloat cx = x + floor((w - light) / 2), cy = y + floor((h - light) / 2);
    auto vert = [&](int weight, CGFloat y0, CGFloat y1) {
        if (weight == 1)
            CGContextFillRect(c, Rect{{cx, y0}, {light, y1 - y0}});
        else if (weight == 2)
            CGContextFillRect(c, Rect{{cx - floor(light / 2), y0}, {heavy, y1 - y0}});
        else if (weight == 3) {
            CGContextFillRect(c, Rect{{cx - light, y0}, {light, y1 - y0}});
            CGContextFillRect(c, Rect{{cx + light, y0}, {light, y1 - y0}});
        }
    };
    auto horiz = [&](int weight, CGFloat x0, CGFloat x1) {
        if (weight == 1)
            CGContextFillRect(c, Rect{{x0, cy}, {x1 - x0, light}});
        else if (weight == 2)
            CGContextFillRect(c, Rect{{x0, cy - floor(light / 2)}, {x1 - x0, heavy}});
        else if (weight == 3) {
            CGContextFillRect(c, Rect{{x0, cy - light}, {x1 - x0, light}});
            CGContextFillRect(c, Rect{{x0, cy + light}, {x1 - x0, light}});
        }
    };
    int up = (b >> 12) & 15, down = (b >> 8) & 15, left = (b >> 4) & 15, right = b & 15;
    int any = MAX(MAX(up, down), MAX(left, right)),
        thick = any == 1 ? 0
        : any == 2       ? int(floor(light / 2)) + int(heavy) - int(light)
                         : int(light);
    vert(up, cy - (left || right ? thick : 0), y + h);
    vert(down, y, cy + light + (left || right ? thick : 0));
    horiz(left, x, cx + light + (up || down ? thick : 0));
    horiz(right, cx - (up || down ? thick : 0), x + w);
}

bool draw_block(CGContextRef c, char32_t cp, CGFloat x, CGFloat y, CGFloat w, CGFloat h) {
    auto part = [&](CGFloat fx, CGFloat fy, CGFloat fw, CGFloat fh) {
        CGContextFillRect(c,
                          Rect{{x + round(fx * w), y + round(fy * h)},
                               {round((fx + fw) * w) - round(fx * w), round((fy + fh) * h) - round(fy * h)}});
    };
    if (cp == 0x2580)
        return part(0, 0.5, 1, 0.5), true;
    if (cp >= 0x2581 && cp <= 0x2588)
        return part(0, 0, 1, (cp - 0x2580) / 8.0), true;
    if (cp >= 0x2589 && cp <= 0x258F)
        return part(0, 0, (0x2590 - cp) / 8.0, 1), true;
    if (cp == 0x2590)
        return part(0.5, 0, 0.5, 1), true;
    if (cp >= 0x2591 && cp <= 0x2593) {
        CGContextSetAlpha(c, (cp - 0x2590) / 4.0);
        part(0, 0, 1, 1);
        CGContextSetAlpha(c, 1);
        return true;
    }
    if (cp == 0x2594)
        return part(0, 0.875, 1, 0.125), true;
    if (cp == 0x2595)
        return part(0.875, 0, 0.125, 1), true;
    static const uint8_t quad[10] = {4, 8, 1, 13, 9, 7, 11, 2, 6, 14};
    if (cp >= 0x2596 && cp <= 0x259F) {
        uint8_t q = quad[cp - 0x2596];
        if (q & 1)
            part(0, 0.5, 0.5, 0.5);
        if (q & 2)
            part(0.5, 0.5, 0.5, 0.5);
        if (q & 4)
            part(0, 0, 0.5, 0.5);
        if (q & 8)
            part(0.5, 0, 0.5, 0.5);
        return true;
    }
    return false;
}

bool draw_powerline(CGContextRef c, char32_t cp, CGFloat x, CGFloat y, CGFloat w, CGFloat h) {
    if (cp != 0xE0B0 && cp != 0xE0B2)
        return false;
    CGContextBeginPath(c);
    if (cp == 0xE0B0) {
        CGContextMoveToPoint(c, x, y), CGContextAddLineToPoint(c, x + w, y + h / 2),
            CGContextAddLineToPoint(c, x, y + h);
    } else {
        CGContextMoveToPoint(c, x + w, y), CGContextAddLineToPoint(c, x, y + h / 2),
            CGContextAddLineToPoint(c, x + w, y + h);
    }
    CGContextClosePath(c);
    CGContextFillPath(c);
    return true;
}

void set_fill(CGContextRef c, uint32_t rgb, CGFloat a = 1) {
    CGContextSetRGBFillColor(c, ((rgb >> 16) & 0xFF) / 255.0, ((rgb >> 8) & 0xFF) / 255.0, (rgb & 0xFF) / 255.0, a);
}

double text_min_contrast() {
    NSUserDefaults* d = NSUserDefaults.standardUserDefaults;
    NSString* k = RXNS(RXN_178);
    return [d objectForKey:k] && ![d boolForKey:k] ? 1 : 4.5;
}

struct Sel {
    bool on = false;
    int line0 = 0, col0 = 0, line1 = 0, col1 = 0;
};

struct ImagePlaced {
    uint32_t image = 0, placement = 0;
    int64_t line = 0;
    int col = 0, cols = 1, rows = 1, z = 0;
    bool alternate = false;
    CGImageRef picture = nullptr;
    ImagePlaced() = default;
    ImagePlaced(const ImagePlaced& o)
        : image(o.image),
          placement(o.placement),
          line(o.line),
          col(o.col),
          cols(o.cols),
          rows(o.rows),
          z(o.z),
          alternate(o.alternate),
          picture(CGImageRetain(o.picture)) {}
    ImagePlaced& operator=(const ImagePlaced& o) {
        if (this != &o) {
            CGImageRelease(picture);
            image = o.image, placement = o.placement, line = o.line, col = o.col, cols = o.cols, rows = o.rows, z = o.z,
            alternate = o.alternate;
            picture = CGImageRetain(o.picture);
        }
        return *this;
    }
    ~ImagePlaced() { CGImageRelease(picture); }
};

void draw_images(CGContextRef c, const Terminal& t, const std::vector<ImagePlaced>& images, int cw, int ch, int H,
                 int back, bool under) {
    for (const ImagePlaced& p : images) {
        if ((p.z < 0) != under || p.alternate != t.alternate())
            continue;
        int64_t row = p.line - int64_t(t.scrolled()) + back;
        if (row + p.rows <= 0 || row >= t.rows())
            continue;
        CGContextDrawImage(
            c,
            Rect{{CGFloat(p.col * cw), CGFloat(H - (row + p.rows) * ch)}, {CGFloat(p.cols * cw), CGFloat(p.rows * ch)}},
            p.picture);
    }
}

CF_RETURNS_RETAINED CGImageRef term_picture(const Terminal& t, Fonts* F, int cw, int ch, bool focused,
                                            Terminal::CursorShape shape, int back, const Sel& sel,
                                            const std::vector<ImagePlaced>& images, int y_from = 0, int y_to = -1,
                                            int margin = 0) {
    if (y_to < 0)
        y_to = t.rows();
    int W = t.cols() * cw, H = t.rows() * ch, HB = (y_to - y_from) * ch + 2 * margin;
    static CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c =
        CGBitmapContextCreate(nullptr, size_t(W), size_t(HB), 8, 0, srgb,
                              uint32_t(kCGImageAlphaPremultipliedFirst) | uint32_t(kCGBitmapByteOrder32Little));
    if (!c)
        return nullptr;
    CGContextTranslateCTM(c, 0, -CGFloat(H - y_to * ch - margin));
    const double min_contrast = text_min_contrast();
    uint32_t dfg = t.default_fg() != Terminal::kUnset ? t.default_fg() : 0xd8d8d8,
             dbg = t.default_bg() != Terminal::kUnset ? t.default_bg() : 0x1c1c1e;
    auto resolve = [&](rx::term::Color col, uint32_t fallback) -> uint32_t {
        if (rx::term::is_rgb(col))
            return col & 0xFFFFFF;
        if (rx::term::is_palette(col))
            return t.palette_rgb(uint8_t(col & 0xFF));
        return fallback;
    };
    CGFloat base = floor((ch - (F->ascent + F->descent)) / 2 + F->descent);
    CGContextSetShouldSmoothFonts(c, false);
    CGContextSetLineWidth(c, 0.5);
    draw_images(c, t, images, cw, ch, H, back, true);
    for (int y = y_from; y < y_to; y++) {
        const int line = t.scrollback() - back + y;
        const TermCell* r = line < t.scrollback() ? t.scrollback_row(line) : t.row(line - t.scrollback());
        CGFloat bottom = H - (y + 1) * ch;
        for (int x = 0; x < t.cols();) {
            auto bg_of = [&](const TermCell& cell, bool* is_default) {
                bool inv = cell.attrs & rx::term::kInverse;
                rx::term::Color col = inv ? cell.fg : cell.bg;
                *is_default = !inv && col == rx::term::kDefault;
                return resolve(col, inv ? dfg : dbg);
            };
            bool def;
            uint32_t bg = bg_of(r[x], &def);
            int e = x + 1;
            for (; e < t.cols(); e++) {
                bool d2;
                if (bg_of(r[e], &d2) != bg || d2 != def)
                    break;
            }
            if (!def) {
                set_fill(c, bg);
                CGContextFillRect(c, Rect{{CGFloat(x * cw), bottom}, {CGFloat((e - x) * cw), CGFloat(ch)}});
            }
            x = e;
        }
        if (sel.on && line >= sel.line0 && line <= sel.line1) {
            int a = line == sel.line0 ? sel.col0 : 0, b = line == sel.line1 ? sel.col1 : t.cols() - 1;
            if (b >= a) {
                set_fill(c, dfg, 0.3);
                CGContextFillRect(c, Rect{{CGFloat(a * cw), bottom}, {CGFloat((b - a + 1) * cw), CGFloat(ch)}});
            }
        }
        for (int x = 0; x < t.cols();) {
            const TermCell& cell = r[x];
            int step = MAX(1, int(cell.width));
            if (cell.width == 0) {
                x++;
                continue;
            }
            bool inv = cell.attrs & rx::term::kInverse;
            const uint32_t under = inv ? resolve(cell.fg, dfg) : resolve(cell.bg, dbg);
            uint32_t fg = (cell.attrs & rx::term::kHidden)
                ? under
                : rx::term::text_colour(inv ? resolve(cell.bg, dbg) : resolve(cell.fg, dfg), under,
                                        cell.attrs & rx::term::kDim, cell.cp, min_contrast);
            int style = ((cell.attrs & rx::term::kBold) ? 1 : 0) | ((cell.attrs & rx::term::kItalic) ? 2 : 0);
            set_fill(c, fg);
            CGFloat px = x * cw;
            bool plain = cell.cp < 0x80 && !cell.comb[0] && cell.width == 1;
            int e = x + step;
            if (plain) {
                Face& f = F->face[style];
                CGGlyph glyphs[512];
                CGPoint at[512];
                size_t n = 0;
                for (e = x; e < t.cols() && n < 512; e++) {
                    const TermCell& d = r[e];
                    if (d.cp >= 0x80 || d.comb[0] || d.width != 1 || d.attrs != cell.attrs || d.fg != cell.fg
                        || d.bg != cell.bg)
                        break;
                    if (d.cp == U' ' || !f.ascii[d.cp])
                        continue;
                    glyphs[n] = f.ascii[d.cp];
                    at[n++] = CGPointMake(e * cw, bottom + base);
                }
                if (e == x)
                    e = x + 1;
                if (n) {
                    CGContextSetTextDrawingMode(c, f.stroke ? kCGTextFillStroke : kCGTextFill);
                    if (f.stroke)
                        CGContextSetRGBStrokeColor(c, ((fg >> 16) & 0xFF) / 255.0, ((fg >> 8) & 0xFF) / 255.0,
                                                   (fg & 0xFF) / 255.0, 1);
                    CTFontDrawGlyphs(f.font, glyphs, at, n, c);
                }
            } else if (cell.cp >= 0x2500 && cell.cp < 0x2580 && kBox[cell.cp - 0x2500]) {
                draw_box(c, kBox[cell.cp - 0x2500], px, bottom, cw, ch);
            } else if (cell.cp >= 0x2580 && cell.cp < 0x25A0 && draw_block(c, cell.cp, px, bottom, cw, ch)) {
            } else if (draw_powerline(c, cell.cp, px, bottom, cw * step, ch)) {
            } else {
                UniChar u[8];
                CFIndex len = 0;
                for (char32_t cp : {cell.cp, cell.comb[0], cell.comb[1]}) {
                    if (!cp)
                        continue;
                    if (cp >= 0x10000) {
                        u[len++] = UniChar(0xD800 + ((cp - 0x10000) >> 10)),
                        u[len++] = UniChar(0xDC00 + ((cp - 0x10000) & 0x3FF));
                    } else {
                        u[len++] = UniChar(cp);
                    }
                }
                Face& f = F->face[style];
                if (cell.comb[0]) {
                    CFStringRef s = CFStringCreateWithCharacters(nullptr, u, len);
                    NSDictionary* a = @{
                        (id)kCTFontAttributeName: (__bridge id)f.font,
                        (id)kCTForegroundColorFromContextAttributeName: @YES
                    };
                    CFAttributedStringRef as = CFAttributedStringCreate(nullptr, s, (__bridge CFDictionaryRef)a);
                    CTLineRef line2 = CTLineCreateWithAttributedString(as);
                    CGContextSaveGState(c);
                    CGContextSetTextPosition(c, px, bottom + base);
                    CTLineDraw(line2, c);
                    CGContextRestoreGState(c);
                    CGContextSetTextMatrix(c, CGAffineTransformIdentity);
                    CFRelease(line2), CFRelease(as), CFRelease(s);
                } else {
                    auto it = F->fallback.find(cell.cp);
                    if (it == F->fallback.end()) {
                        CFStringRef s = CFStringCreateWithCharacters(nullptr, u, len);
                        CTFontRef ff = CTFontCreateForString(F->face[0].font, s, CFRangeMake(0, len));
                        CGGlyph g[2] = {0, 0};
                        CTFontGetGlyphsForCharacters(ff, u, g, len);
                        CFRelease(s);
                        it = F->fallback.emplace(cell.cp, std::make_pair(ff, g[0])).first;
                    }
                    if (it->second.second) {
                        CGPoint at = CGPointMake(px, bottom + base);
                        CGContextSetTextDrawingMode(c, kCGTextFill);
                        CTFontDrawGlyphs(it->second.first, &it->second.second, &at, 1, c);
                    }
                }
            }
            if (cell.attrs & (rx::term::kUnderline | rx::term::kStrike | rx::term::kOverline)) {
                CGFloat w = (e - x) * cw, thick = MAX(1, round(ch / 16.0));
                if (cell.attrs & rx::term::kUnderline) {
                    CGContextFillRect(c, Rect{{px, bottom + base - 2 * thick}, {w, thick}});
                    if (cell.underline == 2)
                        CGContextFillRect(c, Rect{{px, bottom + base - 4 * thick}, {w, thick}});
                }
                if (cell.attrs & rx::term::kStrike)
                    CGContextFillRect(c, Rect{{px, bottom + floor(ch / 2)}, {w, thick}});
                if (cell.attrs & rx::term::kOverline)
                    CGContextFillRect(c, Rect{{px, bottom + ch - thick}, {w, thick}});
            }
            x = e;
        }
    }
    draw_images(c, t, images, cw, ch, H, back, false);
    if (!back && t.cursor_visible() && t.cursor_y() >= y_from && t.cursor_y() < y_to && t.cursor_x() < t.cols()) {
        uint32_t cc = t.cursor_rgb() != Terminal::kUnset ? t.cursor_rgb() : dfg;
        CGFloat bottom = H - (t.cursor_y() + 1) * ch, px = t.cursor_x() * cw;
        CGFloat thick = MAX(1, round(ch / 16.0));
        set_fill(c, cc);
        if (focused && shape == Terminal::CursorShape::bar) {
            CGContextFillRect(c, Rect{{px, bottom}, {thick, CGFloat(ch)}});
        } else if (focused && shape == Terminal::CursorShape::underline) {
            CGContextFillRect(c, Rect{{px, bottom + base - 2 * thick}, {CGFloat(cw), thick}});
        } else if (focused) {
            CGContextFillRect(c, Rect{{px, bottom}, {CGFloat(cw), CGFloat(ch)}});
            const TermCell& under = t.row(t.cursor_y())[t.cursor_x()];
            if (under.cp < 0x80 && under.cp != U' ' && F->face[0].ascii[under.cp]) {
                set_fill(c, dbg);
                CGPoint at = CGPointMake(px, bottom + base);
                CGContextSetTextDrawingMode(c, kCGTextFill);
                CTFontDrawGlyphs(F->face[0].font, &F->face[0].ascii[under.cp], &at, 1, c);
            }
        } else {
            CGContextSetRGBStrokeColor(c, ((cc >> 16) & 0xFF) / 255.0, ((cc >> 8) & 0xFF) / 255.0, (cc & 0xFF) / 255.0,
                                       1);
            CGContextSetLineWidth(c, 1);
            CGContextStrokeRect(c, Rect{{px + 0.5, bottom + 0.5}, {CGFloat(cw - 1), CGFloat(ch - 1)}});
        }
    }
    CGImageRef img = CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    return img;
}

struct GlyphKey {
    uint64_t a, b, c;
    bool operator==(const GlyphKey& o) const { return a == o.a && b == o.b && c == o.c; }
};
struct GlyphKeyHash {
    size_t operator()(const GlyphKey& k) const {
        return size_t(k.a * 0x9E3779B97F4A7C15ull ^ k.b * 0xC2B2AE3D27D4EB4Full ^ k.c);
    }
};
struct GlyphSlot {
    int x = 0, y = 0, w = 0, h = 0;
    int dx = 0, dy = 0;
    bool color = false;
};
enum class GlyphKind : uint32_t { text = 0, fallback = 1, composed = 2, box = 3, block = 4, powerline = 5 };

rx::gpu::Atlas g_atlas;
std::unordered_map<GlyphKey, GlyphSlot, GlyphKeyHash> g_glyphs;

template <typename Draw>
const GlyphSlot& glyph_slot(const GlyphKey& key, int cw, int ch, int step, Draw draw) {
    if (auto it = g_glyphs.find(key); it != g_glyphs.end())
        return it->second;
    GlyphSlot slot;
    const int W = cw * step + 2 * cw, H = 2 * ch, ox = cw, oy = ch / 2;
    static CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    std::vector<uint32_t> px(size_t(W) * size_t(H), 0);
    CGContextRef c =
        CGBitmapContextCreate(px.data(), size_t(W), size_t(H), 8, size_t(W) * 4, srgb,
                              uint32_t(kCGImageAlphaPremultipliedFirst) | uint32_t(kCGBitmapByteOrder32Little));
    if (c) {
        CGContextSetShouldSmoothFonts(c, false);
        CGContextSetLineWidth(c, 0.5);
        CGContextSetRGBFillColor(c, 1, 1, 1, 1);
        CGContextSetRGBStrokeColor(c, 1, 1, 1, 1);
        draw(c, CGFloat(ox), CGFloat(oy));
        CGContextRelease(c);
        int x0 = W, y0 = H, x1 = -1, y1 = -1;
        bool color = false;
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++) {
                const uint32_t p = px[size_t(y) * size_t(W) + size_t(x)];
                const uint32_t a = p >> 24;
                if (!a)
                    continue;
                if (x < x0)
                    x0 = x;
                if (x > x1)
                    x1 = x;
                if (y < y0)
                    y0 = y;
                if (y > y1)
                    y1 = y;
                const uint32_t r = (p >> 16) & 0xFF, g = (p >> 8) & 0xFF, b = p & 0xFF;
                if (r != a || g != a || b != a)
                    color = true;
            }
        if (x1 >= x0 && y1 >= y0) {
            const int w = x1 - x0 + 1, h = y1 - y0 + 1;
            int ax, ay;
            if (g_atlas.place(w, h, &ax, &ay)) {
                g_atlas.upload(ax, ay, w, h, px.data() + size_t(y0) * size_t(W) + size_t(x0), size_t(W) * 4);
                slot = {ax, ay, w, h, x0 - ox, y0 - (H - oy - ch), color};
            }
        }
    }
    return g_glyphs.emplace(key, slot).first->second;
}

simd_float4 rgba(uint32_t rgb, float a = 1) {
    return simd_make_float4(((rgb >> 16) & 0xFF) / 255.f, ((rgb >> 8) & 0xFF) / 255.f, (rgb & 0xFF) / 255.f, a);
}

void term_cells(const Terminal& t, Fonts* F, int cw, int ch, bool focused, Terminal::CursorShape shape, int back,
                const Sel& sel, std::vector<rx::gpu::Cell>& out, bool fill = false) {
    out.clear();
    const int H = t.rows() * ch;
    const double min_contrast = text_min_contrast();
    uint32_t dfg = t.default_fg() != Terminal::kUnset ? t.default_fg() : 0xd8d8d8,
             dbg = t.default_bg() != Terminal::kUnset ? t.default_bg() : 0x1c1c1e;
    auto resolve = [&](rx::term::Color col, uint32_t fallback) -> uint32_t {
        if (rx::term::is_rgb(col))
            return col & 0xFFFFFF;
        if (rx::term::is_palette(col))
            return t.palette_rgb(uint8_t(col & 0xFF));
        return fallback;
    };
    const CGFloat base = floor((ch - (F->ascent + F->descent)) / 2 + F->descent);
    const uint64_t fonts = uint64_t(uintptr_t(F));
    auto solid = [&](CGFloat x, CGFloat yup, CGFloat w, CGFloat h, simd_float4 color) {
        out.push_back(
            {simd_make_float4(float(x), float(H - yup - h), float(w), float(h)), simd_make_float4(0, 0, 0, 0), color});
    };
    if (fill)
        solid(0, 0, t.cols() * cw, H, rgba(dbg));
    auto put = [&](const GlyphSlot& g, int cell_x, int cell_top, simd_float4 color) {
        if (!g.w)
            return;
        out.push_back({simd_make_float4(float(cell_x + g.dx), float(cell_top + g.dy), float(g.w), float(g.h)),
                       simd_make_float4(float(g.x), float(g.y), g.color ? -float(g.w) : float(g.w), float(g.h)),
                       color});
    };
    auto key = [&](GlyphKind kind, char32_t cp, char32_t c1, char32_t c2, int style, int step) {
        return GlyphKey{fonts, uint64_t(cp) | (uint64_t(c1) << 32),
                        uint64_t(c2) | (uint64_t(style) << 24) | (uint64_t(uint32_t(kind)) << 28) | (uint64_t(cw) << 32)
                            | (uint64_t(ch) << 44) | (uint64_t(step) << 56)};
    };
    for (int y = 0; y < t.rows(); y++) {
        const int line = t.scrollback() - back + y;
        const TermCell* r = line < t.scrollback() ? t.scrollback_row(line) : t.row(line - t.scrollback());
        const CGFloat bottom = H - (y + 1) * ch;
        const int top = y * ch;
        for (int x = 0; x < t.cols();) {
            auto bg_of = [&](const TermCell& cell, bool* is_default) {
                bool inv = cell.attrs & rx::term::kInverse;
                rx::term::Color col = inv ? cell.fg : cell.bg;
                *is_default = !inv && col == rx::term::kDefault;
                return resolve(col, inv ? dfg : dbg);
            };
            bool def;
            uint32_t bg = bg_of(r[x], &def);
            int e = x + 1;
            for (; e < t.cols(); e++) {
                bool d2;
                if (bg_of(r[e], &d2) != bg || d2 != def)
                    break;
            }
            if (!def)
                solid(x * cw, bottom, (e - x) * cw, ch, rgba(bg));
            x = e;
        }
        if (sel.on && line >= sel.line0 && line <= sel.line1) {
            int a = line == sel.line0 ? sel.col0 : 0, b = line == sel.line1 ? sel.col1 : t.cols() - 1;
            if (b >= a)
                solid(a * cw, bottom, (b - a + 1) * cw, ch, rgba(dfg, 0.3f));
        }
        for (int x = 0; x < t.cols();) {
            const TermCell& cell = r[x];
            int step = MAX(1, int(cell.width));
            if (cell.width == 0) {
                x++;
                continue;
            }
            bool inv = cell.attrs & rx::term::kInverse;
            const uint32_t under = inv ? resolve(cell.fg, dfg) : resolve(cell.bg, dbg);
            const uint32_t fg = (cell.attrs & rx::term::kHidden)
                ? under
                : rx::term::text_colour(inv ? resolve(cell.bg, dbg) : resolve(cell.fg, dfg), under,
                                        cell.attrs & rx::term::kDim, cell.cp, min_contrast);
            const simd_float4 color = rgba(fg);
            int style = ((cell.attrs & rx::term::kBold) ? 1 : 0) | ((cell.attrs & rx::term::kItalic) ? 2 : 0);
            const int px = x * cw;
            bool plain = cell.cp < 0x80 && !cell.comb[0] && cell.width == 1;
            int e = x + step;
            if (plain) {
                Face& f = F->face[style];
                for (e = x; e < t.cols(); e++) {
                    const TermCell& d = r[e];
                    if (d.cp >= 0x80 || d.comb[0] || d.width != 1 || d.attrs != cell.attrs || d.fg != cell.fg
                        || d.bg != cell.bg)
                        break;
                    if (d.cp == U' ' || !f.ascii[d.cp])
                        continue;
                    const CGGlyph g = f.ascii[d.cp];
                    put(glyph_slot(key(GlyphKind::text, d.cp, 0, 0, style, 1), cw, ch, 1,
                                   [&](CGContextRef c, CGFloat gx, CGFloat gy) {
                                       CGContextSetTextDrawingMode(c, f.stroke ? kCGTextFillStroke : kCGTextFill);
                                       CGPoint at = CGPointMake(gx, gy + base);
                                       CTFontDrawGlyphs(f.font, &g, &at, 1, c);
                                   }),
                        e * cw, top, color);
                }
                if (e == x)
                    e = x + 1;
            } else if (cell.cp >= 0x2500 && cell.cp < 0x2580 && kBox[cell.cp - 0x2500]) {
                const uint16_t b = kBox[cell.cp - 0x2500];
                put(glyph_slot(key(GlyphKind::box, cell.cp, 0, 0, 0, 1), cw, ch, 1,
                               [&](CGContextRef c, CGFloat gx, CGFloat gy) { draw_box(c, b, gx, gy, cw, ch); }),
                    px, top, color);
            } else if (cell.cp >= 0x2580 && cell.cp < 0x25A0) {
                put(glyph_slot(key(GlyphKind::block, cell.cp, 0, 0, 0, 1), cw, ch, 1,
                               [&](CGContextRef c, CGFloat gx, CGFloat gy) { draw_block(c, cell.cp, gx, gy, cw, ch); }),
                    px, top, color);
            } else if (cell.cp == 0xE0B0 || cell.cp == 0xE0B2) {
                put(glyph_slot(key(GlyphKind::powerline, cell.cp, 0, 0, 0, step), cw, ch, step,
                               [&](CGContextRef c, CGFloat gx, CGFloat gy) {
                                   draw_powerline(c, cell.cp, gx, gy, cw * step, ch);
                               }),
                    px, top, color);
            } else {
                UniChar u[8];
                CFIndex len = 0;
                for (char32_t cp : {cell.cp, cell.comb[0], cell.comb[1]}) {
                    if (!cp)
                        continue;
                    if (cp >= 0x10000) {
                        u[len++] = UniChar(0xD800 + ((cp - 0x10000) >> 10)),
                        u[len++] = UniChar(0xDC00 + ((cp - 0x10000) & 0x3FF));
                    } else {
                        u[len++] = UniChar(cp);
                    }
                }
                Face& f = F->face[style];
                if (cell.comb[0]) {
                    put(glyph_slot(key(GlyphKind::composed, cell.cp, cell.comb[0], cell.comb[1], style, step), cw, ch,
                                   step,
                                   [&](CGContextRef c, CGFloat gx, CGFloat gy) {
                                       CFStringRef s = CFStringCreateWithCharacters(nullptr, u, len);
                                       NSDictionary* a = @{
                                           (id)kCTFontAttributeName: (__bridge id)f.font,
                                           (id)kCTForegroundColorFromContextAttributeName: @YES
                                       };
                                       CFAttributedStringRef as =
                                           CFAttributedStringCreate(nullptr, s, (__bridge CFDictionaryRef)a);
                                       CTLineRef line2 = CTLineCreateWithAttributedString(as);
                                       CGContextSetTextPosition(c, gx, gy + base);
                                       CTLineDraw(line2, c);
                                       CFRelease(line2), CFRelease(as), CFRelease(s);
                                   }),
                        px, top, color);
                } else {
                    auto it = F->fallback.find(cell.cp);
                    if (it == F->fallback.end()) {
                        CFStringRef s = CFStringCreateWithCharacters(nullptr, u, len);
                        CTFontRef ff = CTFontCreateForString(F->face[0].font, s, CFRangeMake(0, len));
                        CGGlyph g[2] = {0, 0};
                        CTFontGetGlyphsForCharacters(ff, u, g, len);
                        CFRelease(s);
                        it = F->fallback.emplace(cell.cp, std::make_pair(ff, g[0])).first;
                    }
                    if (it->second.second) {
                        CTFontRef ff = it->second.first;
                        const CGGlyph g = it->second.second;
                        put(glyph_slot(key(GlyphKind::fallback, cell.cp, 0, 0, 0, step), cw, ch, step,
                                       [&](CGContextRef c, CGFloat gx, CGFloat gy) {
                                           CGPoint at = CGPointMake(gx, gy + base);
                                           CGContextSetTextDrawingMode(c, kCGTextFill);
                                           CTFontDrawGlyphs(ff, &g, &at, 1, c);
                                       }),
                            px, top, color);
                    }
                }
            }
            if (cell.attrs & (rx::term::kUnderline | rx::term::kStrike | rx::term::kOverline)) {
                CGFloat w = (e - x) * cw, thick = MAX(1, round(ch / 16.0));
                if (cell.attrs & rx::term::kUnderline) {
                    solid(px, bottom + base - 2 * thick, w, thick, color);
                    if (cell.underline == 2)
                        solid(px, bottom + base - 4 * thick, w, thick, color);
                }
                if (cell.attrs & rx::term::kStrike)
                    solid(px, bottom + floor(ch / 2), w, thick, color);
                if (cell.attrs & rx::term::kOverline)
                    solid(px, bottom + ch - thick, w, thick, color);
            }
            x = e;
        }
    }
    if (!back && t.cursor_visible() && t.cursor_y() < t.rows() && t.cursor_x() < t.cols()) {
        uint32_t cc = t.cursor_rgb() != Terminal::kUnset ? t.cursor_rgb() : dfg;
        CGFloat bottom = H - (t.cursor_y() + 1) * ch, px = t.cursor_x() * cw;
        CGFloat thick = MAX(1, round(ch / 16.0));
        if (focused && shape == Terminal::CursorShape::bar) {
            solid(px, bottom, thick, ch, rgba(cc));
        } else if (focused && shape == Terminal::CursorShape::underline) {
            solid(px, bottom + base - 2 * thick, cw, thick, rgba(cc));
        } else if (focused) {
            solid(px, bottom, cw, ch, rgba(cc));
            const TermCell& under = t.row(t.cursor_y())[t.cursor_x()];
            if (under.cp < 0x80 && under.cp != U' ' && F->face[0].ascii[under.cp]) {
                Face& f = F->face[0];
                const CGGlyph g = f.ascii[under.cp];
                put(glyph_slot(key(GlyphKind::text, under.cp, 0, 0, 4, 1), cw, ch, 1,
                               [&](CGContextRef c, CGFloat gx, CGFloat gy) {
                                   CGContextSetTextDrawingMode(c, kCGTextFill);
                                   CGPoint at = CGPointMake(gx, gy + base);
                                   CTFontDrawGlyphs(f.font, &g, &at, 1, c);
                               }),
                    int(px), t.cursor_y() * ch, rgba(dbg));
            }
        } else {
            const simd_float4 c = rgba(cc);
            solid(px, bottom, cw, 1, c);
            solid(px, bottom + ch - 1, cw, 1, c);
            solid(px, bottom + 1, 1, ch - 2, c);
            solid(px + cw - 1, bottom + 1, 1, ch - 2, c);
        }
    }
}

std::shared_ptr<rx::gpu::CellSet> cell_set(const std::vector<rx::gpu::Cell>& cells, int width, int height) {
    auto s = std::make_shared<rx::gpu::CellSet>();
    s->atlas = g_atlas.texture();
    s->n = uint32_t(cells.size());
    s->width = width, s->height = height;
    if (!cells.empty())
        s->buffer = [rx::gpu::device() newBufferWithBytes:cells.data()
                                                   length:cells.size() * sizeof(rx::gpu::Cell)
                                                  options:MTLResourceStorageModeShared];
    return s;
}

}

static dispatch_queue_t term_queue(void) {
    static dispatch_queue_t q = dispatch_queue_create("rexui.term", DISPATCH_QUEUE_SERIAL);
    return q;
}

static NSDictionary* api_call(const char* method, NSDictionary* args) {
    NSData* json = [NSJSONSerialization dataWithJSONObject:args ?: @{} options:0 error:nil];
    auto r = rx::rexapi::call(method, std::string_view((const char*)json.bytes, json.length));
    if (!r.ok)
        return nil;
    id o = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:r.payload.data() length:r.payload.size()]
                                           options:0
                                             error:nil];
    return [o isKindOfClass:NSDictionary.class] ? o : nil;
}

static NSDictionary* block_method(NSString* session, NSString* block, NSString* method, NSDictionary* args) {
    NSMutableDictionary* p = [@{@"session_id": session, @"block_id": block, @"method": method} mutableCopy];
    if (args)
        p[@"args"] = args;
    return api_call("block.method", p);
}

namespace {
struct Links {
    static constexpr size_t kMax = 65535;
    std::vector<std::string> uris;
    std::unordered_map<std::string, uint16_t> named;
    static uint16_t add(void* ctx, std::string_view params, std::string_view uri) {
        auto* l = static_cast<Links*>(ctx);
        std::string_view id;
        for (size_t i = 0; i < params.size();) {
            size_t e = params.find(':', i);
            std::string_view kv = params.substr(i, e == std::string_view::npos ? std::string_view::npos : e - i);
            if (kv.starts_with("id="))
                id = kv.substr(3);
            if (e == std::string_view::npos)
                break;
            i = e + 1;
        }
        std::string key;
        if (!id.empty()) {
            key.assign(id).append(1, '\x1f').append(uri);
            if (auto it = l->named.find(key); it != l->named.end())
                return it->second;
        }
        if (l->uris.size() >= kMax)
            return 0;
        l->uris.emplace_back(uri);
        auto n = uint16_t(l->uris.size());
        if (!id.empty())
            l->named.emplace(std::move(key), n);
        return n;
    }
    std::string_view uri(uint16_t id) const {
        return id && id <= uris.size() ? std::string_view(uris[id - 1u]) : std::string_view();
    }
};

struct Grid {
    std::shared_ptr<Terminal> term;
    std::shared_ptr<Links> links;
    int cell_w = 0, cell_h = 0;
};
}

static constexpr int kInputLines = 5000;
static Grid snapshot_now(NSString* session, NSString* block, int lines = 0) {
    Grid g;
    NSDictionary* size = block_method(session, block, @"size", nil);
    int cols = int_of(size[@"columns"]), rows = int_of(size[@"rows"]);
    if (cols < 1 || rows < 1)
        return g;
    NSDictionary* vt = block_method(
        session, block, @"format", @{
            @"format": @"vt",
            @"extra_palette": @YES,
            @"extra_cursor": @YES,
            @"extra_modes": @YES,
            @"extra_tabstops": @YES,
            @"extra_charsets": @YES,
            @"extra_scrolling_region": @YES,
            @"extra_style": @YES
        });
    NSString* content = vt[@"content"];
    if (![content isKindOfClass:NSString.class])
        return g;
    auto t = Terminal::make(cols, rows, lines);
    if (!t)
        return g;
    g.term = std::make_shared<Terminal>(std::move(*t));
    g.links = std::make_shared<Links>();
    g.term->on_link(Links::add, g.links.get());
    NSData* bytes = [content dataUsingEncoding:NSUTF8StringEncoding];
    g.term->feed(std::span<const uint8_t>((const uint8_t*)bytes.bytes, bytes.length));
    g.cell_w = int_of(size[@"cell_width_px"]);
    g.cell_h = int_of(size[@"cell_height_px"]);
    return g;
}

static Fonts* fonts_for(int cell_h, CGFloat scale) {
    NSUserDefaults* d = NSUserDefaults.standardUserDefaults;
    NSString* name = [d stringForKey:RXNS(RXN_174)] ?: @"Menlo";
    double pt = [d doubleForKey:RXNS(RXN_175)] ?: 12;
    CGFloat px = pt * scale;
    Fonts* F = fonts_at(name, px);
    CGFloat natural = ceil(F->ascent + F->descent);
    if (cell_h > 0 && fabs(cell_h - natural) > natural * 0.2)
        return fonts_at(name, px * cell_h / natural);
    return F;
}

struct RowPicture {
    int y;
    CGImageRef image;
};

struct RowCache {
    std::vector<uint64_t> keys;
    uint64_t whole = 0;
};

struct TermPicture {
    CGImageRef image = nullptr;
    std::vector<RowPicture> rows_drawn;
    bool banded = false;
    int margin = 0;
    std::shared_ptr<rx::gpu::CellSet> cells;
    int cols = 0, rows = 0, cell_w = 0, cell_h = 0;
    int cursor_x = 0, cursor_y = 0, lines = 0, back = 0;
    Terminal::MouseTracking tracking = Terminal::MouseTracking::none;
    bool alternate = false;
};

static Terminal::CursorShape shape_of(const Terminal& t) {
    NSUserDefaults* d = NSUserDefaults.standardUserDefaults;
    if (t.cursor_shape() != Terminal::CursorShape::unset && ![d boolForKey:RXNS(RXN_177)])
        return t.cursor_shape();
    NSString* pref = [d stringForKey:RXNS(RXN_176)];
    return [pref isEqual:@"bar"]      ? Terminal::CursorShape::bar
        : [pref isEqual:@"underline"] ? Terminal::CursorShape::underline
                                      : Terminal::CursorShape::block;
}

static void natural_cell(Fonts* F, int* cw, int* ch) {
    CGSize adv;
    CGGlyph m = F->face[0].ascii['M'];
    CTFontGetAdvancesForGlyphs(F->face[0].font, kCTFontOrientationHorizontal, &m, &adv, 1);
    *cw = int(ceil(adv.width)), *ch = int(ceil(F->ascent + F->descent));
}

static_assert(std::has_unique_object_representations_v<TermCell>, "a TermCell's bytes are all its fields'");
static uint64_t fnv_bytes(uint64_t h, const void* p, size_t n) {
#ifdef __clang_analyzer__
    return h;
#endif
    const uint8_t* b = static_cast<const uint8_t*>(p);
    for (size_t i = 0; i < n; i++)
        h = (h ^ b[i]) * 1099511628211ull;
    return h;
}

static bool term_gpu(void) {
    static const bool on = [] {
        const char* e = getenv("REXUI_TERM_GPU");
        return !(e && e[0] == '0') && rx::gpu::device();
    }();
    return on;
}

static TermPicture picture_of(const Grid& g, CGFloat scale, bool focused, int back = 0, const Sel& sel = Sel{},
                              const std::vector<ImagePlaced>& images = {}, RowCache* cache = nullptr,
                              bool gpu_ok = true) {
    TermPicture p;
    if (!g.term)
        return p;
    Fonts* F = fonts_for(g.cell_h, scale);
    natural_cell(F, &p.cell_w, &p.cell_h);
    if (g.cell_w > 0)
        p.cell_w = g.cell_w;
    if (g.cell_h > 0)
        p.cell_h = g.cell_h;
    p.cols = g.term->cols(), p.rows = g.term->rows();
    back = MIN(back, g.term->scrollback());
    const Terminal& t = *g.term;
    const Terminal::CursorShape shape = shape_of(t);
    if (cache && images.empty()) {
        p.banded = true;
        p.margin = 2;
        uint64_t whole = 1469598103934665603ull;
        const uint64_t nums[] = {uint64_t(t.default_fg()), uint64_t(t.default_bg()), uint64_t(t.cursor_rgb()),
                                 uint64_t(focused),        uint64_t(shape),          uint64_t(p.cell_w),
                                 uint64_t(p.cell_h),       uint64_t(p.cols),         uint64_t(p.rows),
                                 uint64_t(p.margin),       uint64_t(uintptr_t(F)),   uint64_t(text_min_contrast())};
        whole = fnv_bytes(whole, nums, sizeof nums);
        for (int i = 0; i < 256; i++) {
            const uint32_t c = t.palette_rgb(uint8_t(i));
            whole = fnv_bytes(whole, &c, sizeof c);
        }
        if (whole != cache->whole || cache->keys.size() != size_t(p.rows))
            cache->keys.assign(size_t(p.rows), 0), cache->whole = whole;
        const bool cursor = !back && t.cursor_visible();
        const bool gpu = gpu_ok && term_gpu();
        bool changed = false;
        for (int y = 0; y < p.rows; y++) {
            const int line = t.scrollback() - back + y;
            const TermCell* r = line < t.scrollback() ? t.scrollback_row(line) : t.row(line - t.scrollback());
            uint64_t k = fnv_bytes(1469598103934665603ull, r, size_t(p.cols) * sizeof(TermCell));
            if (sel.on && line >= sel.line0 && line <= sel.line1) {
                const int sl[2] = {line == sel.line0 ? sel.col0 : 0, line == sel.line1 ? sel.col1 : p.cols - 1};
                k = fnv_bytes(k ^ 0x5e1, sl, sizeof sl);
            }
            if (cursor && t.cursor_y() == y) {
                const int cx = t.cursor_x() + 1;
                k = fnv_bytes(k ^ 0xc0, &cx, sizeof cx);
            }
            if (k == 0)
                k = 1;
            if (k == cache->keys[size_t(y)])
                continue;
            if (gpu) {
                cache->keys[size_t(y)] = k;
                changed = true;
                continue;
            }
            CGImageRef img =
                term_picture(t, F, p.cell_w, p.cell_h, focused, shape, back, sel, images, y, y + 1, p.margin);
            if (!img)
                continue;
            cache->keys[size_t(y)] = k;
            p.rows_drawn.push_back({y, img});
        }
        if (gpu && changed) {
            static auto& cells = *new std::vector<rx::gpu::Cell>;
            term_cells(t, F, p.cell_w, p.cell_h, focused, shape, back, sel, cells);
            p.cells = cell_set(cells, p.cols * p.cell_w, p.rows * p.cell_h);
        } else if (gpu) {
            p.banded = false;
        }
    } else {
        if (cache)
            cache->keys.clear();
        p.image = term_picture(t, F, p.cell_w, p.cell_h, focused, shape, back, sel, images);
    }
    p.cursor_x = g.term->cursor_x(), p.cursor_y = g.term->cursor_y(), p.lines = g.term->scrollback(), p.back = back;
    p.tracking = g.term->mouse_tracking(), p.alternate = g.term->alternate();
    return p;
}

@class RXTermPane, RXTermInput;
static void put_picture(RXTermPane* p, TermPicture pic, CGFloat scale);

namespace {

struct Stream {
    NSString *session, *block;
    __weak RXTermPane* pane;
    bool focused = false, hot = false, gone = false;
    bool input = false;
    int back = 0;
    Sel sel;
    int anchor_line = 0, anchor_col = 0, unit = 1;
    std::unordered_map<uint32_t, CGImageRef> images;
    std::vector<ImagePlaced> placed;
    std::string gfx_keys, gfx_data;
    uint64_t cleared_seen = 0;
    RowCache rows;
    const void* rows_pane = nullptr;
    size_t images_bytes = 0;
    CGFloat scale = 1;
    int fd = -1;
    dispatch_source_t source = nullptr;
    rx::rexapi::Frames frames;
    enum class State { hello, skipping, live } state = State::hello;
    uint64_t nonce = 0;
    std::string marker, skipped;
    Grid grid;
    std::string theme;
    std::string pending;
    bool dirty = false, draw_queued = false, heal_queued = false, wrote = false;
    bool resized = false;
    double drawn_at = 0, wrote_at = 0, healed_at = 0;
    int retries = 0;
};

std::unordered_map<std::string, Stream*> g_streams;
int g_control = -1;
dispatch_source_t g_control_source;
rx::rexapi::Frames g_control_frames;
NSMutableSet<NSString*>* g_attached;
uint64_t g_next_id = 1;

double now_s(void) {
    return CACurrentMediaTime();
}

void control_lost(void) {
    if (g_control_source)
        dispatch_source_cancel(g_control_source);
    g_control_source = nullptr;
    g_control = -1;
    g_control_frames = rx::rexapi::Frames();
    [g_attached removeAllObjects];
}

void control_message(uint8_t op, std::string_view data) {
    if (op == 0x9)
        rx::rexapi::send_message(g_control, 0xA, data);
}

bool control_up(void) {
    if (g_control >= 0)
        return true;
    std::string why;
    int fd = rx::rexapi::dial("/api/control", "rex.control.v1", "rexui-term", why);
    if (fd < 0) {
        rexui_log_file([NSString stringWithFormat:@"term: no control connection: %s", why.c_str()]);
        return false;
    }
    g_control = fd;
    if (!g_attached)
        g_attached = [NSMutableSet set];
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, uintptr_t(fd), 0, term_queue());
    g_control_source = src;
    dispatch_source_set_event_handler(src, ^{
        char buf[16384];
        ssize_t n = ::recv(fd, buf, sizeof buf, MSG_DONTWAIT);
        if (n < 0 && (errno == EAGAIN || errno == EINTR))
            return;
        if (n <= 0) {
            if (g_control == fd)
                control_lost();
            return;
        }
        g_control_frames.add(buf, size_t(n));
        uint8_t op;
        std::string_view d;
        while (g_control_frames.next(&op, &d))
            control_message(op, d);
    });
    dispatch_source_set_cancel_handler(src, ^{
        ::close(fd);
    });
    dispatch_resume(src);
    return true;
}

NSDictionary* control_call(const char* method, NSDictionary* args) {
    if (!control_up())
        return nil;
    uint64_t number = g_next_id++;
    NSString* ids = [NSString stringWithFormat:@"t%llu", number];
    NSData* json = [NSJSONSerialization dataWithJSONObject:@{
        @"type": @"request",
        @"id": ids,
        @"method": @(method),
        @"payload": args ?: @{}
    }
                                                   options:0
                                                     error:nil];
    if (!rx::rexapi::send_message(g_control, 0x1, std::string_view((const char*)json.bytes, json.length))) {
        control_lost();
        return nil;
    }
    for (;;) {
        uint8_t op;
        std::string_view d;
        while (g_control_frames.next(&op, &d)) {
            if (op == 0x8) {
                control_lost();
                return nil;
            }
            if (op != 0x1) {
                control_message(op, d);
                continue;
            }
            id o = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:d.data() length:d.size()]
                                                   options:0
                                                     error:nil];
            if (![o isKindOfClass:NSDictionary.class] || ![ids isEqual:o[@"id"]])
                continue;
            NSDictionary* payload = o[@"payload"];
            if (![o[@"type"] isEqual:@"response"]) {
                rexui_log_file(
                    [NSString stringWithFormat:@"term: %s: %@", method, [o[@"error"] description] ?: o[@"type"]]);
                return nil;
            }
            return [payload isKindOfClass:NSDictionary.class] ? payload : @{};
        }
        char buf[16384];
        ssize_t n = ::read(g_control, buf, sizeof buf);
        if (n <= 0) {
            control_lost();
            return nil;
        }
        g_control_frames.add(buf, size_t(n));
    }
}

void stream_start(Stream* s);

void schedule_draw(Stream* s);
bool word_cell(const TermCell& c);
const TermCell* line_at(const Terminal& t, int line);

void sel_to(Stream* s, int line, int col) {
    const Terminal& t = *s->grid.term;
    int l0 = s->anchor_line, c0 = s->anchor_col, l1 = line, c1 = col;
    if (l1 < l0 || (l1 == l0 && c1 < c0))
        std::swap(l0, l1), std::swap(c0, c1);
    if (s->unit == 3)
        c0 = 0, c1 = t.cols() - 1;
    if (s->unit == 2) {
        const TermCell *a = line_at(t, l0), *b = line_at(t, l1);
        while (c0 > 0 && word_cell(a[c0]) && word_cell(a[c0 - 1]))
            c0--;
        while (c1 < t.cols() - 1 && word_cell(b[c1]) && word_cell(b[c1 + 1]))
            c1++;
    }
    s->sel = Sel{true, l0, c0, l1, c1};
}
void schedule_heal(Stream* s);

void on_message(void* ctx, std::string_view json) {
    auto* s = static_cast<Stream*>(ctx);
    id o = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:json.data() length:json.size()]
                                           options:0
                                             error:nil];
    if (![o isKindOfClass:NSDictionary.class])
        return;
    NSString* type = o[@"type"];
    if ([type isEqual:@"resize"]) {
        int cols = int_of(o[@"cols"]), rows = int_of(o[@"rows"]);
        if (s->grid.term && cols > 0 && rows > 0 && (cols != s->grid.term->cols() || rows != s->grid.term->rows())) {
            (void)s->grid.term->resize(cols, rows);
            s->resized = true;
        }
        if (int_of(o[@"cell_width_px"]) > 0)
            s->grid.cell_w = int_of(o[@"cell_width_px"]);
        if (int_of(o[@"cell_height_px"]) > 0)
            s->grid.cell_h = int_of(o[@"cell_height_px"]);
    } else if ([type isEqual:@"theme"]) {
        NSMutableString* osc = [NSMutableString stringWithString:@"\x1b]104\x07"];
        auto color = [&](NSString* key, int code) {
            NSString* c = o[key];
            if (![c isKindOfClass:NSString.class])
                return;
            [osc appendFormat:@"\x1b]%d;%@%@\x07", code, [c hasPrefix:@"#"] ? @"" : @"#", c];
        };
        color(@"foreground", 10);
        color(@"background", 11);
        color(@"cursor", 12);
        for (NSString* e in [o[@"palette"] isKindOfClass:NSArray.class] ? o[@"palette"] : @[]) {
            NSArray* kv = [e isKindOfClass:NSString.class] ? [e componentsSeparatedByString:@"="] : nil;
            if (kv.count == 2)
                [osc appendFormat:@"\x1b]4;%@;%@%@\x07", kv[0], [kv[1] hasPrefix:@"#"] ? @"" : @"#", kv[1]];
        }
        s->theme = osc.UTF8String;
        s->pending = s->theme;
    }
}

int gfx_key(std::string_view keys, char k, int fallback) {
    for (size_t i = 0; i + 1 < keys.size();) {
        size_t end = keys.find(',', i);
        if (end == std::string_view::npos)
            end = keys.size();
        if (keys[i] == k && keys[i + 1] == '=' && end > i + 2) {
            std::string_view v = keys.substr(i + 2, end - i - 2);
            if (v[0] >= '0' && v[0] <= '9') {
                int n = 0;
                for (char c : v) {
                    if (c < '0' || c > '9' || n > 100000000)
                        break;
                    n = n * 10 + (c - '0');
                }
                return n;
            }
            if (v[0] == '-' && v.size() > 1) {
                int n = 0;
                for (char c : v.substr(1)) {
                    if (c < '0' || c > '9' || n > 100000000)
                        break;
                    n = n * 10 + (c - '0');
                }
                return -n;
            }
            return v[0];
        }
        i = end + 1;
    }
    return fallback;
}

CF_RETURNS_RETAINED CGImageRef gfx_decode(std::string_view keys, const std::string& b64) {
    NSString* text = [[NSString alloc] initWithBytes:b64.data() length:b64.size() encoding:NSASCIIStringEncoding];
    NSData* data = text
        ? [[NSData alloc] initWithBase64EncodedString:text options:NSDataBase64DecodingIgnoreUnknownCharacters]
        : nil;
    if (!data.length)
        return nullptr;
    int medium = gfx_key(keys, 't', 'd');
    if (medium == 'f' || medium == 't') {
        NSString* path = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        data = path ? [NSData dataWithContentsOfFile:path] : nil;
        if (!data.length)
            return nullptr;
    } else if (medium != 'd') {
        return nullptr;
    }
    int format = gfx_key(keys, 'f', 32), w = gfx_key(keys, 's', 0), h = gfx_key(keys, 'v', 0);
    if (gfx_key(keys, 'o', 0) == 'z') {
        if (data.length < 2)
            return nullptr;
        size_t cap = format == 100 ? data.length * 32 : size_t(w) * size_t(h) * (format == 24 ? 3 : 4);
        if (!cap || cap > (256u << 20))
            return nullptr;
        NSMutableData* out = [NSMutableData dataWithLength:cap];
        size_t n = compression_decode_buffer((uint8_t*)out.mutableBytes, cap, (const uint8_t*)data.bytes + 2,
                                             data.length - 2, nullptr, COMPRESSION_ZLIB);
        if (!n)
            return nullptr;
        out.length = n;
        data = out;
    }
    if (format == 100) {
        CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr);
        if (!src)
            return nullptr;
        CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, nullptr);
        CFRelease(src);
        return img;
    }
    size_t bytes = format == 24 ? 3 : 4;
    if (w <= 0 || h <= 0 || data.length < size_t(w) * size_t(h) * bytes)
        return nullptr;
    static CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGBitmapInfo info = format == 24 ? CGBitmapInfo(kCGImageAlphaNone) : CGBitmapInfo(kCGImageAlphaLast);
    CGImageRef img = CGImageCreate(size_t(w), size_t(h), 8, bytes * 8, size_t(w) * bytes, srgb, info, provider, nullptr,
                                   false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    return img;
}

void gfx_place(Stream* s, std::string_view keys, uint32_t id, CGImageRef img) {
    Terminal& t = *s->grid.term;
    int cw = s->grid.cell_w, ch = s->grid.cell_h;
    if (cw <= 0 || ch <= 0)
        natural_cell(fonts_for(0, s->scale), &cw, &ch);
    int x = gfx_key(keys, 'x', 0), y = gfx_key(keys, 'y', 0), sw = gfx_key(keys, 'w', 0), sh = gfx_key(keys, 'h', 0);
    CGImageRef part = (x || y || sw || sh)
        ? CGImageCreateWithImageInRect(
              img, CGRectMake(x, y, sw ?: CGImageGetWidth(img) - x, sh ?: CGImageGetHeight(img) - y))
        : CGImageRetain(img);
    if (!part)
        return;
    ImagePlaced p;
    p.image = id, p.placement = uint32_t(gfx_key(keys, 'p', 0));
    p.cols = gfx_key(keys, 'c', 0), p.rows = gfx_key(keys, 'r', 0);
    if (p.cols <= 0)
        p.cols = MAX(1, int(ceil(double(CGImageGetWidth(part)) / cw)));
    if (p.rows <= 0)
        p.rows = MAX(1, int(ceil(double(CGImageGetHeight(part)) / ch)));
    p.line = int64_t(t.scrolled()) + t.cursor_y();
    p.col = t.cursor_x();
    p.z = gfx_key(keys, 'z', 0);
    p.alternate = t.alternate();
    p.picture = part;
    if (p.placement)
        std::erase_if(s->placed, [&](const ImagePlaced& o) { return o.image == id && o.placement == p.placement; });
    s->placed.push_back(p);
    if (gfx_key(keys, 'C', 0) != 1)
        t.cursor_past_image(p.cols, p.rows);
}

void gfx_delete(Stream* s, std::string_view keys) {
    int what = gfx_key(keys, 'd', 'a');
    uint32_t id = uint32_t(gfx_key(keys, 'i', 0));
    if (what == 'i' || what == 'I') {
        std::erase_if(s->placed, [&](const ImagePlaced& o) { return o.image == id; });
        if (what == 'I') {
            if (auto it = s->images.find(id); it != s->images.end()) {
                s->images_bytes -=
                    MIN(s->images_bytes, CGImageGetHeight(it->second) * CGImageGetBytesPerRow(it->second));
                CGImageRelease(it->second);
                s->images.erase(it);
            }
        }
    } else {
        s->placed.clear();
    }
}

void on_graphics(void* ctx, std::string_view apc) {
    auto* s = static_cast<Stream*>(ctx);
    size_t semi = apc.find(';');
    std::string_view keys = apc.substr(0, semi),
                     payload = semi == std::string_view::npos ? std::string_view() : apc.substr(semi + 1);
    bool more = gfx_key(keys, 'm', 0) == 1;
    if (!s->gfx_keys.empty()) {
        s->gfx_data.append(payload);
        if (more)
            return;
    } else if (more) {
        s->gfx_keys = keys;
        s->gfx_data = payload;
        return;
    }
    std::string first = s->gfx_keys.empty() ? std::string(keys) : s->gfx_keys;
    std::string data = s->gfx_keys.empty() ? std::string(payload) : std::move(s->gfx_data);
    s->gfx_keys.clear();
    s->gfx_data.clear();
    int action = gfx_key(first, 'a', 't');
    if (action == 'q')
        return;
    if (action == 'd')
        return gfx_delete(s, first);
    uint32_t id = uint32_t(gfx_key(first, 'i', 0));
    CGImageRef img = nullptr;
    if (action == 'p') {
        if (auto it = s->images.find(id); it != s->images.end())
            img = it->second;
    } else {
        img = gfx_decode(first, data);
        if (!img)
            return;
        size_t bytes = CGImageGetHeight(img) * CGImageGetBytesPerRow(img);
        static constexpr size_t kMaxImages = 128u << 20;
        if (bytes > kMaxImages)
            return CGImageRelease(img);
        while (s->images_bytes + bytes > kMaxImages && !s->images.empty()) {
            auto it = s->images.begin();
            s->images_bytes -= MIN(s->images_bytes, CGImageGetHeight(it->second) * CGImageGetBytesPerRow(it->second));
            CGImageRelease(it->second);
            s->images.erase(it);
        }
        if (auto it = s->images.find(id); id && it != s->images.end()) {
            s->images_bytes -= MIN(s->images_bytes, CGImageGetHeight(it->second) * CGImageGetBytesPerRow(it->second));
            CGImageRelease(it->second);
            s->images.erase(it);
        }
        if (id) {
            s->images[id] = img;
            s->images_bytes += bytes;
        }
    }
    if (img && (action == 'T' || action == 'p'))
        gfx_place(s, first, id, img);
    if (!id && img && action != 'p')
        CGImageRelease(img);
}

void attach_terminal(Stream* s) {
    if (!s->grid.term)
        return;
    s->grid.term->on_rex_message(s->nonce, on_message, s);
    s->grid.term->on_graphics(on_graphics, s);
    s->cleared_seen = s->grid.term->cleared();
    if (!s->theme.empty())
        s->grid.term->feed(std::string_view(s->theme));
}

void draw_now(Stream* s) {
    s->draw_queued = false;
    if (s->gone || !s->grid.term || !s->dirty)
        return;
    RX_INTERVAL(frame, "term draw");
    s->dirty = false;
    s->drawn_at = now_s();
    RXTermPane* to = s->pane;
    if ((__bridge const void*)to != s->rows_pane)
        s->rows = RowCache{}, s->rows_pane = (__bridge const void*)to;
    TermPicture pic = picture_of(s->grid, s->scale, s->focused, s->back, s->sel, s->placed, &s->rows);
    if (!pic.image && !pic.banded)
        return;
    __weak RXTermPane* pane = s->pane;
    CGFloat scale = s->scale;
    dispatch_async(dispatch_get_main_queue(), ^{
        put_picture(pane, pic, scale);
    });
}

void schedule_draw(Stream* s) {
    s->dirty = true;
    if (s->draw_queued)
        return;
    s->draw_queued = true;
    double wait = MAX(0, s->drawn_at + (s->input ? 0.008 : s->hot ? 0.125 : 0.5) - now_s());
    if (wait <= 0)
        return draw_now(s);
    std::string key = s->block.UTF8String;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(wait * NSEC_PER_SEC)), term_queue(), ^{
        auto it = g_streams.find(key);
        if (it != g_streams.end() && it->second == s)
            draw_now(s);
    });
}

void heal_now(Stream* s) {
    s->heal_queued = false;
    if (s->gone)
        return;
    double now = now_s();
    bool quiet = now - s->wrote_at >= 1, spaced = now - s->healed_at >= 3;
    if (!s->wrote && !s->resized)
        return;
    if (!quiet || !spaced)
        return schedule_heal(s);
    s->wrote = s->resized = false;
    s->healed_at = now;
    Grid g = snapshot_now(s->session, s->block, s->input ? kInputLines : 0);
    if (!g.term)
        return;
    if (!g.cell_w)
        g.cell_w = s->grid.cell_w;
    if (!g.cell_h)
        g.cell_h = s->grid.cell_h;
    if (s->grid.term && g.term->cursor_shape() == Terminal::CursorShape::unset)
        g.term->set_cursor_shape(s->grid.term->cursor_shape());
    if (s->grid.term)
        g.term->set_scrolled(s->grid.term->scrolled());
    s->grid = g;
    attach_terminal(s);
    schedule_draw(s);
}

void schedule_heal(Stream* s) {
    if (s->heal_queued)
        return;
    s->heal_queued = true;
    std::string key = s->block.UTF8String;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), term_queue(), ^{
        auto it = g_streams.find(key);
        if (it != g_streams.end() && it->second == s)
            heal_now(s);
    });
}

void feed_live(Stream* s, std::string_view bytes) {
    if (!s->grid.term)
        return;
    s->grid.term->feed(bytes);
    if (s->grid.term->cleared() != s->cleared_seen) {
        s->cleared_seen = s->grid.term->cleared();
        bool alt = s->grid.term->alternate();
        std::erase_if(s->placed, [&](const ImagePlaced& o) { return o.alternate == alt; });
    }
    if (!s->grid.term->alternate())
        std::erase_if(s->placed, [](const ImagePlaced& o) { return o.alternate; });
    if (!s->pending.empty()) {
        std::string p;
        p.swap(s->pending);
        s->grid.term->feed(std::string_view(p));
    }
    s->wrote = true;
    s->wrote_at = now_s();
    schedule_draw(s);
    schedule_heal(s);
}

void stream_stop(Stream* s) {
    if (s->source)
        dispatch_source_cancel(s->source);
    s->source = nullptr;
    s->fd = -1;
    s->frames = rx::rexapi::Frames();
    s->state = Stream::State::hello;
    s->skipped.clear();
}

void stream_retry(Stream* s, bool closed_for_good) {
    stream_stop(s);
    if (s->gone || closed_for_good)
        return;
    int tries = ++s->retries;
    std::string key = s->block.UTF8String;
    double wait = MIN(30, 1 << MIN(tries, 5));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(wait * NSEC_PER_SEC)), term_queue(), ^{
        auto it = g_streams.find(key);
        if (it != g_streams.end() && it->second == s && !s->gone && s->fd < 0)
            stream_start(s);
    });
}

void stream_binary(Stream* s, std::string_view d) {
    switch (s->state) {
    case Stream::State::hello: {
        auto* p = reinterpret_cast<const uint8_t*>(d.data());
        if (d.size() < 2 || p[0] != 0x81 || d.size() != 32) {
            rexui_log_file(
                [NSString stringWithFormat:@"term: %@ refused (reason %d)", s->block, d.size() >= 2 ? p[1] : -1]);
            return stream_retry(s, false);
        }
        uint64_t n = 0;
        for (int i = 7; i >= 0; i--)
            n = n << 8 | p[24 + i];
        s->nonce = n;
        s->marker = "\x1b_rex1;" + std::to_string(n) + ";";
        s->state = Stream::State::skipping;
        s->retries = 0;
        return;
    }
    case Stream::State::skipping: {
        s->skipped.append(d);
        size_t at = s->skipped.find(s->marker);
        if (at == std::string::npos) {
            size_t keep = s->marker.size() - 1;
            if (s->skipped.size() > keep)
                s->skipped.erase(0, s->skipped.size() - keep);
            return;
        }
        s->state = Stream::State::live;
        s->grid = snapshot_now(s->session, s->block, s->input ? kInputLines : 0);
        s->healed_at = now_s();
        attach_terminal(s);
        std::string rest = s->skipped.substr(at);
        s->skipped.clear();
        feed_live(s, rest);
        s->wrote = false;
        return;
    }
    case Stream::State::live:
        return feed_live(s, d);
    }
}

bool control_attached(NSString* session) {
    if (![g_attached containsObject:session]) {
        if (!control_call("session.attach", @{@"session_id": session}))
            return false;
        [g_attached addObject:session];
    }
    return true;
}

void stream_start(Stream* s) {
    if (s->gone || s->fd >= 0)
        return;
    if (!control_attached(s->session))
        return stream_retry(s, false);
    NSDictionary* t = control_call("data.connect", @{
        @"session_id": s->session,
        @"block_id": s->block,
        @"data_ref_id": @"terminal",
        @"subprotocol": @"rex.data.terminal.v1"
    });
    NSString* ticket = t[@"ticket"];
    if (![ticket isKindOfClass:NSString.class])
        return stream_retry(s, false);
    NSMutableString* b64 = [[[ticket stringByReplacingOccurrencesOfString:@"-" withString:@"+"]
        stringByReplacingOccurrencesOfString:@"_"
                                  withString:@"/"] mutableCopy];
    while (b64.length % 4)
        [b64 appendString:@"="];
    NSData* raw = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
    if (raw.length != 16)
        return stream_retry(s, false);
    std::string why;
    int fd = rx::rexapi::dial("/api/data", "rex.data.terminal.v1", "", why);
    if (fd < 0) {
        rexui_log_file([NSString stringWithFormat:@"term: %@: %s", s->block, why.c_str()]);
        return stream_retry(s, false);
    }
    std::string hello = "\x01";
    hello.append((const char*)raw.bytes, raw.length);
    if (!rx::rexapi::send_message(fd, 0x2, hello)) {
        ::close(fd);
        return stream_retry(s, false);
    }
    s->fd = fd;
    s->state = Stream::State::hello;
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, uintptr_t(fd), 0, term_queue());
    s->source = src;
    dispatch_source_set_event_handler(src, ^{
        static char buf[65536];
        if (s->fd != fd)
            return;
        ssize_t n = ::recv(fd, buf, sizeof buf, MSG_DONTWAIT);
        if (n < 0 && (errno == EAGAIN || errno == EINTR))
            return;
        if (n <= 0)
            return stream_retry(s, false);
        s->frames.add(buf, size_t(n));
        uint8_t op;
        std::string_view d;
        while (s->fd == fd && s->frames.next(&op, &d)) {
            if (op == 0x2)
                stream_binary(s, d);
            else if (op == 0x9)
                rx::rexapi::send_message(fd, 0xA, d);
            else if (op == 0x8) {
                int code = d.size() >= 2 ? (uint8_t(d[0]) << 8 | uint8_t(d[1])) : 1000;
                return stream_retry(s, code == 4000 || code == 1000);
            }
        }
    });
    dispatch_source_set_cancel_handler(src, ^{
        ::close(fd);
    });
    dispatch_resume(src);
}

}

static void stream_want(NSString* session, NSString* block, RXTermPane* pane, bool focused, bool hot, bool input,
                        CGFloat scale) {
    __weak RXTermPane* weak = pane;
    dispatch_async(term_queue(), ^{
        std::string key = block.UTF8String;
        Stream* s;
        auto it = g_streams.find(key);
        if (it == g_streams.end()) {
            s = new Stream;
            s->session = session, s->block = block, s->pane = pane, s->focused = focused, s->hot = hot,
            s->input = input, s->scale = scale;
            g_streams[key] = s;
            stream_start(s);
            return;
        }
        s = it->second;
        s->pane = weak;
        bool redraw = s->focused != focused || s->scale != scale || (hot && !s->hot);
        s->focused = focused, s->hot = hot, s->scale = scale;
        if (s->input != input) {
            s->input = input, s->back = 0, s->sel = Sel{};
            if (s->grid.term) {
                Terminal::CursorShape shape = s->grid.term->cursor_shape();
                Grid g = snapshot_now(s->session, s->block, input ? kInputLines : 0);
                if (g.term) {
                    if (!g.cell_w)
                        g.cell_w = s->grid.cell_w;
                    if (!g.cell_h)
                        g.cell_h = s->grid.cell_h;
                    if (g.term->cursor_shape() == Terminal::CursorShape::unset)
                        g.term->set_cursor_shape(shape);
                    g.term->set_scrolled(s->grid.term->scrolled());
                    s->grid = g;
                    attach_terminal(s);
                    redraw = true;
                }
            }
        }
        if (s->fd < 0 && s->retries == 0)
            stream_start(s);
        if (redraw && s->grid.term)
            schedule_draw(s);
    });
}

static void stream_drop(NSString* block) {
    dispatch_async(term_queue(), ^{
        auto it = g_streams.find(block.UTF8String);
        if (it == g_streams.end())
            return;
        Stream* s = it->second;
        g_streams.erase(it);
        s->gone = true;
        if (s->fd >= 0)
            rx::rexapi::send_message(s->fd, 0x8, std::string_view("\x03\xe8", 2));
        stream_stop(s);
        s->grid = Grid();
        s->placed.clear();
        for (auto& kv : s->images)
            CGImageRelease(kv.second);
        s->images.clear();
    });
}

static constexpr CGFloat kPadX = 10, kPadY = 5;

@interface RXTermPane : RXLayer
@property(nonatomic, copy) NSString* block;
@property(nonatomic, copy) NSString* session;
@property(nonatomic, strong) CALayer* clip;
@property(nonatomic) CGFloat z;
@property(nonatomic, strong) CALayer* cells;
@property(nonatomic, strong) NSMutableArray<CALayer*>* rowLayers;
@property(nonatomic) bool drawn;
@property(nonatomic, strong) CALayer* up;
@property(nonatomic) bool focused;
@property(nonatomic) bool again;
@property(nonatomic) TermPicture shown;
@property(nonatomic) CGFloat scale;
@property(nonatomic, strong) CALayer* markedText;
@property(nonatomic) int askedCols, askedRows;
@property(nonatomic, weak) RXTermInput* hoverInput;
@end
@implementation RXTermPane {
   @public
    std::shared_ptr<rx::gpu::CellSet> _cellset;
    rx::gpu::Surface _surface;
    uint64_t _cellsGen, _drawnGen, _renderGen;
    double _warmUntil;
}
- (void)dealloc {
    rx::gpu::cells_surface_done(_surface);
}
@end
@interface RXTermInput (Links)
- (void)linkAgain;
- (void)hoverAt:(CGPoint)q;
- (void)hoverGone;
- (NSString*)hoverLink;
@end

@interface RXTermTab : RXLayer
@property(nonatomic, copy) NSString *tab, *session;
@property(nonatomic, strong) NSMutableDictionary<NSString*, RXTermPane*>* panes;
@property(nonatomic, strong) NSArray* layers;
@property(nonatomic, copy) NSString* zoomed;
@property(nonatomic) NSInteger watchers;
@property(nonatomic) CGSize own;
@property(nonatomic) RXTermInput* input;
@end
@interface RXTermTab () {
    __weak RXTermInput* _w_input;
}
@end
@implementation RXTermTab
- (RXTermInput*)input {
    return _w_input;
}
- (void)setInput:(RXTermInput*)v {
    _w_input = v;
}
@end

static NSMutableDictionary<NSString*, RXTermTab*>* g_tabs;
static __weak CALayer* g_parent;
static CGSize g_area;
static NSEdgeInsets g_insets;
static CGFloat g_gap = 8;
static CGFloat g_scale = 1;

static CGFloat term_scale(void) {
    CGFloat s = dock_window().backingScaleFactor;
    return s > 0 ? s : 1;
}

static void fetch_pane(RXTermPane* p);
static void term_input_gone(RXTermInput* i);

static void place_pane(RXTermPane* p, CGRect f) {
    if (!p)
        return;
    if (!CGRectEqualToRect(p.frame, f))
        p.frame = f;
    CGRect in = CGRectMake(0, 0, f.size.width, f.size.height);
    if (!CGRectEqualToRect(p.clip.frame, in))
        p.clip.frame = in;
    if (p.up && !CGRectEqualToRect(p.up.frame, in))
        p.up.frame = in;
}
static void place_node(RXTermTab* t, NSDictionary* n, CGRect f) {
    if (![n isKindOfClass:NSDictionary.class])
        return;
    if (NSString* b = n[@"block_id"])
        return place_pane(t.panes[b], f);
    NSDictionary* s = n[@"split"];
    if (![s isKindOfClass:NSDictionary.class])
        return;
    double r = num_of(s[@"ratio"]);
    if ([s[@"direction"] isEqual:@"horizontal"]) {
        CGFloat w = MAX(0, f.size.width - g_gap), a = w * r;
        place_node(t, s[@"before"], CGRectMake(f.origin.x, f.origin.y, a, f.size.height));
        place_node(t, s[@"after"], CGRectMake(f.origin.x + a + g_gap, f.origin.y, w - a, f.size.height));
    } else {
        CGFloat h = MAX(0, f.size.height - g_gap), a = h * r;
        place_node(t, s[@"before"], CGRectMake(f.origin.x, f.origin.y, f.size.width, a));
        place_node(t, s[@"after"], CGRectMake(f.origin.x, f.origin.y + a + g_gap, f.size.width, h - a));
    }
}

static NSString* g_shown_tab;
static bool tab_hot(RXTermTab* t) {
    return t.watchers > 0 || [t.tab isEqual:g_shown_tab];
}

static void ask_sizes(RXTermTab* t);

static NSString* g_full_block;

static void place_tab(RXTermTab* t) {
    CGRect area = t.own.width > 0
        ? CGRectMake(0, 0, t.own.width, t.own.height)
        : CGRectMake(g_insets.left, g_insets.top, g_area.width - g_insets.left - g_insets.right,
                     g_area.height - g_insets.top - g_insets.bottom);
    RXTermPane *full = g_full_block ? t.panes[g_full_block] : nil, *solo = full ?: (t.zoomed ? t.panes[t.zoomed] : nil);
    for (RXTermPane* p in t.panes.allValues) {
        bool hide = solo && p != solo;
        if (p.hidden != hide)
            p.hidden = hide;
        CGFloat z = p == solo ? 2 : p.z;
        if (p.zPosition != z)
            p.zPosition = z;
    }
    if (solo) {
        place_pane(solo, full ? (t.own.width > 0 ? area : CGRectMake(0, 0, g_area.width, g_area.height)) : area);
        if (t.own.width > 0)
            ask_sizes(t);
        return;
    }
    for (NSDictionary* layer in t.layers) {
        if (![layer isKindOfClass:NSDictionary.class])
            continue;
        NSArray* b = layer[@"bounds"];
        CGRect f = area;
        if (![layer[@"kind"] isEqual:@"tiled"] && [b isKindOfClass:NSArray.class] && b.count == 4)
            f = CGRectMake(area.origin.x + [b[0] doubleValue] * area.size.width,
                           area.origin.y + [b[1] doubleValue] * area.size.height, [b[2] doubleValue] * area.size.width,
                           [b[3] doubleValue] * area.size.height);
        place_node(t, layer[@"layout"], f);
    }
    if (t.own.width > 0)
        ask_sizes(t);
}

static void walk_layout(RXTermTab* t, NSDictionary* n, NSString* focused, NSMutableSet* seen, CGFloat z) {
    if (![n isKindOfClass:NSDictionary.class])
        return;
    NSString* b = n[@"block_id"];
    if (!b) {
        NSDictionary* s = n[@"split"];
        walk_layout(t, s[@"before"], focused, seen, z);
        walk_layout(t, s[@"after"], focused, seen, z);
        return;
    }
    [seen addObject:b];
    RXTermPane* p = t.panes[b];
    if (!p) {
        p = [RXTermPane layer];
        p.block = b;
        p.session = t.session;
        p.clip = [RXLayer layer];
        p.clip.masksToBounds = YES;
        p.cells = [RXLayer layer];
        p.cells.anchorPoint = CGPointZero;
        p.cells.position = CGPointMake(kPadX, kPadY);
        p.cells.contentsGravity = kCAGravityResize;
        [p.clip addSublayer:p.cells];
        [p addSublayer:p.clip];
        [t addSublayer:p];
        t.panes[b] = p;
    }
    p.z = z;
    bool f = [b isEqual:focused];
    if (!p.drawn || p.focused != f)
        p.again = true;
    p.focused = f;
}

void term_full_block(NSString* block) {
    if (block == g_full_block || [block isEqual:g_full_block])
        return;
    g_full_block = [block copy];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (RXTermTab* t in g_tabs.allValues)
        place_tab(t);
    [CATransaction commit];
}

static void apply_view(RXTermTab* t, NSDictionary* window) {
    NSMutableSet* seen = [NSMutableSet set];
    t.layers = window[@"layers"];
    id zoomed = window[@"zoomed_block_id"];
    t.zoomed = [zoomed isKindOfClass:NSString.class] ? zoomed : nil;
    for (NSDictionary* layer in t.layers)
        if ([layer isKindOfClass:NSDictionary.class])
            walk_layout(t, layer[@"layout"], window[@"focused_block_id"], seen,
                        [layer[@"kind"] isEqual:@"tiled"] ? 0 : 1);
    for (NSString* b in t.panes.allKeys) {
        if ([seen containsObject:b])
            continue;
        stream_drop(b);
        [t.panes[b] removeFromSuperlayer];
        [t.panes removeObjectForKey:b];
    }
    place_tab(t);
    for (RXTermPane* p in t.panes.allValues) {
        if (!p.again)
            continue;
        p.again = false;
        fetch_pane(p);
    }
}

static bool tab_hot(RXTermTab* t);
static void fetch_pane(RXTermPane* p) {
    RXTermTab* t = (RXTermTab*)p.superlayer;
    bool tabbed = [t isKindOfClass:RXTermTab.class], input = tabbed && t.input;
    stream_want(p.session, p.block, p, p.focused && (!input || t.input.focused), tabbed && tab_hot(t), input,
                g_scale = term_scale());
}

static bool pane_hot(RXTermPane* q) {
    RXTermTab* t = (RXTermTab*)q.superlayer;
    if (![t isKindOfClass:RXTermTab.class])
        return true;
    return tab_hot(t) || t.input;
}
static bool pane_warm(RXTermPane* q) {
    return pane_hot(q) || CACurrentMediaTime() < q->_warmUntil;
}

static void show_surface(RXTermPane* q, rx::gpu::Surface s, uint64_t gen) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    q.cells.contents = (__bridge id)s.surface;
    [CATransaction commit];
    rx::gpu::cells_surface_done(q->_surface);
    q->_surface = s;
    q->_drawnGen = gen;
}

static void pane_render(RXTermPane* q, bool sync) {
    if (!q->_cellset || !q->_cellset->width || !q->_cellset->height)
        return;
    RX_INTERVAL(frame, "term render");
    auto set = q->_cellset;
    rx::gpu::Surface s = rx::gpu::cells_surface(set->width, set->height);
    if (!s.surface)
        return;
    id<MTLCommandBuffer> cb = [rx::gpu::queue() commandBuffer];
    if (!rx::gpu::cells_encode(cb, s.texture, *set))
        return rx::gpu::cells_surface_done(s);
    const uint64_t gen = q->_cellsGen, ticket = ++q->_renderGen;
    if (sync) {
        [cb commit];
        [cb waitUntilCompleted];
        show_surface(q, s, gen);
        return;
    }
    [cb commit];
    __weak RXTermPane* w = q;
    __block void (^check)(void) = nil;
    void (^step)(void) = ^{
        RXTermPane* p = w;
        if (!p || p->_renderGen != ticket) {
            rx::gpu::Surface got = s;
            if (cb.status < MTLCommandBufferStatusCompleted) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_MSEC), dispatch_get_main_queue(), check);
                return;
            }
            check = nil;
            rx::gpu::cells_surface_done(got);
            return;
        }
        if (cb.status < MTLCommandBufferStatusCompleted) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_MSEC), dispatch_get_main_queue(), check);
            return;
        }
        check = nil;
        show_surface(p, s, gen);
    };
    check = step;
    dispatch_async(dispatch_get_main_queue(), check);
}

static void wake(CALayer* root, int depth) {
    if (depth > 8)
        return;
    if ([root isKindOfClass:RXTermPane.class]) {
        RXTermPane* q = (RXTermPane*)root;
        q->_warmUntil = CACurrentMediaTime() + 5;
        if (q->_cellset && (!q->_surface.surface || q->_drawnGen != q->_cellsGen))
            pane_render(q, true);
        return;
    }
    for (CALayer* c in root.sublayers)
        wake(c, depth + 1);
}
extern "C" void rexui_term_wake(const void* layer) {
    if (layer && term_gpu())
        wake((__bridge CALayer*)layer, 0);
}

static bool g_sweep_due;
static void term_sweep_soon(void);
static void term_sweep(void) {
    g_sweep_due = false;
    const double now = CACurrentMediaTime();
    bool any = false;
    for (RXTermTab* t in g_tabs.allValues)
        for (RXTermPane* q in t.panes.allValues) {
            if (!q->_surface.surface)
                continue;
            any = true;
            if (pane_hot(q)) {
                q->_warmUntil = MAX(q->_warmUntil, now + 5);
                continue;
            }
            if (now < q->_warmUntil)
                continue;
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            q.cells.contents = nil;
            [CATransaction commit];
            rx::gpu::cells_surface_done(q->_surface);
        }
    if (rx::gpu::cells_surfaces_trim(now) || any)
        term_sweep_soon();
}
static void term_sweep_soon(void) {
    if (g_sweep_due)
        return;
    g_sweep_due = true;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        term_sweep();
    });
}

@interface RXLiveDrag : NSObject {
   @public
    rx::gpu::Surface drawn;
}
@property(nonatomic, copy) NSString* block;
@property(nonatomic, weak) NSView* pane;
@property(nonatomic, weak) NSView* surface;
@property(nonatomic) float surfaceOpacity;
@property(nonatomic, strong) CALayer* overlay;
@property(nonatomic) bool busy, again, started;
@property(nonatomic) CGSize size;
@property(nonatomic) uint64_t gen;
@end
@implementation RXLiveDrag
- (void)dealloc {
    rx::gpu::cells_surface_done(drawn);
}
@end

static NSMutableDictionary<NSString*, RXLiveDrag*>* g_live;
static uint64_t g_live_gen;

static NSView* terminal_view_in(NSView* v, int depth) {
    static Class c = NSClassFromString(RXNS(RXN_165)) ?: NSClassFromString(RXNS(RXN_164));
    if (!c || depth > 24)
        return nil;
    if ([v isKindOfClass:c])
        return v;
    for (NSView* s in v.subviews)
        if (NSView* f = terminal_view_in(s, depth + 1))
            return f;
    return nil;
}

static void live_reflow(RXLiveDrag* d);

static void live_show(RXLiveDrag* d, std::shared_ptr<rx::gpu::CellSet> set, CGFloat scale, uint64_t gen) {
    d.busy = false;
    NSView* pane = d.pane;
    if (!pane || !set || gen != g_live_gen || g_live[d.block] != d)
        return;
    if (set->width && set->height) {
        rx::gpu::Surface s = rx::gpu::cells_surface(set->width, set->height);
        id<MTLCommandBuffer> cb = [rx::gpu::queue() commandBuffer];
        if (s.surface && rx::gpu::cells_encode(cb, s.texture, *set)) {
            [cb commit];
            [cb waitUntilCompleted];
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            if (!d.overlay) {
                d.overlay = [RXLayer layer];
                d.overlay.zPosition = 1000;
                d.overlay.contentsGravity = kCAGravityResize;
                [pane.layer addSublayer:d.overlay];
                if (NSView* t = terminal_view_in(pane, 0)) {
                    d.surface = t;
                    d.surfaceOpacity = t.layer.opacity;
                    t.layer.opacity = 0;
                }
            }
            const CGFloat w = set->width / scale, h = set->height / scale;
            const CGFloat y = pane.isFlipped ? kPadY : pane.bounds.size.height - kPadY - h;
            d.overlay.frame = CGRectMake(kPadX, y, w, h);
            d.overlay.contentsScale = scale;
            d.overlay.contents = (__bridge id)s.surface;
            [CATransaction commit];
            rx::gpu::cells_surface_done(d->drawn);
            d->drawn = s;
        } else {
            rx::gpu::cells_surface_done(s);
        }
    }
    if (d.again) {
        d.again = false;
        live_reflow(d);
    }
}

static void live_reflow(RXLiveDrag* d) {
    NSView* pane = d.pane;
    if (!pane)
        return;
    if (d.busy) {
        d.again = true;
        return;
    }
    d.busy = true;
    const CGSize size = pane.bounds.size;
    const CGFloat scale = term_scale();
    const bool fill = !g_config.transparency;
    const uint64_t gen = g_live_gen;
    std::string key = d.block.UTF8String;
    dispatch_async(term_queue(), ^{
        std::shared_ptr<rx::gpu::CellSet> set;
        auto it = g_streams.find(key);
        if (it != g_streams.end() && it->second->grid.term) {
            Stream* s = it->second;
            Fonts* F = fonts_for(s->grid.cell_h, scale);
            int cw = s->grid.cell_w, ch = s->grid.cell_h;
            if (cw <= 0 || ch <= 0)
                natural_cell(F, &cw, &ch);
            const int cols = MAX(1, int(floor((size.width - 2 * kPadX) * scale / cw))),
                      rows = MAX(1, int(floor((size.height - 2 * kPadY) * scale / ch)));
            const Terminal& t = *s->grid.term;
            if (auto r = t.reflowed(cols, rows)) {
                static auto& cells = *new std::vector<rx::gpu::Cell>;
                term_cells(*r, F, cw, ch, s->focused, shape_of(t), 0, Sel{}, cells, fill);
                set = cell_set(cells, cols * cw, rows * ch);
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            live_show(d, set, scale, gen);
        });
    });
}

void term_live_begin(NSString* session, NSMapTable<NSString*, NSView*>* panes) {
    if (!term_gpu())
        return;
    term_live_end(0);
    g_live = [NSMutableDictionary dictionary];
    g_live_gen++;
    for (NSString* block in panes.keyEnumerator.allObjects) {
        NSView* v = [panes objectForKey:block];
        if (!v || panes_app_of_block(block) || panes_doc_of_block(block))
            continue;
        RXLiveDrag* d = [RXLiveDrag new];
        d.block = block;
        d.pane = v;
        g_live[block] = d;
        const CGFloat scale = term_scale();
        dispatch_async(term_queue(), ^{
            if (g_streams.count(block.UTF8String))
                return;
            dispatch_async(dispatch_get_main_queue(), ^{
                d.started = true;
            });
            stream_want(session, block, nil, false, true, false, scale);
        });
    }
}

void term_live_frame(void) {
    for (RXLiveDrag* d in g_live.allValues) {
        NSView* pane = d.pane;
        if (!pane || CGSizeEqualToSize(pane.bounds.size, d.size))
            continue;
        d.size = pane.bounds.size;
        live_reflow(d);
    }
}

void term_live_end(double delay) {
    if (!g_live.count)
        return;
    NSArray<RXLiveDrag*>* was = g_live.allValues;
    g_live = nil;
    g_live_gen++;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        for (RXLiveDrag* d in was) {
            if (NSView* t = d.surface)
                t.layer.opacity = d.surfaceOpacity;
            [d.overlay removeFromSuperlayer];
            d.overlay = nil;
            if (!d.started)
                continue;
            NSString* block = d.block;
            dispatch_async(term_queue(), ^{
                auto it = g_streams.find(block.UTF8String);
                if (it != g_streams.end() && !it->second->pane)
                    dispatch_async(dispatch_get_main_queue(), ^{
                        stream_drop(block);
                    });
            });
        }
        [CATransaction commit];
    });
}

static void put_picture(RXTermPane* q, TermPicture pic, CGFloat scale) {
    RX_INTERVAL(frame, "term picture");
    CGImageRef image = pic.image;
    std::vector<RowPicture> rows;
    rows.swap(pic.rows_drawn);
    pic.image = nullptr;
    if (q) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        const CGFloat W = pic.cols * pic.cell_w / scale, ch = pic.cell_h / scale, m = pic.margin / scale;
        q.cells.bounds = CGRectMake(0, 0, W, pic.rows * ch);
        q.cells.contentsScale = scale;
        if (pic.cells) {
            for (CALayer* r in q.rowLayers)
                [r removeFromSuperlayer];
            [q.rowLayers removeAllObjects];
            q->_cellset = pic.cells;
            q->_cellsGen++;
            if (pane_warm(q))
                pane_render(q, false);
            else if (!q->_surface.surface)
                q.cells.contents = nil;
            term_sweep_soon();
        } else if (pic.banded) {
            q.cells.contents = nil;
            if (!q.rowLayers)
                q.rowLayers = [NSMutableArray array];
            while (q.rowLayers.count > (NSUInteger)pic.rows)
                [q.rowLayers.lastObject removeFromSuperlayer], [q.rowLayers removeLastObject];
            while (q.rowLayers.count < (NSUInteger)pic.rows) {
                CALayer* r = [RXLayer layer];
                r.anchorPoint = CGPointZero;
                r.contentsGravity = kCAGravityResize;
                [q.cells addSublayer:r];
                [q.rowLayers addObject:r];
            }
            for (const RowPicture& r : rows) {
                CALayer* l = q.rowLayers[(NSUInteger)r.y];
                l.bounds = CGRectMake(0, 0, W, ch + 2 * m);
                l.position = CGPointMake(0, r.y * ch - m);
                l.contentsScale = scale;
                l.contents = (__bridge id)r.image;
            }
        } else {
            for (CALayer* r in q.rowLayers)
                [r removeFromSuperlayer];
            [q.rowLayers removeAllObjects];
            q.cells.contents = (__bridge id)image;
            q->_cellset = nullptr;
            rx::gpu::cells_surface_done(q->_surface);
        }
        [CATransaction commit];
        q.shown = pic;
        q.scale = scale;
        q.drawn = true;
        if (RXTermInput* i = q.hoverInput)
            [i linkAgain];
    }
    CGImageRelease(image);
    for (const RowPicture& r : rows)
        CGImageRelease(r.image);
}

void term_bytes(size_t out[6]) {
    for (int i = 0; i < 6; i++)
        out[i] = 0;
    auto image_bytes = [](id c) -> size_t {
        if (!c)
            return 0;
        if (CFGetTypeID((__bridge CFTypeRef)c) == CGImageGetTypeID())
            return CGImageGetBytesPerRow((__bridge CGImageRef)c) * CGImageGetHeight((__bridge CGImageRef)c);
        return 0;
    };
    for (RXTermTab* t in g_tabs.allValues)
        for (RXTermPane* q in t.panes.allValues) {
            out[4]++;
            if (q.cells.contents)
                out[5]++;
            if (q->_surface.surface)
                out[0] += IOSurfaceGetAllocSize(q->_surface.surface);
            if (q->_cellset)
                out[1] += size_t(q->_cellset->n) * sizeof(rx::gpu::Cell);
            out[3] += image_bytes(q.cells.contents);
            for (CALayer* r in q.rowLayers)
                out[3] += image_bytes(r.contents);
        }
    if (term_gpu())
        dispatch_sync(term_queue(), ^{
            out[2] = g_atlas.bytes();
        });
}

bool term_gpu_diff(CALayer* root, int out[4], const char* dir) {
    __block RXTermPane* pane = nil;
    __block void (^find)(CALayer*) = nil;
    void (^walk)(CALayer*) = ^(CALayer* l) {
        if (pane)
            return;
        if ([l isKindOfClass:RXTermPane.class]) {
            pane = (RXTermPane*)l;
            return;
        }
        for (CALayer* c in l.sublayers)
            find(c);
    };
    find = walk;
    walk(root);
    if (!pane.block || !rx::gpu::device())
        return false;
    std::string key = pane.block.UTF8String, folder = dir ? dir : "";
    __block bool ok = false;
    dispatch_sync(term_queue(), ^{
        auto it = g_streams.find(key);
        if (it == g_streams.end() || !it->second->grid.term)
            return;
        Stream* s = it->second;
        const Terminal& t = *s->grid.term;
        int index = 0;
        for (bool focused : {true, false}) {
            TermPicture whole = picture_of(s->grid, s->scale, focused, s->back, s->sel, {});
            if (!whole.image)
                return;
            Fonts* F = fonts_for(s->grid.cell_h, s->scale);
            std::vector<rx::gpu::Cell> cells;
            term_cells(t, F, whole.cell_w, whole.cell_h, focused, shape_of(t), MIN(s->back, t.scrollback()), s->sel,
                       cells);
            const size_t W = CGImageGetWidth(whole.image), H = CGImageGetHeight(whole.image);
            auto set = cell_set(cells, int(W), int(H));
            MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                         width:W
                                                                                        height:H
                                                                                     mipmapped:NO];
            d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            d.storageMode = MTLStorageModeShared;
            id<MTLTexture> tex = [rx::gpu::device() newTextureWithDescriptor:d];
            id<MTLCommandBuffer> cb = [rx::gpu::queue() commandBuffer];
            if (!tex || !rx::gpu::cells_encode(cb, tex, *set)) {
                CGImageRelease(whole.image);
                return;
            }
            [cb commit];
            [cb waitUntilCompleted];
            std::vector<uint8_t> a(W * H * 4, 0), b(W * H * 4, 0);
            [tex getBytes:b.data() bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
            CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            CGContextRef ca =
                CGBitmapContextCreate(a.data(), W, H, 8, W * 4, cs,
                                      uint32_t(kCGImageAlphaPremultipliedFirst) | uint32_t(kCGBitmapByteOrder32Little));
            CGContextDrawImage(ca, CGRectMake(0, 0, W, H), whole.image);
            int differ = 0;
            for (size_t i = 0; i < a.size(); i += 4) {
                int m = 0;
                for (int k = 0; k < 4; k++)
                    m = MAX(m, abs(int(a[i + k]) - int(b[i + k])));
                if (m > 24)
                    differ++;
            }
            out[index++] = differ;
            if (focused && !folder.empty()) {
                auto save = [&](CGImageRef img, const char* name) {
                    NSURL* u = [NSURL fileURLWithPath:[NSString stringWithFormat:@"%s/%s", folder.c_str(), name]];
                    CGImageDestinationRef dst =
                        CGImageDestinationCreateWithURL((__bridge CFURLRef)u, CFSTR("public.png"), 1, nullptr);
                    if (!dst)
                        return;
                    CGImageDestinationAddImage(dst, img, nullptr);
                    CGImageDestinationFinalize(dst);
                    CFRelease(dst);
                };
                CGContextRef cg = CGBitmapContextCreate(
                    b.data(), W, H, 8, W * 4, cs,
                    uint32_t(kCGImageAlphaPremultipliedFirst) | uint32_t(kCGBitmapByteOrder32Little));
                CGImageRef gimg = CGBitmapContextCreateImage(cg);
                save(whole.image, "cpu.png");
                save(gimg, "gpu.png");
                CGImageRelease(gimg);
                CGContextRelease(cg);
            }
            CGContextRelease(ca);
            CGColorSpaceRelease(cs);
            CGImageRelease(whole.image);
            if (focused)
                out[2] = int(cells.size());
        }
        out[3] = int(g_atlas.bytes() / 1024);
        ok = true;
    });
    return ok;
}

int term_banded_diff(CALayer* root) {
    __block RXTermPane* pane = nil;
    __block void (^find)(CALayer*) = nil;
    void (^walk)(CALayer*) = ^(CALayer* l) {
        if (pane)
            return;
        if ([l isKindOfClass:RXTermPane.class]) {
            pane = (RXTermPane*)l;
            return;
        }
        for (CALayer* c in l.sublayers)
            find(c);
    };
    find = walk;
    walk(root);
    if (!pane.block)
        return -1;
    std::string key = pane.block.UTF8String;
    __block int differ = -1;
    dispatch_sync(term_queue(), ^{
        auto it = g_streams.find(key);
        if (it == g_streams.end() || !it->second->grid.term)
            return;
        Stream* s = it->second;
        TermPicture whole = picture_of(s->grid, s->scale, s->focused, s->back, s->sel, {});
        RowCache fresh;
        TermPicture rows = picture_of(s->grid, s->scale, s->focused, s->back, s->sel, {}, &fresh, false);
        if (!whole.image)
            return;
        const size_t W = CGImageGetWidth(whole.image), H = CGImageGetHeight(whole.image);
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        auto bitmap = [&](std::vector<uint8_t>& px) {
            px.assign(W * H * 4, 0);
            return CGBitmapContextCreate(
                px.data(), W, H, 8, W * 4, cs,
                uint32_t(kCGImageAlphaPremultipliedFirst) | uint32_t(kCGBitmapByteOrder32Little));
        };
        std::vector<uint8_t> a, b;
        CGContextRef ca = bitmap(a), cb = bitmap(b);
        CGContextDrawImage(ca, CGRectMake(0, 0, W, H), whole.image);
        for (const RowPicture& r : rows.rows_drawn) {
            const CGFloat hb = CGImageGetHeight(r.image), top = CGFloat(r.y * rows.cell_h - rows.margin);
            CGContextDrawImage(cb, CGRectMake(0, CGFloat(H) - top - hb, W, hb), r.image);
            CGImageRelease(r.image);
        }
        CGContextRelease(ca), CGContextRelease(cb), CGColorSpaceRelease(cs);
        CGImageRelease(whole.image);
        differ = 0;
        for (size_t i = 0; i < a.size(); i += 4) {
            int d = 0;
            for (int k = 0; k < 4; k++)
                d = MAX(d, abs(int(a[i + k]) - int(b[i + k])));
            if (d > 24)
                differ++;
        }
    });
    return differ;
}

static RXTermTab* make_tab(NSString* tab) {
    if (!g_tabs)
        g_tabs = [NSMutableDictionary dictionary];
    if (RXTermTab* t = g_tabs[tab])
        return t;
    RXTermTab* t = [RXTermTab layer];
    t.tab = tab;
    t.panes = [NSMutableDictionary dictionary];
    t.opacity = 0;
    t.frame = CGRectMake(0, 0, g_area.width, g_area.height);
    [g_parent addSublayer:t];
    g_tabs[tab] = t;
    return t;
}

static uint64_t g_views_generation;
static void read_views(void) {
    if (!g_tabs.count)
        return;
    uint64_t gen = ++g_views_generation;
    dispatch_async(term_queue(), ^{
        NSMutableArray* views = [NSMutableArray array];
        NSDictionary* list = api_call("session.list", nil);
        for (NSDictionary* s in list[@"sessions"]) {
            NSString* sid = [s isKindOfClass:NSDictionary.class] ? s[@"session_id"] : nil;
            if (!sid)
                continue;
            NSDictionary* v = api_call("session.view", @{@"session_id": sid});
            if (v)
                [views addObject:v];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != g_views_generation)
                return;
            NSMutableSet* alive = [NSMutableSet set];
            for (NSDictionary* v in views) {
                for (NSDictionary* w in v[@"windows"]) {
                    if (![w isKindOfClass:NSDictionary.class])
                        continue;
                    NSString* id = w[@"window_id"];
                    [alive addObject:id];
                    RXTermTab* t = g_tabs[id];
                    if (!t)
                        continue;
                    t.session = v[@"session_id"];
                    apply_view(t, w);
                }
            }
            for (NSString* id in g_tabs.allKeys) {
                if ([alive containsObject:id])
                    continue;
                RXTermInput* input = g_tabs[id].input;
                for (NSString* b in g_tabs[id].panes)
                    stream_drop(b);
                [g_tabs[id] removeFromSuperlayer];
                [g_tabs removeObjectForKey:id];
                if (input)
                    term_input_gone(input);
            }
            pane_styles_wake();
        });
    });
}

void term_tabs_rex_event(void) {
    if (!g_tabs.count)
        return;
    static bool queued;
    if (queued)
        return;
    queued = true;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10), dispatch_get_main_queue(), ^{
        queued = false;
        read_views();
    });
}

extern "C" void rexui_term_want(const char* ids, const void* parent) {
    g_parent = (__bridge CALayer*)parent;
    bool added = false;
    for (NSString* id in [@(ids) componentsSeparatedByString:@"\n"]) {
        if (!id.length || g_tabs[id])
            continue;
        make_tab(id);
        added = true;
    }
    if (added)
        read_views();
}

static void tell_streams(RXTermTab* t) {
    for (RXTermPane* p in t.panes.allValues)
        fetch_pane(p);
}

extern "C" void rexui_term_shown(const char* id) {
    NSString* now = @(id);
    if ([now isEqual:g_shown_tab])
        return;
    RXTermTab* was = g_tabs[g_shown_tab ?: @""];
    g_shown_tab = now;
    if (was)
        tell_streams(was);
    if (RXTermTab* t = g_tabs[now])
        tell_streams(t);
}

static void drop_tab(RXTermTab* t) {
    for (NSString* b in t.panes)
        stream_drop(b);
    [t removeFromSuperlayer];
    [g_tabs removeObjectForKey:t.tab];
}

void term_tab_watch(CALayer* layer, bool on) {
    if (![layer isKindOfClass:RXTermTab.class])
        return;
    RXTermTab* t = (RXTermTab*)layer;
    t.watchers = MAX(0, t.watchers + (on ? 1 : -1));
    tell_streams(t);
    panes_attach_soon();
    if (on)
        rexui_term_wake((__bridge const void*)t);
    if (on || t.watchers || g_config.tab_slide)
        return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!t.watchers && !g_config.tab_slide && g_tabs[t.tab] == t)
            drop_tab(t);
    });
}

void term_tabs_config_changed(void) {
    if (g_config.tab_slide)
        return;
    for (RXTermTab* t in g_tabs.allValues)
        if (!t.watchers)
            drop_tab(t);
}

extern "C" bool rexui_term_fit(double w, double h, double top, double left, double bottom, double right, double gap) {
    CGSize area = CGSizeMake(w, h);
    NSEdgeInsets in = NSEdgeInsetsMake(top, left, bottom, right);
    if (CGSizeEqualToSize(area, g_area) && NSEdgeInsetsEqual(in, g_insets) && gap == g_gap)
        return false;
    g_area = area, g_insets = in, g_gap = gap;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (RXTermTab* t in g_tabs.allValues) {
        t.frame = CGRectMake(0, 0, w, h);
        place_tab(t);
    }
    [CATransaction commit];
    return true;
}

extern "C" const void* rexui_term_tab(const char* id) {
    RXTermTab* t = g_tabs[@(id)];
    return t.panes.count && !t.input ? (__bridge const void*)t : nullptr;
}

CALayer* term_tab_layer(NSString* id) {
    if (!id.length)
        return nil;
    RXTermTab* t = g_tabs[id];
    if (!t && g_parent) {
        t = make_tab(id);
        read_views();
    }
    return t;
}

CALayer* term_block_layer(NSString* block) {
    for (RXTermTab* t in g_tabs.allValues)
        if (RXTermPane* p = t.panes[block])
            return p;
    return nil;
}

NSString* term_pane_blank(CALayer* layer) {
    if (![layer isKindOfClass:RXTermPane.class])
        return nil;
    RXTermPane* q = (RXTermPane*)layer;
    if (q.cells.contents || q.rowLayers.count || q.up.sublayers.count || q.hidden)
        return nil;
    RXTermTab* t = (RXTermTab*)q.superlayer;
    bool tabbed = [t isKindOfClass:RXTermTab.class];
    NSString* why = !q.drawn  ? @"no picture has come"
        : !q->_cellset        ? @"no cells"
        : q->_surface.surface ? @"a surface not shown"
                              : @"cells not drawn";
    return [NSString stringWithFormat:@"%@ %@ (%.0fx%.0f; tab %@, watchers %ld, %@, %@)", q.block, why,
                                      q.bounds.size.width, q.bounds.size.height, tabbed ? t.tab : @"none",
                                      tabbed ? (long)t.watchers : -1L,
                                      pane_hot(q)        ? @"hot"
                                          : pane_warm(q) ? @"warm"
                                                         : @"cold",
                                      tabbed && t.superlayer ? @"in the overlay" : @"in no layer"];
}
NSString* term_tab_blank(CALayer* tab) {
    if (![tab isKindOfClass:RXTermTab.class])
        return nil;
    for (RXTermPane* q in ((RXTermTab*)tab).panes.allValues)
        if (NSString* why = term_pane_blank(q))
            return why;
    return nil;
}

bool term_block_drawn(NSString* block) {
    RXTermPane* p = (RXTermPane*)term_block_layer(block);
    return [p isKindOfClass:RXTermPane.class] && pane_warm(p);
}

bool term_block_hot(NSString* block) {
    RXTermPane* p = (RXTermPane*)term_block_layer(block);
    return [p isKindOfClass:RXTermPane.class] && pane_hot(p);
}

CALayer* term_block_clip(NSString* block) {
    RXTermPane* p = (RXTermPane*)term_block_layer(block);
    if (p && !p.up) {
        p.up = [RXLayer layer];
        p.up.geometryFlipped = YES;
        p.up.frame = p.clip.bounds;
        [p.clip addSublayer:p.up];
    }
    return p.up;
}

static __weak RXTermTab* g_arrived;
static CFTimeInterval g_arrived_at;
extern "C" void rexui_term_arrived(const void* layer) {
    CALayer* l = (__bridge CALayer*)layer;
    g_arrived = [l isKindOfClass:RXTermTab.class] ? (RXTermTab*)l : nil;
    g_arrived_at = CACurrentMediaTime();
}
NSDictionary* term_arrived_tab(void) {
    RXTermTab* t = g_arrived;
    if (!t || !t.panes.count || (!rex_slide_busy() && CACurrentMediaTime() - g_arrived_at > 0.5))
        return nil;
    NSString* focused = @"";
    for (RXTermPane* p in t.panes.allValues)
        if (p.focused)
            focused = p.block;
    return @{@"blocks": [NSSet setWithArray:t.panes.allKeys], @"focused": focused};
}

NSArray<NSDictionary*>* term_preview_panes(void) {
    NSMutableArray* out = [NSMutableArray array];
    NSArray* keys = [g_tabs.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString* tab in keys) {
        RXTermTab* t = g_tabs[tab];
        if (t.input)
            continue;
        NSArray* ps = [t.panes.allValues sortedArrayUsingComparator:^NSComparisonResult(RXTermPane* a, RXTermPane* b) {
            if (a.zPosition != b.zPosition)
                return a.zPosition < b.zPosition ? NSOrderedAscending : NSOrderedDescending;
            CGPoint pa = a.frame.origin, pb = b.frame.origin;
            if (round(pa.y) != round(pb.y))
                return pa.y < pb.y ? NSOrderedAscending : NSOrderedDescending;
            return pa.x < pb.x ? NSOrderedAscending : pa.x > pb.x ? NSOrderedDescending : NSOrderedSame;
        }];
        NSUInteger i = 0;
        RXTermPane *full = g_full_block ? t.panes[g_full_block] : nil,
                   *solo = full ?: (t.zoomed ? t.panes[t.zoomed] : nil);
        for (RXTermPane* p in ps) {
            [out addObject:@{
                @"block": p.block,
                @"key": [NSString stringWithFormat:@"%@#%p", p.block, p],
                @"index": @(i++),
                @"focused": @(p.focused),
                @"tabPanes": @(ps.count),
                @"zoomed": @(p == solo && !full),
                @"fullscreen": @(p == full),
                @"covered": @(solo && p != solo),
                @"width": @(round(p.bounds.size.width)),
                @"height": @(round(p.bounds.size.height)),
                @"layer": p
            }];
        }
    }
    return out;
}

extern "C" int rexui_term_png(const char* session, const char* block, const char* path) {
    __block TermPicture p;
    NSString *s = @(session), *b = @(block);
    CGFloat scale = dock_window().backingScaleFactor ?: 1;
    dispatch_sync(term_queue(), ^{
        p = picture_of(snapshot_now(s, b), scale, true);
    });
    if (!p.image)
        return 1;
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(path)],
                                                                CFSTR("public.png"), 1, nullptr);
    if (dst) {
        CGImageDestinationAddImage(dst, p.image, nullptr);
        CGImageDestinationFinalize(dst);
        CFRelease(dst);
    }
    CGImageRelease(p.image);
    return dst ? 0 : 3;
}

extern "C" const char* rexui_term_all(void) {
    static NSString* s;
    s = [[g_tabs.allKeys sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@"\n"];
    return s.UTF8String ?: "";
}

extern "C" const char* rexui_term_want_more(const char* id) {
    NSString* s = @(id);
    if (!term_tab_layer(s))
        return "no";
    return "yes";
}

static NSString* key_name(unsigned short code) {
    switch (code) {
    case kVK_ANSI_A:
        return @"key_a";
    case kVK_ANSI_B:
        return @"key_b";
    case kVK_ANSI_C:
        return @"key_c";
    case kVK_ANSI_D:
        return @"key_d";
    case kVK_ANSI_E:
        return @"key_e";
    case kVK_ANSI_F:
        return @"key_f";
    case kVK_ANSI_G:
        return @"key_g";
    case kVK_ANSI_H:
        return @"key_h";
    case kVK_ANSI_I:
        return @"key_i";
    case kVK_ANSI_J:
        return @"key_j";
    case kVK_ANSI_K:
        return @"key_k";
    case kVK_ANSI_L:
        return @"key_l";
    case kVK_ANSI_M:
        return @"key_m";
    case kVK_ANSI_N:
        return @"key_n";
    case kVK_ANSI_O:
        return @"key_o";
    case kVK_ANSI_P:
        return @"key_p";
    case kVK_ANSI_Q:
        return @"key_q";
    case kVK_ANSI_R:
        return @"key_r";
    case kVK_ANSI_S:
        return @"key_s";
    case kVK_ANSI_T:
        return @"key_t";
    case kVK_ANSI_U:
        return @"key_u";
    case kVK_ANSI_V:
        return @"key_v";
    case kVK_ANSI_W:
        return @"key_w";
    case kVK_ANSI_X:
        return @"key_x";
    case kVK_ANSI_Y:
        return @"key_y";
    case kVK_ANSI_Z:
        return @"key_z";
    case kVK_ANSI_0:
        return @"digit_0";
    case kVK_ANSI_1:
        return @"digit_1";
    case kVK_ANSI_2:
        return @"digit_2";
    case kVK_ANSI_3:
        return @"digit_3";
    case kVK_ANSI_4:
        return @"digit_4";
    case kVK_ANSI_5:
        return @"digit_5";
    case kVK_ANSI_6:
        return @"digit_6";
    case kVK_ANSI_7:
        return @"digit_7";
    case kVK_ANSI_8:
        return @"digit_8";
    case kVK_ANSI_9:
        return @"digit_9";
    case kVK_ANSI_Minus:
        return @"minus";
    case kVK_ANSI_Equal:
        return @"equal";
    case kVK_ANSI_LeftBracket:
        return @"bracket_left";
    case kVK_ANSI_RightBracket:
        return @"bracket_right";
    case kVK_ANSI_Backslash:
        return @"backslash";
    case kVK_ANSI_Semicolon:
        return @"semicolon";
    case kVK_ANSI_Quote:
        return @"quote";
    case kVK_ANSI_Grave:
        return @"backquote";
    case kVK_ANSI_Comma:
        return @"comma";
    case kVK_ANSI_Period:
        return @"period";
    case kVK_ANSI_Slash:
        return @"slash";
    case kVK_ISO_Section:
        return @"intl_backslash";
    case kVK_Return:
        return @"enter";
    case kVK_Tab:
        return @"tab";
    case kVK_Space:
        return @"space";
    case kVK_Delete:
        return @"backspace";
    case kVK_Escape:
        return @"escape";
    case kVK_ForwardDelete:
        return @"delete";
    case kVK_Help:
        return @"insert";
    case kVK_Home:
        return @"home";
    case kVK_End:
        return @"end";
    case kVK_PageUp:
        return @"page_up";
    case kVK_PageDown:
        return @"page_down";
    case kVK_LeftArrow:
        return @"arrow_left";
    case kVK_RightArrow:
        return @"arrow_right";
    case kVK_UpArrow:
        return @"arrow_up";
    case kVK_DownArrow:
        return @"arrow_down";
    case kVK_F1:
        return @"f1";
    case kVK_F2:
        return @"f2";
    case kVK_F3:
        return @"f3";
    case kVK_F4:
        return @"f4";
    case kVK_F5:
        return @"f5";
    case kVK_F6:
        return @"f6";
    case kVK_F7:
        return @"f7";
    case kVK_F8:
        return @"f8";
    case kVK_F9:
        return @"f9";
    case kVK_F10:
        return @"f10";
    case kVK_F11:
        return @"f11";
    case kVK_F12:
        return @"f12";
    case kVK_F13:
        return @"f13";
    case kVK_F14:
        return @"f14";
    case kVK_F15:
        return @"f15";
    case kVK_F16:
        return @"f16";
    case kVK_F17:
        return @"f17";
    case kVK_F18:
        return @"f18";
    case kVK_F19:
        return @"f19";
    case kVK_F20:
        return @"f20";
    case kVK_ANSI_Keypad0:
        return @"numpad_0";
    case kVK_ANSI_Keypad1:
        return @"numpad_1";
    case kVK_ANSI_Keypad2:
        return @"numpad_2";
    case kVK_ANSI_Keypad3:
        return @"numpad_3";
    case kVK_ANSI_Keypad4:
        return @"numpad_4";
    case kVK_ANSI_Keypad5:
        return @"numpad_5";
    case kVK_ANSI_Keypad6:
        return @"numpad_6";
    case kVK_ANSI_Keypad7:
        return @"numpad_7";
    case kVK_ANSI_Keypad8:
        return @"numpad_8";
    case kVK_ANSI_Keypad9:
        return @"numpad_9";
    case kVK_ANSI_KeypadDecimal:
        return @"numpad_decimal";
    case kVK_ANSI_KeypadMultiply:
        return @"numpad_multiply";
    case kVK_ANSI_KeypadPlus:
        return @"numpad_add";
    case kVK_ANSI_KeypadMinus:
        return @"numpad_subtract";
    case kVK_ANSI_KeypadDivide:
        return @"numpad_divide";
    case kVK_ANSI_KeypadEnter:
        return @"numpad_enter";
    case kVK_ANSI_KeypadEquals:
        return @"numpad_equal";
    case kVK_ANSI_KeypadClear:
        return @"num_lock";
    case kVK_Shift:
        return @"shift_left";
    case kVK_RightShift:
        return @"shift_right";
    case kVK_Control:
        return @"control_left";
    case kVK_RightControl:
        return @"control_right";
    case kVK_Option:
        return @"alt_left";
    case kVK_RightOption:
        return @"alt_right";
    case kVK_Command:
        return @"meta_left";
    case kVK_RightCommand:
        return @"meta_right";
    case kVK_CapsLock:
        return @"caps_lock";
    default:
        return @"unidentified";
    }
}

static NSString* mods_of(NSEventModifierFlags m) {
    NSMutableArray* a = [NSMutableArray array];
    if (m & NSEventModifierFlagShift)
        [a addObject:@"shift"];
    if (m & NSEventModifierFlagControl)
        [a addObject:@"ctrl"];
    if (m & NSEventModifierFlagOption)
        [a addObject:@"alt"];
    if (m & NSEventModifierFlagCommand)
        [a addObject:@"super"];
    if (m & NSEventModifierFlagCapsLock)
        [a addObject:@"caps_lock"];
    return [a componentsJoinedByString:@"+"];
}

namespace {

std::unordered_map<std::string, std::pair<int, int>> g_asked;

void on_stream(NSString* block, void (^f)(Stream* s)) {
    dispatch_async(term_queue(), ^{
        auto it = g_streams.find(block.UTF8String);
        if (it != g_streams.end() && !it->second->gone)
            f(it->second);
    });
}

const TermCell* line_at(const Terminal& t, int line) {
    return line < t.scrollback() ? t.scrollback_row(line) : t.row(line - t.scrollback());
}
bool line_wrapped(const Terminal& t, int line) {
    return line < t.scrollback() ? t.scrollback_wrapped(line) : t.wrapped(line - t.scrollback());
}

std::string sel_text(const Terminal& t, const Sel& sel) {
    std::string out;
    if (!sel.on)
        return out;
    int total = t.scrollback() + t.rows();
    for (int line = sel.line0; line <= sel.line1 && line < total; line++) {
        const TermCell* r = line_at(t, line);
        int a = line == sel.line0 ? sel.col0 : 0, b = line == sel.line1 ? sel.col1 : t.cols() - 1;
        b = MIN(b, t.cols() - 1);
        std::string row;
        for (int x = a; x <= b; x++) {
            if (r[x].width == 0)
                continue;
            for (char32_t cp : {r[x].cp ? r[x].cp : char32_t(U' '), r[x].comb[0], r[x].comb[1]}) {
                if (!cp)
                    continue;
                if (cp < 0x80)
                    row += char(cp);
                else if (cp < 0x800)
                    row += char(0xC0 | (cp >> 6)), row += char(0x80 | (cp & 0x3F));
                else if (cp < 0x10000)
                    row += char(0xE0 | (cp >> 12)), row += char(0x80 | ((cp >> 6) & 0x3F)),
                        row += char(0x80 | (cp & 0x3F));
                else
                    row += char(0xF0 | (cp >> 18)), row += char(0x80 | ((cp >> 12) & 0x3F)),
                        row += char(0x80 | ((cp >> 6) & 0x3F)), row += char(0x80 | (cp & 0x3F));
            }
        }
        bool wraps = line_wrapped(t, line) && b == t.cols() - 1;
        if (!wraps) {
            while (!row.empty() && row.back() == ' ')
                row.pop_back();
        }
        out += row;
        if (line != sel.line1 && !wraps)
            out += '\n';
    }
    return out;
}

bool word_cell(const TermCell& c) {
    char32_t p = c.cp;
    if (p >= 0x80)
        return true;
    return (p >= '0' && p <= '9') || (p >= 'a' && p <= 'z') || (p >= 'A' && p <= 'Z') || p == '_' || p == '-'
        || p == '.' || p == '/' || p == '~';
}

struct LinkHit {
    bool on = false, osc = false;
    int line0 = 0, col0 = 0, line1 = 0, col1 = 0;
    std::string uri;
    uint32_t rgb = 0xd8d8d8;
};

uint32_t text_rgb(const Terminal& t, const TermCell& c) {
    uint32_t dfg = t.default_fg() != Terminal::kUnset ? t.default_fg() : 0xd8d8d8,
             dbg = t.default_bg() != Terminal::kUnset ? t.default_bg() : 0x1c1c1e;
    bool inv = c.attrs & rx::term::kInverse;
    rx::term::Color col = inv ? c.bg : c.fg;
    if (rx::term::is_rgb(col))
        return col & 0xFFFFFF;
    if (rx::term::is_palette(col))
        return t.palette_rgb(uint8_t(col & 0xFF));
    return inv ? dbg : dfg;
}

LinkHit link_at(const Terminal& t, const Links* links, int line, int col) {
    LinkHit h;
    if (rx::term::LinkSpan s = rx::term::hyperlink_at(t, line, col); s.on && links) {
        std::string_view uri = links->uri(rx::term::line_cells(t, s.line0)[s.col0].link);
        if (!uri.empty())
            return LinkHit{true,    true,   s.line0,          s.col0,
                           s.line1, s.col1, std::string(uri), text_rgb(t, rx::term::line_cells(t, s.line0)[s.col0])};
    }
    char buf[4096];
    size_t n = 0;
    rx::term::LinkSpan s = rx::term::url_at(t, line, col, buf, &n);
    if (!s.on)
        return h;
    return LinkHit{true,
                   false,
                   s.line0,
                   s.col0,
                   s.line1,
                   s.col1,
                   std::string(buf, n),
                   text_rgb(t, rx::term::line_cells(t, s.line0)[s.col0])};
}

}

static void cell_at(RXTermPane* p, CGPoint q, int* x, int* y);
static __weak RXTermInput* g_hover_input;
static NSEventModifierFlags g_given_mods;

@implementation RXTermInput {
    RXTermTab* _tab;
    RXNode* __weak _owner;
    NSString* _typed;
    bool _in_key;
    NSString* _marked;
    CGFloat _scroll;
    bool _selecting, _tracked;
    int _anchor_line, _anchor_col, _unit;
    bool _has_selection;
    uint8_t _buttons;
    CGPoint _hover_q;
    bool _hovering;
    NSString* _hover_block;
    int _hover_x, _hover_y;
    bool _hover_cmd;
    uint64_t _hover_gen;
    NSString* _link;
    int _link_line0, _link_col0, _link_line1, _link_col1, _link_top;
    __weak RXTermPane* _link_pane;
    NSMutableArray<CALayer*>* _link_layers;
}

- (void)linkShow:(const LinkHit&)h top:(int)top pane:(RXTermPane*)p {
    bool had = _link != nil;
    for (CALayer* l in _link_layers)
        [l removeFromSuperlayer];
    [_link_layers removeAllObjects];
    if (RXTermPane* was = _link_pane; was && was != p)
        was.hoverInput = nil;
    _link = h.on ? @(h.uri.c_str()) : nil;
    _link_pane = h.on ? p : nil;
    p.hoverInput = h.on ? self : nil;
    if (h.on) {
        _link_line0 = h.line0, _link_col0 = h.col0, _link_line1 = h.line1, _link_col1 = h.col1, _link_top = top;
        TermPicture s = p.shown;
        CGFloat k = p.scale ?: 1, cw = s.cell_w / k, ch = s.cell_h / k, thick = MAX(1, round(k)) / k;
        CGColorRef colour =
            CGColorCreateSRGB(((h.rgb >> 16) & 0xFF) / 255.0, ((h.rgb >> 8) & 0xFF) / 255.0, (h.rgb & 0xFF) / 255.0, 1);
        if (!_link_layers)
            _link_layers = [NSMutableArray array];
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        for (int line = h.line0; line <= h.line1; line++) {
            int y = line - top;
            if (y < 0 || y >= s.rows)
                continue;
            int a = line == h.line0 ? h.col0 : 0, b = line == h.line1 ? h.col1 : s.cols - 1;
            CALayer* u = [RXLayer layer];
            u.backgroundColor = colour;
            u.zPosition = 9;
            u.frame = CGRectMake(a * cw, (y + 1) * ch - thick - round(ch * 0.08 * k) / k, (b - a + 1) * cw, thick);
            [p.cells addSublayer:u];
            [_link_layers addObject:u];
        }
        [CATransaction commit];
        CGColorRelease(colour);
    }
    if (had != (_link != nil))
        ui_pointer_refresh();
}

- (void)linkClear {
    _hover_block = nil;
    _hover_gen++;
    if (_link) {
        LinkHit none;
        [self linkShow:none top:0 pane:_link_pane];
    }
}

- (void)hoverAt:(CGPoint)q {
    _hover_q = q, _hovering = true;
    RXTermPane* p = [self paneAt:q];
    bool cmd = ((NSEvent.modifierFlags | g_given_mods) & NSEventModifierFlagDeviceIndependentFlagsMask)
        == NSEventModifierFlagCommand;
    if (!p || !cmd || _selecting || _tracked)
        return [self linkClear];
    int x, y;
    cell_at(p, q, &x, &y);
    if ([_hover_block isEqualToString:p.block] && _hover_x == x && _hover_y == y && _hover_cmd == cmd)
        return;
    _hover_block = p.block, _hover_x = x, _hover_y = y, _hover_cmd = cmd;
    uint64_t gen = ++_hover_gen;
    __weak RXTermInput* weak = self;
    __weak RXTermPane* pane = p;
    on_stream(p.block, ^(Stream* s) {
        if (!s->grid.term)
            return;
        const Terminal& t = *s->grid.term;
        int top = t.scrollback() - MIN(s->back, t.scrollback());
        LinkHit h = link_at(t, s->grid.links.get(), top + y, x);
        dispatch_async(dispatch_get_main_queue(), ^{
            RXTermInput* me = weak;
            RXTermPane* pp = pane;
            if (!me || !pp || me->_hover_gen != gen)
                return;
            [me linkShow:h top:top pane:pp];
        });
    });
}

- (void)linkAgain {
    if (!_hovering)
        return;
    _hover_block = nil;
    [self hoverAt:_hover_q];
}

- (void)hoverGone {
    _hovering = false;
    [self linkClear];
}

static void open_link(NSString* uri) {
    NSURL* url = [NSURL URLWithString:uri];
    if (!url)
        url = [NSURL
            URLWithString:[uri stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet
                                                                                      .URLFragmentAllowedCharacterSet]];
    if (!url.scheme.length)
        return;
    if (url.isFileURL) {
        NSString* host = url.host.lowercaseString ?: @"";
        NSString* me = NSProcessInfo.processInfo.hostName.lowercaseString ?: @"";
        NSString* short_me = [me componentsSeparatedByString:@"."].firstObject ?: me;
        if (host.length && ![host isEqualToString:@"localhost"] && ![host isEqualToString:me]
            && ![host isEqualToString:short_me]) {
            rexui_log([NSString stringWithFormat:@"term: a link to a file on %@ not opened", host]);
            return;
        }
        url = [NSURL fileURLWithPath:url.path];
    }
    [NSWorkspace.sharedWorkspace openURL:url];
}

- (bool)openLinkAt:(CGPoint)q {
    NSEvent* e = NSApp.currentEvent;
    if (!_link || !(e.modifierFlags & NSEventModifierFlagCommand))
        return false;
    RXTermPane* p = [self paneAt:q];
    if (!p || p != _link_pane)
        return false;
    int x, y;
    cell_at(p, q, &x, &y);
    int line = _link_top + y;
    bool in = (line > _link_line0 || (line == _link_line0 && x >= _link_col0))
        && (line < _link_line1 || (line == _link_line1 && x <= _link_col1));
    if (!in && _hover_x == x && _hover_y == y)
        in = true;
    if (!in)
        return false;
    open_link(_link);
    return true;
}

- (RXTermPane*)keyPane {
    for (RXTermPane* p in _tab.panes.allValues)
        if (p.focused)
            return p;
    return _tab.panes.allValues.firstObject;
}

- (NSString*)session {
    return _tab.session;
}

- (void)send:(const char*)method args:(NSDictionary*)args {
    NSString* session = _tab.session;
    if (!session)
        return;
    dispatch_async(term_queue(), ^{
        if (control_attached(session))
            control_call(method, args);
    });
}

- (void)event:(NSString*)type payload:(NSDictionary*)payload block:(NSString*)block {
    if (!block || !_tab.session)
        return;
    [self send:"block.event"
          args:@{@"session_id": _tab.session, @"block_id": block, @"event": @{@"type": type, @"payload": payload}}];
}

- (void)sendKey:(NSEvent*)ev text:(NSString*)text action:(NSString*)action {
    RXTermPane* p = [self keyPane];
    if (!p || !_tab.session)
        return;
    NSEventModifierFlags m = ev.modifierFlags;
    NSString* unshifted = [ev charactersByApplyingModifiers:0];
    unichar u = unshifted.length ? [unshifted characterAtIndex:0] : 0;
    if (u >= 0xF700 && u <= 0xF8FF)
        u = 0;
    NSEventModifierFlags used = text.length ? m & (NSEventModifierFlagShift | NSEventModifierFlagOption) : 0;
    NSDictionary* key = @{
        @"key": key_name(ev.keyCode),
        @"mods": mods_of(m),
        @"consumed_mods": mods_of(used),
        @"text": text ?: @"",
        @"unshifted_codepoint": @(u),
        @"composing": @NO,
        @"action": action
    };
    [self send:"client.key" args:@{@"session_id": _tab.session, @"block_id": p.block, @"key": key}];
}

- (void)handleKey:(NSEvent*)ev {
    id root = [self.host respondsToSelector:@selector(rootView)] ? [self.host rootView] : nil;
    [self clearView];
    _in_key = true;
    _typed = @"";
    bool composing = _marked.length > 0;
    [root interpretKeyEvents:@[ev]];
    _in_key = false;
    if (_marked.length || (composing && !_typed.length))
        return;
    [self sendKey:ev text:_typed action:ev.isARepeat ? @"repeat" : @"press"];
}
- (void)handleKeyUp:(NSEvent*)ev {
    if (!_marked.length)
        [self sendKey:ev text:@"" action:@"release"];
}

- (void)clearView {
    _has_selection = false;
    NSMutableSet* blocks = [NSMutableSet setWithArray:_tab.panes.allKeys];
    for (NSString* b in blocks) {
        on_stream(b, ^(Stream* s) {
            if (!s->back && !s->sel.on)
                return;
            s->back = 0, s->sel = Sel{};
            schedule_draw(s);
        });
    }
}

- (NSString*)text {
    return @"";
}
- (NSRange)selection {
    return NSMakeRange(0, _has_selection ? 1 : 0);
}
- (NSRange)marked {
    return _marked.length ? NSMakeRange(0, _marked.length) : NSMakeRange(NSNotFound, 0);
}
- (void)insert:(NSString*)s {
    _marked = nil;
    [self showMarked];
    if (_in_key) {
        _typed = [_typed stringByAppendingString:s];
        return;
    }
    RXTermPane* p = [self keyPane];
    if (p)
        [self event:@"paste" payload:@{@"text": s} block:p.block];
}
- (void)setMarked:(NSString*)s selected:(NSRange)sr replacing:(NSRange)rr {
    _marked = s.length ? [s copy] : nil;
    [self showMarked];
}
- (void)unmark {
    _marked = nil;
    [self showMarked];
}
- (bool)perform:(SEL)sel {
    if (sel == @selector(selectAll:)) {
        RXTermPane* p = [self keyPane];
        _has_selection = true;
        if (p)
            on_stream(p.block, ^(Stream* s) {
                if (!s->grid.term)
                    return;
                s->sel =
                    Sel{true, 0, 0, s->grid.term->scrollback() + s->grid.term->rows() - 1, s->grid.term->cols() - 1};
                schedule_draw(s);
            });
    }
    return true;
}
- (void)copySelection {
    RXTermPane* p = [self keyPane];
    if (!p)
        return;
    on_stream(p.block, ^(Stream* s) {
        if (!s->grid.term)
            return;
        NSString* text = @(sel_text(*s->grid.term, s->sel).c_str());
        if (!text.length)
            return;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSPasteboard* pb = NSPasteboard.generalPasteboard;
            [pb clearContents];
            [pb setString:text forType:NSPasteboardTypeString];
        });
    });
}
- (void)cut {
}
- (void)paste {
    NSString* s = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
    RXTermPane* p = [self keyPane];
    [self clearView];
    if (s.length && p)
        [self event:@"paste" payload:@{@"text": s} block:p.block];
}
- (void)undo:(bool)redo {
    if (NSEvent* e = NSApp.currentEvent; e.type == NSEventTypeKeyDown)
        [self sendKey:e text:@"" action:@"press"];
}
- (void)setFocused:(bool)f {
    bool was = self.focused;
    [super setFocused:f];
    if (was == f)
        return;
    if (RXTermPane* p = [self keyPane])
        [self event:@"focus" payload:@{@"action": f ? @"in" : @"out"} block:p.block];
    for (RXTermPane* p in _tab.panes.allValues)
        fetch_pane(p);
    if (!f) {
        _marked = nil;
        [self showMarked];
    }
}

- (RXTermPane*)paneAt:(CGPoint)q {
    for (RXTermPane* p in _tab.panes.allValues)
        if (CGRectContainsPoint(p.frame, q))
            return p;
    return nil;
}

static void cell_at(RXTermPane* p, CGPoint q, int* x, int* y) {
    TermPicture s = p.shown;
    CGFloat k = p.scale ?: 1, w = (s.cell_w ?: 16) / k, h = (s.cell_h ?: 32) / k;
    *x = MAX(0, MIN(int((q.x - p.frame.origin.x - kPadX) / w), MAX(0, s.cols - 1)));
    *y = MAX(0, MIN(int((q.y - p.frame.origin.y - kPadY) / h), MAX(0, s.rows - 1)));
}

- (void)mouse:(NSString*)action at:(CGPoint)q button:(NSString*)button event:(NSEvent*)e pane:(RXTermPane*)p {
    int x, y;
    cell_at(p, q, &x, &y);
    CGFloat k = p.scale ?: 1;
    [self event:@"mouse"
        payload:@{
            @"button": button,
            @"modifiers": mods_of(e.modifierFlags),
            @"x": @(x),
            @"y": @(y),
            @"action": action,
            @"pixel": @{
                @"x": @(int((q.x - p.frame.origin.x - kPadX) * k)),
                @"y": @(int((q.y - p.frame.origin.y - kPadY) * k))
            }
        }
          block:p.block];
}

static NSString* button_of(NSEvent* e) {
    switch (e.buttonNumber) {
    case 0:
        return @"left";
    case 1:
        return @"right";
    case 2:
        return @"middle";
    default:
        return [NSString stringWithFormat:@"%@", @[@"four", @"five", @"six", @"seven", @"eight", @"nine",
                                                   @"ten"][MIN(6, MAX(0, e.buttonNumber - 3))]];
    }
}

- (void)pressAt:(CGPoint)q clicks:(NSInteger)clicks extend:(bool)extend {
    NSEvent* e = NSApp.currentEvent;
    RXTermPane* p = [self paneAt:q];
    if (!p)
        return;
    if ([self openLinkAt:q])
        return;
    if (!p.focused && _tab.session)
        [self send:"session.focus_block" args:@{@"session_id": _tab.session, @"block_id": p.block}];
    _tracked = p.shown.tracking != Terminal::MouseTracking::none && !(e.modifierFlags & NSEventModifierFlagShift);
    if (_tracked) {
        _buttons++;
        return [self mouse:@"press" at:q button:button_of(e) event:e pane:p];
    }
    int x, y;
    cell_at(p, q, &x, &y);
    int unit = (int)MIN(clicks, 3);
    _selecting = true;
    _has_selection = unit > 1;
    _unit = unit;
    on_stream(p.block, ^(Stream* s) {
        if (!s->grid.term)
            return;
        const Terminal& t = *s->grid.term;
        int line = t.scrollback() - MIN(s->back, t.scrollback()) + y;
        s->anchor_line = line, s->anchor_col = x, s->unit = unit;
        if (extend && s->sel.on)
            return;
        s->sel = Sel{};
        if (unit > 1)
            sel_to(s, line, x);
        schedule_draw(s);
    });
}

- (void)dragTo:(CGPoint)q {
    NSEvent* e = NSApp.currentEvent;
    RXTermPane* p = [self paneAt:q] ?: [self keyPane];
    if (!p)
        return;
    if (_tracked) {
        if (p.shown.tracking == Terminal::MouseTracking::drag || p.shown.tracking == Terminal::MouseTracking::any)
            [self mouse:@"motion" at:q button:button_of(e) event:e pane:p];
        return;
    }
    if (!_selecting)
        return;
    int x, y;
    cell_at(p, q, &x, &y);
    _has_selection = true;
    on_stream(p.block, ^(Stream* s) {
        if (!s->grid.term)
            return;
        const Terminal& t = *s->grid.term;
        sel_to(s, t.scrollback() - MIN(s->back, t.scrollback()) + y, x);
        schedule_draw(s);
    });
}

- (void)releaseAt:(CGPoint)q {
    NSEvent* e = NSApp.currentEvent;
    RXTermPane* p = [self paneAt:q] ?: [self keyPane];
    if (_tracked && p)
        [self mouse:@"release" at:q button:button_of(e) event:e pane:p];
    _tracked = _selecting = false;
    if (_buttons)
        _buttons--;
}

- (void)otherPress:(NSEvent*)e at:(CGPoint)q up:(bool)up {
    RXTermPane* p = [self paneAt:q];
    if (p && p.shown.tracking != Terminal::MouseTracking::none)
        [self mouse:up ? @"release" : @"press" at:q button:button_of(e) event:e pane:p];
}

- (bool)scrollBy:(NSEvent*)e {
    CGPoint q = CGPointZero;
    RXNode* n = self.node;
    id host = self.host;
    if (n && [host isKindOfClass:RXLayerHost.class]) {
        NSPoint in = [(RXLayerHost*)host convertPoint:e.locationInWindow fromView:nil];
        q = [n.layer convertPoint:NSPointToCGPoint(in) fromLayer:[(RXLayerHost*)host layer]];
    }
    RXTermPane* p = [self paneAt:q] ?: [self keyPane];
    if (!p)
        return false;
    TermPicture s = p.shown;
    CGFloat k = p.scale ?: 1, line = (s.cell_h ?: 32) / k;
    CGFloat dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * line;
    if (s.tracking != Terminal::MouseTracking::none || s.alternate) {
        int x, y;
        cell_at(p, q, &x, &y);
        [self event:@"wheel"
            payload:@{
                @"modifiers": mods_of(e.modifierFlags),
                @"delta_x": @(-e.scrollingDeltaX),
                @"delta_y": @(-dy),
                @"delta_z": @0,
                @"delta_mode": @"pixel",
                @"x": @(x),
                @"y": @(y)
            }
              block:p.block];
        return true;
    }
    _scroll += dy;
    int whole = int(_scroll / line);
    if (!whole)
        return true;
    _scroll -= whole * line;
    on_stream(p.block, ^(Stream* st) {
        if (!st->grid.term)
            return;
        int b = MAX(0, MIN(st->back + whole, st->grid.term->scrollback()));
        if (b == st->back)
            return;
        st->back = b;
        schedule_draw(st);
    });
    [self linkAgain];
    return true;
}

- (void)showMarked {
    RXTermPane* p = [self keyPane];
    if (!p)
        return;
    if (!_marked.length) {
        [p.markedText removeFromSuperlayer];
        p.markedText = nil;
        return;
    }
    TermPicture s = p.shown;
    CGFloat k = p.scale ?: 1;
    NSUserDefaults* d = NSUserDefaults.standardUserDefaults;
    NSString* name = [d stringForKey:RXNS(RXN_174)] ?: @"Menlo";
    double pt = [d doubleForKey:RXNS(RXN_175)] ?: 12;
    CTFontRef font = CTFontCreateWithName((__bridge CFStringRef)name, pt * k, nullptr);
    NSDictionary* a =
        @{(id)kCTFontAttributeName: (__bridge id)font, (id)kCTForegroundColorFromContextAttributeName: @YES};
    NSAttributedString* as = [[NSAttributedString alloc] initWithString:_marked attributes:a];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
    CGFloat ascent, descent, leading;
    double w = CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
    int W = int(ceil(w)) + 2, H = MAX(int(ceil(ascent + descent)) + 2, s.cell_h);
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c =
        CGBitmapContextCreate(nullptr, size_t(W), size_t(H), 8, 0, srgb,
                              uint32_t(kCGImageAlphaPremultipliedFirst) | uint32_t(kCGBitmapByteOrder32Little));
    CGColorSpaceRelease(srgb);
    if (c) {
        CGContextSetRGBFillColor(c, 0.1, 0.1, 0.12, 0.95);
        CGContextFillRect(c, CGRectMake(0, 0, W, H));
        CGContextSetRGBFillColor(c, 0.95, 0.95, 0.95, 1);
        CGContextSetTextPosition(c, 1, descent + 1);
        CTLineDraw(line, c);
        CGContextFillRect(c, CGRectMake(0, 0, W, MAX(1, round(k))));
        CGImageRef img = CGBitmapContextCreateImage(c);
        CGContextRelease(c);
        if (!p.markedText) {
            p.markedText = [RXLayer layer];
            p.markedText.zPosition = 10;
            [p.clip addSublayer:p.markedText];
        }
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        p.markedText.contents = (__bridge id)img;
        p.markedText.contentsScale = k;
        p.markedText.frame =
            CGRectMake(kPadX + s.cursor_x * s.cell_w / k, kPadY + s.cursor_y * s.cell_h / k, W / k, H / k);
        [CATransaction commit];
        CGImageRelease(img);
    }
    CFRelease(line);
    CFRelease(font);
}

- (NSRect)windowRectFor:(NSRange)r {
    RXTermPane* p = [self keyPane];
    id host = self.host;
    if (!p || ![host isKindOfClass:RXLayerHost.class])
        return NSZeroRect;
    TermPicture s = p.shown;
    CGFloat k = p.scale ?: 1;
    CGRect cell =
        CGRectMake(kPadX + s.cursor_x * s.cell_w / k, kPadY + s.cursor_y * s.cell_h / k, s.cell_w / k, s.cell_h / k);
    CGRect in = [p convertRect:cell toLayer:[(RXLayerHost*)host layer]];
    return [(RXLayerHost*)host convertRect:NSRectFromCGRect(in) toView:nil];
}
- (NSUInteger)indexAtWindowPoint:(NSPoint)win {
    return 0;
}

- (void)openTab:(RXTermTab*)t owner:(RXNode*)n {
    _tab = t;
    _owner = n;
}
- (RXTermTab*)tab {
    return _tab;
}
- (void)notifyGone {
    if (RXNode* n = _owner)
        tabpreview_gone(n);
}
- (NSString*)hoverLink {
    return _link;
}
@end

void term_input_hover(id host, RXTermInput* i, CGPoint q) {
    RXTermInput* was = g_hover_input;
    if (!i && was && host && was.host != host)
        return;
    if (was && was != i)
        [was hoverGone];
    g_hover_input = i;
    if (i)
        [i hoverAt:q];
}
void term_flags_changed(void) {
    if (RXTermInput* i = g_hover_input)
        [i linkAgain];
}
NSCursor* term_input_cursor(RXTermInput* i) {
    return [i hoverLink] ? NSCursor.pointingHandCursor : nil;
}
NSString* term_hovered_link(void) {
    return [g_hover_input hoverLink];
}
void term_hover_given_mods(NSEventModifierFlags m) {
    g_given_mods = m;
}

bool term_cell_point(RXNode* n, int col, int row, CGPoint* out) {
    RXTermInput* i = [n.editor isKindOfClass:RXTermInput.class] ? (RXTermInput*)n.editor : nil;
    RXTermPane* p = [i tab].panes.allValues.firstObject;
    if (!p.drawn)
        return false;
    TermPicture s = p.shown;
    CGFloat k = p.scale ?: 1;
    *out = CGPointMake(p.frame.origin.x + kPadX + (col + 0.5) * s.cell_w / k,
                       p.frame.origin.y + kPadY + (row + 0.5) * s.cell_h / k);
    return true;
}

static void term_input_gone(RXTermInput* i) {
    [i notifyGone];
}

static void ask_sizes(RXTermTab* t) {
    NSString* session = t.session;
    if (!session)
        return;
    CGFloat scale = term_scale();
    for (RXTermPane* p in t.panes.allValues) {
        CGSize size = p.bounds.size;
        if (size.width < 1 || size.height < 1)
            continue;
        NSString* block = p.block;
        double wide = (size.width - 2 * kPadX) * scale, high = (size.height - 2 * kPadY) * scale;
        dispatch_async(term_queue(), ^{
            int cw = 0, ch = 0;
            auto it = g_streams.find(block.UTF8String);
            if (it != g_streams.end())
                cw = it->second->grid.cell_w, ch = it->second->grid.cell_h;
            if (cw <= 0 || ch <= 0)
                natural_cell(fonts_for(0, scale), &cw, &ch);
            int cols = MAX(2, int(wide / cw)), rows = MAX(1, int(high / ch));
            std::string key = block.UTF8String;
            auto asked = g_asked.find(key);
            bool first = asked == g_asked.end();
            if (!first && asked->second == std::make_pair(cols, rows))
                return;
            if (!control_attached(session))
                return;
            if (first)
                control_call("session.own_block", @{@"session_id": session, @"block_ids": @[block], @"mode": @"take"});
            NSDictionary* got = control_call(
                "block.method", @{
                    @"session_id": session,
                    @"block_id": block,
                    @"method": @"resize",
                    @"args": @{@"columns": @(cols), @"rows": @(rows), @"cell_width_px": @(cw), @"cell_height_px": @(ch)}
                });
            if (got)
                g_asked[key] = {cols, rows};
        });
    }
}

RXTermInput* term_input_open(RXNode* n, NSString* window, NSString* session) {
    RXTermTab* t = make_tab(window);
    if (t.input)
        return nil;
    RXTermInput* i = [[RXTermInput alloc] initMultiline:true];
    [i openTab:t owner:n];
    i.node = n;
    i.host = host_of(n);
    t.input = i;
    if (session)
        t.session = session;
    t.watchers++;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [n.layer addSublayer:t];
    t.opacity = 1;
    t.frame = CGRectMake(0, 0, n.layer.bounds.size.width, n.layer.bounds.size.height);
    t.own = t.frame.size;
    [CATransaction commit];
    read_views();
    return i;
}

void term_input_fit(RXTermInput* i, CGSize size) {
    RXTermTab* t = [i tab];
    if (!t || (CGSizeEqualToSize(t.own, size) && t.frame.size.width == size.width))
        return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    t.own = size;
    t.frame = CGRectMake(0, 0, size.width, size.height);
    place_tab(t);
    [CATransaction commit];
}

NSString* term_input_window(RXTermInput* i) {
    return [i tab].tab;
}

void term_input_close(RXTermInput* i) {
    RXTermTab* t = [i tab];
    if (i.focused)
        editor_blur(i);
    if (g_hover_input == i)
        term_input_hover(nil, nil, CGPointZero);
    if (!t)
        return;
    NSString* session = t.session;
    NSArray* blocks = t.panes.allKeys;
    t.input = nil;
    t.own = CGSizeZero;
    t.watchers = MAX(0, t.watchers - 1);
    if (session && blocks.count) {
        dispatch_async(term_queue(), ^{
            for (NSString* b in blocks)
                g_asked.erase(b.UTF8String);
            if (control_attached(session))
                control_call("session.disown_block", @{@"session_id": session, @"block_ids": blocks});
        });
    }
    drop_tab(t);
    [i openTab:nil owner:nil];
}

void term_session_find(NSString* label, void (^done)(NSString* session, NSString* window)) {
    dispatch_async(term_queue(), ^{
        NSString *session = nil, *window = nil;
        NSDictionary* list = api_call("session.list", nil);
        for (NSDictionary* s in list[@"sessions"]) {
            if (![s isKindOfClass:NSDictionary.class] || ![s[@"label"] isEqual:label])
                continue;
            NSDictionary* v = api_call("session.view", @{@"session_id": s[@"session_id"] ?: @""});
            NSArray* windows = v[@"windows"];
            if (![windows isKindOfClass:NSArray.class] || !windows.count)
                break;
            session = s[@"session_id"];
            window = [v[@"active_window_id"] isKindOfClass:NSString.class] ? v[@"active_window_id"]
                                                                           : windows.firstObject[@"window_id"];
            break;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            done(session, window);
        });
    });
}
