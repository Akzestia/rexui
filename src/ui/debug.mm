// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "base/trace.h"
#include "chrome/chrome.h"
#include "rex/rex.h"
#include "ui/ui.h"

#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <signal.h>
#include <spawn.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <unistd.h>

extern char** environ;

static bool g_on;
static NSMutableArray<NSDictionary*>* g_console;
static long g_console_n;
static NSMapTable<RXDoc*, NSNumber*>* g_console_upto;
static bool g_console_cleared;
static NSDictionary *g_selected, *g_hovered;
const void* g_debug_sel_doc;
int g_debug_sel_uid = -1;
static long g_sel_revision;
static bool g_picking;
static NSMutableArray<NSString*>* g_edited;
static NSDictionary* g_look = @{};
static long g_revision;
long g_tree_reads;
double g_tree_last_ms;
static constexpr double k_tree_quiet = 20;
static NSMutableDictionary<NSString*, NSNumber*>* g_file_revisions;
static NSMutableDictionary<NSString*, NSNumber*>* g_tree_ready;
static NSMutableDictionary<NSString*, id>* g_sent;
static bool g_push_due;
static CALayer* g_hl;
static RXTextLayer* g_hl_label;
static __weak RXNode* g_hl_node;
static NSTimer* g_hl_timer;

static constexpr NSUInteger kConsoleMax = 1000, kConsoleSent = 500;

bool debug_picking(void) {
    return g_picking;
}

static NSDictionary* options(void) {
    return [g_state dictionaryForKey:@"debug options"] ?: @{};
}

NSString* debug_ui_dir(void) {
    NSString* conf = g_config.values[@"debug-ui"];
    if ([conf isEqualToString:@"none"] || [conf isEqualToString:@"false"])
        return nil;
    BOOL dir = NO;
    if (conf.length && ![conf isEqualToString:@"default"]) {
        NSString* p = conf.stringByExpandingTildeInPath;
        if (!p.isAbsolutePath)
            p = [ui_dir() stringByAppendingPathComponent:p];
        return [NSFileManager.defaultManager fileExistsAtPath:p isDirectory:&dir] && dir ? p : nil;
    }
    NSString* own = [ui_dir() stringByAppendingPathComponent:@"debug"];
    if ([NSFileManager.defaultManager fileExistsAtPath:own isDirectory:&dir] && dir)
        return own;
    NSString* home = NSProcessInfo.processInfo.environment[@"REXUI_HOME"]
        ?: [NSHomeDirectory() stringByAppendingPathComponent:@"rexui/build"];
    return [home.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"src/ui/devtools"];
}

static CFAbsoluteTime g_leaving;

bool debug_file_loads(NSString* name) {
    return g_on || CFAbsoluteTimeGetCurrent() < g_leaving || [name hasPrefix:@"hud"];
}

static RXDoc* doc_named(NSString* file) {
    if (!file.length)
        return nil;
    for (RXDoc* d in g_docs) {
        if ([d.path isEqualToString:file])
            return d;
    }
    for (RXDoc* d in g_docs) {
        if ([d.path.lastPathComponent isEqualToString:file])
            return d;
    }
    return nil;
}

static NSArray* docs_list(void) {
    NSMutableArray* out = [NSMutableArray array];
    for (RXDoc* d in g_docs) {
        RXNode* r = d.root;
        [out addObject:@{
            @"file": d.path.lastPathComponent ?: @"",
            @"path": d.path ?: @"",
            @"type": r.type ?: @"",
            @"side": r && is_elem(r, E::Dock) ? str(r, P::side, @"right") : @"",
            @"nodes": @(d.nodes.count),
            @"error": d.error ?: @"",
            @"devtools": @(d.devtools),
            @"pane": @(d.pane),
            @"root": @(r ? r.uid : 0)
        }];
    }
    return out;
}

static NSArray* console_tail(void) {
    NSUInteger n = g_console.count;
    return n > kConsoleSent ? [g_console subarrayWithRange:NSMakeRange(n - kConsoleSent, kConsoleSent)] : [g_console copy] ?: @[];
}

static NSMutableDictionary<NSString*, NSNumber*>* g_here;

static void push_soon(void);

static NSMutableDictionary<NSString*, NSNumber*>* g_opening;
static NSMutableSet<NSString*>* g_floated;
static void opening(NSString* path) {
    if (!g_opening)
        g_opening = [NSMutableDictionary dictionary];
    g_opening[path.lastPathComponent] = @(CACurrentMediaTime());
}
static NSArray<NSString*>* paned_files(void) {
    NSMutableSet* out = [NSMutableSet set];
    double now = CACurrentMediaTime();
    for (NSString* f in g_opening.allKeys) {
        if (now - [g_opening[f] doubleValue] < 8)
            [out addObject:f];
        else
            [g_opening removeObjectForKey:f];
    }
    for (NSString* p in g_here)
        [out addObject:p.lastPathComponent];
    for (RXDoc* d in g_docs) {
        if (d.devtools && d.pane) {
            [out addObject:d.path.lastPathComponent];
            [g_opening removeObjectForKey:d.path.lastPathComponent];
        }
    }
    if ([out containsObject:@"Devtools.rui"])
        [out addObjectsFromArray:@[@"elements.rui", @"console.rui"]];
    return out.allObjects;
}

static bool paned(void) {
    if (g_here.count)
        return true;
    for (RXDoc* d in g_docs) {
        if (d.devtools && d.pane)
            return true;
    }
    return false;
}

static NSString* last_agent(void);
static long g_picked;

static NSDictionary* state(bool with_console) {
    NSMutableDictionary* s = [@{
        @"enabled": @(g_on),
        @"options": options(),
        @"docs": docs_list(),
        @"selected": g_selected ?: NSNull.null,
        @"hovered": g_hovered ?: NSNull.null,
        @"picking": @(g_picking),
        @"revision": @(g_revision),
        @"revisions": [g_file_revisions copy] ?: @{},
        @"theme": g_look,
        @"paned": @(paned()),
        @"agents": agent_list(),
        @"agentsFinding": @(agent_finding()),
        @"agentRunning": @(agent_running()),
        @"lastAgent": last_agent(),
        @"picked": @(g_picked),
        @"panedFiles": paned_files(),
        @"selectedRevision": @(g_sel_revision)
    } mutableCopy];
    if (with_console)
        s[@"console"] = console_tail();
    return s;
}

static void debug_set_enabled(bool on);
static bool doc_floating(RXDoc* d) {
    NSString* block = panes_block_of_doc(d);
    if (!block)
        return false;
    for (NSWindow* w in NSApp.windows) {
        NSView *chrome = chrome_of(w), *content = chrome ? chrome_content(chrome) : nil;
        const void *p = nullptr, *l = nullptr;
        if (content && rex_floating_pane((__bridge const void*)content, block.UTF8String, &p, &l))
            return true;
    }
    return false;
}
static bool reads_console(RXDoc* d) {
    return [doc_call(d, @"wantsConsole", @[]) boolValue];
}

void set_debug(RXDoc* doc) {
    if (!doc.ctx || !doc.wants_debug)
        return;
    NSMutableDictionary* s = [state(true) mutableCopy];
    s[@"here"] = @{
        @"path": doc.path ?: @"",
        @"pane": @(doc.pane),
        @"devtools": @(doc.devtools),
        @"floating": @(doc.pane && ([g_floated containsObject:doc.path.lastPathComponent ?: @""] || doc_floating(doc)))
    };
    if (!g_console_upto)
        g_console_upto = [NSMapTable weakToStrongObjectsMapTable];
    [g_console_upto setObject:@(g_console_n) forKey:doc];
    doc_call(doc, @"setDebug", @[s]);
}

static void open_in_pane(NSString* path, NSString* direction, NSString* side, NSString* anchor = nil) {
    if (!path.length || !g_session_id.length)
        return;
    opening(path);
    [g_floated removeObject:path.lastPathComponent];
    ui_open_pane(path, @{@"direction": direction, @"side": side, @"focus": @NO, @"anchor": anchor ?: @""}, nil);
}

