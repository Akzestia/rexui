// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#import <IOKit/IOKitLib.h>
#import <Metal/Metal.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <sys/resource.h>
#import "base/rexui.h"
#import "rex/rex.h"
#import "ui/ui.h"

static NSMutableDictionary* g_diag;
static NSMutableArray<NSMutableDictionary*>* g_calls;
static NSMutableArray<NSDictionary*>* g_events;
static NSString* g_event_state = @"inactive";
static NSString* g_event_error = @"";
static NSString* g_event_session = @"";
static NSTask* g_events_task;
static NSHashTable<RXDoc*>* g_followers;

static NSString* cli_path(void) {
    return [NSBundle.mainBundle.bundlePath
        stringByAppendingPathComponent:@"Contents/Helpers/Rex Server.rex/Contents/MacOS/rex"];
}

static NSDictionary* state(void) {
    NSMutableDictionary* s = [g_diag ?: @{} mutableCopy];
    s[@"calls"] = [[NSArray alloc] initWithArray:g_calls ?: @[] copyItems:YES];
    s[@"events"] = [g_events copy] ?: @[];
    s[@"eventState"] = g_event_state;
    s[@"eventError"] = g_event_error;
    s[@"following"] = @(g_events_task != nil);
    for (NSString* k in @[@"binary", @"server", @"sync", @"gpu"])
        if (!s[k])
            s[k] = @{};
    return s;
}

static bool wanted(RXDoc* d) {
    return d.ctx && d.wants_diagnostics && [doc_call(d, @"wantsDiagnostics", @[]) boolValue];
}

static void push(void) {
    NSDictionary* s = state();
    for (RXDoc* d in [g_docs copy])
        if (d.ctx && d.wants_diagnostics)
            doc_call(d, @"setDiagnostics", @[s]);
}

static void push_soon(void) {
    static bool queued;
    if (queued)
        return;
    queued = true;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(), ^{
        queued = false;
        push();
    });
}

void diagnostics_doc_loaded(id d) {
    RXDoc* doc = d;
    if (doc.ctx && doc.wants_diagnostics)
        doc_call(doc, @"setDiagnostics", @[state()]);
}

static NSDictionary* bundle_info(NSString* path) {
    NSBundle* b = [NSBundle bundleWithPath:path];
    if (!b)
        return @{};
    NSDictionary* i = b.infoDictionary;
    return @{
        @"path": path,
        @"name": i[@"CFBundleName"] ?: path.lastPathComponent.stringByDeletingPathExtension,
        @"bundleId": b.bundleIdentifier ?: @"",
        @"version": i[@"CFBundleShortVersionString"] ?: @"",
        @"build": i[@"CFBundleVersion"] ?: @"",
        @"executable": b.executablePath ?: @""
    };
}

static NSDictionary* binary(void) {
    NSMutableDictionary* app = [bundle_info(NSBundle.mainBundle.bundlePath) mutableCopy];
    app[@"pid"] = @(getpid());
    app[@"arch"] = @"arm64";
    app[@"started"] =
        @(floor(([NSDate.date timeIntervalSince1970] - NSProcessInfo.processInfo.systemUptime + 0) * 1000));
    app[@"adHoc"] = @YES;
    NSString* stock = @"/Applications/Rex Beta.app";
    NSString* dylib = NSProcessInfo.processInfo.environment[@"DYLD_INSERT_LIBRARIES"] ?: @"";
    return @{
        @"app": app,
        @"stock": bundle_info(stock),
        @"cli": @{@"path": cli_path(), @"exists": @([NSFileManager.defaultManager isExecutableFileAtPath:cli_path()])},
        @"rexui": @{@"dylib": dylib, @"home": NSProcessInfo.processInfo.environment[@"REXUI_HOME"] ?: @""}
    };
}

static double mach_ms(uint64_t t) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom)
        mach_timebase_info(&tb);
    return (double)t * tb.numer / tb.denom / 1e6;
}

