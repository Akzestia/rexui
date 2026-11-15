// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "base/trace.h"
#include "ui/ui.h"

#include <fcntl.h>
#include <string>
#include <vector>

#include <unistd.h>
#include <unordered_map>
#include "core/io/io.h"
#include "core/io/proto.h"
#include "rexui_proto.h"

@interface RXProcBox : NSObject
@property(nonatomic, weak) RXNode* node;
@property(nonatomic) uint32_t io_id;
@property(nonatomic, copy) NSString* args0;
@property(nonatomic) uint32_t features;
@property(nonatomic) bool v2;
@property(nonatomic) bool decided;
@end
@implementation RXProcBox
@end

NSString* doc_dir(RXNode* n) {
    return n.doc.path.stringByDeletingLastPathComponent;
}

static NSString* distro_of(NSString* dir) {
    NSFileManager* fm = NSFileManager.defaultManager;
    for (NSString* d = dir; d.length > 1 && ![d isEqualToString:NSHomeDirectory()];
         d = d.stringByDeletingLastPathComponent) {
        if ([fm fileExistsAtPath:[d stringByAppendingPathComponent:@"MODULE.bazel"]])
            return d;
    }
    return dir;
}

static NSString* backends_bin(NSString* dir);
NSString* distro_backends_bin(NSString* dir) {
    return backends_bin(dir);
}
static NSString* backends_bin(NSString* dir) {
    char real[PATH_MAX];
    NSString* p = realpath(dir.fileSystemRepresentation, real) ? @(real) : dir;
    if ([p hasPrefix:@"/"])
        p = [p substringFromIndex:1];
    return [NSString stringWithFormat:@"%@/Library/Caches/rexui/distros/%@/bin", NSHomeDirectory(),
                                      [p stringByReplacingOccurrencesOfString:@"/" withString:@"%"]];
}

static NSString* rexui_cli(void) {
    NSString* home = NSProcessInfo.processInfo.environment[@"REXUI_HOME"];
    NSString* mine = home ? [home stringByAppendingPathComponent:@"../src/cli/rexui"].stringByStandardizingPath : nil;
    if (mine && [NSFileManager.defaultManager isExecutableFileAtPath:mine])
        return mine;
    NSString* bin = [NSHomeDirectory() stringByAppendingPathComponent:@".local/bin/rexui"];
    return [NSFileManager.defaultManager isExecutableFileAtPath:bin] ? bin : nil;
}

void build_backends(NSString* dir) {
    static NSMutableSet<NSString*>* building;
    if (!building)
        building = [NSMutableSet set];
    NSFileManager* fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"MODULE.bazel"]]
        || ![fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"backends"]] || [building containsObject:dir]) {
        return;
    }
    NSString* cli = rexui_cli();
    if (!cli) {
        rexui_log([NSString stringWithFormat:@"build: no rexui command (just cli::install) for %@'s backends", dir]);
        return;
    }
    NSTask* task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:cli];
    task.arguments = @[@"build", @"--stale", dir];
    NSMutableDictionary* env = [NSProcessInfo.processInfo.environment mutableCopy];
    [env removeObjectForKey:@"DYLD_INSERT_LIBRARIES"];
    task.environment = env;
    NSPipe* out = [NSPipe pipe];
    task.standardOutput = out, task.standardError = out;
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];
    NSMutableData* text = [NSMutableData data];
    out.fileHandleForReading.readabilityHandler = ^(NSFileHandle* h) {
        NSData* d = h.availableData;
        if (!d.length)
            h.readabilityHandler = nil;
        @synchronized(text) {
            [text appendData:d];
        }
    };
    task.terminationHandler = ^(NSTask* t) {
        int code = t.terminationStatus;
        dispatch_async(dispatch_get_main_queue(), ^{
            [building removeObject:dir];
            NSString* all;
            @synchronized(text) {
                all = [[NSString alloc] initWithData:text encoding:NSUTF8StringEncoding] ?: @"";
            }
            NSMutableArray* lines = [NSMutableArray array];
            for (NSString* l in [all componentsSeparatedByString:@"\n"]) {
                if (([l hasPrefix:@"  "] && ![l hasPrefix:@"  /"]) || [l hasPrefix:@"building "] ||
                    [l hasPrefix:@"ERROR"] || [l hasPrefix:@"rexui:"] || [l containsString:@"error:"]) {
                    [lines addObject:l];
                }
            }
            for (NSString* l in lines)
                rexui_log([@"build: " stringByAppendingString:l]);
            if (code) {
                rexui_log([NSString stringWithFormat:@"build: %@'s backends failed (%d): rexui build %@",
                                                     dir.lastPathComponent, code, dir]);
                return;
            }
            for (RXDoc* doc in g_docs) {
                if (![doc.path.stringByDeletingLastPathComponent isEqualToString:dir])
                    continue;
                for (RXNode* n in doc.nodes.allValues) {
                    if (is_elem(n, E::Process) && !n.pid && n.doc)
                        spawn(n);
                }
            }
        });
    };
    NSError* error = nil;
    if ([task launchAndReturnError:&error])
        [building addObject:dir];
    else
        rexui_log([NSString stringWithFormat:@"build: cannot run %@: %@", cli, error.localizedDescription]);
}

