// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include <CoreGraphics/CoreGraphics.h>
#include <crt_externs.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <objc/runtime.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

void rexui_embed_cursor_hidden(int hidden);
void rexui_embed_capture(int on);
void rexui_embed_warp(double x, double y);

static bool g_wine;

static CGError no_associate(boolean_t connected) {
    if (!g_wine)
        rexui_embed_capture(!connected);
    return kCGErrorSuccess;
}
static CGError no_warp(CGPoint p) {
    rexui_embed_warp(p.x, p.y);
    return kCGErrorSuccess;
}
static CGError no_move(CGDirectDisplayID d, CGPoint p) {
    CGRect b = CGDisplayBounds(d);
    rexui_embed_warp(b.origin.x + p.x, b.origin.y + p.y);
    return kCGErrorSuccess;
}
static CGError hide_cursor(CGDirectDisplayID d) {
    rexui_embed_cursor_hidden(1);
    return kCGErrorSuccess;
}
static CGError show_cursor(CGDirectDisplayID d) {
    rexui_embed_cursor_hidden(0);
    return kCGErrorSuccess;
}

static double g_w, g_h, g_scale = 1;
static struct {
    CGDisplayReconfigurationCallBack cb;
    void* info;
} g_reconfig[8];
static int g_nreconfig;

static CGRect pane_bounds(CGDirectDisplayID d) {
    CGRect r = CGDisplayBounds(d);
    if (g_w > 0)
        r.size = CGSizeMake(g_w, g_h);
    return r;
}
static size_t pane_pixels_wide(CGDirectDisplayID d) {
    return g_w > 0 ? (size_t)(g_w * g_scale) : CGDisplayPixelsWide(d);
}
static size_t pane_pixels_high(CGDirectDisplayID d) {
    return g_w > 0 ? (size_t)(g_h * g_scale) : CGDisplayPixelsHigh(d);
}
static size_t mode_width(CGDisplayModeRef m) {
    return g_w > 0 ? (size_t)g_w : CGDisplayModeGetWidth(m);
}
static size_t mode_height(CGDisplayModeRef m) {
    return g_w > 0 ? (size_t)g_h : CGDisplayModeGetHeight(m);
}
static size_t mode_pixel_width(CGDisplayModeRef m) {
    return g_w > 0 ? (size_t)(g_w * g_scale) : CGDisplayModeGetPixelWidth(m);
}
static size_t mode_pixel_height(CGDisplayModeRef m) {
    return g_w > 0 ? (size_t)(g_h * g_scale) : CGDisplayModeGetPixelHeight(m);
}
static CGError reconfig_register(CGDisplayReconfigurationCallBack cb, void* info) {
    if (g_nreconfig < 8)
        g_reconfig[g_nreconfig].cb = cb, g_reconfig[g_nreconfig++].info = info;
    return CGDisplayRegisterReconfigurationCallback(cb, info);
}

double rexui_embed_display_pixels_high(void) {
    return (double)pane_pixels_high(CGMainDisplayID());
}

void rexui_embed_set_pane(double w, double h, double scale) {
    if (w == g_w && h == g_h && scale == g_scale)
        return;
    int had = g_w > 0;
    g_w = w, g_h = h, g_scale = scale > 0 ? scale : 1;
    if (!had && !g_nreconfig)
        return;
    CGDirectDisplayID d = CGMainDisplayID();
    for (int i = 0; i < g_nreconfig; i++)
        g_reconfig[i].cb(d, kCGDisplayBeginConfigurationFlag, g_reconfig[i].info);
    for (int i = 0; i < g_nreconfig; i++)
        g_reconfig[i].cb(d, kCGDisplaySetModeFlag | kCGDisplayDesktopShapeChangedFlag, g_reconfig[i].info);
}

