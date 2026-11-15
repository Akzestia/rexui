// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#import "base/rexui.h"
#import "chrome/chrome.h"

NSArray<NSDictionary*>* cursor_file_frames(NSString* path, NSString** error);

@interface RXCursorRole : NSObject
@property(nonatomic, copy) NSString* name;
@property(nonatomic, strong) NSArray<NSCursor*>* frames;
@property(nonatomic, strong) NSArray<NSNumber*>* ends;
@end
@implementation RXCursorRole
@end

static NSDictionary<NSString*, RXCursorRole*>* g_roles;
static NSMapTable<NSCursor*, NSString*>* g_system;
static NSHashTable<NSCursor*>* g_ours;
static RXCursorRole* g_role;
static double g_started;
static NSTimer* g_timer;

static NSString* role_of_name(NSString* file) {
    NSString* n = [[file.stringByDeletingPathExtension precomposedStringWithCompatibilityMapping] lowercaseString];
    n = [[n componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet] componentsJoinedByString:@""];
    if ([n containsString:@"nwse"])
        return @"diagonal1";
    if ([n containsString:@"nesw"])
        return @"diagonal2";
    NSRange d = [n rangeOfString:@"斜め"];
    if (d.location == NSNotFound)
        d = [n rangeOfString:@"diag"];
    if (d.location != NSNotFound) {
        NSRange digit = [n rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet
                                           options:0
                                             range:NSMakeRange(d.location, n.length - d.location)];
        if (digit.location != NSNotFound)
            return [n characterAtIndex:digit.location] == '2' ? @"diagonal2" : @"diagonal1";
    }
    static NSArray* table = @[
        @[@"help", @"ヘルプ", @"help"],
        @[@"text", @"テキスト", @"text", @"beam"],
        @[@"linked", @"リンク", @"link", @"hand"],
        @[@"vertical", @"上下", @"vert"],
        @[@"horizontal", @"左右", @"horz", @"hori"],
        @[@"drag", @"移動", @"move"],
        @[@"background", @"バックグラウンド", @"working", @"background", @"appstarting"],
        @[@"busy", @"待ち状態", @"busy", @"wait"],
        @[@"unavailable", @"不可", @"unavailable", @"notallowed", @"forbidden"],
        @[@"handwriting", @"手書き", @"handwriting", @"pen"],
        @[@"crosshair", @"領域選択", @"precision", @"cross"],
        @[@"alternate", @"代替", @"alternate"],
        @[@"human", @"人の選択", @"person"],
        @[@"place", @"場所", @"pin", @"location"],
        @[@"idle", @"通常", @"待機中", @"normal", @"arrow", @"default", @"pointer"],
    ];
    for (NSArray* row in table)
        for (NSUInteger i = 1; i < row.count; i++)
            if ([n containsString:row[i]])
                return row[0];
    return nil;
}

static NSCursor* make_cursor(CGImageRef img, NSPoint hot, double size) {
    double w = CGImageGetWidth(img), h = CGImageGetHeight(img), k = size / MAX(w, h);
    NSImage* image = [[NSImage alloc] initWithCGImage:img size:NSMakeSize(w * k, h * k)];
    NSPoint at = NSMakePoint(MIN(MAX(hot.x * k, 0), w * k - 1), MIN(MAX(hot.y * k, 0), h * k - 1));
    return [[NSCursor alloc] initWithImage:image hotSpot:at];
}

