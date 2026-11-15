// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "base/rexui.h"
#import "chrome/chrome.h"
#import "ui/ui.h"

static dispatch_queue_t ops_queue(void) {
    static dispatch_queue_t q = dispatch_queue_create("rexui.files", DISPATCH_QUEUE_SERIAL);
    return q;
}

static NSString* expand(id p) {
    if (![p isKindOfClass:NSString.class] || ![p length])
        return nil;
    return [p stringByExpandingTildeInPath].stringByStandardizingPath;
}

static NSArray<NSString*>* paths_of(id v) {
    NSMutableArray* out = [NSMutableArray array];
    for (id p in [v isKindOfClass:NSArray.class] ? v : (v ? @[v] : @[]))
        if (NSString* e = expand(p))
            [out addObject:e];
    return out;
}

static double ms(NSDate* d) {
    return d ? floor(d.timeIntervalSince1970 * 1000) : 0;
}

static NSArray<NSURLResourceKey>* keys(void) {
    return @[
        NSURLIsDirectoryKey, NSURLIsPackageKey, NSURLIsHiddenKey, NSURLIsSymbolicLinkKey, NSURLFileSizeKey,
        NSURLTotalFileAllocatedSizeKey, NSURLContentModificationDateKey, NSURLCreationDateKey, NSURLContentTypeKey,
        NSURLLocalizedTypeDescriptionKey, NSURLTagNamesKey, NSURLIsReadableKey, NSURLIsWritableKey,
        NSURLIsApplicationKey
    ];
}

static NSDictionary* entry(NSURL* u) {
    NSDictionary* r = [u resourceValuesForKeys:keys() error:nil] ?: @{};
    bool dir = [r[NSURLIsDirectoryKey] boolValue], package = [r[NSURLIsPackageKey] boolValue];
    UTType* type = r[NSURLContentTypeKey];
    NSString* kind = dir && !package                                             ? @"folder"
        : [type conformsToType:UTTypeImage]                                      ? @"image"
        : [type conformsToType:UTTypeMovie] || [type conformsToType:UTTypeVideo] ? @"video"
        : [type conformsToType:UTTypeAudio]                                      ? @"audio"
        : [type conformsToType:UTTypeSourceCode]                                 ? @"code"
        : [type conformsToType:UTTypeText]                                       ? @"text"
        : [type conformsToType:UTTypePDF]                                        ? @"pdf"
        : [type conformsToType:UTTypeArchive]                                    ? @"archive"
        : [r[NSURLIsApplicationKey] boolValue]                                   ? @"app"
                                                                                 : @"file";
    return @{
        @"name": u.lastPathComponent ?: @"",
        @"path": u.path ?: @"",
        @"dir": @(dir && !package),
        @"package": @(package),
        @"hidden": @([r[NSURLIsHiddenKey] boolValue] || [u.lastPathComponent hasPrefix:@"."]),
        @"link": @([r[NSURLIsSymbolicLinkKey] boolValue]),
        @"size": r[NSURLFileSizeKey] ?: @0,
        @"modified": @(ms(r[NSURLContentModificationDateKey])),
        @"created": @(ms(r[NSURLCreationDateKey])),
        @"kind": kind,
        @"type": r[NSURLLocalizedTypeDescriptionKey] ?: @"",
        @"uti": type.identifier ?: @"",
        @"ext": u.pathExtension.lowercaseString ?: @"",
        @"tags": r[NSURLTagNamesKey] ?: @[],
        @"readable": @([r[NSURLIsReadableKey] boolValue]),
        @"writable": @([r[NSURLIsWritableKey] boolValue])
    };
}

static id list(NSString* path, bool hidden, NSString** err) {
    NSURL* dir = [NSURL fileURLWithPath:path isDirectory:YES];
    NSError* e;
    NSArray<NSURL*>* urls =
        [NSFileManager.defaultManager contentsOfDirectoryAtURL:dir
                                    includingPropertiesForKeys:keys()
                                                       options:hidden ? 0 : NSDirectoryEnumerationSkipsHiddenFiles
                                                         error:&e];
    if (!urls) {
        *err = e.localizedDescription ?: @"can't read the folder";
        return nil;
    }
    NSMutableArray* entries = [NSMutableArray arrayWithCapacity:urls.count];
    for (NSURL* u in urls)
        [entries addObject:entry(u)];
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
        if ([a[@"dir"] boolValue] != [b[@"dir"] boolValue])
            return [a[@"dir"] boolValue] ? NSOrderedAscending : NSOrderedDescending;
        return [a[@"name"] localizedStandardCompare:b[@"name"]];
    }];
    return @{
        @"path": path,
        @"name": path.lastPathComponent ?: @"/",
        @"parent": [path isEqualToString:@"/"] ? @"" : path.stringByDeletingLastPathComponent,
        @"entries": entries
    };
}

