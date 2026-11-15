// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#import <ImageIO/ImageIO.h>
#import "base/rexui.h"
#import "chrome/chrome.h"

static void (*orig_set_icon)(id, SEL, NSImage*);
static NSImage* g_rex_icon;
static bool g_ours;
static NSString* g_override;
static NSArray<NSImage*>* g_frames;
static NSArray<NSNumber*>* g_delays;
static NSUInteger g_frame;
static NSTimer* g_timer;

@interface RXDockTileView : NSView
@property(nonatomic, strong) NSImage* image;
@end
@implementation RXDockTileView
- (void)drawRect:(NSRect)r {
    [self.image drawInRect:self.bounds fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
}
@end

static void hook_set_icon(NSApplication* self, SEL sel, NSImage* image) {
    g_rex_icon = image;
    if (!g_ours)
        orig_set_icon(self, sel, image);
}

static NSString* resolve(NSString* path) {
    path = path.stringByExpandingTildeInPath;
    return path.isAbsolutePath ? path : [ui_dir() stringByAppendingPathComponent:path];
}

static NSArray<NSImage*>* load(NSString* path, NSArray<NSNumber*>** delays) {
    BOOL dir = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&dir])
        return nil;
    NSMutableArray *frames = [NSMutableArray array], *times = [NSMutableArray array];
    double each = 1.0 / MAX(g_config.app_icon_fps, 1);
    if (dir) {
        NSArray* names = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:nil]
            sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
        for (NSString* n in names) {
            if (![n.pathExtension.lowercaseString isEqualToString:@"png"])
                continue;
            if (NSImage* img = [[NSImage alloc] initWithContentsOfFile:[path stringByAppendingPathComponent:n]]) {
                [frames addObject:img];
                [times addObject:@(each)];
            }
        }
    } else if ([path.pathExtension.lowercaseString isEqualToString:@"gif"]) {
        CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], nullptr);
        for (size_t i = 0; src && i < CGImageSourceGetCount(src); i++) {
            CGImageRef cg = CGImageSourceCreateImageAtIndex(src, i, nullptr);
            if (!cg)
                continue;
            NSDictionary* props = (__bridge_transfer NSDictionary*)CGImageSourceCopyPropertiesAtIndex(src, i, nullptr);
            NSDictionary* gif = props[(__bridge NSString*)kCGImagePropertyGIFDictionary];
            double d = [gif[(__bridge NSString*)kCGImagePropertyGIFUnclampedDelayTime] doubleValue];
            if (d <= 0.01)
                d = [gif[(__bridge NSString*)kCGImagePropertyGIFDelayTime] doubleValue];
            [frames addObject:[[NSImage alloc] initWithCGImage:cg size:NSZeroSize]];
            [times addObject:@(d > 0.01 ? d : 0.1)];
            CGImageRelease(cg);
        }
        if (src)
            CFRelease(src);
    } else if (NSImage* img = [[NSImage alloc] initWithContentsOfFile:path]) {
        [frames addObject:img];
        [times addObject:@0];
    }
    *delays = times;
    return frames.count ? frames : nil;
}

static void stop_animation(void) {
    [g_timer invalidate];
    g_timer = nil;
    if (NSApp.dockTile.contentView) {
        NSApp.dockTile.contentView = nil;
        [NSApp.dockTile display];
    }
}

static void step(void) {
    if (g_frames.count < 2)
        return;
    g_frame = (g_frame + 1) % g_frames.count;
    RXDockTileView* v = (RXDockTileView*)NSApp.dockTile.contentView;
    if (![v isKindOfClass:RXDockTileView.class])
        return;
    v.image = g_frames[g_frame];
    [NSApp.dockTile display];
    double d = MAX(g_delays[g_frame].doubleValue, 1.0 / MAX(g_config.app_icon_fps, 1));
    g_timer = [NSTimer timerWithTimeInterval:d
                                     repeats:NO
                                       block:^(NSTimer*) {
                                           step();
                                       }];
    g_timer.tolerance = d * 0.2;
    [NSRunLoop.mainRunLoop addTimer:g_timer forMode:NSRunLoopCommonModes];
}

static void show(NSString* path) {
    stop_animation();
    g_frames = nil;
    NSArray* delays = nil;
    NSArray* frames = path.length ? load(resolve(path), &delays) : nil;
    if (path.length && !frames)
        rexui_log([NSString stringWithFormat:@"icon: can't read %@", path]);
    if (!frames) {
        if (g_ours)
            orig_set_icon(NSApp, @selector(setApplicationIconImage:), g_rex_icon);
        g_ours = false;
        return;
    }
    g_ours = true;
    g_frames = frames, g_delays = delays, g_frame = 0;
    orig_set_icon(NSApp, @selector(setApplicationIconImage:), frames[0]);
    if (frames.count > 1) {
        RXDockTileView* v = [[RXDockTileView alloc]
            initWithFrame:NSMakeRect(0, 0, NSApp.dockTile.size.width, NSApp.dockTile.size.height)];
        v.image = frames[0];
        NSApp.dockTile.contentView = v;
        [NSApp.dockTile display];
        double d = MAX([delays[0] doubleValue], 1.0 / MAX(g_config.app_icon_fps, 1));
        g_timer = [NSTimer timerWithTimeInterval:d
                                         repeats:NO
                                           block:^(NSTimer*) {
                                               step();
                                           }];
        [NSRunLoop.mainRunLoop addTimer:g_timer forMode:NSRunLoopCommonModes];
    }
    rexui_log([NSString stringWithFormat:@"icon: %@ (%lu frame%s)", path.lastPathComponent, (unsigned long)frames.count,
                                         frames.count == 1 ? "" : "s"]);
}

static NSString* wanted(void) {
    return g_override ?: g_config.app_icon ?: @"";
}

void icon_config_changed(void) {
    static NSString* was;
    static double was_fps;
    NSString* now = wanted();
    if (was && [was isEqualToString:now] && was_fps == g_config.app_icon_fps)
        return;
    was = now, was_fps = g_config.app_icon_fps;
    show(now);
}

void icon_set(NSString* path) {
    g_override = path;
    icon_config_changed();
}

void icon_init(void) {
    swizzle([NSApplication class], @selector(setApplicationIconImage:), (IMP)hook_set_icon, (IMP*)&orig_set_icon);
}