static NSDictionary<NSString*, RXCursorRole*>* load_theme(NSString* folder, double size) {
    NSMutableDictionary<NSString*, NSArray*>* files = [NSMutableDictionary dictionary];
    NSMutableArray<NSString*>* paths = [NSMutableArray array];
    NSDirectoryEnumerator* e = [NSFileManager.defaultManager enumeratorAtPath:folder];
    for (NSString* rel in e) {
        if (e.level > 3)
            [e skipDescendants];
        if ([@[@"ani", @"cur", @"ico", @"png"] containsObject:rel.pathExtension.lowercaseString])
            [paths addObject:rel];
    }
    [paths sortUsingComparator:^NSComparisonResult(NSString* a, NSString* b) {
        bool aa = [a.pathExtension.lowercaseString isEqualToString:@"ani"],
             ba = [b.pathExtension.lowercaseString isEqualToString:@"ani"];
        if (aa != ba)
            return aa ? NSOrderedAscending : NSOrderedDescending;
        return [a compare:b];
    }];
    int unknown = 0;
    for (NSString* rel in paths) {
        NSString* role = role_of_name(rel.lastPathComponent);
        if (files[role])
            continue;
        if (!role) {
            unknown++;
            continue;
        }
        NSString* err = nil;
        NSArray* f = cursor_file_frames([folder stringByAppendingPathComponent:rel], &err);
        if (!f.count) {
            rexui_log([NSString stringWithFormat:@"cursor: %@: %@", rel, err]);
            continue;
        }
        if (!files[role])
            files[role] = f;
    }
    NSMutableDictionary* roles = [NSMutableDictionary dictionary];
    for (NSString* role in files) {
        RXCursorRole* r = [RXCursorRole new];
        r.name = role;
        NSMutableArray *frames = [NSMutableArray array], *ends = [NSMutableArray array];
        double t = 0;
        for (NSDictionary* f in files[role]) {
            [frames addObject:make_cursor((__bridge CGImageRef)f[@"image"], [f[@"hotspot"] pointValue], size)];
            t += [f[@"delay"] doubleValue];
            [ends addObject:@(t)];
        }
        r.frames = frames, r.ends = ends;
        roles[role] = r;
    }
    rexui_log([NSString
        stringWithFormat:@"cursor: %@: %lu roles (%@)%@", folder.lastPathComponent, (unsigned long)roles.count,
                         [[roles.allKeys sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@" "],
                         unknown ? [NSString stringWithFormat:@", %d files of no role", unknown] : @""]);
    return roles;
}

static void map_system(void) {
    g_system = [NSMapTable strongToStrongObjectsMapTable];
    void (^put)(NSCursor*, NSString*) = ^(NSCursor* c, NSString* role) {
        if (c)
            [g_system setObject:role forKey:c];
    };
    put(NSCursor.arrowCursor, @"idle");
    put(NSCursor.contextualMenuCursor, @"idle");
    put(NSCursor.IBeamCursor, @"text");
    put(NSCursor.IBeamCursorForVerticalLayout, @"text");
    put(NSCursor.pointingHandCursor, @"linked");
    put(NSCursor.dragLinkCursor, @"linked");
    put(NSCursor.openHandCursor, @"drag");
    put(NSCursor.closedHandCursor, @"drag");
    put(NSCursor.dragCopyCursor, @"alternate");
    put(NSCursor.crosshairCursor, @"crosshair");
    put(NSCursor.operationNotAllowedCursor, @"unavailable");
    put(NSCursor.disappearingItemCursor, @"unavailable");
    put(NSCursor.resizeLeftRightCursor, @"horizontal");
    put(NSCursor.resizeLeftCursor, @"horizontal");
    put(NSCursor.resizeRightCursor, @"horizontal");
    put(NSCursor.resizeUpDownCursor, @"vertical");
    put(NSCursor.resizeUpCursor, @"vertical");
    put(NSCursor.resizeDownCursor, @"vertical");
    if (@available(macOS 15.0, *)) {
        put(NSCursor.columnResizeCursor, @"horizontal");
        put(NSCursor.rowResizeCursor, @"vertical");
        NSDictionary<NSNumber*, NSString*>* frames = @{
            @(NSCursorFrameResizePositionTop): @"vertical",
            @(NSCursorFrameResizePositionBottom): @"vertical",
            @(NSCursorFrameResizePositionLeft): @"horizontal",
            @(NSCursorFrameResizePositionRight): @"horizontal",
            @(NSCursorFrameResizePositionTopLeft): @"diagonal1",
            @(NSCursorFrameResizePositionBottomRight): @"diagonal1",
            @(NSCursorFrameResizePositionTopRight): @"diagonal2",
            @(NSCursorFrameResizePositionBottomLeft): @"diagonal2",
        };
        for (NSNumber* pos in frames)
            for (NSNumber* dir in @[
                     @(NSCursorFrameResizeDirectionsInward), @(NSCursorFrameResizeDirectionsOutward),
                     @(NSCursorFrameResizeDirectionsAll)
                 ])
                put([NSCursor frameResizeCursorFromPosition:(NSCursorFrameResizePosition)pos.integerValue
                                               inDirections:(NSCursorFrameResizeDirections)dir.integerValue],
                    frames[pos]);
    }
}

static RXCursorRole* role_for(NSString* name) {
    if (!name)
        return nil;
    if (RXCursorRole* r = g_roles[name])
        return r;
    if ([name hasPrefix:@"diagonal"] || [name isEqualToString:@"alternate"])
        return g_roles[@"idle"];
    return nil;
}

static bool pointer_over_rex(void) {
    if (!NSApp.isActive)
        return false;
    NSInteger n = [NSWindow windowNumberAtPoint:NSEvent.mouseLocation belowWindowWithWindowNumber:0];
    return [NSApp windowWithWindowNumber:n] != nil;
}

static NSUInteger frame_now(RXCursorRole* r, double* next) {
    double total = r.ends.lastObject.doubleValue;
    if (r.frames.count < 2 || total <= 0) {
        *next = 0;
        return 0;
    }
    double t = fmod(CACurrentMediaTime() - g_started, total);
    NSUInteger i = 0;
    while (i + 1 < r.ends.count && t >= r.ends[i].doubleValue)
        i++;
    *next = r.ends[i].doubleValue - t;
    return i;
}

static void stop(void) {
    [g_timer invalidate];
    g_timer = nil;
}

static void schedule(double in);

static void tick(void) {
    g_timer = nil;
    if (!g_role || !pointer_over_rex() || ![g_ours containsObject:NSCursor.currentCursor]) {
        g_role = nil;
        return;
    }
    double next;
    NSUInteger i = frame_now(g_role, &next);
    NSCursor* f = g_role.frames[i];
    if (f != NSCursor.currentCursor)
        orig_cursor_set(f, @selector(set));
    schedule(next);
}

static void schedule(double in) {
    if (in <= 0)
        return;
    double fps = g_config.cursor_fps > 0 ? g_config.cursor_fps : 15;
    in = MAX(in, 1.0 / fps);
    stop();
    g_timer = [NSTimer timerWithTimeInterval:in
                                     repeats:NO
                                       block:^(NSTimer*) {
                                           tick();
                                       }];
    g_timer.tolerance = in * 0.1;
    [NSRunLoop.mainRunLoop addTimer:g_timer forMode:NSRunLoopCommonModes];
}

NSCursor* cursor_themed(NSCursor* c) {
    if (!g_roles.count || !c)
        return c;
    if ([g_ours containsObject:c])
        return c;
    RXCursorRole* r = role_for([g_system objectForKey:c]);
    if (!r) {
        stop();
        g_role = nil;
        return c;
    }
    if (r != g_role) {
        g_role = r;
        g_started = CACurrentMediaTime();
    }
    double next;
    NSUInteger i = frame_now(r, &next);
    if (!g_timer)
        schedule(next);
    return r.frames[i];
}

void cursor_config_changed(void) {
    static NSString* was;
    static double was_size;
    NSString* path = g_config.cursor.stringByExpandingTildeInPath ?: @"";
    if (path.length && !path.isAbsolutePath)
        path = [ui_dir() stringByAppendingPathComponent:path];
    double size = g_config.cursor_size > 0 ? g_config.cursor_size : 32;
    if ([path isEqualToString:was ?: @""] && size == was_size)
        return;
    was = path, was_size = size;
    stop();
    g_role = nil;
    if (!path.length) {
        if (g_roles.count)
            rexui_log(@"cursor: macOS's own");
        g_roles = nil;
        g_ours = nil;
        use_cursor(NSCursor.arrowCursor);
        return;
    }
    if (!g_system)
        map_system();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary* roles = load_theme(path, size);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![was isEqualToString:path])
                return;
            NSHashTable* ours = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
            for (RXCursorRole* r in roles.allValues)
                for (NSCursor* f in r.frames)
                    [ours addObject:f];
            g_roles = roles, g_ours = ours;
            if (roles.count && pointer_over_rex())
                use_cursor(NSCursor.currentCursor);
        });
    });
}