static NSDictionary* places(void) {
    NSString* home = NSHomeDirectory();
    NSFileManager* fm = NSFileManager.defaultManager;
    NSMutableArray* fav = [NSMutableArray array];
    NSArray* spots = @[
        @[home, @"house"], @[@"Desktop", @"menubar.dock.rectangle"], @[@"Documents", @"doc"],
        @[@"Downloads", @"arrow.down.circle"], @[@"Pictures", @"photo"], @[@"Movies", @"film"],
        @[@"Music", @"music.note"], @[@"/Applications", @"square.grid.2x2"],
        @[@"Library/Mobile Documents/com~apple~CloudDocs", @"icloud"]
    ];
    for (NSArray* s in spots) {
        NSString* p = [s[0] isAbsolutePath] ? s[0] : [home stringByAppendingPathComponent:s[0]];
        BOOL dir;
        if (![fm fileExistsAtPath:p isDirectory:&dir] || !dir)
            continue;
        NSString* name = [p isEqualToString:home] ? NSUserName()
            : [s[0] hasPrefix:@"Library/Mobile"]  ? @"iCloud Drive"
                                                  : p.lastPathComponent;
        [fav addObject:@{@"name": name, @"path": p, @"icon": s[1]}];
    }
    NSMutableArray* vols = [NSMutableArray array];
    NSArray* vkeys = @[
        NSURLVolumeLocalizedNameKey, NSURLVolumeTotalCapacityKey, NSURLVolumeAvailableCapacityForImportantUsageKey,
        NSURLVolumeIsRemovableKey, NSURLVolumeIsEjectableKey, NSURLVolumeIsInternalKey
    ];
    for (NSURL* v in [fm mountedVolumeURLsIncludingResourceValuesForKeys:vkeys
                                                                 options:NSVolumeEnumerationSkipHiddenVolumes]) {
        NSDictionary* r = [v resourceValuesForKeys:vkeys error:nil];
        [vols addObject:@{@"name" : r[NSURLVolumeLocalizedNameKey] ?: v.lastPathComponent ?: @"/", @"path" : v.path ?: @"/",
                          @"capacity" : r[NSURLVolumeTotalCapacityKey] ?: @0, @"free" : r[NSURLVolumeAvailableCapacityForImportantUsageKey] ?: @0,
                          @"removable" : @([r[NSURLVolumeIsRemovableKey] boolValue] || [r[NSURLVolumeIsEjectableKey] boolValue]),
                          @"internal" : @([r[NSURLVolumeIsInternalKey] boolValue])}];
    }
    return @{
        @"home": home,
        @"favourites": fav,
        @"volumes": vols,
        @"trash": [home stringByAppendingPathComponent:@".Trash"]
    };
}

static NSMutableArray<NSDictionary*>* g_undo;

static NSString* free_name(NSString* dir, NSString* name) {
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* p = [dir stringByAppendingPathComponent:name];
    if (![fm fileExistsAtPath:p])
        return p;
    NSString *base = name.stringByDeletingPathExtension, *ext = name.pathExtension;
    for (int i = 2; i < 10000; i++) {
        NSString* n = [NSString stringWithFormat:@"%@ %d", base, i];
        if (ext.length)
            n = [n stringByAppendingPathExtension:ext];
        p = [dir stringByAppendingPathComponent:n];
        if (![fm fileExistsAtPath:p])
            return p;
    }
    return nil;
}

static void remember(NSString* kind, NSArray* pairs) {
    if (!pairs.count)
        return;
    if (!g_undo)
        g_undo = [NSMutableArray array];
    [g_undo addObject:@{@"kind": kind, @"pairs": pairs}];
    while (g_undo.count > 50)
        [g_undo removeObjectAtIndex:0];
}

static NSDictionary* result(NSArray* done, NSArray* failed) {
    return @{@"done": done, @"failed": failed};
}