static void open_floating(NSString* path, NSArray* bounds) {
    if (!path.length || !g_session_id.length)
        return;
    opening(path);
    if (!g_floated)
        g_floated = [NSMutableSet set];
    [g_floated addObject:path.lastPathComponent];
    if (bounds.count != 4)
        bounds = @[@0.2, @0.15, @0.6, @0.6];
    ui_open_pane(
        path,
        @{@"floating": @YES,
          @"bounds": bounds,
          @"focus": @NO},
        ^{
            [g_opening removeObjectForKey:path.lastPathComponent];
            push_soon();
        });
    push_soon();
}

static void open_here(NSString* path, NSString* in_block = nil) {
    if (NSString* name = path.lastPathComponent)
        [g_floated removeObject:name];
    NSDictionary* b = in_block.length ? nil : panes_last_block();
    NSString *block = in_block.length ? in_block : b[@"block"],
             *session = in_block.length ? g_session_id : b[@"session"];
    if (!path.length || ![block hasPrefix:@"block:"]) {
        rexui_log(@"debug: no focused pane to open the tools in");
        return;
    }
    __block pid_t pid = 0;
    pid = ui_pane_here(path, block, session, ^{
        if ([g_here[path] intValue] == pid)
            [g_here removeObjectForKey:path];
        push_soon();
    });
    if (!pid)
        return;
    if (!g_here)
        g_here = [NSMutableDictionary dictionary];
    g_here[path] = @(pid);
    push_soon();
}

static void close_pane_of(RXDoc* doc) {
    if (NSNumber* pid = g_here[doc.path]) {
        kill(pid.intValue, SIGTERM);
        return;
    }
    NSString* block = doc.pane ? panes_block_of_doc(doc) : nil;
    if (!block.length || !g_session_id.length)
        return;
    NSString* json = [[NSString alloc] initWithData:json_data(@{@"session_id": g_session_id, @"block_id": block}, 0)
                                           encoding:NSUTF8StringEncoding];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        rex_cli(@[@"api", @"call", @"block.close", json], nil);
    });
}

static void push(void) {
    g_push_due = false;
    bool any = false;
    for (RXDoc* d in g_docs)
        any |= d.ctx && d.wants_debug;
    if (!any) {
        g_sent = nil;
        return;
    }
    NSDictionary* now = state(false);
    NSMutableDictionary* changed = [NSMutableDictionary dictionary];
    for (NSString* k in now) {
        if (![now[k] isEqual:g_sent[k]])
            changed[k] = now[k];
    }
    g_sent = [now mutableCopy];
    const bool cleared = g_console_cleared;
    g_console_cleared = false;
    for (RXDoc* d in [g_docs copy]) {
        if (!d.ctx || !d.wants_debug)
            continue;
        NSMutableDictionary* mine = [changed mutableCopy];
        if (reads_console(d)) {
            const long upto = [[g_console_upto objectForKey:d] longValue];
            if (cleared)
                mine[@"console"] = console_tail();
            else if (upto < g_console_n) {
                NSUInteger from = g_console.count;
                while (from > 0 && [g_console[from - 1][@"n"] longValue] > upto
                       && g_console.count - from < kConsoleSent)
                    from--;
                mine[@"consoleAdd"] = [g_console subarrayWithRange:NSMakeRange(from, g_console.count - from)];
            }
            [g_console_upto setObject:@(g_console_n) forKey:d];
        }
        if (mine.count)
            doc_call(d, @"setDebug", @[mine]);
    }
}

static void push_soon(void) {
    if (g_push_due)
        return;
    g_push_due = true;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        push();
    });
}

static NSMutableSet<NSString*>* g_changed;
static void changed_soon(double after) {
    static bool due;
    if (due)
        return;
    due = true;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(after * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        due = false;
        g_revision++;
        const double now = CACurrentMediaTime();
        double next = 0;
        for (NSString* path in [g_changed copy]) {
            const double ready = [g_tree_ready[path] doubleValue];
            if (ready > now) {
                next = next > 0 ? MIN(next, ready - now) : ready - now;
                continue;
            }
            g_file_revisions[path] = @([g_file_revisions[path] longValue] + 1);
            [g_changed removeObject:path];
        }
        push_soon();
        if (next > 0)
            changed_soon(MAX(0.25, next));
    });
}
void debug_changed(RXDoc* doc) {
    if (!g_docs.count || doc.devtools)
        return;
    if (g_on && doc.path) {
        if (!g_changed)
            g_changed = [NSMutableSet set], g_file_revisions = [NSMutableDictionary dictionary],
            g_tree_ready = [NSMutableDictionary dictionary];
        [g_changed addObject:doc.path];
    }
    changed_soon(0.25);
}

void debug_console_add(NSString* file, NSString* level, NSString* text) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            debug_console_add(file, level, text);
        });
        return;
    }
    if (!g_console)
        g_console = [NSMutableArray array];
    static constexpr NSUInteger k_line_max = 16384;
    if (text.length > k_line_max) {
        const NSUInteger total = text.length;
        text = [[text substringToIndex:[text rangeOfComposedCharacterSequenceAtIndex:k_line_max].location]
            stringByAppendingFormat:@"… (%lu characters in all)", (unsigned long)total];
    }
    if (!file) {
        NSRange r = [text rangeOfString:@".rui: "];
        if (r.location != NSNotFound && [text rangeOfString:@" "].location > r.location) {
            file = [text substringToIndex:r.location + 4];
            text = [text substringFromIndex:r.location + 6];
        }
    }
    [g_console addObject:@{
        @"n": @(++g_console_n),
        @"t": @(round(NSDate.date.timeIntervalSince1970 * 1000)),
        @"file": file ?: @"",
        @"level": level ?: @"info",
        @"text": text ?: @""
    }];
    if (g_console.count > kConsoleMax)
        [g_console removeObjectsInRange:NSMakeRange(0, g_console.count - kConsoleMax)];
    push_soon();
}

static NSString* label_of(RXNode* n) {
    NSString* id = [obj(n, @"id") isKindOfClass:NSString.class] ? obj(n, @"id") : nil;
    CGSize s = n.layer.bounds.size;
    return [NSString stringWithFormat:@"%@%@  %g × %g", n.type, id.length ? [@"#" stringByAppendingString:id] : @"",
                                      round(s.width), round(s.height)];
}

static void place_highlight(void) {
    RXNode* n = g_hl_node;
    id<RXHost> h = n ? host_of(n) : nil;
    if (!n.layer || !h.layer || !n.layer.superlayer) {
        [g_hl removeFromSuperlayer];
        return;
    }
    if (!g_hl) {
        g_hl = still([RXLayer layer]);
        g_hl.zPosition = 1e6;
        g_hl.borderWidth = 1;
        g_hl_label = (RXTextLayer*)still([RXTextLayer layer]);
        g_hl_label.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightMedium];
        g_hl_label.color = NSColor.whiteColor;
        g_hl_label.cornerRadius = 3;
        g_hl_label.contentsScale = backing_scale();
        [g_hl addSublayer:g_hl_label];
    }
    NSColor* accent = ui_accent() ?: NSColor.controlAccentColor;
    CGRect r = [n.layer convertRect:n.layer.bounds toLayer:h.layer];
    NSString* text = label_of(n);
    if (g_hl.superlayer == h.layer && CGRectEqualToRect(g_hl.frame, r) && [g_hl_label.text isEqualToString:text])
        return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (g_hl.superlayer != h.layer)
        [h.layer addSublayer:g_hl];
    g_hl.frame = r;
    g_hl.backgroundColor = [accent colorWithAlphaComponent:0.18].CGColor;
    g_hl.borderColor = accent.CGColor;
    g_hl_label.text = text;
    g_hl_label.backgroundColor = [accent colorWithAlphaComponent:0.92].CGColor;
    CGSize ls =
        CGSizeMake(ceil([g_hl_label.text sizeWithAttributes:@{NSFontAttributeName: g_hl_label.font}].width) + 10, 16);
    CGFloat y = r.origin.y >= ls.height + 2 ? -ls.height - 2 : 2;
    g_hl_label.frame = CGRectMake(0, y, ls.width, ls.height);
    [g_hl_label setNeedsDisplay];
    [CATransaction commit];
}