NSString* cursor_describe(void) {
    if (!g_roles.count)
        return @"cursor: macOS's own";
    double next;
    return g_role
        ? [NSString stringWithFormat:@"cursor: %@, frame %lu of %lu", g_role.name,
                                     (unsigned long)frame_now(g_role, &next), (unsigned long)g_role.frames.count]
        : @"cursor: themed, none of ours shown";
}

void (*orig_cursor_set)(id, SEL);
bool g_cursor_direct;
static constexpr double kFlip = 0.12;
static NSCursor *g_cursor_last, *g_cursor_prev;
static double g_cursor_at, g_cursor_changed;
static NSCursor *g_cursor_want, *g_cursor_req;
static int g_cursor_flips;
static bool g_cursor_armed;

static void cursor_apply(NSCursor* c, SEL sel) {
    NSCursor* cur = NSCursor.currentCursor;
    double now = CACurrentMediaTime();
    if (c != cur)
        g_cursor_prev = cur, g_cursor_changed = now;
    g_cursor_last = c;
    g_cursor_at = now;
    orig_cursor_set(c, sel);
}

static void cursor_settle(void) {
    g_cursor_armed = false;
    if (!g_cursor_want)
        return;
    if (g_cursor_flips > 1) {
        g_cursor_flips = 0;
        g_cursor_armed = true;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kFlip * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            cursor_settle();
        });
        return;
    }
    NSCursor* w = g_cursor_want;
    g_cursor_want = nil;
    g_cursor_flips = 0;
    if (w != NSCursor.currentCursor && !pane_drag_cursor() && !ui_host_under_pointer())
        cursor_apply(w, @selector(set));
}