static NSDictionary* transfer(NSArray<NSString*>* srcs, NSString* dest, bool move) {
    NSFileManager* fm = NSFileManager.defaultManager;
    NSMutableArray *done = [NSMutableArray array], *failed = [NSMutableArray array], *pairs = [NSMutableArray array];
    for (NSString* src in srcs) {
        if ([dest isEqualToString:src] || [dest hasPrefix:[src stringByAppendingString:@"/"]]) {
            [failed addObject:@{@"path": src, @"error": @"can't go into itself"}];
            continue;
        }
        if (move && [src.stringByDeletingLastPathComponent isEqualToString:dest])
            continue;
        NSString* to = free_name(dest, src.lastPathComponent);
        NSError* e;
        bool ok =
            to && (move ? [fm moveItemAtPath:src toPath:to error:&e] : [fm copyItemAtPath:src toPath:to error:&e]);
        if (ok)
            [done addObject:to], [pairs addObject:@[src, to]];
        else
            [failed addObject:@{@"path": src, @"error": e.localizedDescription ?: @"failed"}];
    }
    remember(move ? @"move" : @"copy", pairs);
    return result(done, failed);
}

static NSDictionary* trash(NSArray<NSString*>* paths) {
    NSMutableArray *done = [NSMutableArray array], *failed = [NSMutableArray array], *pairs = [NSMutableArray array];
    for (NSString* p in paths) {
        NSURL* out;
        NSError* e;
        if ([NSFileManager.defaultManager trashItemAtURL:[NSURL fileURLWithPath:p] resultingItemURL:&out error:&e])
            [done addObject:p], [pairs addObject:@[p, out.path ?: @""]];
        else
            [failed addObject:@{@"path": p, @"error": e.localizedDescription ?: @"failed"}];
    }
    remember(@"trash", pairs);
    return result(done, failed);
}

static NSDictionary* undo(void) {
    NSDictionary* op = g_undo.lastObject;
    if (!op)
        return @{@"undone": @"", @"done": @[], @"failed": @[]};
    [g_undo removeLastObject];
    NSFileManager* fm = NSFileManager.defaultManager;
    NSMutableArray *done = [NSMutableArray array], *failed = [NSMutableArray array];
    for (NSArray* pair in [op[@"pairs"] reverseObjectEnumerator]) {
        NSString *from = pair[0], *to = pair[1];
        NSError* e;
        bool ok;
        if ([op[@"kind"] isEqualToString:@"copy"] || [op[@"kind"] isEqualToString:@"mkdir"])
            ok = [fm trashItemAtURL:[NSURL fileURLWithPath:to] resultingItemURL:nil error:&e];
        else
            ok = ![fm fileExistsAtPath:from] && [fm moveItemAtPath:to toPath:from error:&e];
        if (ok)
            [done addObject:from];
        else
            [failed addObject:@{@"path": from, @"error": e.localizedDescription ?: @"its place is taken"}];
    }
    return @{@"undone": op[@"kind"], @"done": done, @"failed": failed};
}

static id search(NSString* query, NSString* scope, int limit, bool content) {
    NSTask* t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/mdfind"];
    NSMutableArray* args = [NSMutableArray array];
    if (scope.length)
        [args addObjectsFromArray:@[@"-onlyin", scope]];
    if (!content)
        [args addObject:@"-name"];
    [args addObject:query];
    t.arguments = args;
    NSPipe* out = [NSPipe pipe];
    t.standardOutput = out;
    t.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![t launchAndReturnError:nil])
        return @[];
    NSMutableArray* found = [NSMutableArray array];
    NSMutableData* buf = [NSMutableData data];
    NSFileHandle* h = out.fileHandleForReading;
    while ((int)found.count < limit) {
        NSData* d = h.availableData;
        if (!d.length)
            break;
        [buf appendData:d];
        NSString* s = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding];
        if (!s)
            continue;
        NSArray* lines = [s componentsSeparatedByString:@"\n"];
        found = [NSMutableArray array];
        for (NSUInteger i = 0; i + 1 < lines.count && (int)found.count < limit; i++)
            if ([lines[i] length])
                [found addObject:entry([NSURL fileURLWithPath:lines[i]])];
    }
    if (t.isRunning)
        [t terminate];
    return found;
}