static void highlight(RXNode* n) {
    g_hl_node = n;
    [g_hl_timer invalidate];
    g_hl_timer = nil;
    if (!n) {
        [g_hl removeFromSuperlayer];
        return;
    }
    place_highlight();
    g_hl_timer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                 repeats:YES
                                                   block:^(NSTimer* t) {
                                                       if (!g_hl_node) {
                                                           [t invalidate];
                                                           [g_hl removeFromSuperlayer];
                                                           return;
                                                       }
                                                       place_highlight();
                                                   }];
}

static RXNode* node_in(NSDictionary* a) {
    RXDoc* d = doc_named([a[@"file"] isKindOfClass:NSString.class] ? a[@"file"] : nil);
    return d.nodes[@(int_of(a[@"uid"]))];
}

static NSDictionary* ref(RXNode* n) {
    return n.doc ? @{@"file": n.doc.path ?: @"", @"uid": @(n.uid)} : nil;
}
static void select_node(RXNode* n) {
    g_selected = ref(n);
    g_debug_sel_doc = g_selected ? (__bridge const void*)n.doc : nullptr;
    g_debug_sel_uid = g_selected ? n.uid : -1;
}
void debug_selected_changed(void) {
    static bool due;
    if (due || !g_on)
        return;
    due = true;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        due = false;
        g_sel_revision++;
        push_soon();
    });
}

void debug_pick_hover(RXNode* n) {
    NSDictionary* r = ref(n);
    if ((r || g_hovered) && ![r isEqual:g_hovered]) {
        g_hovered = r;
        highlight(n);
        push_soon();
    }
}

void debug_pick_click(RXNode* n) {
    g_picking = false;
    g_hovered = nil;
    select_node(n);
    g_picked++;
    if (NSEvent* e = NSApp.currentEvent; e.window)
        g_context_at = e.locationInWindow;
    highlight(nil);
    push_soon();
}

static __weak RXDockView* g_pick_host;
static NSPoint g_pick_at;
void debug_pick_host(RXDockView* host, NSPoint p) {
    g_pick_host = host, g_pick_at = p;
}
void debug_flags_changed(NSEvent* e) {
    RXDockView* h = g_pick_host;
    if (!g_picking || !h.window)
        return;
    host_pointer(h, [h convertPoint:g_pick_at toView:nil]);
}

static void stop_picking(void) {
    g_picking = false;
    g_hovered = nil;
    highlight(nil);
    push_soon();
}

static NSDictionary* frame_of(RXNode* n) {
    NSRect r = node_window_rect(n);
    return @{
        @"x": @(round(r.origin.x)),
        @"y": @(round(r.origin.y)),
        @"width": @(round(r.size.width)),
        @"height": @(round(r.size.height))
    };
}

static void walk(RXNode* n, int depth, NSDictionary* outline, NSMutableArray* out) {
    NSArray* o = outline[[NSString stringWithFormat:@"%d", n.uid]];
    CGSize s = n.layer.bounds.size;
    [out addObject:@{
        @"uid": @(n.uid),
        @"type": n.type ?: @"",
        @"depth": @(depth),
        @"children": @(n.children.count),
        @"id": o.count > 0 ? o[0] : @"",
        @"comp": o.count > 1 ? o[1] : @"",
        @"file": o.count > 2 ? o[2] : @"",
        @"line": o.count > 3 ? o[3] : @0,
        @"visible": @(flag(n, P::visible, true) && !(n.layer && n.layer.hidden)),
        @"width": @(round(s.width)),
        @"height": @(round(s.height))
    }];
    for (RXNode* c in n.children)
        walk(c, depth + 1, outline, out);
}

static NSArray* tree(RXDoc* d) {
    if (!d.root)
        return @[];
    const double t0 = CACurrentMediaTime();
    NSDictionary* outline = d.ctx ? dict_of(doc_call(d, @"debugOutline", @[])) : @{};
    NSMutableArray* out = [NSMutableArray array];
    walk(d.root, 0, outline, out);
    const double now = CACurrentMediaTime();
    if (g_tree_ready && d.path)
        g_tree_ready[d.path] = @(now + MIN(5.0, (now - t0) * k_tree_quiet));
    g_tree_reads++;
    return out;
}

static void walk_rows(RXNode* n, int depth, std::vector<rx::engine::core::TreeRow>& out) {
    const CGSize s = n.layer.bounds.size;
    out.push_back({uint32_t(n.uid), depth, uint32_t(n.children.count), float(round(s.width)), float(round(s.height)),
                   flag(n, P::visible, true) && !(n.layer && n.layer.hidden) ? 1u : 0u});
    for (RXNode* c in n.children)
        walk_rows(c, depth + 1, out);
}

id debug_tree_rows(NSString* file) {
    RXDoc* d = doc_named(file);
    if (!d.root || !d.engine)
        return nil;
    const double t0 = CACurrentMediaTime();
    static std::vector<rx::engine::core::TreeRow> rows;
    rows.clear();
    walk_rows(d.root, 0, rows);
    id answer = engine_tree_rows(d, rows.data(), rows.size());
    const double now = CACurrentMediaTime();
    g_tree_last_ms = (now - t0) * 1000;
    if (g_tree_ready && d.path)
        g_tree_ready[d.path] = @(now + MIN(5.0, (now - t0) * k_tree_quiet));
    g_tree_reads++;
    return answer;
}

static id plain(id v) {
    if (!v || [v isKindOfClass:NSString.class] || [v isKindOfClass:NSNumber.class])
        return v ?: NSNull.null;
    if ([v isKindOfClass:NSArray.class] || [v isKindOfClass:NSDictionary.class])
        return [NSJSONSerialization isValidJSONObject:v] ? v : [v description];
    return [v description];
}

static NSDictionary* inspect(RXDoc* d, int uid) {
    RXNode* n = d.nodes[@(uid)];
    if (!n || !d.ctx)
        return nil;
    NSMutableDictionary* out =
        [dict_of(doc_call(d, @"debugInspect", @[@(uid)])) mutableCopy] ?: [NSMutableDictionary dictionary];
    out[@"frame"] = frame_of(n);
    out[@"file"] = out[@"file"] ?: d.path.lastPathComponent;
    out[@"path"] = d.path;
    NSMutableDictionary* native = [NSMutableDictionary dictionary];
    NSDictionary* props = props_dict(n);
    for (NSString* k in props)
        native[k] = plain(props[k]);
    out[@"native"] = native;
    NSMutableDictionary* drawn = [NSMutableDictionary dictionary];
    if (CALayer* l = n.layer) {
        drawn[@"layer"] = NSStringFromClass(l.class);
        drawn[@"opacity"] = @(l.opacity);
        drawn[@"hidden"] = @(l.hidden);
        drawn[@"onScreen"] = @(node_on_screen(n));
        if (l.mask)
            drawn[@"mask"] = NSStringFromClass(l.mask.class);
        drawn[@"sublayers"] = @(l.sublayers.count);
    }
    if (n.view)
        drawn[@"view"] = NSStringFromClass(n.view.class);
    if (n.pid)
        drawn[@"pid"] = @(n.pid);
    out[@"drawn"] = drawn;
    return out;
}

struct Usage {
    double cpu, mem;
};

static double mach_ms(uint64_t t) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom)
        mach_timebase_info(&tb);
    return (double)t * tb.numer / tb.denom / 1e6;
}

static Usage usage_of(pid_t pid, NSMutableDictionary<NSNumber*, NSArray*>* seen, double now) {
    rusage_info_v4 ri;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t*)&ri) != 0)
        return {-1, -1};
    double cpu_ms = mach_ms(ri.ri_user_time + ri.ri_system_time), cpu = -1;
    if (NSArray* last = seen[@(pid)]) {
        double dt = now - [last[0] doubleValue];
        if (dt > 0)
            cpu = MAX(0, (cpu_ms - [last[1] doubleValue]) / dt * 100);
    }
    seen[@(pid)] = @[@(now), @(cpu_ms)];
    return {cpu, ri.ri_phys_footprint / 1048576.0};
}