static void note_vertical(NSCursor* asked, NSString* who) {
    static bool was;
    if (!g_system)
        map_system();
    bool v = [[g_system objectForKey:asked] isEqualToString:@"vertical"];
    if (v == was)
        return;
    was = v;
    if (!v)
        return;
    NSString* from = who;
    if (!from) {
        NSArray<NSString*>* st = NSThread.callStackSymbols;
        NSMutableArray<NSString*>* frames = [NSMutableArray array];
        for (NSUInteger i = 2; i < st.count && frames.count < 5; i++) {
            NSArray<NSString*>* parts =
                [st[i] componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            NSMutableArray<NSString*>* words = [NSMutableArray array];
            for (NSString* w in parts)
                if (w.length)
                    [words addObject:w];
            if (words.count > 3)
                [frames addObject:[[words subarrayWithRange:NSMakeRange(3, words.count - 3)]
                                      componentsJoinedByString:@" "]];
        }
        from = [frames componentsJoinedByString:@" < "];
    }
    NSCursor* app = panes_cursor_here();
    rexui_log_file(
        [NSString stringWithFormat:@"cursor: vertical resize, from %@%@", from, app ? @" (over an app's pane)" : @""]);
}

void hook_cursor_set(NSCursor* self, SEL sel) {
    note_vertical(self, g_cursor_direct ? @"rexui's own (direct)" : nil);
    if (g_cursor_direct) {
        g_cursor_want = nil;
        return cursor_apply(self, sel);
    }
    if (NSCursor* held = pane_drag_cursor(); held && self != held)
        return;
    if (NSCursor* app = panes_cursor_here())
        self = app;
    else
        self = cursor_themed(self);
    NSCursor* cur = NSCursor.currentCursor;
    if ((self != cur || g_cursor_want) && ui_host_under_pointer())
        return;
    double now = CACurrentMediaTime();
    if (self != g_cursor_req)
        g_cursor_flips++;
    g_cursor_req = self;
    if (self == cur) {
        if (g_cursor_want)
            g_cursor_want = self;
        if (self == g_cursor_last && now - g_cursor_at < 0.25)
            return;
        return cursor_apply(self, sel);
    }
    if (g_cursor_want || (self == g_cursor_prev && now - g_cursor_changed < kFlip)) {
        if (!g_cursor_want)
            g_cursor_flips = 0;
        g_cursor_want = self;
        if (!g_cursor_armed) {
            g_cursor_armed = true;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kFlip * NSEC_PER_SEC)), dispatch_get_main_queue(),
                           ^{
                               cursor_settle();
                           });
        }
        return;
    }
    cursor_apply(self, sel);
}

void use_cursor(NSCursor* c) {
    note_vertical(c, @"rexui's own (use_cursor)");
    if (pane_drag_cursor())
        return;
    NSCursor* show = panes_cursor_here() ?: cursor_themed(c);
    g_cursor_want = nil;
    g_cursor_req = show;
    if (show != NSCursor.currentCursor)
        cursor_apply(show, @selector(set));
}