static NSDictionary* usage(pid_t pid) {
    static NSMutableDictionary<NSNumber*, NSArray*>* seen = [NSMutableDictionary dictionary];
    rusage_info_v4 ri;
    if (pid <= 0 || proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t*)&ri) != 0)
        return @{@"cpu": @(-1), @"memory": @(-1)};
    double now = CACurrentMediaTime() * 1000, ms = mach_ms(ri.ri_user_time + ri.ri_system_time), cpu = -1;
    if (NSArray* last = seen[@(pid)]) {
        double dt = now - [last[0] doubleValue];
        if (dt > 0)
            cpu = MAX(0, (ms - [last[1] doubleValue]) / dt * 100);
    }
    seen[@(pid)] = @[@(now), @(ms)];
    return @{@"cpu": @(round(cpu * 10) / 10), @"memory": @(round(ri.ri_phys_footprint / 1048576.0 * 10) / 10)};
}

static id json(NSData* d) {
    return d.length ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingFragmentsAllowed error:nil] : nil;
}

static bool g_reading;

static void read_server(void) {
    if (g_reading)
        return;
    g_reading = true;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *err = nil, *verr = nil;
        NSDictionary* status = json(rex_cli(@[@"api", @"call", @"server.status"], &err));
        static NSDictionary* version;
        static NSString* instance;
        if (!version || ![instance isEqualToString:status[@"instance_id"]]) {
            version = json(rex_cli(@[@"api", @"call", @"server.version"], &verr));
            instance = status[@"instance_id"];
        }
        NSDictionary* v = version;
        dispatch_async(dispatch_get_main_queue(), ^{
            g_reading = false;
            if (!g_diag)
                g_diag = [NSMutableDictionary dictionary];
            NSMutableDictionary* s = [NSMutableDictionary dictionary];
            bool ok = [status isKindOfClass:NSDictionary.class];
            s[@"running"] = @(ok);
            s[@"error"] = ok
                ? @""
                : [err ?: @"no answer" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            s[@"socket"] =
                [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/rex/server.sock"];
            if (ok) {
                NSDictionary* map = @{
                    @"pid": @"pid",
                    @"instance_id": @"instanceId",
                    @"host_id": @"hostId",
                    @"started_at": @"startedAt",
                    @"session_count": @"sessions",
                    @"api_revision": @"apiRevision",
                    @"exit_empty": @"exitEmpty"
                };
                for (NSString* k in map)
                    if (status[k])
                        s[map[k]] = status[k];
                if ([status[@"config"] isKindOfClass:NSDictionary.class])
                    s[@"config"] = status[@"config"];
                [s addEntriesFromDictionary:usage([status[@"pid"] intValue])];
            }
            if ([v isKindOfClass:NSDictionary.class]) {
                NSDictionary* map = @{
                    @"rex_version": @"version",
                    @"commit": @"commit",
                    @"built_at": @"builtAt",
                    @"platform": @"platform",
                    @"dirty": @"dirty"
                };
                for (NSString* k in map)
                    if (v[k])
                        s[map[k]] = v[k];
            }
            g_diag[@"server"] = s;
            NSMutableDictionary* sync = [NSMutableDictionary dictionary];
            sync[@"hosts"] = (__bridge_transfer NSArray*)rex_hosts() ?: @[];
            if (ok && [status[@"tailscale"] isKindOfClass:NSDictionary.class])
                sync[@"tailscale"] = status[@"tailscale"];
            if (ok)
                sync[@"apiRevision"] = status[@"api_revision"] ?: @0;
            g_diag[@"sync"] = sync;
            NSMutableDictionary* app = [g_diag[@"binary"][@"app"] mutableCopy];
            if (app) {
                [app addEntriesFromDictionary:usage(getpid())];
                NSMutableDictionary* b = [g_diag[@"binary"] mutableCopy];
                b[@"app"] = app;
                g_diag[@"binary"] = b;
            }
            push();
        });
    });
}