static NSDictionary* usage_dict(NSString* name, pid_t pid, Usage u) {
    return
        @{@"name": name ?: @"",
          @"pid": @(pid),
          @"cpu": @(round(u.cpu * 10) / 10),
          @"mem": @(round(u.mem * 10) / 10)};
}

static NSArray<NSString*>* args_of(pid_t pid) {
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
    size_t size = 0;
    if (sysctl(mib, 3, nullptr, &size, nullptr, 0) != 0 || size < sizeof(int))
        return nil;
    std::vector<char> buf(size);
    if (sysctl(mib, 3, buf.data(), &size, nullptr, 0) != 0)
        return nil;
    int argc;
    memcpy(&argc, buf.data(), sizeof argc);
    size_t i = sizeof argc;
    while (i < size && buf[i])
        i++;
    while (i < size && !buf[i])
        i++;
    NSMutableArray* out = [NSMutableArray array];
    while (i < size && (int)out.count < argc) {
        const char* a = buf.data() + i;
        size_t n = strnlen(a, size - i);
        [out addObject:[[NSString alloc] initWithBytes:a length:n encoding:NSUTF8StringEncoding] ?: @""];
        i += n + 1;
    }
    return out;
}

static NSDictionary* process_info(pid_t pid, NSString* name, NSString* role,
                                  NSMutableDictionary<NSNumber*, NSArray*>* seen, double now) {
    Usage u = usage_of(pid, seen, now);
    if (u.mem < 0)
        return nil;
    NSMutableDictionary* d = [usage_dict(name, pid, u) mutableCopy];
    d[@"role"] = role ?: @"";
    proc_taskinfo ti;
    if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, sizeof ti) == sizeof ti) {
        d[@"threads"] = @(ti.pti_threadnum);
        d[@"running"] = @(ti.pti_numrunning);
        d[@"resident"] = @(round(ti.pti_resident_size / 1048576.0));
        d[@"cpuTime"] = @(round(mach_ms(ti.pti_total_user + ti.pti_total_system) / 100) / 10);
    }
    proc_bsdinfo bi;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, sizeof bi) == sizeof bi) {
        d[@"started"] = @(bi.pbi_start_tvsec);
        d[@"ppid"] = @(bi.pbi_ppid);
    }
    std::vector<pid_t> kids(4096);
    int bytes = proc_listpids(PROC_PPID_ONLY, (uint32_t)pid, kids.data(), (int)(kids.size() * sizeof(pid_t)));
    int nkids = 0;
    for (int i = 0; i < MAX(0, bytes) / (int)sizeof(pid_t); i++)
        nkids += kids[i] > 0;
    d[@"children"] = @(nkids);
    int fdsize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nullptr, 0);
    if (fdsize > 0) {
        std::vector<proc_fdinfo> fds(fdsize / sizeof(proc_fdinfo) + 16);
        int got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds.data(), (int)(fds.size() * sizeof(proc_fdinfo)));
        int socks = 0;
        for (int i = 0; i < got / (int)sizeof(proc_fdinfo); i++)
            socks += fds[i].proc_fdtype == PROX_FDTYPE_SOCKET;
        d[@"sockets"] = @(socks);
    }
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(pid, path, sizeof path) > 0) {
        NSString* p = @(path);
        d[@"path"] = p;
        NSRange app = [p rangeOfString:@".app/Contents/MacOS/"];
        if (app.location != NSNotFound) {
            NSString* plist = [[p substringToIndex:app.location + 4] stringByAppendingString:@"/Contents/Info.plist"];
            NSDictionary* info = [NSDictionary dictionaryWithContentsOfFile:plist];
            NSString *shortv = info[@"CFBundleShortVersionString"], *build = info[@"CFBundleVersion"];
            if (shortv || build)
                d[@"version"] = shortv && build ? [NSString stringWithFormat:@"%@ (%@)", shortv, build] : shortv ?: build;
        }
        NSDate* built = [NSFileManager.defaultManager attributesOfItemAtPath:p error:nil].fileModificationDate;
        if (built && d[@"started"] && built.timeIntervalSince1970 > [d[@"started"] doubleValue] + 1)
            d[@"replaced"] = @YES;
    }
    NSArray* args = args_of(pid);
    if (args.count) {
        NSMutableArray* shown = [args mutableCopy];
        shown[0] = [args[0] lastPathComponent];
        d[@"command"] = [shown componentsJoinedByString:@" "];
    }
    return d;
}