static NSArray<NSString*>* command_of(RXNode* n) {
    id cmd = obj(n, P::command);
    if ([cmd isKindOfClass:NSString.class])
        return [cmd length] ? @[@"/bin/sh", @"-c", cmd] : nil;
    if (![cmd isKindOfClass:NSArray.class] || [cmd count] == 0)
        return nil;
    NSMutableArray* args = [NSMutableArray array];
    for (id a in cmd)
        [args addObject:[a isKindOfClass:NSString.class] ? a : [a description]];
    NSString* exe = [args[0] stringByExpandingTildeInPath];
    if (!exe.isAbsolutePath && [exe containsString:@"/"])
        exe = [doc_dir(n) stringByAppendingPathComponent:exe];
    args[0] = exe;
    return args;
}

static NSString* resolve_exe(NSString* cmd, NSString* path) {
    if ([cmd containsString:@"/"])
        return cmd;
    for (NSString* dir in [path componentsSeparatedByString:@":"]) {
        NSString* f = [dir stringByAppendingPathComponent:cmd];
        if ([NSFileManager.defaultManager isExecutableFileAtPath:f])
            return f;
    }
    return nil;
}

NSHashTable<RXNode*>* g_spawned;

static void exited(RXNode* n, RXProcBox* box, int code);
static RXProcBox* g_box[rx::io::k_max];

struct Pending {
    uint32_t io_id;
    RXPromise* promise;
    NSString* json;
    __weak RXNode* node;
};
static std::unordered_map<uint64_t, Pending> g_calls;
static uint64_t g_call_seq;

static void calls_end(uint32_t io_id, NSString* why) {
    for (auto it = g_calls.begin(); it != g_calls.end();) {
        if (it->second.io_id != io_id) {
            ++it;
            continue;
        }
        RXPromise* p = it->second.promise;
        it = g_calls.erase(it);
        [p reject:why];
    }
}

static void replied(std::string_view text, int flags) {
    if (text.size() < 8)
        return;
    uint64_t seq = rexui_get_u64(reinterpret_cast<const uint8_t*>(text.data()));
    auto it = g_calls.find(seq);
    if (it == g_calls.end())
        return;
    RXPromise* p = it->second.promise;
    g_calls.erase(it);
    NSData* d = [NSData dataWithBytes:text.data() + 8 length:text.size() - 8];
    id v = [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingFragmentsAllowed error:nil];
    if (flags & REXUI_REPLY_ERROR) {
        NSString* why =
            [v isKindOfClass:NSString.class] ? v : [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        [p reject:why.length ? why : @"the backend rejected the call"];
    } else {
        [p resolve:v ?: NSNull.null];
    }
}

static void calls_decided(RXProcBox* box) {
    box.decided = true;
    bool takes = box.v2 && (box.features & rx::io::proto::k_call);
    for (auto it = g_calls.begin(); it != g_calls.end();) {
        Pending& c = it->second;
        if (c.io_id != box.io_id || !c.json) {
            ++it;
            continue;
        }
        NSString* j = c.json;
        c.json = nil;
        if (takes && rx::io::call(box.io_id, it->first, j.UTF8String ?: "null")) {
            ++it;
            continue;
        }
        RXPromise* p = c.promise;
        it = g_calls.erase(it);
        [p reject:takes ? @"the backend isn't reading its stdin"
                        : @"the backend doesn't take calls (protocol 2's \"call\")"];
    }
}

RXPromise* process_call(RXNode* n, NSString* json) {
    RXPromise* p = [RXPromise new];
    RXProcBox* box = n.proc_box;
    if (!box || !n.io_id) {
        id cmd = obj(n, P::command);
        if (flag(n, P::running, true) && ([cmd isKindOfClass:NSArray.class] ? [cmd count] : [string_of(cmd) length])) {
            g_calls[++g_call_seq] = {0, p, json ?: @"null", n};
            return p;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [p reject:@"the backend isn't running"];
        });
        return p;
    }
    if (!box.decided) {
        g_calls[++g_call_seq] = {box.io_id, p, json ?: @"null"};
        return p;
    }
    if (!box.v2 || !(box.features & rx::io::proto::k_call)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [p reject:@"the backend doesn't take calls (protocol 2's \"call\")"];
        });
        return p;
    }
    uint64_t seq = ++g_call_seq;
    const char* j = json.UTF8String ?: "null";
    if (!rx::io::call(box.io_id, seq, j)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [p reject:@"the backend isn't reading its stdin"];
        });
        return p;
    }
    g_calls[seq] = {box.io_id, p};
    return p;
}
static CFRunLoopSourceRef g_io_source;

