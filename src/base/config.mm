// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "base/rexui.h"

#include "lua/lua.hpp"

#include <algorithm>

Config g_config;
uint64_t g_config_generation;

static NSString* config_path(void) {
    NSString* own = [ui_dir() stringByAppendingPathComponent:@"rui-config.lua"];
    if ([NSFileManager.defaultManager fileExistsAtPath:own])
        return own;
    return [NSHomeDirectory() stringByAppendingPathComponent:@".config/rex/rui-config.lua"];
}

static void stop_runaway(lua_State* L, lua_Debug*) {
    luaL_error(L, "still running after 10 million steps (a loop?)");
}

static constexpr size_t kLuaMemoryMax = 64u << 20;
static void* capped_alloc(void* ud, void* ptr, size_t osize, size_t nsize) {
    size_t& used = *static_cast<size_t*>(ud);
    size_t old = ptr ? osize : 0;
    if (nsize == 0) {
        free(ptr);
        used -= old;
        return nullptr;
    }
    if (nsize > old && nsize - old > kLuaMemoryMax - used)
        return nullptr;
    void* p = realloc(ptr, nsize);
    if (p)
        used = used - old + nsize;
    return p;
}

static NSString* lua_text(const char* s) {
    return s ? [NSString stringWithUTF8String:s] : nil;
}

static int log_print(lua_State* L) {
    NSMutableArray* parts = [NSMutableArray array];
    int n = lua_gettop(L);
    for (int i = 1; i <= n; i++)
        [parts addObject:lua_text(luaL_tolstring(L, i, nullptr)) ?: @"?"];
    rexui_log([@"rui-config.lua: " stringByAppendingString:[parts componentsJoinedByString:@" "]]);
    return 0;
}

static NSString* as_text(lua_State* L, int i) {
    switch (lua_type(L, i)) {
    case LUA_TBOOLEAN:
        return lua_toboolean(L, i) ? @"true" : @"false";
    case LUA_TNUMBER:
        if (lua_isinteger(L, i))
            return [NSString stringWithFormat:@"%lld", (long long)lua_tointeger(L, i)];
        return [NSString stringWithFormat:@"%.14g", lua_tonumber(L, i)];
    case LUA_TSTRING:
        return lua_text(lua_tostring(L, i));
    case LUA_TTABLE: {
        NSMutableArray* parts = [NSMutableArray array];
        lua_Integer n = (lua_Integer)lua_rawlen(L, i), keys = 0;
        for (lua_pushnil(L); lua_next(L, i); lua_pop(L, 1))
            keys++;
        if (keys != n)
            return nil;
        for (lua_Integer k = 1; k <= n; k++) {
            lua_rawgeti(L, i, k);
            NSString* t = lua_type(L, -1) == LUA_TTABLE ? nil : as_text(L, lua_gettop(L));
            lua_pop(L, 1);
            if (!t)
                return nil;
            [parts addObject:t];
        }
        return [parts componentsJoinedByString:@","];
    }
    default:
        return nil;
    }
}

static NSDictionary<NSString*, NSString*>* read_lua(NSString* path, NSString** error) {
    size_t used = 0;
    lua_State* L = lua_newstate(capped_alloc, &used);
    if (!L) {
        *error = @"rui-config.lua: no memory for Lua";
        return nil;
    }
    const struct {
        const char* name;
        lua_CFunction open;
    } libs[] = {
        {"_G", luaopen_base},
        {LUA_STRLIBNAME, luaopen_string},
        {LUA_TABLIBNAME, luaopen_table},
        {LUA_MATHLIBNAME, luaopen_math},
        {LUA_UTF8LIBNAME, luaopen_utf8},
    };
    for (auto& lib : libs) {
        luaL_requiref(L, lib.name, lib.open, 1);
        lua_pop(L, 1);
    }
    for (const char* name : {"dofile", "loadfile"}) {
        lua_pushnil(L);
        lua_setglobal(L, name);
    }
    lua_pushcfunction(L, log_print);
    lua_setglobal(L, "print");
    lua_sethook(L, stop_runaway, LUA_MASKCOUNT, 10000000);
    NSMutableDictionary* out = nil;
    if (luaL_loadfilex(L, path.fileSystemRepresentation, "t") != LUA_OK || lua_pcall(L, 0, 1, 0) != LUA_OK) {
        *error = lua_text(lua_tostring(L, -1)) ?: @"error";
    } else if (!lua_istable(L, -1)) {
        *error =
            [path.lastPathComponent stringByAppendingString:@": returns no table (return { option = value, ... })"];
    } else {
        out = [NSMutableDictionary dictionary];
        lua_pushnil(L);
        while (lua_next(L, -2)) {
            if (lua_type(L, -2) == LUA_TSTRING) {
                NSString* key = [lua_text(lua_tostring(L, -2)) stringByReplacingOccurrencesOfString:@"_"
                                                                                         withString:@"-"];
                if (!key)
                    rexui_log(@"rui-config.lua: a key that isn't UTF-8");
                else if (NSString* v = as_text(L, lua_gettop(L)))
                    out[key] = v;
                else
                    rexui_log([NSString
                        stringWithFormat:@"rui-config.lua: %@ isn't true/false, a number, a string or a list of them",
                                         key]);
            }
            lua_pop(L, 1);
        }
    }
    lua_close(L);
    return out;
}