static void gpu_read(NSMutableDictionary<NSNumber*, NSArray*>* byPid, NSDictionary** stats) {
    io_service_t accel = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"));
    if (!accel)
        return;
    CFTypeRef ps = IORegistryEntryCreateCFProperty(accel, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0);
    if (ps)
        *stats = (__bridge_transfer NSDictionary*)ps;
    io_iterator_t it;
    if (IORegistryEntryCreateIterator(accel, kIOServicePlane, kIORegistryIterateRecursively, &it) == KERN_SUCCESS) {
        io_object_t o;
        while ((o = IOIteratorNext(it))) {
            NSString* creator = (__bridge_transfer NSString*)IORegistryEntryCreateCFProperty(
                o, CFSTR("IOUserClientCreator"), kCFAllocatorDefault, 0);
            NSArray* uses = (__bridge_transfer NSArray*)IORegistryEntryCreateCFProperty(o, CFSTR("AppUsage"),
                                                                                        kCFAllocatorDefault, 0);
            IOObjectRelease(o);
            if (![creator isKindOfClass:NSString.class] || ![creator hasPrefix:@"pid "]
                || ![uses isKindOfClass:NSArray.class])
                continue;
            NSRange comma = [creator rangeOfString:@", "];
            if (comma.location == NSNotFound)
                continue;
            int pid = [creator substringWithRange:NSMakeRange(4, comma.location - 4)].intValue;
            NSString* name = [creator substringFromIndex:NSMaxRange(comma)];
            double ns = 0;
            for (NSDictionary* u in uses)
                if ([u isKindOfClass:NSDictionary.class])
                    ns += [u[@"accumulatedGPUTime"] doubleValue];
            NSArray* had = byPid[@(pid)];
            byPid[@(pid)] = @[name, @(ns + [had[1] doubleValue])];
        }
        IOObjectRelease(it);
    }
    IOObjectRelease(accel);
}

static void read_gpu(void) {
    static NSDictionary<NSNumber*, NSArray*>* last;
    static double lastAt;
    NSMutableDictionary<NSNumber*, NSArray*>* now = [NSMutableDictionary dictionary];
    NSDictionary* stats = nil;
    gpu_read(now, &stats);
    double at = CACurrentMediaTime(), dt = (at - lastAt) * 1e9;
    NSMutableArray* procs = [NSMutableArray array];
    double rex = 0, server = 0;
    pid_t me = getpid();
    if (last && dt > 0) {
        for (NSNumber* pid in now) {
            double d = [now[pid][1] doubleValue] - [last[pid][1] doubleValue];
            if (d <= 0 || !last[pid])
                continue;
            double f = MIN(1, d / dt);
            if (pid.intValue == me)
                rex = f;
            if ([now[pid][0] isEqualToString:@"WindowServer"])
                server = f;
            [procs addObject:@{@"pid": pid, @"name": now[pid][0], @"fraction": @(round(f * 10000) / 10000)}];
        }
        [procs sortUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
            return [b[@"fraction"] compare:a[@"fraction"]];
        }];
    }
    last = now, lastAt = at;
    static NSString* device = MTLCreateSystemDefaultDevice().name ?: @"";
    NSMutableDictionary* g = [@{
        @"device": device,
        @"rex": @(round(rex * 10000) / 10000),
        @"windowServer": @(round(server * 10000) / 10000),
        @"processes": [procs subarrayWithRange:NSMakeRange(0, MIN(procs.count, 12))]
    } mutableCopy];
    NSDictionary* keys = @{
        @"Device Utilization %": @"utilization",
        @"Renderer Utilization %": @"renderer",
        @"Tiler Utilization %": @"tiler",
        @"In use system memory": @"memoryInUse",
        @"Alloc system memory": @"memoryAllocated"
    };
    for (NSString* k in keys)
        if ([stats[k] isKindOfClass:NSNumber.class])
            g[keys[k]] = stats[k];
    static NSMutableArray* history = [NSMutableArray array];
    [history addObject:@{
        @"time": @(floor(NSDate.date.timeIntervalSince1970 * 1000)),
        @"rex": g[@"rex"],
        @"utilization": g[@"utilization"] ?: @0
    }];
    while (history.count > 60)
        [history removeObjectAtIndex:0];
    g[@"history"] = [history copy];
    if (!g_diag)
        g_diag = [NSMutableDictionary dictionary];
    g_diag[@"gpu"] = g;
}