void process_io_event(uint32_t id, int kind, int code, std::string_view text) {
    if (kind == 0xff) {
        RXProcBox* b = g_box[id & 0xFF];
        if (b && b.io_id == id && !b.decided)
            calls_decided(b);
        return;
    }
    rx::io::Event e{id, static_cast<rx::io::Kind>(kind), code, text};
    if (e.kind == rx::io::Kind::exit)
        rx::io::release(e.id), calls_end(e.id, @"the backend exited");
    RXProcBox* box = g_box[e.id & 0xFF];
    if (!box || box.io_id != e.id)
        return;
    if (e.kind == rx::io::Kind::exit)
        g_box[e.id & 0xFF] = nil;
    RXNode* n = box.node;
    if (!n || n.proc_box != box || !n.doc)
        return;
    if (e.kind == rx::io::Kind::exit)
        return exited(n, box, e.code);
    if (e.kind == rx::io::Kind::hello) {
        box.v2 = true, box.features = static_cast<uint32_t>(e.code);
        calls_decided(box);
        rexui_log([NSString stringWithFormat:@"%@ [%@]: protocol 2 (%@%@%@)", n.doc.path.lastPathComponent,
                                             box.args0 ?: @"?", box.features & rx::io::proto::k_patch ? @"patch " : @"",
                                             box.features & rx::io::proto::k_call ? @"call " : @"",
                                             box.features & rx::io::proto::k_credit ? @"credit" : @""]);
        return;
    }
    if (e.kind == rx::io::Kind::reply)
        return replied(e.text, e.code);
    if (e.kind == rx::io::Kind::out && !box.decided)
        calls_decided(box);
    RX_INTERVAL(ingest, "line");
    NSString* line =
        [[NSString alloc] initWithBytes:e.text.data() length:e.text.size() encoding:NSUTF8StringEncoding] ?: @"";
    if (e.kind == rx::io::Kind::err) {
        rexui_log(
            [NSString stringWithFormat:@"%@ [%@]: %@", n.doc.path.lastPathComponent, str(n, P::command, @"?"), line]);
    } else if (n.doc.ctx) {
        doc_call(n.doc, e.code == 1 ? @"line" : @"message", @[@(n.uid), line]);
    }
}

static void on_event(void*, const rx::io::Event& e) {
    process_io_event(e.id, static_cast<int>(e.kind), e.code, e.text);
}

static void io_drain(void*) {
    (void)rx::io::drain(on_event, nullptr);
}

static bool io_start(void) {
    static bool ok;
    if (ok)
        return true;
    if (engine_take_io())
        return ok = true;
    CFRunLoopSourceContext ctx{};
    ctx.perform = io_drain;
    g_io_source = CFRunLoopSourceCreate(nullptr, 0, &ctx);
    CFRunLoopAddSource(CFRunLoopGetMain(), g_io_source, kCFRunLoopCommonModes);
    CFRunLoopObserverRef obs =
        CFRunLoopObserverCreateWithHandler(nullptr, kCFRunLoopBeforeWaiting | kCFRunLoopAfterWaiting, true, 0,
                                           ^(CFRunLoopObserverRef, CFRunLoopActivity a) {
                                               if (a == kCFRunLoopAfterWaiting)
                                                   return rx::io::main_awake();
                                               rx::io::main_sleeping();
                                               if (rx::io::pending()) {
                                                   rx::io::main_awake();
                                                   CFRunLoopSourceSignal(g_io_source);
                                                   CFRunLoopWakeUp(CFRunLoopGetMain());
                                               }
                                           });
    CFRunLoopAddObserver(CFRunLoopGetMain(), obs, kCFRunLoopCommonModes);
    ok = rx::io::start(
        [](void*) {
            CFRunLoopSourceSignal(g_io_source);
            CFRunLoopWakeUp(CFRunLoopGetMain());
        },
        nullptr);
    if (ok) {
        [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationWillTerminateNotification
                                                        object:nil
                                                         queue:nil
                                                    usingBlock:^(NSNotification*) {
                                                        rx::io::stop_all();
                                                    }];
    } else {
        rexui_log(@"process: the io thread couldn't start: no backends");
    }
    return ok;
}