static bool parse_pair(NSString* text, CGFloat* a, CGFloat* b, double max) {
    NSArray<NSString*>* parts = [text componentsSeparatedByString:@","];
    if (parts.count > 2)
        return false;
    double v[2] = {0, 0};
    for (NSUInteger i = 0; i < parts.count; i++) {
        NSScanner* scan = [NSScanner scannerWithString:parts[i]];
        if (![scan scanDouble:&v[i]] || !scan.isAtEnd || v[i] < 0 || v[i] > max)
            return false;
    }
    if (parts.count == 1)
        v[1] = v[0];
    *a = v[0], *b = v[1];
    return true;
}

static bool parse_bool(NSString* text, bool* out) {
    NSString* t = text.lowercaseString;
    if ([@[@"true", @"yes", @"on", @"1"] containsObject:t])
        return *out = true, true;
    if ([@[@"false", @"no", @"off", @"0"] containsObject:t])
        return *out = false, true;
    return false;
}

static void parse_modifiers(NSString* text, NSEventModifierFlags* out) {
    NSDictionary<NSString*, NSNumber*>* names = @{
        @"cmd": @(NSEventModifierFlagCommand),
        @"command": @(NSEventModifierFlagCommand),
        @"super": @(NSEventModifierFlagCommand),
        @"ctrl": @(NSEventModifierFlagControl),
        @"control": @(NSEventModifierFlagControl),
        @"alt": @(NSEventModifierFlagOption),
        @"opt": @(NSEventModifierFlagOption),
        @"option": @(NSEventModifierFlagOption),
        @"shift": @(NSEventModifierFlagShift),
    };
    NSEventModifierFlags m = 0;
    for (NSString* part in [text.lowercaseString componentsSeparatedByString:@"+"]) {
        NSNumber* f = names[[part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]];
        if (!f)
            return;
        m |= f.unsignedLongValue;
    }
    if (m)
        *out = m;
}