typedef struct SDL_Window SDL_Window;
static bool (*sdl3_relative)(SDL_Window*, bool);
static bool (*sdl3_grab)(SDL_Window*, bool);
static bool (*sdl3_rect)(SDL_Window*, const void*);
static int (*sdl2_relative)(int);
static void (*sdl2_grab)(SDL_Window*, int);
static bool no_sdl3_relative(SDL_Window* w, bool on) {
    return sdl3_relative(w, false);
}
static bool no_sdl3_grab(SDL_Window* w, bool on) {
    return sdl3_grab(w, false);
}
static bool no_sdl3_rect(SDL_Window* w, const void* r) {
    return sdl3_rect(w, NULL);
}
static int no_sdl2_relative(int on) {
    return sdl2_relative(0);
}
static bool relative_allowed(void) {
    static int allowed = -1;
    if (allowed < 0) {
        const char* e = getenv("REXUI_EMBED_RELATIVE");
        allowed = e && *e == '1';
    }
    return allowed;
}

bool rexui_embed_global_mouse(double* x, double* y);
static uint32_t (*sdl2_global)(int*, int*);
static uint32_t (*sdl3_global)(float*, float*);
static uint32_t pane_sdl2_global(int* x, int* y) {
    uint32_t b = sdl2_global(x, y);
    double gx, gy;
    if (rexui_embed_global_mouse(&gx, &gy)) {
        if (x)
            *x = (int)gx;
        if (y)
            *y = (int)gy;
    }
    return b;
}
static uint32_t pane_sdl3_global(float* x, float* y) {
    uint32_t b = sdl3_global(x, y);
    double gx, gy;
    if (rexui_embed_global_mouse(&gx, &gy)) {
        if (x)
            *x = (float)gx;
        if (y)
            *y = (float)gy;
    }
    return b;
}
static bool sdl3_loaded(void) {
    return dlsym(RTLD_DEFAULT, "SDL_GetWindowRelativeMouseMode") != NULL;
}
static void no_sdl2_grab(SDL_Window* w, int on) {
    sdl2_grab(w, 0);
}

static void* pane_dlsym(void* handle, const char* name) {
    void* f = dlsym(handle, name);
    if (!f || !name)
        return f;
#define SWAP(sym, real, ours)       \
    if (!strcmp(name, sym)) {       \
        real = (__typeof__(real))f; \
        return (void*)ours;         \
    }
    if (!relative_allowed()) {
        SWAP("SDL_SetWindowRelativeMouseMode", sdl3_relative, no_sdl3_relative)
        SWAP("SDL_SetWindowMouseGrab", sdl3_grab, no_sdl3_grab)
        SWAP("SDL_SetWindowMouseRect", sdl3_rect, no_sdl3_rect)
        SWAP("SDL_SetRelativeMouseMode", sdl2_relative, no_sdl2_relative)
        SWAP("SDL_SetWindowGrab", sdl2_grab, no_sdl2_grab)
    }
    if (!strcmp(name, "SDL_GetGlobalMouseState")) {
        Dl_info i;
        bool three = dladdr(f, &i) && i.dli_fname ? strstr(i.dli_fname, "SDL3") != NULL : sdl3_loaded();
        if (three) {
            sdl3_global = (__typeof__(sdl3_global))f;
            return (void*)pane_sdl3_global;
        }
        sdl2_global = (__typeof__(sdl2_global))f;
        return (void*)pane_sdl2_global;
    }
#undef SWAP
    return f;
}