static id preview(NSString* path, NSUInteger max, NSString** err) {
    NSFileHandle* h = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!h) {
        *err = @"can't read it";
        return nil;
    }
    NSData* d = [h readDataUpToLength:max error:nil];
    [h closeFile];
    if (memchr(d.bytes, 0, d.length))
        return @{@"text": @"", @"binary": @YES};
    NSString* s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    for (NSUInteger cut = 1; !s && cut <= 3 && cut < d.length; cut++)
        s = [[NSString alloc] initWithData:[d subdataWithRange:NSMakeRange(0, d.length - cut)]
                                  encoding:NSUTF8StringEncoding];
    return s ? @{@"text": s, @"binary": @NO} : @{@"text": @"", @"binary": @YES};
}

static NSData* png(CGImageRef image) {
    if (!image)
        return nil;
    NSMutableData* data = [NSMutableData data];
    CGImageDestinationRef dst = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)data, (__bridge CFStringRef)UTTypePNG.identifier, 1, nullptr);
    if (!dst)
        return nil;
    CGImageDestinationAddImage(dst, image, nullptr);
    bool ok = CGImageDestinationFinalize(dst);
    CFRelease(dst);
    return ok ? data : nil;
}

static NSData* icon_png(NSString* path, CGFloat px) {
    NSImage* icon = [NSWorkspace.sharedWorkspace iconForFile:path];
    NSRect r = NSMakeRect(0, 0, px, px);
    CGImageRef cg = [icon CGImageForProposedRect:&r context:nil hints:@{NSImageHintCTM: NSAffineTransform.transform}];
    return png(cg);
}

bool files_image(NSString* source, void (^done)(NSData*)) {
    bool thumb = [source hasPrefix:@"thumb:"];
    if (!thumb && ![source hasPrefix:@"icon:"])
        return false;
    NSString* path = [source substringFromIndex:thumb ? 6 : 5];
    NSRange hash = [path rangeOfString:@"#" options:NSBackwardsSearch];
    if (hash.location != NSNotFound)
        path = [path substringToIndex:hash.location];
    path = path.stringByExpandingTildeInPath;
    if (!thumb) {
        dispatch_async(dispatch_get_main_queue(), ^{
            done(icon_png(path, 128));
        });
        return true;
    }
    QLThumbnailGenerationRequest* req =
        [[QLThumbnailGenerationRequest alloc] initWithFileAtURL:[NSURL fileURLWithPath:path]
                                                           size:CGSizeMake(256, 256)
                                                          scale:2
                                            representationTypes:QLThumbnailGenerationRequestRepresentationTypeAll];
    [QLThumbnailGenerator.sharedGenerator
        generateBestRepresentationForRequest:req
                           completionHandler:^(QLThumbnailRepresentation* rep, NSError*) {
                               NSData* d = rep ? png(rep.CGImage) : nil;
                               if (d)
                                   done(d);
                               else
                                   dispatch_async(dispatch_get_main_queue(), ^{
                                       done(icon_png(path, 256));
                                   });
                           }];
    return true;
}

static NSMapTable<RXDoc*, NSMutableDictionary<NSString*, dispatch_source_t>*>* g_watch;

static void emit_doc(RXDoc* d, NSString* signal, NSArray* args) {
    if (d.ctx && d.root)
        doc_call(d, @"emit", @[@(d.root.uid), signal, args]);
}

static void watch(RXDoc* doc, NSArray<NSString*>* paths) {
    if (!g_watch)
        g_watch = [NSMapTable weakToStrongObjectsMapTable];
    NSMutableDictionary<NSString*, dispatch_source_t>* had =
        [g_watch objectForKey:doc] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, dispatch_source_t>* now = [NSMutableDictionary dictionary];
    for (NSString* p in paths) {
        if (had[p]) {
            now[p] = had[p];
            [had removeObjectForKey:p];
            continue;
        }
        int fd = open(p.fileSystemRepresentation, O_EVTONLY);
        if (fd < 0)
            continue;
        dispatch_source_t s = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_VNODE, fd,
            DISPATCH_VNODE_WRITE | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_ATTRIB,
            dispatch_get_main_queue());
        __weak RXDoc* weak = doc;
        __block int gen = 0;
        dispatch_source_set_event_handler(s, ^{
            int mine = ++gen;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(), ^{
                if (mine == gen)
                    if (RXDoc* d = weak)
                        emit_doc(d, @"filesChanged", @[p]);
            });
        });
        dispatch_source_set_cancel_handler(s, ^{
            close(fd);
        });
        dispatch_resume(s);
        now[p] = s;
    }
    for (dispatch_source_t s in had.allValues)
        dispatch_source_cancel(s);
    [g_watch setObject:now forKey:doc];
}

