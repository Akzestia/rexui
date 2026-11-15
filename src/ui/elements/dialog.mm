// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "ui/ui.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static constexpr CGFloat kW = 520, kH = 420, kRow = 24, kHead = 40, kFoot = 48, kPad = 10;

@interface RXPicker : RXDockView
@property(nonatomic, copy) NSString* folder;
@property(nonatomic, copy) NSArray<UTType*>* types;
@property(nonatomic, copy) NSString* mode;
@property(nonatomic) bool multiple;
@property(nonatomic, strong) NSMutableIndexSet* picks;
@property(nonatomic, strong) NSMutableArray<CALayer*>* pickLayers;
@property(nonatomic, copy) NSString* saveName;
@property(nonatomic, strong) RXTextLayer* nameLabel;
@property(nonatomic, strong) NSArray<NSDictionary*>* entries;
@property(nonatomic) NSInteger picked;
@property(nonatomic) CGFloat scroll;
@property(nonatomic, strong) CALayer *list, *rowsLayer, *highlight;
@property(nonatomic, strong) RXTextLayer* where;
@property(nonatomic, strong) CALayer *open, *cancel;
@property(nonatomic) NSInteger hover_button;
@property(nonatomic) uint64_t listing;
@end

static RXPicker* g_picker;

static RXTextLayer* label(NSString* s, NSFont* f, NSColor* c, CGFloat scale) {
    RXTextLayer* t = [RXTextLayer layer];
    t.font = f, t.text = s, t.color = c, t.contentsScale = scale;
    return t;
}

static void picker_done(NSString* path, NSArray<NSString*>* paths = nil);

@implementation RXPicker
- (CGFloat)listHeight {
    return kH - kHead - kFoot;
}
- (CGFloat)maxScroll {
    return MAX(0, (CGFloat)(self.entries.count + 1) * kRow - self.listHeight);
}

static NSArray<NSDictionary*>* list_folder(NSString* folder, NSString* mode, NSArray<UTType*>* types) {
    NSFileManager* fm = NSFileManager.defaultManager;
    NSMutableArray *dirs = [NSMutableArray array], *files = [NSMutableArray array];
    NSArray<NSURL*>* urls = [fm contentsOfDirectoryAtURL:[NSURL fileURLWithPath:folder isDirectory:YES]
                              includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey]
                                                 options:NSDirectoryEnumerationSkipsHiddenFiles
                                                   error:nil];
    const bool folders_only = [mode isEqualToString:@"folder"];
    for (NSURL* u in urls) {
        NSString* name = u.lastPathComponent;
        if ([name hasPrefix:@"."])
            continue;
        NSString* path = [folder stringByAppendingPathComponent:name];
        NSNumber *is_dir = nil, *is_link = nil;
        [u getResourceValue:&is_dir forKey:NSURLIsDirectoryKey error:nil];
        [u getResourceValue:&is_link forKey:NSURLIsSymbolicLinkKey error:nil];
        BOOL dir = is_dir.boolValue;
        if (is_link.boolValue && ![fm fileExistsAtPath:path isDirectory:&dir])
            continue;
        if (dir && ![name.pathExtension isEqualToString:@"app"]) {
            [dirs addObject:@{@"name": name, @"path": path, @"dir": @YES}];
            continue;
        }
        if (folders_only)
            continue;
        if (types.count) {
            UTType* t = [UTType typeWithFilenameExtension:name.pathExtension];
            bool ok = false;
            for (UTType* want in types)
                ok = ok || (t && [t conformsToType:want]);
            if (!ok)
                continue;
        }
        [files addObject:@{@"name": name, @"path": path, @"dir": @NO}];
    }
    NSComparator by_name = ^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
        return [a[@"name"] localizedStandardCompare:b[@"name"]];
    };
    [dirs sortUsingComparator:by_name];
    [files sortUsingComparator:by_name];
    return [dirs arrayByAddingObjectsFromArray:files];
}