static RXPromise* call(NSString* method, id payload) {
    if (!g_calls)
        g_calls = [NSMutableArray array];
    NSString* text = @"";
    if ([payload isKindOfClass:NSString.class])
        text = payload;
    else if (payload && ![payload isKindOfClass:NSNull.class]) {
        NSData* d = json_data(payload, NSJSONWritingFragmentsAllowed);
        text = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"";
    }
    NSMutableDictionary* rec = [@{
        @"id": NSUUID.UUID.UUIDString,
        @"method": method ?: @"",
        @"request": text,
        @"startedAt": @(floor(NSDate.date.timeIntervalSince1970 * 1000)),
        @"outcome": @"pending",
        @"response": @"",
        @"duration": @(-1)
    } mutableCopy];
    [g_calls insertObject:rec atIndex:0];
    while (g_calls.count > 100)
        [g_calls removeLastObject];
    push();
    NSArray* args = text.length ? @[@"api", @"call", method ?: @"", text] : @[@"api", @"call", method ?: @""];
    double t0 = CACurrentMediaTime();
    RXPromise* p = [RXPromise new];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString* err = nil;
        NSData* out = rex_cli(args, &err);
        dispatch_async(dispatch_get_main_queue(), ^{
            rec[@"duration"] = @(round((CACurrentMediaTime() - t0) * 10000) / 10);
            NSString* body = out ? [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding] : nil;
            rec[@"outcome"] = out ? @"success" : @"failure";
            rec[@"response"] =
                (out ? body : [err stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet])
                ?: @"";
            push();
            if (out)
                [p resolve:json(out) ?: body ?: NSNull.null];
            else
                [p reject:rec[@"response"]];
        });
    });
    return p;
}

static void stop_events(void) {
    if (g_events_task.isRunning)
        [g_events_task terminate];
    g_events_task = nil;
    g_event_state = @"inactive";
    push();
}