static double g_finder_until;

static bool routing(void) {
    return [g_config.file_manager isEqualToString:@"rexui"] && CACurrentMediaTime() > g_finder_until;
}

static bool files_route(NSArray<NSString*>* paths) {
    if (!routing() || !paths.count)
        return false;
    __block bool taken = false;
    void (^go)(void) = ^{
        if (!(taken = ui_command(@"client.files")))
            return;
        for (RXDoc* d in [g_docs copy])
            emit_doc(d, @"reveal", @[paths]);
    };
    if (NSThread.isMainThread)
        go();
    else
        dispatch_sync(dispatch_get_main_queue(), go);
    if (taken)
        rexui_log_file(
            [NSString stringWithFormat:@"files: %@ shown by the docks", paths.firstObject.lastPathComponent]);
    return taken;
}

bool files_route_url(NSURL* url) {
    if (!url.isFileURL || !routing())
        return false;
    NSNumber *dir, *package;
    [url getResourceValue:&dir forKey:NSURLIsDirectoryKey error:nil];
    [url getResourceValue:&package forKey:NSURLIsPackageKey error:nil];
    if (!dir.boolValue || package.boolValue)
        return false;
    return files_route(@[url.path]);
}

static void (*orig_activate)(id, SEL, NSArray<NSURL*>*);
static void hook_activate(NSWorkspace* self, SEL sel, NSArray<NSURL*>* urls) {
    NSMutableArray* paths = [NSMutableArray array];
    for (NSURL* u in urls)
        if (u.isFileURL && u.path)
            [paths addObject:u.path];
    if (!files_route(paths))
        orig_activate(self, sel, urls);
}

static BOOL (*orig_select)(id, SEL, NSString*, NSString*);
static BOOL hook_select(NSWorkspace* self, SEL sel, NSString* file, NSString* root) {
    NSString* p = file.length ? file : root;
    return (p.length && files_route(@[p])) ? YES : orig_select(self, sel, file, root);
}

void files_init(void) {
    swizzle(NSWorkspace.class, @selector(activateFileViewerSelectingURLs:), (IMP)hook_activate, (IMP*)&orig_activate);
    swizzle(NSWorkspace.class, @selector(selectFile:inFileViewerRootedAtPath:), (IMP)hook_select, (IMP*)&orig_select);
}