- (void)load:(NSString*)folder {
    static uint64_t listings;
    self.folder = folder.stringByStandardizingPath;
    self.entries = @[];
    self.picked = -1;
    [self.picks removeAllIndexes];
    self.scroll = 0;
    const uint64_t mine = self.listing = ++listings;
    [self draw];
    NSString *path = self.folder, *mode = self.mode;
    NSArray<UTType*>* types = self.types;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSDictionary*>* entries = list_folder(path, mode, types);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (g_picker != self || self.listing != mine)
                return;
            self.listing = 0;
            self.entries = entries;
            [self draw];
        });
    });
}

- (void)confirm {
    if ([self.mode isEqualToString:@"save"]) {
        if (self.saveName.length)
            picker_done([self.folder stringByAppendingPathComponent:self.saveName]);
        return;
    }
    if ([self.mode isEqualToString:@"folder"]) {
        NSDictionary* e = self.picked >= 0 && self.picked < (NSInteger)self.entries.count
            ? self.entries[(NSUInteger)self.picked]
            : nil;
        picker_done(e ? e[@"path"] : self.folder);
        return;
    }
    if (self.multiple && self.picks.count) {
        NSMutableArray<NSString*>* all = [NSMutableArray array];
        [self.picks enumerateIndexesUsingBlock:^(NSUInteger i, BOOL*) {
            if (i < self.entries.count && ![self.entries[i][@"dir"] boolValue])
                [all addObject:self.entries[i][@"path"]];
        }];
        if (all.count)
            return picker_done(all.firstObject, all);
    }
    if (self.picked >= 0)
        [self take:self.picked + 1];
}

- (CGRect)row:(NSInteger)i {
    return CGRectMake(0, (CGFloat)i * kRow - self.scroll, kW - 2 * kPad, kRow);
}

- (void)draw {
    CGFloat scale = self.window.backingScaleFactor ?: 2;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    NSString* where = [self.folder stringByAbbreviatingWithTildeInPath];
    self.where.text = self.listing ? [where stringByAppendingString:@"  (loading)"] : where;
    for (CALayer* l in [self.rowsLayer.sublayers copy])
        [l removeFromSuperlayer];
    NSFont* f = [NSFont systemFontOfSize:13];
    NSInteger first = MAX(0, (NSInteger)(self.scroll / kRow)),
              last = MIN((NSInteger)self.entries.count, (NSInteger)((self.scroll + self.listHeight) / kRow) + 1);
    for (NSInteger i = first; i <= last; i++) {
        NSString* name;
        bool dir;
        if (i == 0)
            name = @"..", dir = true;
        else if (i - 1 < (NSInteger)self.entries.count)
            name = self.entries[(NSUInteger)i - 1][@"name"], dir = [self.entries[(NSUInteger)i - 1][@"dir"] boolValue];
        else
            break;
        CGRect r = [self row:i];
        CALayer* icon = [RXLayer layer];
        put_symbol(
            icon,
            symbol(dir ? @"folder.fill" : @"doc", 12, NSFontWeightRegular, [g_theme.fg colorWithAlphaComponent:0.6]),
            NSMakeRect(8, r.origin.y + (kRow - 16) / 2, 16, 16));
        [self.rowsLayer addSublayer:icon];
        RXTextLayer* t =
            label(name, f, i == self.picked + 1 && self.picked >= 0 ? NSColor.whiteColor : g_theme.fg, scale);
        NSSize s = text_size(t, CGFLOAT_MAX);
        t.frame = CGRectMake(32, r.origin.y + (kRow - ceil(s.height)) / 2, MIN(ceil(s.width) + 1, r.size.width - 40),
                             ceil(s.height));
        [self.rowsLayer addSublayer:t];
    }
    self.highlight.hidden = self.picked < 0;
    if (self.picked >= 0)
        self.highlight.frame = CGRectInset([self row:self.picked + 1], 2, 1);
    for (CALayer* x in self.pickLayers)
        [x removeFromSuperlayer];
    [self.pickLayers removeAllObjects];
    [self.picks enumerateIndexesUsingBlock:^(NSUInteger i, BOOL*) {
        if ((NSInteger)i == self.picked)
            return;
        RXLayer* x = [RXLayer layer];
        x.cornerRadius = 4;
        x.backgroundColor = self.highlight.backgroundColor;
        x.opacity = 0.5;
        x.frame = CGRectInset([self row:(NSInteger)i + 1], 2, 1);
        [self.rowsLayer.superlayer insertSublayer:x below:self.rowsLayer];
        [self.pickLayers addObject:x];
    }];
    const bool can = [self.mode isEqualToString:@"folder"]
        || ([self.mode isEqualToString:@"save"] ? self.saveName.length > 0 : self.picked >= 0 || self.picks.count > 0);
    self.open.opacity = can ? 1 : 0.5;
    if (self.nameLabel)
        self.nameLabel.text = self.saveName.length ? self.saveName : @" ";
    [CATransaction commit];
}