static NSArray* thread_groups(double now) {
    static NSMutableDictionary<NSNumber*, NSArray*>* last = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSMutableDictionary*>* groups = [NSMutableDictionary dictionary];
    NSMutableDictionary* seen = [NSMutableDictionary dictionary];
    thread_act_array_t th;
    mach_msg_type_number_t n = 0;
    if (task_threads(mach_task_self(), &th, &n) != KERN_SUCCESS)
        return @[];
    thread_t main_thread = pthread_mach_thread_np(pthread_self());
    for (mach_msg_type_number_t i = 0; i < n; i++) {
        thread_extended_info_data_t ex;
        thread_identifier_info_data_t ident;
        mach_msg_type_number_t c = THREAD_EXTENDED_INFO_COUNT, ic = THREAD_IDENTIFIER_INFO_COUNT;
        if (thread_info(th[i], THREAD_EXTENDED_INFO, (thread_info_t)&ex, &c) == KERN_SUCCESS
            && thread_info(th[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&ident, &ic) == KERN_SUCCESS) {
            NSString* name = th[i] == main_thread ? @"main (AppKit, Rex's UI, rexui's layers)"
                : ex.pth_name[0]                  ? @(ex.pth_name)
                                                  : @"(unnamed: system workers)";
            double ms = (ex.pth_user_time + ex.pth_system_time) / 1e6, cpu = 0;
            NSArray* was = last[@(ident.thread_id)];
            if (was && now > [was[0] doubleValue])
                cpu = MAX(0, (ms - [was[1] doubleValue]) / (now - [was[0] doubleValue]) * 100);
            seen[@(ident.thread_id)] = @[@(now), @(ms)];
            NSMutableDictionary* g = groups[name]
                ?: (groups[name] =
                        [@{@"name": name,
                           @"count": @0,
                           @"running": @0,
                           @"cpu": @0.0,
                           @"total": @0.0} mutableCopy]);
            g[@"count"] = @([g[@"count"] intValue] + 1);
            g[@"running"] = @([g[@"running"] intValue] + (ex.pth_run_state == TH_STATE_RUNNING));
            g[@"cpu"] = @([g[@"cpu"] doubleValue] + cpu);
            g[@"total"] = @([g[@"total"] doubleValue] + ms / 1000);
        }
        mach_port_deallocate(mach_task_self(), th[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)th, n * sizeof(thread_act_t));
    [last setDictionary:seen];
    NSMutableArray* out = [NSMutableArray array];
    for (NSMutableDictionary* g in groups.allValues) {
        g[@"cpu"] = @(round([g[@"cpu"] doubleValue] * 10) / 10);
        g[@"total"] = @(round([g[@"total"] doubleValue] * 10) / 10);
        [out addObject:g];
    }
    return [out sortedArrayUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
        double x = [a[@"cpu"] doubleValue], y = [b[@"cpu"] doubleValue];
        if (x != y)
            return x > y ? NSOrderedAscending : NSOrderedDescending;
        return [b[@"total"] compare:a[@"total"]];
    }];
}

static NSArray<NSNumber*>* rex_server_pids(void) {
    static NSArray* cached;
    static double at;
    double now = CACurrentMediaTime();
    if (cached && now - at < 10)
        return cached;
    at = now;
    int n = proc_listallpids(nullptr, 0);
    std::vector<pid_t> pids(MAX(0, n) + 64);
    n = proc_listallpids(pids.data(), (int)(pids.size() * sizeof(pid_t)));
    NSMutableArray* out = [NSMutableArray array];
    char path[PROC_PIDPATHINFO_MAXSIZE];
    for (int i = 0; i < n; i++) {
        if (proc_pidpath(pids[i], path, sizeof path) > 0 && strstr(path, "/Rex Server.app/Contents/MacOS/"))
            [out addObject:@(pids[i])];
    }
    return cached = out;
}

static NSString* server_role(NSArray<NSString*>* args) {
    NSString* line = [[args subarrayWithRange:NSMakeRange(MIN(1, args.count), args.count - MIN(1, args.count))]
        componentsJoinedByString:@" "];
    if ([line hasPrefix:@"server run"])
        return @"server";
    if ([line hasPrefix:@"server logs"])
        return @"log follower";
    return line.length ? line : @"?";
}

static NSDictionary* perf(void) {
    static NSMutableDictionary<NSNumber*, NSArray*>* seen = [NSMutableDictionary dictionary];
    static NSMutableDictionary<NSString*, NSArray*>* js_seen = [NSMutableDictionary dictionary];
    double now = CACurrentMediaTime() * 1000;
    shader_gpu_timing(5);
    static NSMutableDictionary<NSString*, NSArray*>* gpu_seen = [NSMutableDictionary dictionary];
    pid_t self_pid = getpid();
    NSMutableDictionary* rex =
        [process_info(self_pid, @"Rex UI", @"this app", seen, now) mutableCopy] ?: [NSMutableDictionary dictionary];
    NSArray* threads = thread_groups(now);
    NSMutableArray* server = [NSMutableArray array];
    for (NSNumber* p in rex_server_pids()) {
        NSString* role = server_role(args_of(p.intValue) ?: @[]);
        if (NSMutableDictionary* d = [process_info(p.intValue, @"Rex Server", role, seen, now) mutableCopy]) {
            d[@"ours"] = @([d[@"ppid"] intValue] == self_pid);
            [server addObject:d];
        }
    }
    [server sortUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
        return [@(![a[@"role"] isEqual:@"server"]) compare:@(![b[@"role"] isEqual:@"server"])];
    }];
    NSMutableArray* docs = [NSMutableArray array];
    double js_total = 0;
    for (RXDoc* d in g_docs) {
        if (!d.ctx)
            continue;
        NSDictionary* st = dict_of(doc_call(d, @"stats", @[]));
        double ms = [st[@"ms"] doubleValue], calls = [st[@"calls"] doubleValue], evals = [st[@"evals"] doubleValue];
        NSArray* last = js_seen[d.path];
        double dt = last ? (now - [last[0] doubleValue]) / 1000 : 0;
        auto rate = [&](double v, int i) { return dt > 0 ? MAX(0, (v - [last[i] doubleValue]) / dt) : 0; };
        double ms_s = rate(ms, 1);
        js_seen[d.path] = @[@(now), @(ms), @(calls), @(evals)];
        double gpu_ns, gpu_passes;
        shader_gpu_totals(d, &gpu_ns, &gpu_passes);
        NSArray* glast = gpu_seen[d.path];
        double gdt = glast ? (now - [glast[0] doubleValue]) / 1000 : 0;
        double gpu_ms_s = gdt > 0 ? MAX(0, (gpu_ns - [glast[1] doubleValue]) / 1e6 / gdt) : 0;
        double gpu_passes_s = gdt > 0 ? MAX(0, (gpu_passes - [glast[2] doubleValue]) / gdt) : 0;
        gpu_seen[d.path] = @[@(now), @(gpu_ns), @(gpu_passes)];
        js_total += ms_s;
        NSMutableArray* backends = [NSMutableArray array];
        int natives = 0;
        for (RXNode* n in d.nodes.allValues) {
            if (n.view)
                natives++;
            if (!is_elem(n, E::Process) || !n.pid)
                continue;
            pid_t pid = n.pid;
            id command = obj(n, P::command);
            id first = [command isKindOfClass:NSArray.class] ? [command firstObject]
                : [command isKindOfClass:NSString.class]     ? [[command componentsSeparatedByString:@" "] firstObject]
                                                             : nil;
            NSString* name = [first isKindOfClass:NSString.class] && [first length] ? [first lastPathComponent] : @"?";
            [backends addObject:usage_dict(name, pid, usage_of(pid, seen, now))];
        }
        [docs addObject:@{
            @"file": d.path.lastPathComponent ?: @"",
            @"path": d.path ?: @"",
            @"devtools": @(d.devtools),
            @"pane": @(d.pane),
            @"ms": @(round(ms_s * 100) / 100),
            @"calls": @(round(rate(calls, 2))),
            @"evals": @(round(rate(evals, 3))),
            @"gpu": @(round(gpu_ms_s * 100) / 100),
            @"gpuPasses": @(round(gpu_passes_s)),
            @"nodes": @(d.nodes.count),
            @"natives": @(natives),
            @"backends": backends,
            @"error": d.error ?: @""
        }];
    }
    NSMutableSet* live = [NSMutableSet setWithObject:@(self_pid)];
    for (NSDictionary* s in server)
        [live addObject:s[@"pid"]];
    for (NSDictionary* d in docs)
        for (NSDictionary* b in d[@"backends"])
            [live addObject:b[@"pid"]];
    for (NSNumber* p in seen.allKeys)
        if (![live containsObject:p])
            [seen removeObjectForKey:p];
    NSSet* paths = [NSSet setWithArray:[docs valueForKey:@"path"]];
    for (NSString* p in js_seen.allKeys)
        if (![paths containsObject:p])
            [js_seen removeObjectForKey:p];
    rex[@"engine"] = @(round(js_total * 100) / 100);
    static uint64_t last_n[rx::trace::k_cats];
    static double last_ns[rx::trace::k_cats], last_t;
    uint64_t n_now[rx::trace::k_cats];
    double ns_now[rx::trace::k_cats];
    rx::trace::totals(n_now, ns_now);
    double tdt = last_t ? (now - last_t) / 1000 : 0;
    NSMutableDictionary* counters = [NSMutableDictionary dictionary];
    for (int i = 0; i < rx::trace::k_cats; i++) {
        if (tdt > 0 && n_now[i] >= last_n[i] && n_now[i] > last_n[i])
            counters[@(rx::trace::cat_name((rx::trace::Cat)i))] = @{
                @"n": @(round((n_now[i] - last_n[i]) / tdt)),
                @"ms": @(round((ns_now[i] - last_ns[i]) / 1e6 / tdt * 100) / 100)
            };
        last_n[i] = n_now[i], last_ns[i] = ns_now[i];
    }
    last_t = now;
    std::string lj = rx::trace::long_json();
    id longs = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:lj.data() length:lj.size()]
                                               options:0
                                                 error:nil]
        ?: @{};
    return @{
        @"rex": rex,
        @"threads": threads,
        @"server": server,
        @"docs": docs,
        @"fps": @(g_fps),
        @"rexui": counters,
        @"long": longs,
        @"cores": @(NSProcessInfo.processInfo.activeProcessorCount),
        @"now": @((long)NSDate.date.timeIntervalSince1970)
    };
}

NSString* debug_session_id(void) {
    return g_session_id;
}
void debug_agents_changed(void) {
    push_soon();
}

static NSMutableArray<NSString*>* g_focus_history;
static NSMutableDictionary<NSString*, NSNumber*>* g_focus_at;

void debug_pane_focused(NSString* block) {
    if (![block hasPrefix:@"block:"] || [g_focus_history.lastObject isEqualToString:block])
        return;
    if (!g_focus_history)
        g_focus_history = [NSMutableArray array];
    [g_focus_history removeObject:block];
    [g_focus_history addObject:block];
    if (!g_focus_at)
        g_focus_at = [NSMutableDictionary dictionary];
    g_focus_at[block] = @(CACurrentMediaTime());
    if (g_focus_history.count > 32)
        [g_focus_history removeObjectAtIndex:0];
    push_soon();
}
static NSString* last_agent(void) {
    double when = 0;
    NSString* session = agent_latest_session(&when);
    NSSet* agents = [NSSet setWithArray:[agent_list() valueForKey:@"key"]];
    for (NSString* b in g_focus_history.reverseObjectEnumerator) {
        if (![agents containsObject:b])
            continue;
        if (!session || [g_focus_at[b] doubleValue] > when)
            return b;
        break;
    }
    return session ?: @"";
}