id files_native(RXDoc* doc, NSString* op, NSDictionary* a) {
    NSString* path = expand(a[@"path"]);
    if ([op isEqualToString:@"list"]) {
        bool hidden = truthy_of(a[@"hidden"]);
        return rx_promise(nil, ^id(NSString** err) {
            return path ? list(path, hidden, err) : (*err = @"no path", nil);
        });
    }
    if ([op isEqualToString:@"stat"]) {
        if (!path || ![NSFileManager.defaultManager fileExistsAtPath:path])
            return NSNull.null;
        return entry([NSURL fileURLWithPath:path]);
    }
    if ([op isEqualToString:@"places"])
        return places();
    if ([op isEqualToString:@"watch"]) {
        if (doc)
            watch(doc, paths_of(a[@"paths"]));
        return nil;
    }
    if ([op isEqualToString:@"copy"] || [op isEqualToString:@"move"]) {
        NSArray* srcs = paths_of(a[@"paths"]);
        NSString* dest = expand(a[@"dest"]);
        bool move = [op isEqualToString:@"move"];
        return rx_promise(ops_queue(), ^id(NSString** err) {
            return dest ? transfer(srcs, dest, move) : (*err = @"no folder", nil);
        });
    }
    if ([op isEqualToString:@"rename"]) {
        NSString* name = [a[@"name"] isKindOfClass:NSString.class] ? a[@"name"] : @"";
        return rx_promise(ops_queue(), ^id(NSString** err) {
            if (!path || !name.length || [name containsString:@"/"])
                return (*err = @"not a name", nil);
            NSString* to = [path.stringByDeletingLastPathComponent stringByAppendingPathComponent:name];
            if ([to isEqualToString:path])
                return to;
            if ([NSFileManager.defaultManager fileExistsAtPath:to]
                && ![to.lowercaseString isEqualToString:path.lowercaseString])
                return (*err = [NSString stringWithFormat:@"“%@” is already there", name], nil);
            NSError* e;
            if (![NSFileManager.defaultManager moveItemAtPath:path toPath:to error:&e])
                return (*err = e.localizedDescription ?: @"failed", nil);
            remember(@"rename", @[@[path, to]]);
            return to;
        });
    }
    if ([op isEqualToString:@"mkdir"]) {
        NSString* name =
            [a[@"name"] isKindOfClass:NSString.class] && [a[@"name"] length] ? a[@"name"] : @"untitled folder";
        return rx_promise(ops_queue(), ^id(NSString** err) {
            NSString* to = path ? free_name(path, name) : nil;
            NSError* e;
            if (!to
                || ![NSFileManager.defaultManager createDirectoryAtPath:to
                                            withIntermediateDirectories:NO
                                                             attributes:nil
                                                                  error:&e])
                return (*err = e.localizedDescription ?: @"failed", nil);
            remember(@"mkdir", @[@[to, to]]);
            return to;
        });
    }
    if ([op isEqualToString:@"trash"]) {
        NSArray* ps = paths_of(a[@"paths"]);
        return rx_promise(ops_queue(), ^id(NSString**) {
            return trash(ps);
        });
    }
    if ([op isEqualToString:@"undo"])
        return rx_promise(ops_queue(), ^id(NSString**) {
            return undo();
        });
    if ([op isEqualToString:@"open"]) {
        NSArray* ps = paths_of(a[@"paths"]);
        NSString* app = expand(a[@"app"]);
        NSMutableArray* urls = [NSMutableArray array];
        for (NSString* p in ps)
            [urls addObject:[NSURL fileURLWithPath:p]];
        if (!urls.count)
            return @NO;
        NSWorkspaceOpenConfiguration* cfg = [NSWorkspaceOpenConfiguration configuration];
        if (app)
            [NSWorkspace.sharedWorkspace openURLs:urls
                             withApplicationAtURL:[NSURL fileURLWithPath:app]
                                    configuration:cfg
                                completionHandler:nil];
        else
            for (NSURL* u in urls)
                [NSWorkspace.sharedWorkspace openURL:u configuration:cfg completionHandler:nil];
        return @YES;
    }
    if ([op isEqualToString:@"apps"]) {
        if (!path)
            return @[];
        NSURL* u = [NSURL fileURLWithPath:path];
        NSURL* def = [NSWorkspace.sharedWorkspace URLForApplicationToOpenURL:u];
        NSMutableArray* out = [NSMutableArray array];
        for (NSURL* app in [NSWorkspace.sharedWorkspace URLsForApplicationsToOpenURL:u]) {
            NSDictionary* d = @{
                @"name": [NSFileManager.defaultManager displayNameAtPath:app.path].stringByDeletingPathExtension ?: @"",
                @"path": app.path ?: @"",
                @"default": @([app isEqual:def])
            };
            if ([app isEqual:def])
                [out insertObject:d atIndex:0];
            else
                [out addObject:d];
        }
        return out;
    }
    if ([op isEqualToString:@"search"]) {
        NSString* q = [a[@"query"] isKindOfClass:NSString.class] ? a[@"query"] : @"";
        NSString* scope = expand(a[@"scope"]);
        int limit = int_of(a[@"limit"]) > 0 ? int_of(a[@"limit"]) : 200;
        bool content = truthy_of(a[@"content"]);
        return rx_promise(nil, ^id(NSString**) {
            return q.length ? search(q, scope, limit, content) : @[];
        });
    }
    if ([op isEqualToString:@"read"]) {
        NSUInteger max = [a[@"max"] unsignedIntegerValue] ?: 65536;
        return rx_promise(nil, ^id(NSString** err) {
            return path ? preview(path, MIN(max, (NSUInteger)1 << 20), err) : (*err = @"no path", nil);
        });
    }
    if ([op isEqualToString:@"finder"]) {
        if (!path)
            return @NO;
        g_finder_until = CACurrentMediaTime() + 1;
        [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:path]]];
        return @YES;
    }
    if ([op isEqualToString:@"routing"])
        return @([g_config.file_manager isEqualToString:@"rexui"]);
    return nil;
}