void spawn(RXNode* n) {
    RX_INTERVAL(spawn, "spawn");
    stop(n);
    NSArray<NSString*>* args = command_of(n);
    if (!args || !flag(n, P::running, true) || !n.doc)
        return;
    if (!io_start())
        return;
    if (!g_spawned)
        g_spawned = [NSHashTable weakObjectsHashTable];
    [g_spawned addObject:n];
    NSMutableDictionary* env = [NSProcessInfo.processInfo.environment mutableCopy];
    [env removeObjectForKey:@"DYLD_INSERT_LIBRARIES"];
    [env removeObjectForKey:@"REX_TRANSPARENT_DUMP"];
    env[@"PATH"] =
        [NSString stringWithFormat:@"%@:%@:%@/.config/rex/backends:%@/.local/bin:/opt/homebrew/bin:/usr/local/bin:%@",
                                   backends_bin(distro_of(doc_dir(n))), backends_bin(ui_dir()), NSHomeDirectory(),
                                   NSHomeDirectory(), env[@"PATH"] ?: @"/usr/bin:/bin:/usr/sbin:/sbin"];
    env[@"REXUI_DISTRO"] = ui_dir();
    if (const char* only = getenv("REXUI_SPAWN_ONLY")) {
        NSString* exe = resolve_exe(args.firstObject.stringByExpandingTildeInPath, env[@"PATH"]);
        if (!exe || ![exe.stringByStandardizingPath hasPrefix:@(only)]) {
            rexui_log([NSString stringWithFormat:@"%@: not spawned (REXUI_SPAWN_ONLY): %@",
                                                 n.doc.path.lastPathComponent, [args componentsJoinedByString:@" "]]);
            return;
        }
    }
    std::vector<std::string> store;
    store.emplace_back("/usr/bin/env");
    for (NSString* a in args)
        store.emplace_back(a.UTF8String ?: "");
    std::vector<std::string> envs;
    for (NSString* k in env)
        envs.emplace_back(std::string(k.UTF8String ?: "") + "=" + ([env[k] UTF8String] ?: ""));
    std::vector<char*> argv, envp;
    for (std::string& a : store)
        argv.push_back(a.data());
    argv.push_back(nullptr);
    for (std::string& e : envs)
        envp.push_back(e.data());
    envp.push_back(nullptr);
    int32_t pid = 0;
    auto id = rx::io::spawn({"/usr/bin/env", argv.data(), envp.data(), doc_dir(n).fileSystemRepresentation}, &pid);
    if (!id) {
        rexui_log([NSString stringWithFormat:@"%@: cannot run %@: %s", n.doc.path.lastPathComponent,
                                             [args componentsJoinedByString:@" "], strerror(id.error())]);
        return;
    }
    RXProcBox* box = [RXProcBox new];
    __weak RXNode* spawned = n;
    for (auto& [seq, c] : g_calls)
        if (!c.io_id && c.node == spawned)
            c.io_id = *id, c.node = nil;
    box.node = n;
    box.io_id = *id;
    box.args0 = args.firstObject;
    g_box[*id & 0xFF] = box;
    n.proc_box = box;
    n.io_id = *id;
    n.pid = pid;
    engine_route(n.doc, n.uid, *id);
    n.started = NSDate.date;
    NSString* prog = args.firstObject;
    if ([prog isEqualToString:@"/bin/sh"] && args.count == 3) {
        NSArray* words = [args[2] componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        prog = [words.firstObject stringByExpandingTildeInPath];
        if (!prog.isAbsolutePath && [prog containsString:@"/"])
            prog = [doc_dir(n) stringByAppendingPathComponent:prog];
    }
    n.exe = resolve_exe(prog, env[@"PATH"]);
    n.exe_mtime =
        n.exe ? [NSFileManager.defaultManager attributesOfItemAtPath:n.exe error:nil].fileModificationDate : nil;
}

static void exited(RXNode* n, RXProcBox* box, int code) {
    if (flag(n, P::restart, true))
        rexui_log([NSString
            stringWithFormat:@"%@: %@ exited with %d", n.doc.path.lastPathComponent, box.args0 ?: @"?", code]);
    n.pid = 0, n.io_id = 0;
    doc_call(n.doc, @"emit", @[@(n.uid), @"exited", @[@(code)]]);
    if (n.proc_box != box || !flag(n, P::restart, true) || !flag(n, P::running, true))
        return;
    if (n.started && -n.started.timeIntervalSinceNow > 30)
        n.failures = 0;
    double delay = MIN(30, 1 << MIN(n.failures, 5));
    n.failures++;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        RXNode* m = box.node;
        if (m && m.proc_box == box && !m.pid && m.doc)
            spawn(m);
    });
}