- (void)reveal:(NSInteger)i {
    CGRect r = [self row:i + 1];
    if (r.origin.y < 0)
        self.scroll += r.origin.y;
    else if (CGRectGetMaxY(r) > self.listHeight)
        self.scroll += CGRectGetMaxY(r) - self.listHeight;
    self.scroll = MAX(0, MIN(self.scroll, self.maxScroll));
}

- (void)take:(NSInteger)row {
    if (row == 0)
        return [self load:self.folder.stringByDeletingLastPathComponent];
    NSDictionary* e = row - 1 < (NSInteger)self.entries.count ? self.entries[(NSUInteger)row - 1] : nil;
    if (!e)
        return;
    if ([e[@"dir"] boolValue])
        return [self load:e[@"path"]];
    if ([self.mode isEqualToString:@"save"]) {
        self.saveName = e[@"name"];
        return [self draw];
    }
    picker_done(e[@"path"]);
}

- (NSInteger)rowAt:(NSPoint)p {
    CGPoint q = [self.list convertPoint:NSPointToCGPoint(p) fromLayer:self.layer];
    if (!CGRectContainsPoint(self.list.bounds, q))
        return -1;
    NSInteger i = (NSInteger)((q.y + self.scroll) / kRow);
    return i <= (NSInteger)self.entries.count ? i : -1;
}
- (NSInteger)buttonAt:(NSPoint)p {
    CGPoint q = NSPointToCGPoint(p);
    if (CGRectContainsPoint(self.open.frame, q))
        return 1;
    if (CGRectContainsPoint(self.cancel.frame, q))
        return 2;
    return 0;
}
- (void)pointer:(NSPoint)p {
    NSInteger b = NSPointInRect(p, self.bounds) ? [self buttonAt:p] : 0;
    if (b == self.hover_button)
        return;
    self.hover_button = b;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.cancel.borderColor = [g_theme.fg colorWithAlphaComponent:b == 2 ? 0.4 : 0.18].CGColor;
    [CATransaction commit];
}
- (void)pointerLeft:(NSPoint)p {
    [self pointer:NSMakePoint(-1e6, -1e6)];
}
- (void)mouseDown:(NSEvent*)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if (NSInteger b = [self buttonAt:p]) {
        if (b == 2)
            return picker_done(nil);
        return [self confirm];
    }
    NSInteger row = [self rowAt:p];
    if (row < 0)
        return;
    if (ui_clicks(e) >= 2 || row == 0)
        return [self take:row];
    if (self.multiple && (e.modifierFlags & NSEventModifierFlagCommand)) {
        const NSUInteger i = (NSUInteger)row - 1;
        if ([self.picks containsIndex:i])
            [self.picks removeIndex:i];
        else
            [self.picks addIndex:i];
    } else {
        [self.picks removeAllIndexes];
        [self.picks addIndex:(NSUInteger)row - 1];
    }
    self.picked = row - 1;
    [self draw];
}
- (void)mouseDragged:(NSEvent*)e {
}
- (void)mouseUp:(NSEvent*)e {
}
- (void)rightMouseDown:(NSEvent*)e {
}
- (void)scrollWheel:(NSEvent*)e {
    CGFloat d = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 12;
    self.scroll = round(MAX(0, MIN(self.maxScroll, self.scroll - d)));
    [self draw];
}
@end