static void start_events(void) {
    if (g_events_task)
        return;
    NSTask* t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:cli_path()];
    t.arguments = g_event_session.length ? @[@"events", @"--json", @"--session", g_event_session]
                                         : @[@"events", @"--json", @"--all"];
    NSMutableDictionary* env = [NSProcessInfo.processInfo.environment mutableCopy];
    [env removeObjectForKey:@"DYLD_INSERT_LIBRARIES"];
    t.environment = env;
    NSPipe *out = [NSPipe pipe], *err = [NSPipe pipe];
    t.standardOutput = out;
    t.standardError = err;
    NSMutableData* pending = [NSMutableData data];
    __weak NSTask* weak = t;
    out.fileHandleForReading.readabilityHandler = ^(NSFileHandle* h) {
        NSData* d = h.availableData;
        if (!d.length) {
            h.readabilityHandler = nil;
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (g_events_task != weak)
                return;
            [pending appendData:d];
            const char* b = (const char*)pending.bytes;
            NSUInteger start = 0;
            for (NSUInteger i = 0; i < pending.length; i++) {
                if (b[i] != '\n')
                    continue;
                NSData* line = [pending subdataWithRange:NSMakeRange(start, i - start)];
                start = i + 1;
                NSString* text = [[NSString alloc] initWithData:line encoding:NSUTF8StringEncoding];
                if (!text.length)
                    continue;
                NSDictionary* e = json(line);
                if (!g_events)
                    g_events = [NSMutableArray array];
                [g_events insertObject:@{
                    @"id": NSUUID.UUID.UUIDString,
                    @"receivedAt": @(floor(NSDate.date.timeIntervalSince1970 * 1000)),
                    @"type": [e isKindOfClass:NSDictionary.class] ? e[@"type"] ?: @"" : @"",
                    @"session": [e isKindOfClass:NSDictionary.class] ? e[@"session_id"] ?: @"" : @"",
                    @"event": e ?: NSNull.null,
                    @"text": text
                }
                               atIndex:0];
                while (g_events.count > 300)
                    [g_events removeLastObject];
                g_event_state = @"subscribed";
            }
            [pending replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
            push_soon();
        });
    };
    t.terminationHandler = ^(NSTask* task) {
        NSData* e = [err.fileHandleForReading readDataToEndOfFile];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (g_events_task != task)
                return;
            g_events_task = nil;
            g_event_state = @"failed";
            g_event_error = [[[NSString alloc] initWithData:e encoding:NSUTF8StringEncoding] ?: @""
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (!g_event_error.length)
                g_event_error = [NSString stringWithFormat:@"rex events exited (%d)", task.terminationStatus];
            rexui_log([@"diagnostics: events: " stringByAppendingString:g_event_error]);
            push();
        });
    };
    NSError* error;
    if (![t launchAndReturnError:&error]) {
        g_event_state = @"failed";
        g_event_error = error.localizedDescription ?: @"rex events didn't start";
        push();
        return;
    }
    g_events_task = t;
    g_event_state = @"subscribing";
    g_event_error = @"";
    push();
}

static void sync_follow(void) {
    bool any = false;
    for (RXDoc* d in g_followers)
        any |= d.ctx && d.wants_diagnostics;
    if (any)
        start_events();
    else if (g_events_task)
        stop_events();
}

void diagnostics_update(void) {
    static int n;
    bool any = false;
    for (RXDoc* d in g_docs)
        any |= wanted(d);
    if (g_followers.count)
        sync_follow();
    if (!any || n++ % 2)
        return;
    if (!g_diag)
        g_diag = [NSMutableDictionary dictionary];
    if (!g_diag[@"binary"])
        g_diag[@"binary"] = binary();
    read_gpu();
    read_server();
}

id diagnostics_native(RXDoc* doc, NSString* op, NSDictionary* a) {
    if ([op isEqualToString:@"call"])
        return call([a[@"method"] isKindOfClass:NSString.class] ? a[@"method"] : @"", a[@"payload"]);
    if ([op isEqualToString:@"clearCalls"]) {
        [g_calls removeAllObjects];
        push();
    } else if ([op isEqualToString:@"clearEvents"]) {
        [g_events removeAllObjects];
        push();
    } else if ([op isEqualToString:@"follow"]) {
        if (!g_followers)
            g_followers = [NSHashTable weakObjectsHashTable];
        NSString* session = [a[@"session"] isKindOfClass:NSString.class] ? a[@"session"] : @"";
        if (![session isEqualToString:g_event_session] && g_events_task)
            stop_events();
        g_event_session = session;
        if (truthy_of(a[@"on"]) && doc)
            [g_followers addObject:doc];
        else if (doc)
            [g_followers removeObject:doc];
        sync_follow();
        if (!g_followers.count && g_events_task)
            stop_events();
    } else if ([op isEqualToString:@"refresh"]) {
        if (!g_diag)
            g_diag = [NSMutableDictionary dictionary];
        g_diag[@"binary"] = binary();
        read_gpu();
        read_server();
    } else if ([op isEqualToString:@"reveal"]) {
        NSString* p = [a[@"path"] isKindOfClass:NSString.class] ? [a[@"path"] stringByExpandingTildeInPath] : nil;
        if (p.length)
            [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:p]]];
    }
    return nil;
}
