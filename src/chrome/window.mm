// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "chrome/chrome.h"
#include "core/sync/rmw.h"

#include <dlfcn.h>
#include <atomic>

static void set_blur(NSWindow* w, int radius) {
    using Connection = int (*)(void);
    using SetBlur = int32_t (*)(int, NSInteger, int);
    static Connection connection = (Connection)dlsym(RTLD_DEFAULT, "CGSMainConnectionID");
    static SetBlur set = (SetBlur)dlsym(RTLD_DEFAULT, "CGSSetWindowBackgroundBlurRadius");
    static char k_blur;
    if (!connection || !set || w.windowNumber <= 0)
        return;
    NSArray* now = @[@(w.windowNumber), @(radius)];
    NSArray* was = objc_getAssociatedObject(w, &k_blur);
    if ([now isEqual:was] || (!was && !radius))
        return;
    int32_t err = set(connection(), w.windowNumber, radius);
    if (err) {
        rexui_log([NSString stringWithFormat:@"blur: %d on window %ld failed (%d)", radius, (long)w.windowNumber, err]);
        return;
    }
    objc_setAssociatedObject(w, &k_blur, now, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

bool chrome_theme(double rgb[3]) {
    if (g_theme_rgb[0] < 0)
        return false;
    for (int i = 0; i < 3; i++)
        rgb[i] = g_theme_rgb[i];
    return true;
}

static char k_saved_window_bg;
static char k_saved_window_opaque;

void hook_window_set_background(NSWindow* self, SEL sel, NSColor* c) {
    if (is_rex_window(self)) {
        objc_setAssociatedObject(self, &k_saved_window_bg, c ?: (id)NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (transparent())
            c = g_window_bg ?: NSColor.clearColor;
    }
    orig_window_set_background(self, sel, c);
}

void update_window_bg(void) {
    if (g_theme_rgb[0] < 0)
        return;
    g_window_bg = [NSColor colorWithSRGBRed:g_theme_rgb[0]
                                      green:g_theme_rgb[1]
                                       blue:g_theme_rgb[2]
                                      alpha:g_config.opacity];
}

void tint_window(NSWindow* w) {
    if (transparent()) {
        if (!objc_getAssociatedObject(w, &k_saved_window_opaque)) {
            objc_setAssociatedObject(w, &k_saved_window_opaque, @(w.isOpaque), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (!objc_getAssociatedObject(w, &k_saved_window_bg)) {
            objc_setAssociatedObject(w, &k_saved_window_bg, w.backgroundColor ?: (id)NSNull.null,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (w.isOpaque)
            w.opaque = NO;
        NSColor* bg = g_window_bg ?: NSColor.clearColor;
        if (![w.backgroundColor isEqual:bg])
            orig_window_set_background(w, @selector(setBackgroundColor:), bg);
        set_blur(w, panes_full_opaque(w) ? 0 : g_config.blur);
        return;
    }
    set_blur(w, 0);
    if (NSNumber* opaque = objc_getAssociatedObject(w, &k_saved_window_opaque)) {
        if (w.isOpaque != opaque.boolValue)
            w.opaque = opaque.boolValue;
        objc_setAssociatedObject(w, &k_saved_window_opaque, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (id bg = objc_getAssociatedObject(w, &k_saved_window_bg)) {
        NSColor* c = bg == NSNull.null ? NSColor.windowBackgroundColor : bg;
        if (![w.backgroundColor isEqual:c])
            orig_window_set_background(w, @selector(setBackgroundColor:), c);
    }
}

NSMutableArray<NSString*>* g_clears;

static void note_clear(id self, MTLClearColor c) {
    NSString* line = [NSString stringWithFormat:@"%@ r=%.3f g=%.3f b=%.3f a=%.3f", NSStringFromClass([self class]),
                                                c.red, c.green, c.blue, c.alpha];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_clears)
            g_clears = [NSMutableArray array];
        if ([g_clears.lastObject isEqualToString:line])
            return;
        [g_clears addObject:line];
        if (g_clears.count > 40)
            [g_clears removeObjectAtIndex:0];
    });
}

static NSMapTable* g_other_clears;

static void hook_other_clear(id self, SEL sel, MTLClearColor c) {
    if (g_debug_clears)
        note_clear(self, c);
    IMP orig = nullptr;
    for (Class k = [self class]; k && !orig; k = class_getSuperclass(k))
        orig = (IMP)[[g_other_clears objectForKey:k] pointerValue];
    if (c.alpha >= 1.0 && g_config.transparency) {
        constexpr double a = 0.02;
        c = MTLClearColorMake(c.red * a, c.green * a, c.blue * a, a);
    }
    if (orig)
        ((void (*)(id, SEL, MTLClearColor))orig)(self, sel, c);
}

void hook_other_clear_classes(Class done) {
    g_other_clears = [NSMapTable strongToStrongObjectsMapTable];
    Class base = NSClassFromString(@"MTLRenderPassColorAttachmentDescriptor");
    if (!base)
        return;
    unsigned count = 0;
    Class* all = objc_copyClassList(&count);
    for (unsigned i = 0; i < count; i++) {
        Class c = all[i];
        if (c == done || c == base)
            continue;
        bool sub = false;
        for (Class k = class_getSuperclass(c); k; k = class_getSuperclass(k)) {
            if (k == base) {
                sub = true;
                break;
            }
        }
        if (!sub)
            continue;
        unsigned n = 0;
        Method* ms = class_copyMethodList(c, &n);
        Method found = nullptr;
        for (unsigned j = 0; j < n; j++) {
            if (method_getName(ms[j]) == @selector(setClearColor:))
                found = ms[j];
        }
        free(ms);
        if (!found)
            continue;
        [g_other_clears setObject:[NSValue valueWithPointer:(void*)method_getImplementation(found)] forKey:c];
        method_setImplementation(found, (IMP)hook_other_clear);
    }
    free(all);
}

static bool theme_from_prefs(double rgb[3]) {
    NSUserDefaults* d = NSUserDefaults.standardUserDefaults;
    NSString* appearance = [d stringForKey:RXNS(RXN_173)];
    bool dark = [appearance isEqualToString:@"dark"]
        || (![appearance isEqualToString:@"light"] && [[NSApp.effectiveAppearance bestMatchFromAppearancesWithNames:@[
                    NSAppearanceNameDarkAqua, NSAppearanceNameAqua
                ]] isEqualToString:NSAppearanceNameDarkAqua]);
    NSString* tid = [d stringForKey:dark ? RXNS(RXN_171) : RXNS(RXN_169)];
    if (![tid hasPrefix:@"custom-"])
        return false;
    id raw = [d objectForKey:RXNS(RXN_172)];
    NSData* data = [raw isKindOfClass:NSData.class] ? raw
        : [raw isKindOfClass:NSString.class]        ? [raw dataUsingEncoding:NSUTF8StringEncoding]
                                                    : nil;
    static NSData* last_data;
    static NSString* last_tid;
    static double last[3];
    static bool last_ok;
    if (!data)
        return false;
    if (![data isEqual:last_data] || ![tid isEqual:last_tid]) {
        last_data = data, last_tid = tid, last_ok = false;
        id themes = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        for (NSDictionary* t in [themes isKindOfClass:NSArray.class] ? themes : @[]) {
            if (![t isKindOfClass:NSDictionary.class] || ![t[RXNS(RXN_004)] isEqual:tid])
                continue;
            NSDictionary* palette = t[RXNS(RXN_187)];
            NSDictionary* bg = [palette isKindOfClass:NSDictionary.class] ? palette[RXNS(RXN_191)] : nil;
            if (![bg isKindOfClass:NSDictionary.class])
                break;
            last[0] = [bg[RXNS(RXN_081)] doubleValue], last[1] = [bg[RXNS(RXN_082)] doubleValue],
            last[2] = [bg[RXNS(RXN_083)] doubleValue];
            last_ok = true;
        }
    }
    if (last_ok)
        rgb[0] = last[0], rgb[1] = last[1], rgb[2] = last[2];
    return last_ok;
}

static void theme_from_clear(double r, double g, double b) {
    static double want[3];
    static bool pending;
    want[0] = r, want[1] = g, want[2] = b;
    if (pending)
        return;
    pending = true;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        pending = false;
        theme_from_prefs(want);
        if (want[0] == g_theme_rgb[0] && want[1] == g_theme_rgb[1] && want[2] == g_theme_rgb[2])
            return;
        rexui_log([NSString stringWithFormat:@"theme: clear colour %.3f %.3f %.3f (was %.3f %.3f %.3f)", want[0],
                                             want[1], want[2], g_theme_rgb[0], g_theme_rgb[1], g_theme_rgb[2]]);
        g_theme_rgb[0] = want[0], g_theme_rgb[1] = want[1], g_theme_rgb[2] = want[2];
        update_window_bg();
        apply_all();
        ui_theme_changed();
    });
}

void hook_set_clear(id self, SEL sel, MTLClearColor c) {
    if (g_debug_clears)
        note_clear(self, c);
    if (c.alpha >= 1.0) {
        static std::atomic<uint64_t> last{~0ull};
        uint64_t key = (uint64_t)lround(c.red * 65535) << 32 | (uint64_t)lround(c.green * 65535) << 16
            | (uint64_t)lround(c.blue * 65535);
        if (rx::sync::exchange(last, key, std::memory_order_relaxed) != key) {
            double r = c.red, g = c.green, b = c.blue;
            dispatch_async(dispatch_get_main_queue(), ^{
                theme_from_clear(r, g, b);
            });
        }
        if (transparent()) {
            constexpr double a = 0.02;
            c = MTLClearColorMake(c.red * a, c.green * a, c.blue * a, a);
        }
    }
    orig_set_clear(self, sel, c);
}