struct MemCount {
    uint64_t layers = 0, with_contents = 0, contents_bytes = 0, shaders = 0, drawing = 0, drawable_bytes = 0,
             images = 0, image_bytes = 0;
};
static void mem_layer(CALayer* l, NSHashTable* nodes, MemCount& m, int depth) {
    if (!l || depth > 64)
        return;
    m.layers++;
    if ([l isKindOfClass:CAMetalLayer.class]) {
        m.shaders++;
        const uint64_t b = shader_drawable_bytes(l);
        m.drawing += b > 0, m.drawable_bytes += b;
    } else if (id c = l.contents) {
        m.with_contents++;
        if (CFGetTypeID((__bridge CFTypeRef)c) == CGImageGetTypeID()) {
            CGImageRef img = (__bridge CGImageRef)c;
            const uint64_t b = (uint64_t)CGImageGetBytesPerRow(img) * CGImageGetHeight(img);
            m.images++, m.image_bytes += b, m.contents_bytes += b;
        } else {
            const CGFloat s = l.contentsScale;
            m.contents_bytes += (uint64_t)(l.bounds.size.width * s * l.bounds.size.height * s * 4);
        }
    }
    if (l.mask)
        mem_layer(l.mask, nodes, m, depth + 1);
    for (CALayer* c in l.sublayers)
        if (![nodes containsObject:c])
            mem_layer(c, nodes, m, depth + 1);
}
static NSDictionary* memory(void) {
    NSMutableArray* files = [NSMutableArray array];
    MemCount all;
    uint64_t nodes_all = 0, natives_all = 0;
    auto mb = [](uint64_t b) { return @(round((double)b / 1048576.0 * 100) / 100); };
    for (RXDoc* d in g_docs) {
        NSArray<RXNode*>* ns = d.nodes.allValues;
        NSHashTable* layers = [NSHashTable
            hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality | NSPointerFunctionsWeakMemory];
        for (RXNode* n in ns)
            if (n.layer)
                [layers addObject:n.layer];
        MemCount m;
        uint64_t natives = 0;
        for (RXNode* n in ns) {
            if (n.view)
                natives++;
            if (n.layer)
                mem_layer(n.layer, layers, m, 0);
        }
        nodes_all += ns.count, natives_all += natives;
        all.layers += m.layers, all.with_contents += m.with_contents, all.contents_bytes += m.contents_bytes;
        all.shaders += m.shaders, all.drawing += m.drawing, all.drawable_bytes += m.drawable_bytes,
            all.images += m.images, all.image_bytes += m.image_bytes;
        [files addObject:@{
            @"file": d.path.lastPathComponent ?: @"",
            @"path": d.path ?: @"",
            @"nodes": @(ns.count),
            @"natives": @(natives),
            @"layers": @(m.layers),
            @"withContents": @(m.with_contents),
            @"contentsMB": mb(m.contents_bytes),
            @"shaders": @(m.shaders),
            @"shadersDrawing": @(m.drawing),
            @"drawablesMB": mb(m.drawable_bytes),
            @"images": @(m.images),
            @"imagesMB": mb(m.image_bytes)
        }];
    }
    [files sortUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
        double x = [a[@"contentsMB"] doubleValue] + [a[@"drawablesMB"] doubleValue],
               y = [b[@"contentsMB"] doubleValue] + [b[@"drawablesMB"] doubleValue];
        return x > y ? NSOrderedAscending : x < y ? NSOrderedDescending : NSOrderedSame;
    }];
    task_vm_info_data_t vm;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    const double footprint = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &count) == KERN_SUCCESS
        ? vm.phys_footprint / 1048576.0
        : 0;
    return @{
        @"files": files,
        @"total": @{
            @"nodes": @(nodes_all),
            @"natives": @(natives_all),
            @"layers": @(all.layers),
            @"withContents": @(all.with_contents),
            @"contentsMB": mb(all.contents_bytes),
            @"shaders": @(all.shaders),
            @"shadersDrawing": @(all.drawing),
            @"drawablesMB": mb(all.drawable_bytes),
            @"images": @(all.images),
            @"imagesMB": mb(all.image_bytes),
            @"footprintMB": @(round(footprint * 10) / 10)
        },
        @"caches": @{@"fonts": @(fonts_kept()), @"symbols": @(symbols_kept())}
    };
}

static struct {
    __weak NSView* view;
    NSPoint from;
    CGPoint origin;
    CGSize area;
    NSString* layer_id;
    double bx, by, bw, bh;
    double nx, ny;
    bool on, dropped;
    int gen;
} g_fd;
static dispatch_queue_t fd_queue(void) {
    static dispatch_queue_t q = dispatch_queue_create("rexui.floating-drag", DISPATCH_QUEUE_SERIAL);
    return q;
}

static NSDictionary* layer_of_block(id v, NSString* block) {
    if ([v isKindOfClass:NSDictionary.class]) {
        NSDictionary* d = v;
        if ([d[@"layer_id"] isKindOfClass:NSString.class] && [d[@"blocks"] isKindOfClass:NSArray.class]) {
            for (id b in d[@"blocks"])
                if ([b isKindOfClass:NSDictionary.class] && [b[@"block_id"] isEqual:block])
                    return d;
        }
        for (id k in d) {
            if (NSDictionary* f = layer_of_block(d[k], block))
                return f;
        }
    } else if ([v isKindOfClass:NSArray.class]) {
        for (id x in v) {
            if (NSDictionary* f = layer_of_block(x, block))
                return f;
        }
    }
    return nil;
}

static void fd_settle(int gen, int tries) {
    NSView* v = g_fd.view;
    if (gen != g_fd.gen || !v)
        return;
    if (tries > 0 && CGPointEqualToPoint(v.frame.origin, g_fd.origin)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            fd_settle(gen, tries - 1);
        });
        return;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    v.layer.transform = CATransform3DIdentity;
    [CATransaction commit];
    g_fd.on = false;
}

static void fd_commit(void) {
    if (!g_fd.layer_id || !g_session_id.length)
        return;
    int gen = g_fd.gen;
    NSDictionary* req = @{
        @"session_id": g_session_id,
        @"layer_id": g_fd.layer_id,
        @"bounds": @[@(g_fd.nx), @(g_fd.ny), @(g_fd.bw), @(g_fd.bh)]
    };
    NSString* json = [[NSString alloc] initWithData:json_data(req, 0) encoding:NSUTF8StringEncoding];
    dispatch_async(fd_queue(), ^{
        NSString* err = nil;
        bool ok = rex_cli(@[@"api", @"call", @"session.resize_layer", json], &err) != nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok)
                rexui_log([@"debug: a floating pane's move: " stringByAppendingString:err ?: @"?"]);
            fd_settle(gen, ok ? 60 : 0);
        });
    });
}

static void fd_follow(void) {
    NSView* v = g_fd.view;
    NSWindow* w = v.window;
    if (!v || !w || !v.superview)
        return;
    NSPoint at = [w convertPointFromScreen:NSEvent.mouseLocation];
    double dx = at.x - g_fd.from.x, down = g_fd.from.y - at.y;
    if (g_fd.layer_id && g_fd.area.width > 0 && g_fd.area.height > 0) {
        g_fd.nx = MAX(0, MIN(1 - g_fd.bw, g_fd.bx + dx / g_fd.area.width));
        g_fd.ny = MAX(0, MIN(1 - g_fd.bh, g_fd.by + down / g_fd.area.height));
        dx = (g_fd.nx - g_fd.bx) * g_fd.area.width, down = (g_fd.ny - g_fd.by) * g_fd.area.height;
    }
    NSPoint a = [v.superview convertPoint:g_fd.from fromView:nil],
            b = [v.superview convertPoint:NSMakePoint(g_fd.from.x + dx, g_fd.from.y - down) fromView:nil];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    v.layer.transform = CATransform3DMakeTranslation(b.x - a.x, b.y - a.y, 0);
    [CATransaction commit];
}