typedef const void* TISRef;
static TISRef (*real_layout)(void);
static TISRef wine_layout(void) {
    static TISRef chosen;
    static bool looked;
    if (!looked) {
        looked = true;
        const char* id = getenv("REXUI_WINE_LAYOUT");
        CFArrayRef (*list)(CFDictionaryRef, Boolean) =
            (CFArrayRef(*)(CFDictionaryRef, Boolean))dlsym(RTLD_DEFAULT, "TISCreateInputSourceList");
        CFStringRef* key = (CFStringRef*)dlsym(RTLD_DEFAULT, "kTISPropertyInputSourceID");
        if (id && *id && list && key) {
            CFStringRef v = CFStringCreateWithCString(NULL, id, kCFStringEncodingUTF8);
            CFDictionaryRef q = CFDictionaryCreate(NULL, (const void**)key, (const void**)&v, 1,
                                                   &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            CFArrayRef found = list(q, true);
            if (found && CFArrayGetCount(found))
                chosen = CFRetain(CFArrayGetValueAtIndex(found, 0));
            if (found)
                CFRelease(found);
            CFRelease(q);
            CFRelease(v);
        }
        if (!real_layout)
            real_layout = (TISRef(*)(void))dlsym(RTLD_DEFAULT, "TISCopyCurrentKeyboardLayoutInputSource");
    }
    if (chosen)
        return CFRetain(chosen);
    return real_layout ? real_layout() : NULL;
}

static const struct {
    const char* name;
    void* to;
} k_rebinds[] = {
    {"TISCopyCurrentKeyboardLayoutInputSource", (void*)wine_layout},
    {"dlsym", (void*)pane_dlsym},
    {"CGDisplayBounds", (void*)pane_bounds},
    {"CGDisplayPixelsWide", (void*)pane_pixels_wide},
    {"CGDisplayPixelsHigh", (void*)pane_pixels_high},
    {"CGDisplayModeGetWidth", (void*)mode_width},
    {"CGDisplayModeGetHeight", (void*)mode_height},
    {"CGDisplayModeGetPixelWidth", (void*)mode_pixel_width},
    {"CGDisplayModeGetPixelHeight", (void*)mode_pixel_height},
    {"CGDisplayRegisterReconfigurationCallback", (void*)reconfig_register},
    {"CGAssociateMouseAndMouseCursorPosition", (void*)no_associate},
    {"CGWarpMouseCursorPosition", (void*)no_warp},
    {"CGDisplayMoveCursorToPoint", (void*)no_move},
    {"CGDisplayHideCursor", (void*)hide_cursor},
    {"CGDisplayShowCursor", (void*)show_cursor},
};

static bool g_wine_shims;
static bool wine_rebinds(const char* name) {
    return !strcmp(name, "CGAssociateMouseAndMouseCursorPosition") || !strcmp(name, "CGWarpMouseCursorPosition")
        || !strcmp(name, "CGDisplayMoveCursorToPoint") || !strcmp(name, "CGDisplayHideCursor")
        || !strcmp(name, "CGDisplayShowCursor")
        || (!strcmp(name, "TISCopyCurrentKeyboardLayoutInputSource") && getenv("REXUI_WINE_LAYOUT"));
}

static int shim_pipe2(int fds[2], int flags) {
    static int (*real)(int[2], int);
    static bool looked;
    if (!looked)
        real = (int (*)(int[2], int))dlsym(RTLD_DEFAULT, "pipe2"), looked = true;
    if (real)
        return real(fds, flags);
    if (flags & ~(O_CLOEXEC | O_NONBLOCK)) {
        errno = EINVAL;
        return -1;
    }
    if (pipe(fds) == -1)
        return -1;
    for (int i = 0; i < 2; i++) {
        if (flags & O_CLOEXEC)
            fcntl(fds[i], F_SETFD, fcntl(fds[i], F_GETFD) | FD_CLOEXEC);
        if (flags & O_NONBLOCK)
            fcntl(fds[i], F_SETFL, fcntl(fds[i], F_GETFL) | O_NONBLOCK);
    }
    return 0;
}

enum { IMAGE_APP, IMAGE_WINEMAC, IMAGE_NTDLL };

static uintptr_t g_winemac_lo, g_winemac_hi;
static void note_winemac(const struct mach_header_64* h, intptr_t slide) {
    const struct load_command* lc = (const struct load_command*)(h + 1);
    for (uint32_t i = 0; i < h->ncmds; i++, lc = (const struct load_command*)((const char*)lc + lc->cmdsize)) {
        const struct segment_command_64* seg = (const struct segment_command_64*)lc;
        if (lc->cmd != LC_SEGMENT_64 || strcmp(seg->segname, SEG_TEXT))
            continue;
        g_winemac_lo = (uintptr_t)slide + seg->vmaddr;
        g_winemac_hi = g_winemac_lo + seg->vmsize;
        return;
    }
}

static void rebind_section(const struct section_64* sect, intptr_t slide, const struct nlist_64* symtab,
                           const char* strtab, const uint32_t* indirect, int image) {
    const uint32_t* ind = indirect + sect->reserved1;
    void** ptrs = (void**)(slide + sect->addr);
    size_t count = sect->size / sizeof(void*);
    for (size_t i = 0; i < count; i++) {
        uint32_t si = ind[i];
        if (si & (INDIRECT_SYMBOL_ABS | INDIRECT_SYMBOL_LOCAL))
            continue;
        const char* name = strtab + symtab[si].n_un.n_strx;
        if (name[0] == '_')
            name++;
        if (image == IMAGE_NTDLL) {
            if (!strcmp(name, "pipe2")) {
                vm_address_t page = (vm_address_t)&ptrs[i] & ~(vm_address_t)(vm_page_size - 1);
                if (vm_protect(mach_task_self(), page, vm_page_size, 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY)
                    == KERN_SUCCESS)
                    ptrs[i] = (void*)shim_pipe2;
            }
            continue;
        }
        for (size_t j = 0; j < sizeof k_rebinds / sizeof k_rebinds[0]; j++) {
            if (strcmp(name, k_rebinds[j].name))
                continue;
            if (g_wine && !wine_rebinds(name))
                break;
            if (!g_wine && !strncmp(name, "TIS", 3))
                break;
            vm_address_t page = (vm_address_t)&ptrs[i] & ~(vm_address_t)(vm_page_size - 1);
            if (vm_protect(mach_task_self(), page, vm_page_size, 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY)
                != KERN_SUCCESS)
                break;
            ptrs[i] = k_rebinds[j].to;
            break;
        }
    }
}

static void rebind_image(const struct mach_header* mh, intptr_t slide) {
    Dl_info info, self;
    if (!dladdr(mh, &info) || !info.dli_fname)
        return;
    if (dladdr((void*)rebind_image, &self) && self.dli_fbase == info.dli_fbase)
        return;
    if (!strncmp(info.dli_fname, "/System/", 8) || !strncmp(info.dli_fname, "/usr/lib/", 9))
        return;
    int image = IMAGE_APP;
    if (g_wine || g_wine_shims) {
        size_t n = strlen(info.dli_fname);
        if (g_wine && n >= 11 && !strcmp(info.dli_fname + n - 11, "/winemac.so"))
            image = IMAGE_WINEMAC;
        else if (g_wine_shims && n >= 9 && !strcmp(info.dli_fname + n - 9, "/ntdll.so"))
            image = IMAGE_NTDLL;
        else
            return;
    }
    const struct mach_header_64* h = (const struct mach_header_64*)mh;
    if (h->magic != MH_MAGIC_64)
        return;
    if (image == IMAGE_WINEMAC)
        note_winemac(h, slide);
    const struct segment_command_64* linkedit = NULL;
    const struct symtab_command* symtab_cmd = NULL;
    const struct dysymtab_command* dysymtab_cmd = NULL;
    const struct load_command* lc = (const struct load_command*)(h + 1);
    for (uint32_t i = 0; i < h->ncmds; i++, lc = (const struct load_command*)((const char*)lc + lc->cmdsize)) {
        if (lc->cmd == LC_SEGMENT_64 && !strcmp(((const struct segment_command_64*)lc)->segname, SEG_LINKEDIT))
            linkedit = (const struct segment_command_64*)lc;
        else if (lc->cmd == LC_SYMTAB)
            symtab_cmd = (const struct symtab_command*)lc;
        else if (lc->cmd == LC_DYSYMTAB)
            dysymtab_cmd = (const struct dysymtab_command*)lc;
    }
    if (!linkedit || !symtab_cmd || !dysymtab_cmd || !dysymtab_cmd->nindirectsyms)
        return;
    uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64* symtab = (const struct nlist_64*)(base + symtab_cmd->symoff);
    const char* strtab = (const char*)(base + symtab_cmd->stroff);
    const uint32_t* indirect = (const uint32_t*)(base + dysymtab_cmd->indirectsymoff);
    lc = (const struct load_command*)(h + 1);
    for (uint32_t i = 0; i < h->ncmds; i++, lc = (const struct load_command*)((const char*)lc + lc->cmdsize)) {
        if (lc->cmd != LC_SEGMENT_64)
            continue;
        const struct segment_command_64* seg = (const struct segment_command_64*)lc;
        if (strcmp(seg->segname, "__DATA") && strcmp(seg->segname, "__DATA_CONST")
            && strcmp(seg->segname, "__AUTH_CONST"))
            continue;
        const struct section_64* sect = (const struct section_64*)(seg + 1);
        for (uint32_t s = 0; s < seg->nsects; s++) {
            uint32_t type = sect[s].flags & SECTION_TYPE;
            if (type == S_LAZY_SYMBOL_POINTERS || type == S_NON_LAZY_SYMBOL_POINTERS)
                rebind_section(&sect[s], slide, symtab, strtab, indirect, image);
        }
    }
}

static bool from_app(void* caller) {
    Dl_info i;
    return dladdr(caller, &i) && i.dli_fbase == (void*)_NSGetMachExecuteHeader();
}

bool rexui_embed_mouse_location(double* x, double* y);
static CGPoint (*real_mouse_location)(id, SEL);
static CGPoint pane_mouse_location(id self, SEL sel) {
    double x, y;
    if (from_app(__builtin_return_address(0)) && rexui_embed_mouse_location(&x, &y))
        return CGPointMake(x, y);
    return real_mouse_location(self, sel);
}

bool rexui_embed_mouse_in_window(void* window, double* x, double* y);
static CGPoint (*real_window_mouse)(id, SEL);
static CGPoint pane_window_mouse(id self, SEL sel) {
    double x, y;
    if (from_app(__builtin_return_address(0)) && rexui_embed_mouse_in_window((void*)self, &x, &y))
        return CGPointMake(x, y);
    return real_window_mouse(self, sel);
}

bool rexui_embed_adopted_frame(double* r);
static CGRect (*real_visible_frame)(id, SEL);
static CGRect pane_visible_frame(id self, SEL sel) {
    CGRect f = real_visible_frame(self, sel);
    double r[4];
    if (from_app(__builtin_return_address(0)) && rexui_embed_adopted_frame(r))
        f = CGRectUnion(f, CGRectMake(r[0], r[1], r[2], r[3]));
    return f;
}

void rexui_embed_rebind(void) {
    Method m = class_getClassMethod(objc_getClass("NSEvent"), sel_registerName("mouseLocation"));
    if (m)
        real_mouse_location = (CGPoint(*)(id, SEL))method_setImplementation(m, (IMP)pane_mouse_location);
    m = class_getInstanceMethod(objc_getClass("NSWindow"), sel_registerName("mouseLocationOutsideOfEventStream"));
    if (m)
        real_window_mouse = (CGPoint(*)(id, SEL))method_setImplementation(m, (IMP)pane_window_mouse);
    m = class_getInstanceMethod(objc_getClass("NSScreen"), sel_registerName("visibleFrame"));
    if (m)
        real_visible_frame = (CGRect(*)(id, SEL))method_setImplementation(m, (IMP)pane_visible_frame);
    struct winsize ws;
    if (ioctl(1, TIOCGWINSZ, &ws) == 0 && ws.ws_xpixel > 0 && ws.ws_ypixel > 0) {
        CGDisplayModeRef m = CGDisplayCopyDisplayMode(CGMainDisplayID());
        double scale =
            m && CGDisplayModeGetWidth(m) ? (double)CGDisplayModeGetPixelWidth(m) / CGDisplayModeGetWidth(m) : 1;
        if (m)
            CGDisplayModeRelease(m);
        g_scale = scale;
        g_w = ws.ws_xpixel / scale, g_h = ws.ws_ypixel / scale;
    }
    _dyld_register_func_for_add_image(rebind_image);
}

static bool g_registered;
static void register_images(void) {
    if (!g_registered)
        g_registered = true, _dyld_register_func_for_add_image(rebind_image);
}

bool rexui_embed_wine_mouse_location(double* x, double* y);
static CGPoint wine_mouse_location(id self, SEL sel) {
    uintptr_t from = (uintptr_t)__builtin_return_address(0);
    double x, y;
    if (from >= g_winemac_lo && from < g_winemac_hi && rexui_embed_wine_mouse_location(&x, &y))
        return CGPointMake(x, y);
    return real_mouse_location(self, sel);
}

void rexui_embed_rebind_wine(void) {
    g_wine = true;
    Method m = class_getClassMethod(objc_getClass("NSEvent"), sel_registerName("mouseLocation"));
    if (m)
        real_mouse_location = (CGPoint(*)(id, SEL))method_setImplementation(m, (IMP)wine_mouse_location);
    register_images();
}

void rexui_embed_wine_shims(void) {
    g_wine_shims = true;
    register_images();
}