static void picker_done(NSString* path, NSArray<NSString*>* paths) {
    RXPicker* p = g_picker;
    if (!p)
        return;
    g_picker = nil;
    RXNode* n = p.node;
    CABasicAnimation* a = [CABasicAnimation animationWithKeyPath:@"opacity"];
    a.fromValue = @1, a.toValue = @0, a.duration = 0.12;
    p.layer.opacity = 0;
    [p.layer addAnimation:a forKey:@"out"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 130 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [p removeFromSuperview];
    });
    if (n.doc.ctx)
        doc_call(n.doc, @"emit", @[@(n.uid), path ? @"accepted" : @"rejected", path ? @[path] : @[]]);
    if (path && p.multiple && n.doc.ctx)
        doc_call(n.doc, @"emit", @[@(n.uid), @"acceptedAll", @[paths ?: @[path]]]);
}

void picker_unloaded(RXDoc* doc) {
    if (g_picker && g_picker.node.doc == doc)
        picker_done(nil);
}

bool picker_key(NSEvent* e) {
    RXPicker* p = g_picker;
    if (!p || e.type != NSEventTypeKeyDown)
        return false;
    bool cmd = e.modifierFlags & NSEventModifierFlagCommand;
    NSInteger n = (NSInteger)p.entries.count;
    switch (e.keyCode) {
    case 53:
        picker_done(nil);
        return true;
    case 36:
    case 76:
        [p confirm];
        return true;
    case 51:
        if ([p.mode isEqualToString:@"save"] && p.saveName.length) {
            p.saveName = [p.saveName
                substringToIndex:[p.saveName rangeOfComposedCharacterSequenceAtIndex:p.saveName.length - 1].location];
            [p draw];
        }
        return true;
    case 126:
        if (cmd)
            [p take:0];
        else if (n)
            p.picked = MAX(0, p.picked - 1), [p reveal:p.picked], [p draw];
        return true;
    case 125:
        if (cmd && p.picked >= 0)
            [p take:p.picked + 1];
        else if (n)
            p.picked = MIN(n - 1, p.picked + 1), [p reveal:p.picked], [p draw];
        return true;
    default:
        if ([p.mode isEqualToString:@"save"] && !cmd && e.characters.length && ![e.characters containsString:@"/"] &&
            [e.characters characterAtIndex:0] >= 0x20 && [e.characters characterAtIndex:0] != 0x7f) {
            p.saveName = [p.saveName ?: @"" stringByAppendingString:e.characters];
            [p draw];
        }
        return true;
    }
}

long picker_listed(void) {
    return g_picker && !g_picker.listing ? (long)g_picker.entries.count : -1;
}