static void parse_curve(NSString* text, double out[4]) {
    NSArray<NSString*>* parts = [text componentsSeparatedByString:@","];
    double v[4];
    bool ok = parts.count == 4;
    for (NSUInteger i = 0; ok && i < 4; i++) {
        NSScanner* scan = [NSScanner
            scannerWithString:[parts[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]];
        ok = [scan scanDouble:&v[i]] && scan.isAtEnd && v[i] >= -2 && v[i] <= 3;
    }
    if (ok && v[0] >= 0 && v[0] <= 1 && v[2] >= 0 && v[2] <= 1)
        std::copy(v, v + 4, out);
}

bool load_config(void) {
    static bool loaded;
    static NSString* last_path;
    static NSDate* last_mtime;
    NSString* path = config_path();
    NSDate* mtime = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil].fileModificationDate;
    if (loaded && [path isEqualToString:last_path] && (mtime == last_mtime || [mtime isEqual:last_mtime])) {
        return false;
    }
    loaded = true;
    last_path = path;
    last_mtime = mtime;
    NSDictionary<NSString*, NSString*>* values = @{};
    if (mtime) {
        NSString* error = nil;
        values = read_lua(path, &error);
        if (!values) {
            rexui_log([@"config: " stringByAppendingString:error]);
            return false;
        }
    }
    Config c;
    c.values = values;
    for (NSString* key in values) {
        NSString* value = values[key];
        CGFloat a, b;
        bool flag;
        if ([key isEqualToString:@"transparency"]) {
            if (parse_bool(value, &flag))
                c.transparency = flag;
        } else if ([key isEqualToString:@"tab-preview-zoom"]) {
            if (parse_pair(value, &a, &b, 8) && a == b && a >= 1)
                c.tab_preview_zoom = a;
        } else if ([key isEqualToString:@"background-opacity"]) {
            if (parse_pair(value, &a, &b, 1) && a == b)
                c.opacity = a;
        } else if ([key isEqualToString:@"background-blur"]) {
            if (parse_pair(value, &a, &b, 100) && a == b)
                c.blur = int(lround(a));
            else if (parse_bool(value, &flag))
                c.blur = flag ? 20 : 0;
        } else if ([key isEqualToString:@"traffic-lights"]) {
            if (parse_bool(value, &flag))
                c.traffic_lights = flag;
        } else if ([key isEqualToString:@"tab-bar"]) {
            if (parse_bool(value, &flag))
                c.tab_bar = flag;
        } else if ([key isEqualToString:@"session-keys"]) {
            if (parse_bool(value, &flag))
                c.session_keys = flag;
        } else if ([key isEqualToString:@"pane-buttons"]) {
            if (parse_bool(value, &flag))
                c.pane_buttons = flag;
        } else if ([key isEqualToString:@"pane-scrollbars"]) {
            if (parse_bool(value, &flag))
                c.pane_scrollbars = flag;
        } else if ([key isEqualToString:@"pane-scroll"]) {
            if ([@[@"smooth", @"rex"] containsObject:value.lowercaseString])
                c.pane_scroll_smooth = [value.lowercaseString isEqualToString:@"smooth"];
        } else if ([key isEqualToString:@"pane-scroll-lines"]) {
            if (parse_pair(value, &a, &b, 50) && a == b && a > 0)
                c.pane_scroll_lines = a;
        } else if ([key isEqualToString:@"pane-scroll-duration"]) {
            if (parse_pair(value, &a, &b, 2000) && a == b)
                c.pane_scroll_ms = a;
        } else if ([key isEqualToString:@"pane-scroll-trackpad-duration"]) {
            if (parse_pair(value, &a, &b, 2000) && a == b)
                c.pane_scroll_trackpad_ms = a;
        } else if ([key isEqualToString:@"pane-scroll-speed"]) {
            if (parse_pair(value, &a, &b, 10) && a == b && a > 0)
                c.pane_scroll_speed = a;
        } else if ([key isEqualToString:@"pane-scroll-bounce"]) {
            if (parse_bool(value, &flag))
                c.pane_scroll_bounce = flag;
        } else if ([key isEqualToString:@"pane-scroll-bounce-size"]) {
            if (parse_pair(value, &a, &b, 1000) && a == b)
                c.pane_scroll_bounce_size = a;
        } else if ([key isEqualToString:@"pane-scroll-bounce-spring"]) {
            if (parse_pair(value, &a, &b, 60) && a >= 1 && b >= 0.05 && b <= 2)
                c.pane_scroll_bounce_spring[0] = a, c.pane_scroll_bounce_spring[1] = b;
        } else if ([key isEqualToString:@"app-icon"]) {
            c.app_icon = [@[@"none", @"false", @"rex"] containsObject:value.lowercaseString] ? @"" : value;
        } else if ([key isEqualToString:@"loading-screen"]) {
            c.loading_screen = [@[@"none", @"false"] containsObject:value.lowercaseString] ? @"" : value;
        } else if ([key isEqualToString:@"loading-max"]) {
            if (parse_pair(value, &a, &b, 120) && a == b && a >= 1)
                c.loading_max = a;
        } else if ([key isEqualToString:@"app-icon-fps"]) {
            if (parse_pair(value, &a, &b, 60) && a == b && a >= 1)
                c.app_icon_fps = a;
        } else if ([key isEqualToString:@"cursor"]) {
            c.cursor = [@[@"none", @"false", @"macos"] containsObject:value.lowercaseString] ? @"" : value;
        } else if ([key isEqualToString:@"cursor-size"]) {
            if (parse_pair(value, &a, &b, 256) && a == b && a >= 8)
                c.cursor_size = a;
        } else if ([key isEqualToString:@"cursor-fps"]) {
            if (parse_pair(value, &a, &b, 60) && a == b && a >= 1)
                c.cursor_fps = a;
        } else if ([key isEqualToString:@"notifications"]) {
            if ([@[@"rex", @"rexui"] containsObject:value.lowercaseString])
                c.notifications = value.lowercaseString;
        } else if ([key isEqualToString:@"file-manager"]) {
            if ([@[@"finder", @"rexui"] containsObject:value.lowercaseString])
                c.file_manager = value.lowercaseString;
        } else if ([key isEqualToString:@"rex-windows"]) {
            if ([@[@"rex", @"rexui"] containsObject:value.lowercaseString])
                c.rex_windows = value.lowercaseString;
        } else if ([key isEqualToString:@"notifications-system"]) {
            if ([@[@"inactive", @"always", @"never"] containsObject:value.lowercaseString])
                c.notifications_system = value.lowercaseString;
        } else if ([key isEqualToString:@"single-window"]) {
            if (parse_bool(value, &flag))
                c.single_window = flag;
        } else if ([key isEqualToString:@"ui"]) {
            if (parse_bool(value, &flag))
                c.ui = flag;
        } else if ([key isEqualToString:@"window-padding-x"]) {
            if (parse_pair(value, &a, &b, 1000))
                c.left = a, c.right = b;
        } else if ([key isEqualToString:@"window-padding-y"]) {
            if (parse_pair(value, &a, &b, 1000))
                c.top = a, c.bottom = b;
        } else if ([key isEqualToString:@"background-gif"]) {
            c.gif = value.length ? value.stringByExpandingTildeInPath : nil;
        } else if ([key isEqualToString:@"background-gif-visible"]) {
            if (parse_bool(value, &flag))
                c.gif_visible = flag;
        } else if ([key isEqualToString:@"background-gif-height"]) {
            if (parse_pair(value, &a, &b, 4000) && a == b && a > 0)
                c.gif_height = a;
        } else if ([key isEqualToString:@"background-gif-margin"]) {
            if (parse_pair(value, &a, &b, 1000) && a == b)
                c.gif_margin = a;
        } else if ([key isEqualToString:@"background-gif-opacity"]) {
            if (parse_pair(value, &a, &b, 1) && a == b)
                c.gif_opacity = a;
        } else if ([key isEqualToString:@"background-gif-position"]) {
            NSDictionary<NSString*, NSNumber*>* corners = @{
                @"top-left": @(int(Corner::top_left)),
                @"top-right": @(int(Corner::top_right)),
                @"bottom-left": @(int(Corner::bottom_left)),
                @"bottom-right": @(int(Corner::bottom_right)),
                @"center": @(int(Corner::center)),
            };
            if (NSNumber* n = corners[value])
                c.gif_corner = Corner(n.intValue);
        } else if ([key isEqualToString:@"language"]) {
            NSString* l = value.lowercaseString;
            if ([l isEqualToString:@"auto"] ||
                [l rangeOfString:@"^[a-z]{2,3}$" options:NSRegularExpressionSearch].location != NSNotFound)
                c.language = l;
        } else if ([key isEqualToString:@"locales"]) {
            NSMutableArray* list = [NSMutableArray array];
            for (NSString* p in [value componentsSeparatedByString:@","]) {
                NSString* t = [p stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                if (t.length)
                    [list addObject:t];
            }
            c.locales = list;
        } else if ([key isEqualToString:@"pane-shader-unfocused-fps"]) {
            if (parse_pair(value, &a, &b, 120) && a == b && a >= 0)
                c.pane_shader_unfocused_fps = a;
        } else if ([key isEqualToString:@"power-saving"]) {
            if (parse_bool(value, &flag))
                c.power_saving = flag;
        } else if ([key isEqualToString:@"lazy-layers"]) {
            if (parse_bool(value, &flag))
                c.lazy_layers = flag;
        } else if ([key isEqualToString:@"budget-engine-ms"]) {
            if (parse_pair(value, &a, &b, 1000) && a == b && a >= 0)
                c.budget_engine_ms = a;
        } else if ([key isEqualToString:@"budget-layers"]) {
            if (parse_pair(value, &a, &b, 1000000) && a == b && a >= 0)
                c.budget_layers = a;
        } else if ([key isEqualToString:@"shader-pacing"]) {
            NSString* v = [value isKindOfClass:NSString.class] ? [(NSString*)value lowercaseString] : @"";
            NSUInteger i = [@[@"even", @"atleast", @"exact"] indexOfObject:v];
            if (i != NSNotFound)
                c.shader_pacing = (int)i;
        } else if ([key isEqualToString:@"tab-slide"]) {
            if (parse_bool(value, &flag))
                c.tab_slide = flag;
        } else if ([key isEqualToString:@"tab-slide-axis"]) {
            NSString* v = [value isKindOfClass:NSString.class] ? [(NSString*)value lowercaseString] : @"";
            if ([v isEqualToString:@"vertical"] || [v isEqualToString:@"horizontal"])
                c.tab_slide_vertical = [v isEqualToString:@"vertical"];
        } else if ([key isEqualToString:@"tab-slide-duration"]) {
            if (parse_pair(value, &a, &b, 5000) && a == b)
                c.tab_slide_ms = a;
        } else if ([key isEqualToString:@"tab-slide-curve"]) {
            parse_curve(value, c.tab_slide_curve);
        } else if ([key isEqualToString:@"pane-motion"]) {
            NSString* v = value.lowercaseString;
            if ([v isEqualToString:@"rex"])
                c.pane_motion = 2;
            else if ([v isEqualToString:@"rexui"])
                c.pane_motion = 1;
            else if ([v isEqualToString:@"none"])
                c.pane_motion = 0;
            else if (parse_bool(value, &flag))
                c.pane_motion = flag ? 1 : 0;
        } else if ([key isEqualToString:@"focus-ring"]) {
            if (parse_bool(value, &flag))
                c.focus_ring = flag;
        } else if ([key isEqualToString:@"link-in-pane"]) {
            if (parse_bool(value, &flag))
                c.link_in_pane = flag;
        } else if ([key isEqualToString:@"pane-web-focus"]) {
            if (parse_bool(value, &flag))
                c.pane_web_focus = flag;
        } else if ([key isEqualToString:@"pane-inherit"]) {
            if (parse_bool(value, &flag))
                c.pane_inherit = flag ? @[@"bg", @"media", @"mediaKind", @"shape", @"dim", @"blur"] : @[];
            else {
                NSMutableArray* list = [NSMutableArray array];
                for (NSString* p in [value componentsSeparatedByString:@","]) {
                    NSString* t = [p stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                    if (t.length)
                        [list addObject:t];
                }
                c.pane_inherit = list;
            }
        } else if ([key isEqualToString:@"pane-resize"]) {
            if (parse_bool(value, &flag))
                c.pane_resize = flag;
        } else if ([key isEqualToString:@"pane-glide"]) {
            if (parse_bool(value, &flag))
                c.pane_glide = flag;
        } else if ([key isEqualToString:@"pane-glide-duration"]) {
            if (parse_pair(value, &a, &b, 5000) && a == b)
                c.pane_glide_ms = a;
        } else if ([key isEqualToString:@"pane-glide-curve"]) {
            parse_curve(value, c.pane_glide_curve);
        } else if ([key isEqualToString:@"pane-drag"]) {
            if (parse_bool(value, &flag))
                c.pane_drag = flag;
        } else if ([key isEqualToString:@"pane-drag-modifier"]) {
            parse_modifiers(value, &c.pane_drag_modifier);
        } else if ([key isEqualToString:@"pane-drag-dry-run"]) {
            if (parse_bool(value, &flag))
                c.pane_drag_dry_run = flag;
        } else if ([key isEqualToString:@"pane-lane"]) {
            if (parse_bool(value, &flag))
                c.pane_lane = flag;
        } else if ([key isEqualToString:@"web-scrollbars"]) {
            if (parse_bool(value, &flag))
                c.web_scrollbars = flag;
        } else if ([key isEqualToString:@"web-resize"]) {
            NSString* v =
                [value stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\"' "]];
            if ([v isEqualToString:@"steps"])
                c.web_resize = WebResize::steps;
            else if ([v isEqualToString:@"stretch"])
                c.web_resize = WebResize::stretch;
            else if ([v isEqualToString:@"live"])
                c.web_resize = WebResize::live;
        } else if ([key isEqualToString:@"pane-keep"]) {
            if (parse_bool(value, &flag))
                c.pane_keep = flag;
        } else if ([key isEqualToString:@"pane-drop-links"]) {
            if (parse_bool(value, &flag))
                c.pane_drop_links = flag;
        } else if ([key isEqualToString:@"rex-sidebar"]) {
            if (parse_bool(value, &flag))
                c.rex_sidebar = flag;
        } else if ([key isEqualToString:@"quit-key"]) {
            c.quit_key =
                [value stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\"' "]];
        } else if ([key isEqualToString:@"pane-fullscreen-key"]) {
            c.pane_fullscreen_key =
                [value stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\"' "]];
        } else if ([key isEqualToString:@"pane-raw-mouse"]) {
            if (parse_bool(value, &flag))
                c.pane_raw_mouse = flag;
        } else if ([key isEqualToString:@"pane-raw-mouse-scale"]) {
            if (parse_pair(value, &a, &b, 100) && a == b && a > 0)
                c.pane_raw_mouse_scale = a;
        }
    }
    if (const char* e = getenv("REXUI_NO_UI"); e && e[0] == '1')
        c.ui = false;
    g_config = c;
    g_config_generation++;
    return true;
}