void stop(RXNode* n) {
    n.generation++;
    if (n.io_id)
        engine_route(nil, 0, n.io_id), rx::io::stop(n.io_id);
    n.io_id = 0, n.pid = 0;
    n.proc_box = nil;
    n.parked = false;
    [n.out setLength:0];
    [n.err setLength:0];
}

static NSMutableDictionary<NSString*, NSMutableArray<NSDictionary*>*>* g_parked;

static NSString* park_key(RXNode* n) {
    NSArray* args = command_of(n);
    return args ? [args componentsJoinedByString:@"\x1f"] : nil;
}

void process_park(RXDoc* doc) {
    NSString* path = doc.path;
    if (!path)
        return;
    NSMutableArray* list = [NSMutableArray array];
    for (NSNumber* uid in [doc.nodes.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        RXNode* n = doc.nodes[uid];
        NSString* key = is_elem(n, E::Process) && n.pid && n.proc_box ? park_key(n) : nil;
        if (!key)
            continue;
        id state = nil;
        if (NSString* j = engine_value(doc, n.uid, @"state"))
            state = [NSJSONSerialization JSONObjectWithData:[j dataUsingEncoding:NSUTF8StringEncoding]
                                                    options:0
                                                      error:nil];
        n.parked = true;
        [list addObject:@{@"key": key, @"node": n, @"state": [state isKindOfClass:NSDictionary.class] ? state : @{}}];
    }
    if (!list.count)
        return;
    if (!g_parked)
        g_parked = [NSMutableDictionary dictionary];
    for (NSDictionary* e in g_parked[path])
        stop(e[@"node"]);
    g_parked[path] = list;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (g_parked[path] != list)
            return;
        for (NSDictionary* e in list)
            stop(e[@"node"]);
        [g_parked removeObjectForKey:path];
    });
}

void process_adopt(RXDoc* doc) {
    NSMutableArray<NSDictionary*>* list = doc.path ? g_parked[doc.path] : nil;
    if (!list)
        return;
    [g_parked removeObjectForKey:doc.path];
    unsigned kept = 0;
    for (NSNumber* uid in [doc.nodes.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        RXNode* n = doc.nodes[uid];
        if (!is_elem(n, E::Process) || n.pid || !flag(n, P::running, true))
            continue;
        NSString* key = park_key(n);
        NSUInteger i = key ? [list indexOfObjectPassingTest:^BOOL(NSDictionary* e, NSUInteger, BOOL*) {
            return [e[@"key"] isEqualToString:key];
        }]
                           : NSNotFound;
        if (i == NSNotFound)
            continue;
        NSDictionary* e = list[i];
        [list removeObjectAtIndex:i];
        RXNode* old = e[@"node"];
        RXProcBox* box = old.proc_box;
        if (!box || !old.pid) {
            stop(old);
            continue;
        }
        n.pid = old.pid, n.io_id = old.io_id, n.started = old.started, n.failures = old.failures;
        n.exe = old.exe, n.exe_mtime = old.exe_mtime;
        [n.out setData:old.out], [n.err setData:old.err];
        n.proc_box = box, box.node = n;
        engine_route(doc, n.uid, n.io_id);
        old.pid = 0, old.io_id = 0, old.proc_box = nil, old.parked = false;
        n.kept = true;
        if (!g_spawned)
            g_spawned = [NSHashTable weakObjectsHashTable];
        [g_spawned addObject:n];
        if ([e[@"state"] count])
            doc_call(doc, @"update", @[@(n.uid), @{@"state": e[@"state"]}]);
        kept++;
    }
    for (NSDictionary* e in list)
        stop(e[@"node"]);
    if (kept)
        rexui_log([NSString stringWithFormat:@"%@: %u Process%@ kept running across the reload",
                                             doc.path.lastPathComponent, kept, kept == 1 ? @"" : @"es"]);
    dispatch_async(dispatch_get_main_queue(), ^{
        for (RXNode* n in doc.nodes.allValues)
            n.kept = false;
    });
}

void send_line(RXNode* n, NSString* line) {
    if (!n.io_id)
        return;
    if (!rx::io::send(n.io_id, line.UTF8String ?: "")) {
        static bool told;
        if (!told)
            told = true,
            rexui_log([NSString stringWithFormat:@"%@: a line to %@ dropped: it isn't reading its stdin",
                                                 n.doc.path.lastPathComponent, str(n, P::command, @"?")]);
    }
}