static bool drag_floating(NSString* file, NSString* phase) {
    bool drop = [phase isEqualToString:@"drop"];
    if (!g_fd.on || g_fd.dropped) {
        if (drop || (g_fd.on && g_fd.dropped))
            return false;
        RXDoc* d = nil;
        for (RXDoc* x in g_docs) {
            if (x.pane && file.length
                && ([x.path isEqualToString:file] || [x.path.lastPathComponent isEqualToString:file]))
                d = x;
        }
        NSString* block = d ? panes_block_of_doc(d) : nil;
        NSWindow* w = d ? ui_pane_view(d).window : nil;
        NSView *chrome = w ? chrome_of(w) : nil, *content = chrome ? chrome_content(chrome) : nil;
        const void *p = nullptr, *l = nullptr;
        if (!block || !content || !rex_floating_pane((__bridge const void*)content, block.UTF8String, &p, &l))
            return false;
        NSView* v = (__bridge NSView*)l;
        int gen = ++g_fd.gen;
        g_fd.view = v;
        g_fd.from = [w convertPointFromScreen:NSEvent.mouseLocation];
        g_fd.origin = v.frame.origin;
        g_fd.area = content.bounds.size;
        g_fd.layer_id = nil;
        g_fd.on = true, g_fd.dropped = false;
        NSString* json = [[NSString alloc] initWithData:json_data(@{@"session_id": g_session_id ?: @""}, 0)
                                               encoding:NSUTF8StringEncoding];
        dispatch_async(fd_queue(), ^{
            NSString* err = nil;
            NSData* out = rex_cli(@[@"api", @"call", @"session.view", json], &err);
            id view = out ? [NSJSONSerialization JSONObjectWithData:out options:0 error:nil] : nil;
            NSDictionary* layer = layer_of_block(view, block);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (gen != g_fd.gen)
                    return;
                NSArray* b = layer[@"bounds"];
                if (![b isKindOfClass:NSArray.class] || b.count != 4) {
                    rexui_log([NSString stringWithFormat:@"debug: a floating pane's move: no layer for %@ (%@)", block,
                                                         err ?: @"not in session.view"]);
                    g_fd.dropped = true;
                    fd_settle(gen, 0);
                    return;
                }
                g_fd.layer_id = layer[@"layer_id"];
                g_fd.bx = num_of(b[0], 0), g_fd.by = num_of(b[1], 0), g_fd.bw = num_of(b[2], 1),
                g_fd.bh = num_of(b[3], 1);
                g_fd.nx = g_fd.bx, g_fd.ny = g_fd.by;
                fd_follow();
                if (g_fd.dropped)
                    fd_commit();
            });
        });
        return true;
    }
    fd_follow();
    if (drop) {
        g_fd.dropped = true;
        fd_commit();
    }
    return true;
}