void open_file_dialog(RXNode* n) {
    if (g_picker)
        picker_done(nil);
    id<RXHost> host = host_of(n);
    NSWindow* w = host.window ?: dock_window();
    RXRoot* root = root_of(w);
    if (!root)
        return;
    RXPicker* p = [[RXPicker alloc] initWithFrame:NSZeroRect];
    p.node = n;
    p.mode = str(n, P::mode, @"open");
    p.multiple = flag(n, P::multiple, false);
    p.picks = [NSMutableIndexSet indexSet];
    p.pickLayers = [NSMutableArray array];
    p.saveName = str(n, P::name, @"");
    const bool saving = [p.mode isEqualToString:@"save"], choosing = [p.mode isEqualToString:@"folder"];
    NSMutableArray<UTType*>* types = [NSMutableArray array];
    id want = obj(n, P::types);
    for (id t in [want isKindOfClass:[NSArray class]] ? want : want ? @[want] : @[]) {
        NSString* s = [t description];
        UTType* type = [s containsString:@"."] ? [UTType typeWithIdentifier:s] : [UTType typeWithFilenameExtension:s];
        if (type)
            [types addObject:type];
        else
            rexui_log([NSString stringWithFormat:@"FileDialog: no file type %@", s]);
    }
    p.types = types;
    CGFloat scale = w.backingScaleFactor ?: 2;
    CALayer* l = p.layer;
    l.backgroundColor = [g_theme.bg colorWithAlphaComponent:0.98].CGColor;
    l.cornerRadius = 12;
    l.cornerCurve = kCACornerCurveContinuous;
    l.borderWidth = 0.5;
    l.borderColor = [g_theme.fg colorWithAlphaComponent:0.14].CGColor;
    l.shadowOpacity = 0.4, l.shadowRadius = 20, l.shadowOffset = CGSizeMake(0, 8);
    NSString* title = str(n, P::title, @"");
    RXTextLayer* head = label(title.length ? title
                                           : tr(saving         ? @"Save"
                                                    : choosing ? @"Choose"
                                                               : @"Open"),
                              [NSFont boldSystemFontOfSize:13], g_theme.fg, scale);
    NSSize hs = text_size(head, kW - 2 * kPad);
    head.frame = CGRectMake(kPad + 4, 8, ceil(hs.width) + 1, ceil(hs.height));
    [l addSublayer:head];
    p.where = label(@"", [NSFont systemFontOfSize:11], [g_theme.fg colorWithAlphaComponent:0.55], scale);
    p.where.frame = CGRectMake(kPad + 4, 24, kW - 2 * kPad - 8, 14);
    [l addSublayer:p.where];
    p.list = [RXLayer layer];
    p.list.frame = CGRectMake(kPad, kHead, kW - 2 * kPad, kH - kHead - kFoot);
    p.list.masksToBounds = YES;
    p.list.cornerRadius = 6;
    p.list.backgroundColor = [g_theme.fg colorWithAlphaComponent:0.04].CGColor;
    [l addSublayer:p.list];
    p.highlight = [RXLayer layer];
    p.highlight.cornerRadius = 4;
    p.highlight.backgroundColor = (ui_accent() ?: NSColor.controlAccentColor).CGColor;
    p.highlight.hidden = YES;
    [p.list addSublayer:p.highlight];
    p.rowsLayer = [RXLayer layer];
    p.rowsLayer.frame = p.list.bounds;
    [p.list addSublayer:p.rowsLayer];
    auto button = [&](NSString* text, bool primary, CGFloat right) {
        RXLayer* b = [RXLayer layer];
        RXTextLayer* t = label(text, [NSFont systemFontOfSize:13], primary ? NSColor.whiteColor : g_theme.fg, scale);
        NSSize s = text_size(t, CGFLOAT_MAX);
        CGFloat bw = MAX(80, ceil(s.width) + 28);
        b.frame = CGRectMake(right - bw, kH - kFoot + 10, bw, 28);
        b.cornerRadius = 7;
        b.backgroundColor = primary ? (ui_accent() ?: NSColor.controlAccentColor).CGColor
                                    : [g_theme.fg colorWithAlphaComponent:0.06].CGColor;
        b.borderWidth = primary ? 0 : 0.5;
        b.borderColor = [g_theme.fg colorWithAlphaComponent:0.18].CGColor;
        t.frame = CGRectMake((bw - ceil(s.width)) / 2, (28 - ceil(s.height)) / 2, ceil(s.width) + 1, ceil(s.height));
        [b addSublayer:t];
        [l addSublayer:b];
        return b;
    };
    p.open = button(tr(saving ? @"Save" : choosing ? @"Choose" : @"Open"), true, kW - kPad);
    p.cancel = button(tr(@"Cancel"), false, CGRectGetMinX(p.open.frame) - 8);
    if (saving) {
        p.nameLabel = label(p.saveName, p.where.font, g_theme.fg, scale);
        p.nameLabel.frame = CGRectMake(kPad + 4, kH - kFoot + 16, CGRectGetMinX(p.cancel.frame) - kPad - 16, 18);
        [l addSublayer:p.nameLabel];
    }
    NSRect b = root.bounds;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    p.frame = NSMakeRect(round(NSMidX(b) - kW / 2), round(NSMidY(b) - kH / 2), kW, kH);
    [root addHost:p band:kBandMenu];
    [CATransaction commit];
    NSString* folder = str(n, P::folder, @"");
    folder = folder.length ? folder.stringByExpandingTildeInPath : NSHomeDirectory();
    if (!folder.isAbsolutePath)
        folder = [doc_dir(n) stringByAppendingPathComponent:folder];
    g_picker = p;
    [p load:folder];
    CABasicAnimation* a = [CABasicAnimation animationWithKeyPath:@"opacity"];
    a.fromValue = @0, a.toValue = @1, a.duration = 0.12;
    [l addAnimation:a forKey:@"in"];
    [NSApp activateIgnoringOtherApps:YES];
}