id debug_native(NSString* op, id arg) {
    if ([op isEqualToString:@"perf"])
        return perf();
    if ([op isEqualToString:@"memory"])
        return memory();
    NSDictionary* ag = [arg isKindOfClass:NSDictionary.class] ? arg : @{};
    if ([op isEqualToString:@"findAgents"]) {
        agent_find(^{
            push_soon();
        });
        push_soon();
        return nil;
    }
    if ([op isEqualToString:@"agentSend"]) {
        if (agent_push(ag[@"key"], ag[@"text"]))
            return nil;
        agent_send(ag[@"session"], ag[@"block"], ag[@"text"], truthy_of(ag[@"submit"]), truthy_of(ag[@"focus"], true));
        return nil;
    }
    if ([op isEqualToString:@"agentNew"]) {
        agent_new(ag[@"text"], ag[@"cwd"], ag[@"program"]);
        return nil;
    }
    if ([op isEqualToString:@"agentRun"]) {
        agent_run(ag[@"text"], ag[@"cwd"]);
        push_soon();
        return nil;
    }
    if ([op isEqualToString:@"spotlight"]) {
        pane_spotlight([arg isKindOfClass:NSString.class] ? arg : @"");
        return nil;
    }
    if ([op isEqualToString:@"agentStop"]) {
        agent_stop();
        return nil;
    }
    if ([op isEqualToString:@"state"]) {
        NSString* home = NSProcessInfo.processInfo.environment[@"REXUI_HOME"];
        return @{
            @"enabled": @(g_on),
            @"docs": docs_list(),
            @"selected": g_selected ?: NSNull.null,
            @"picking": @(g_picking),
            @"repo": home.length ? home.stringByStandardizingPath.stringByDeletingLastPathComponent : @""
        };
    }
    if ([op isEqualToString:@"console"]) {
        NSUInteger n = MIN(g_console.count, (NSUInteger)MAX(1, MIN(500, int_of(ag[@"lines"]) ?: 80)));
        return [g_console subarrayWithRange:NSMakeRange(g_console.count - n, n)];
    }
    NSDictionary* a = [arg isKindOfClass:NSDictionary.class] ? arg : nil;
    if ([op isEqualToString:@"toggle"]) {
        debug_set_enabled([arg isKindOfClass:NSNumber.class] ? [arg boolValue] : !g_on);
        return @(g_on);
    }
    if ([op isEqualToString:@"option"]) {
        NSString* k = a[@"key"];
        if (!k.length)
            return nil;
        NSMutableDictionary* o = [options() mutableCopy];
        id v = a[@"value"];
        if (!v || v == NSNull.null)
            [o removeObjectForKey:k];
        else
            o[k] = v;
        [g_state setObject:o forKey:@"debug options"];
        push_soon();
        return nil;
    }
    if ([op isEqualToString:@"tree"])
        return tree(doc_named(arg));
    if ([op isEqualToString:@"inspect"])
        return inspect(doc_named(a[@"file"]), int_of(a[@"uid"]));
    if ([op isEqualToString:@"edit"]) {
        RXDoc* d = doc_named(a[@"file"]);
        if (!d.ctx)
            return @"no such file";
        NSString* err = string_of(doc_call(d, @"debugEdit", @[a[@"uid"] ?: @0, a[@"name"] ?: @"", a[@"value"] ?: @""]));
        debug_changed(d);
        debug_selected_changed();
        if (!err.length) {
            static constexpr NSUInteger kKept = 64;
            if (!g_edited)
                g_edited = [NSMutableArray array];
            if (g_edited.count == kKept)
                [g_edited removeObjectAtIndex:0];
            [g_edited addObject:d.path ?: @""];
        }
        return err;
    }
    if ([op isEqualToString:@"undo"]) {
        while (g_edited.count) {
            NSString* path = g_edited.lastObject;
            [g_edited removeLastObject];
            RXDoc* d = doc_named(path);
            if (!d.ctx)
                continue;
            id uid = doc_call(d, @"debugUndo", @[]);
            if (![uid isKindOfClass:NSNumber.class] || ![uid intValue])
                continue;
            debug_changed(d);
            debug_selected_changed();
            return @{@"file": d.path ?: path, @"uid": uid};
        }
        return nil;
    }
    if ([op isEqualToString:@"eval"]) {
        RXDoc* d = doc_named(a[@"file"]);
        NSString* file = d.path.lastPathComponent ?: a[@"file"];
        debug_console_add(file, @"input", a[@"code"] ?: @"");
        if (d.ctx)
            doc_wants_text(d, a[@"code"]);
        NSDictionary* r = d.ctx ? dict_of(doc_call(d, @"debugEval", @[a[@"code"] ?: @""]))
                                : @{@"ok": @NO,
                                    @"text": @"no such file"};
        NSString* code = [a[@"code"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (![code hasPrefix:@"console."] || ![r[@"text"] isEqual:@"undefined"])
            debug_console_add(file, truthy_of(r[@"ok"]) ? @"result" : @"error", r[@"text"] ?: @"");
        return r;
    }
    if ([op isEqualToString:@"highlight"]) {
        highlight(node_in(a));
        return nil;
    }
    if ([op isEqualToString:@"select"]) {
        select_node(node_in(a));
        push_soon();
        return nil;
    }
    if ([op isEqualToString:@"pick"]) {
        if ([arg boolValue]) {
            g_picking = true;
            push_soon();
        } else {
            stop_picking();
        }
        return nil;
    }
    if ([op isEqualToString:@"openFloating"]) {
        RXDoc* d = doc_named(a[@"file"]);
        NSString* path = d.path ?: a[@"file"];
        if (path && ![path hasPrefix:@"/"])
            path = [debug_ui_dir() stringByAppendingPathComponent:path];
        open_floating(path, [a[@"bounds"] isKindOfClass:NSArray.class] ? a[@"bounds"] : nil);
        return nil;
    }
    if ([op isEqualToString:@"openInPane"]) {
        RXDoc* d = doc_named(a[@"file"]);
        open_in_pane(d.path ?: a[@"file"], a[@"direction"] ?: @"horizontal", a[@"side"] ?: @"after");
        return nil;
    }
    if ([op isEqualToString:@"dragFloating"])
        return @(drag_floating(a[@"file"], a[@"phase"]));
    if ([op isEqualToString:@"dragToPane"]) {
        NSString* phase = a[@"phase"];
        if ([phase isEqualToString:@"move"])
            return @(pane_target_aim(NSEvent.mouseLocation));
        NSDictionary* t = pane_target_end();
        RXDoc* d = doc_named(a[@"file"]);
        NSString* path = d.path ?: a[@"file"];
        if (path && ![path hasPrefix:@"/"])
            path = [debug_ui_dir() stringByAppendingPathComponent:path];
        if (![phase isEqualToString:@"drop"] || !t || !path.length)
            return @NO;
        NSString* zone = t[@"zone"];
        if ([zone isEqualToString:@"center"]) {
            open_here(path, t[@"block"]);
        } else {
            bool across = [zone isEqualToString:@"left"] || [zone isEqualToString:@"right"];
            bool before = [zone isEqualToString:@"left"] || [zone isEqualToString:@"top"];
            open_in_pane(path, across ? @"horizontal" : @"vertical", before ? @"before" : @"after", t[@"block"]);
        }
        push_soon();
        return @YES;
    }
    if ([op isEqualToString:@"complete"]) {
        RXDoc* d = doc_named(a[@"file"]);
        return d.ctx ? dict_of(doc_call(d, @"debugComplete", @[a[@"code"] ?: @""])) : nil;
    }
    if ([op isEqualToString:@"openHere"]) {
        RXDoc* d = doc_named(a[@"file"]);
        open_here(d.path ?: a[@"file"]);
        return nil;
    }
    if ([op isEqualToString:@"closePane"]) {
        for (RXDoc* d in [g_docs copy]) {
            if (d.pane && [d.path isEqual:a[@"file"]])
                close_pane_of(d);
        }
        return nil;
    }
    if ([op isEqualToString:@"theme"]) {
        g_look = [arg isKindOfClass:NSDictionary.class] ? arg : @{};
        push_soon();
        return nil;
    }
    if ([op isEqualToString:@"clear"]) {
        [g_console removeAllObjects];
        g_console_cleared = true;
        push_soon();
    }
    return nil;
}

static void debug_set_enabled(bool on) {
    if (on == g_on)
        return;
    g_on = on;
    [g_state setBool:on forKey:@"debug"];
    g_leaving = 0;
    if (!on) {
        pane_spotlight(@"");
        g_picking = false;
        g_hovered = nil;
        highlight(nil);
        double ms = 0;
        for (RXDoc* d in g_docs) {
            if (d.devtools && !d.pane && d.root.host.window && !d.root.host.hiddenOrHasHiddenAncestor)
                ms = MAX(ms, num(d.root, P::animation, 220));
        }
        if (ms > 0) {
            g_leaving = CFAbsoluteTimeGetCurrent() + ms / 1000 + 0.05;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((ms / 1000 + 0.08) * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                               scan();
                           });
        }
    }
    rexui_log(on ? @"debug: on" : @"debug: off");
    scan();
    push_soon();
}

static void toggle_here(NSString* name) {
    NSString* dir = debug_ui_dir();
    NSString* path = dir ? [dir stringByAppendingPathComponent:name] : nil;
    if (!path || ![NSFileManager.defaultManager fileExistsAtPath:path]) {
        rexui_log([NSString stringWithFormat:@"debug: the debug UI has no %@", name]);
        return;
    }
    if (NSNumber* pid = g_here[path]) {
        kill(pid.intValue, SIGTERM);
        return;
    }
    open_here(path);
    if (!g_on)
        debug_set_enabled(true);
}

struct DebugKey {
    const char *conf, *fallback, *file;
    std::expected<rx::keys::Chord, rx::keys::Error> chord = std::unexpected(rx::keys::Error::empty);
};
static DebugKey g_debug_keys[] = {
    {"debug-elements-key", "cmd+alt+c", "elements.rui"},
    {"debug-console-key", "cmd+alt+j", "console.rui"},
    {"debug-elements-dock-key", "cmd+alt+e", "elements.rui"},
    {"debug-console-dock-key", "cmd+alt+l", "console.rui"},
    {"debug-key", "cmd+alt+i", nullptr},
};
static void debug_keys_read(void) {
    static uint64_t read = ~0ull;
    if (read == g_config_generation)
        return;
    read = g_config_generation;
    for (DebugKey& k : g_debug_keys) {
        NSString* v = g_config.values[@(k.conf)] ?: @(k.fallback);
        k.chord = [v isEqualToString:@"none"] ? std::unexpected(rx::keys::Error::empty) : key_parse(v);
    }
}
static bool debug_key_is(int i, NSEvent* e) {
    return g_debug_keys[i].chord && chord_matches(*g_debug_keys[i].chord, e);
}

bool debug_key(NSEvent* e) {
    if (g_picking && e.keyCode == 53) {
        stop_picking();
        return true;
    }
    debug_keys_read();
    for (int i = 0; i < 2; i++) {
        if (debug_key_is(i, e)) {
            toggle_here(@(g_debug_keys[i].file));
            return true;
        }
    }
    for (int i = 2; i < 4; i++) {
        if (!debug_key_is(i, e))
            continue;
        NSString* opt = [@"hidden " stringByAppendingString:@(g_debug_keys[i].file)];
        NSMutableDictionary* o = [options() mutableCopy];
        if (!g_on || truthy_of(o[opt]))
            [o removeObjectForKey:opt];
        else
            o[opt] = @YES;
        if (!g_on)
            for (int j = 2; j < 4; j++)
                if (j != i)
                    o[[@"hidden " stringByAppendingString:@(g_debug_keys[j].file)]] = @YES;
        [g_state setObject:o forKey:@"debug options"];
        if (!g_on)
            debug_set_enabled(true);
        push_soon();
        return true;
    }
    if (!debug_key_is(4, e))
        return false;
    NSMutableDictionary* o = [options() mutableCopy];
    if ([o[@"hidden elements.rui"] boolValue] && [o[@"hidden console.rui"] boolValue]) {
        [o removeObjectsForKeys:@[@"hidden elements.rui", @"hidden console.rui"]];
        [g_state setObject:o forKey:@"debug options"];
        if (!g_on)
            debug_set_enabled(true);
        push_soon();
    } else {
        debug_set_enabled(!g_on);
    }
    return true;
}

bool debug_pointer_in_devtools(NSEvent* e) {
    NSWindow* ew = e.window;
    if (!g_on)
        return false;
    for (RXDoc* d in g_docs) {
        RXDockView* v = d.devtools ? d.root.host : nil;
        if (!v || v.window != ew || v.hiddenOrHasHiddenAncestor)
            continue;
        if (NSPointInRect([v convertPoint:e.locationInWindow fromView:nil], v.bounds))
            return true;
    }
    return false;
}

bool debug_pointer_near_devtools(NSEvent* e) {
    constexpr CGFloat kRoom = 24;
    NSWindow* ew = e.window;
    if (!g_on)
        return false;
    for (RXDoc* d in g_docs) {
        RXDockView* v = d.devtools ? d.root.host : nil;
        if (!v || v.window != ew || v.hiddenOrHasHiddenAncestor)
            continue;
        if (NSPointInRect([v convertPoint:e.locationInWindow fromView:nil], NSInsetRect(v.bounds, -kRoom, -kRoom)))
            return true;
    }
    return false;
}

void debug_init(void) {
    static bool done;
    if (done)
        return;
    done = true;
    g_on = [g_state boolForKey:@"debug"];
    agent_listen();
    rexui_log_tap = [](NSString* msg) { debug_console_add(nil, @"info", msg); };
}
