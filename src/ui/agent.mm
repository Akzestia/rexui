// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "ui/ui.h"

#include <fcntl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>

static NSArray* g_agents = @[];
static bool g_finding, g_running;
static NSTask* g_run;

@interface RXAgentConn : NSObject
@property(nonatomic) int fd, ident;
@property(nonatomic, strong) NSMutableData* pending;
@property(nonatomic, strong) dispatch_source_t reader;
@property(nonatomic, strong) NSDictionary* hello;
@property(nonatomic) double active;
@end
@implementation RXAgentConn
@end

static NSMutableArray<RXAgentConn*>* g_conns;
static dispatch_queue_t g_conn_writes;

static void conn_write(RXAgentConn* c, id message) {
    if (![NSJSONSerialization isValidJSONObject:message])
        message = @{@"id": message[@"id"] ?: NSNull.null, @"error": @"not JSON"};
    NSMutableData* d = [json_data(message, 0) mutableCopy];
    [d appendBytes:"\n" length:1];
    int fd = c.fd;
    dispatch_async(g_conn_writes, ^{
        const char* p = (const char*)d.bytes;
        size_t left = d.length;
        while (left) {
            ssize_t n = write(fd, p, left);
            if (n <= 0)
                return;
            p += n, left -= (size_t)n;
        }
    });
}

static void conn_drop(RXAgentConn* c) {
    [g_conns removeObject:c];
    if (c.hello)
        rexui_log([NSString stringWithFormat:@"agent: session %@ (%@) left", c.hello[@"pid"], c.hello[@"cwd"]]);
    debug_agents_changed();
}

static void conn_handle(RXAgentConn* c, NSDictionary* m) {
    NSString* op = [m[@"op"] isKindOfClass:NSString.class] ? m[@"op"] : @"";
    id arg = m[@"arg"] == NSNull.null ? nil : m[@"arg"];
    c.active = CACurrentMediaTime();
    if ([op isEqualToString:@"hello"]) {
        c.hello = [arg isKindOfClass:NSDictionary.class] ? arg : @{};
        rexui_log([NSString stringWithFormat:@"agent: session %@ in %@ connected", c.hello[@"pid"], c.hello[@"cwd"]]);
        conn_write(c, @{@"id": m[@"id"] ?: NSNull.null, @"result": @{@"ok": @YES}});
        debug_agents_changed();
        return;
    }
    static NSSet* allowed = [NSSet setWithArray:@[
        @"state", @"tree", @"inspect", @"edit", @"eval", @"console", @"perf", @"select", @"highlight", @"complete"
    ]];
    id result = [allowed containsObject:op] ? debug_native(op, arg) : nil;
    conn_write(c, @{@"id": m[@"id"] ?: NSNull.null, @"result": result ?: NSNull.null});
    debug_agents_changed();
}

static void conn_accept(int listener) {
    int fd = accept(listener, nullptr, nullptr);
    if (fd < 0)
        return;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    static int next;
    RXAgentConn* c = [RXAgentConn new];
    c.fd = fd, c.ident = ++next, c.pending = [NSMutableData data], c.active = CACurrentMediaTime();
    [g_conns addObject:c];
    dispatch_source_t r =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, dispatch_get_main_queue());
    __weak RXAgentConn* weak = c;
    dispatch_source_set_event_handler(r, ^{
        RXAgentConn* c2 = weak;
        char buf[16384];
        ssize_t n = read(fd, buf, sizeof buf);
        if (n <= 0 || !c2) {
            if (c2)
                conn_drop(c2);
            dispatch_source_cancel(r);
            return;
        }
        [c2.pending appendBytes:buf length:(NSUInteger)n];
        for (;;) {
            const char* bytes = (const char*)c2.pending.bytes;
            const char* nl = (const char*)memchr(bytes, '\n', c2.pending.length);
            if (!nl)
                break;
            NSData* line = [c2.pending subdataWithRange:NSMakeRange(0, (NSUInteger)(nl - bytes))];
            [c2.pending replaceBytesInRange:NSMakeRange(0, (NSUInteger)(nl - bytes) + 1) withBytes:nullptr length:0];
            id m = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
            if ([m isKindOfClass:NSDictionary.class])
                conn_handle(c2, m);
        }
        if (c2.pending.length > (4 << 20)) {
            conn_drop(c2);
            dispatch_source_cancel(r);
        }
    });
    dispatch_source_set_cancel_handler(r, ^{
        close(fd);
    });
    c.reader = r;
    dispatch_resume(r);
}

void agent_listen(void) {
    g_conns = [NSMutableArray array];
    g_conn_writes = dispatch_queue_create("rexui.agent.write", DISPATCH_QUEUE_SERIAL);
    NSString* dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/rexui"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString* path = [dir stringByAppendingPathComponent:@"agent.sock"];
    struct sockaddr_un addr = {};
    addr.sun_family = AF_UNIX;
    if (path.length >= sizeof addr.sun_path)
        return;
    strlcpy(addr.sun_path, path.fileSystemRepresentation, sizeof addr.sun_path);
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    unlink(addr.sun_path);
    if (s < 0 || bind(s, (struct sockaddr*)&addr, sizeof addr) != 0 || listen(s, 8) != 0) {
        rexui_log([NSString stringWithFormat:@"agent: can't listen on %@ (%s)", path, strerror(errno)]);
        if (s >= 0)
            close(s);
        return;
    }
    chmod(addr.sun_path, 0600);
    dispatch_source_t src =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)s, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(src, ^{
        conn_accept(s);
    });
    dispatch_resume(src);
    [[maybe_unused]] static dispatch_source_t keep;
    keep = src;
}

NSArray* agent_list(void) {
    NSMutableArray* out = [NSMutableArray array];
    NSMutableSet* merged = [NSMutableSet set];
    for (NSDictionary* a in g_agents) {
        NSMutableDictionary* e = [a mutableCopy];
        e[@"key"] = a[@"block"], e[@"kind"] = @"pane";
        for (RXAgentConn* c in g_conns) {
            if (c.hello && [c.hello[@"pid"] isEqual:a[@"pid"]]) {
                e[@"live"] = @YES, e[@"active"] = @(c.active);
                [merged addObject:@(c.ident)];
            }
        }
        [out addObject:e];
    }
    for (RXAgentConn* c in g_conns) {
        if (!c.hello || [merged containsObject:@(c.ident)])
            continue;
        NSString* cwd = c.hello[@"cwd"] ?: @"";
        [out addObject:@{
            @"key": [NSString stringWithFormat:@"session:%d", c.ident],
            @"kind": @"session",
            @"agent": @"Claude Code",
            @"title": c.hello[@"title"] ?: @"",
            @"sessionLabel": c.hello[@"where"] ?: @"",
            @"cwd": cwd,
            @"current": @NO,
            @"live": @YES,
            @"active": @(c.active),
            @"block": @"",
            @"session": @""
        }];
    }
    return out;
}

NSString* agent_latest_session(double* when) {
    RXAgentConn* best = nil;
    for (RXAgentConn* c in g_conns) {
        if (c.hello && (!best || c.active > best.active))
            best = c;
    }
    if (when)
        *when = best ? best.active : 0;
    if (!best)
        return nil;
    for (NSDictionary* a in g_agents) {
        if ([best.hello[@"pid"] isEqual:a[@"pid"]])
            return a[@"block"];
    }
    return [NSString stringWithFormat:@"session:%d", best.ident];
}

bool agent_push(NSString* key, NSString* text) {
    if (![key hasPrefix:@"session:"])
        return false;
    int ident = [key substringFromIndex:8].intValue;
    for (RXAgentConn* c in g_conns) {
        if (c.ident != ident)
            continue;
        c.active = CACurrentMediaTime();
        conn_write(c, @{@"event": @"ask", @"text": text ?: @""});
        debug_console_add(@"agent", @"info",
                          [NSString stringWithFormat:@"agent: sent to the session in %@", c.hello[@"cwd"] ?: @"?"]);
        debug_agents_changed();
        return true;
    }
    return false;
}
bool agent_finding(void) {
    return g_finding;
}
bool agent_running(void) {
    return g_running;
}

static NSString* json_of(id o) {
    return [[NSString alloc] initWithData:json_data(o, 0) encoding:NSUTF8StringEncoding];
}

static id api(NSString* method, NSDictionary* args) {
    NSString* err = nil;
    NSData* out = rex_cli(@[@"api", @"call", method, json_of(args)], &err);
    if (!out)
        return nil;
    return [NSJSONSerialization JSONObjectWithData:out options:0 error:nil];
}

static NSString* agent_of(NSDictionary* p) {
    static NSDictionary* known = @{
        @"claude": @"Claude Code",
        @"codex": @"Codex",
        @"gemini": @"Gemini",
        @"aider": @"Aider",
        @"opencode": @"opencode",
        @"cursor-agent": @"Cursor Agent",
        @"amp": @"Amp"
    };
    for (NSString* k in @[@"name", @"argv0", @"invoked_path", @"path"]) {
        NSString* v = [p[k] isKindOfClass:NSString.class] ? [p[k] lastPathComponent] : nil;
        if (v && known[v])
            return known[v];
    }
    return nil;
}

void agent_find(void (^done)(void)) {
    if (g_finding)
        return;
    g_finding = true;
    NSString* current = debug_session_id();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray* blocks = [NSMutableArray array];
        for (id so in array_of(dict_of(api(@"session.list", @{}))[@"sessions"])) {
            NSDictionary* s = dict_of(so);
            NSString* sid = string_of(s[@"session_id"]);
            if (!sid.length)
                continue;
            for (id bo in array_of(dict_of(api(@"session.list_blocks", @{@"session_id": sid}))[@"blocks"])) {
                NSDictionary* b = dict_of(bo);
                NSString* block = string_of(b[@"block_id"]);
                if (block.length && [b[@"creator_name"] isEqual:@"com.superlogical.terminal"])
                    [blocks addObject:@[sid, string_of(s[@"label"]) ?: @"", block]];
            }
        }
        NSMutableArray* found = [NSMutableArray array];
        NSLock* lock = [NSLock new];
        dispatch_apply(blocks.count, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) {
            NSArray* b = blocks[i];
            NSDictionary* proc =
                dict_of(api(@"block.method", @{@"session_id": b[0], @"block_id": b[2], @"method": @"process"}));
            NSDictionary* fg = dict_of(proc[@"foreground"]);
            NSString* agent = fg ? agent_of(fg) : nil;
            if (!agent)
                return;
            NSString* title = string_of(dict_of(
                api(@"block.method", @{@"session_id": b[0], @"block_id": b[2], @"method": @"title"}))[@"title"]);
            NSDictionary* a = @{
                @"session": b[0],
                @"sessionLabel": b[1],
                @"block": b[2],
                @"agent": agent,
                @"title": title ?: @"",
                @"cwd": string_of(fg[@"cwd"]) ?: @"",
                @"current": @([b[0] isEqual:current]),
                @"pid": [fg[@"pid"] isKindOfClass:NSNumber.class] ? fg[@"pid"] : @0
            };
            [lock lock];
            [found addObject:a];
            [lock unlock];
        });
        [found sortUsingComparator:^NSComparisonResult(NSDictionary* x, NSDictionary* y) {
            if ([x[@"current"] boolValue] != [y[@"current"] boolValue])
                return [x[@"current"] boolValue] ? NSOrderedAscending : NSOrderedDescending;
            return [x[@"title"] compare:y[@"title"]];
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            g_agents = found;
            g_finding = false;
            rexui_log([NSString stringWithFormat:@"agent: %lu agent pane(s) in %lu terminal(s)",
                                                 (unsigned long)found.count, (unsigned long)blocks.count]);
            if (done)
                done();
        });
    });
}

void agent_send(NSString* session, NSString* block, NSString* text, bool submit, bool focus) {
    if (![block hasPrefix:@"block:"] || !session.length || !text.length)
        return;
    if (focus && ![session isEqualToString:g_session_id])
        rex_run(@"session.select", @{@"session_id": session});
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        id ok = api(
            @"block.event", @{
                @"session_id": session,
                @"block_id": block,
                @"event": @{@"type": @"paste", @"payload": @{@"text": text}}
            });
        if (ok && submit) {
            usleep(250000);
            api(
                @"block.method",
                @{@"session_id": session,
                  @"block_id": block,
                  @"method": @"write",
                  @"args": @{@"data": @"\r"}});
        }
        if (ok && focus)
            api(@"session.focus_block", @{@"session_id": session, @"block_id": block});
        dispatch_async(dispatch_get_main_queue(), ^{
            debug_console_add(
                @"agent", ok ? @"info" : @"error",
                ok ? [NSString stringWithFormat:@"agent: %@ the element to %@", submit ? @"sent" : @"pasted", block]
                   : [@"agent: couldn't paste into " stringByAppendingString:block]);
        });
    });
}

static NSArray<NSString*>* bin_dirs(void) {
    NSString* home = NSHomeDirectory();
    NSMutableArray* dirs = [@[
        [home stringByAppendingPathComponent:@".local/bin"], [home stringByAppendingPathComponent:@".claude/local"],
        @"/opt/homebrew/bin", @"/usr/local/bin"
    ] mutableCopy];
    for (NSString* d in [NSProcessInfo.processInfo.environment[@"PATH"] componentsSeparatedByString:@":"]) {
        if (d.length && ![dirs containsObject:d])
            [dirs addObject:d];
    }
    return dirs;
}

static NSString* program_path(NSString* name) {
    if ([name containsString:@"/"])
        return name;
    for (NSString* d in bin_dirs()) {
        NSString* p = [d stringByAppendingPathComponent:name];
        if ([NSFileManager.defaultManager isExecutableFileAtPath:p])
            return p;
    }
    return name;
}

void agent_new(NSString* text, NSString* cwd, NSString* program) {
    NSString* session = debug_session_id();
    if (!session.length || !text.length)
        return;
    NSString* name = program.length ? program : @"claude";
    NSString* prompt = [text hasPrefix:@"-"] ? [@" " stringByAppendingString:text] : text;
    NSDictionary* req = @{
        @"session_id": session,
        @"direction": @"horizontal",
        @"side": @"after",
        @"focus": @YES,
        @"layout": @{
            @"block": @{
                @"flavor": @"com.superlogical.terminal.shell",
                @"label": name,
                @"options": @{
                    @"command": @[program_path(name), prompt],
                    @"cwd": cwd ?: @"",
                    @"path_prepend": [bin_dirs() subarrayWithRange:NSMakeRange(0, 4)]
                }
            }
        }
    };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        id ok = api(@"session.new_split", req);
        dispatch_async(dispatch_get_main_queue(), ^{
            debug_console_add(
                @"agent", ok ? @"info" : @"error",
                ok ? @"agent: started in a new pane" : @"agent: no new pane (rex api session.new_split failed)");
        });
    });
}

void agent_run(NSString* text, NSString* cwd) {
    if (g_running || !text.length)
        return;
    NSTask* t = [NSTask new];
    t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/env"];
    t.arguments = @[
        program_path(@"claude"), @"-p", @"--output-format", @"stream-json", @"--verbose", @"--permission-mode",
        @"acceptEdits", @"--allowedTools", @"Read,Edit,Write,Glob,Grep"
    ];
    t.currentDirectoryURL = [NSURL fileURLWithPath:cwd.length ? cwd : NSHomeDirectory()];
    NSMutableDictionary* env = [NSProcessInfo.processInfo.environment mutableCopy];
    [env removeObjectForKey:@"DYLD_INSERT_LIBRARIES"];
    env[@"PATH"] = [NSString stringWithFormat:@"%@/.local/bin:/opt/homebrew/bin:/usr/local/bin:%@", NSHomeDirectory(),
                                              env[@"PATH"] ?: @"/usr/bin:/bin"];
    t.environment = env;
    NSPipe *out = [NSPipe pipe], *err = [NSPipe pipe], *input = [NSPipe pipe];
    t.standardOutput = out, t.standardError = err, t.standardInput = input;
    NSMutableData* buf = [NSMutableData data];
    auto say = ^(NSString* level, NSString* s) {
        dispatch_async(dispatch_get_main_queue(), ^{
            debug_console_add(@"agent", level, s);
        });
    };
    out.fileHandleForReading.readabilityHandler = ^(NSFileHandle* h) {
        NSData* d = h.availableData;
        if (!d.length) {
            h.readabilityHandler = nil;
            return;
        }
        [buf appendData:d];
        for (;;) {
            NSRange nl = [buf rangeOfData:[NSData dataWithBytes:"\n" length:1]
                                  options:0
                                    range:NSMakeRange(0, buf.length)];
            if (nl.location == NSNotFound)
                break;
            NSData* line = [buf subdataWithRange:NSMakeRange(0, nl.location)];
            [buf replaceBytesInRange:NSMakeRange(0, NSMaxRange(nl)) withBytes:nullptr length:0];
            NSDictionary* m = dict_of([NSJSONSerialization JSONObjectWithData:line options:0 error:nil]);
            if (!m)
                continue;
            if ([m[@"type"] isEqual:@"assistant"]) {
                for (id co in array_of(dict_of(m[@"message"])[@"content"])) {
                    NSDictionary* c = dict_of(co);
                    if (NSString* s = string_of(c[@"text"]); [c[@"type"] isEqual:@"text"] && s.length)
                        say(@"log", s);
                    else if ([c[@"type"] isEqual:@"tool_use"]) {
                        NSDictionary* in = dict_of(c[@"input"]);
                        NSString *what = string_of(in[@"file_path"]) ?: string_of(in[@"pattern"]) ?: string_of(in[@"path"]) ?: @"";
                        say(@"info",
                            [NSString stringWithFormat:@"agent: %@ %@", string_of(c[@"name"]) ?: @"?",
                                                       what.lastPathComponent]);
                    }
                }
            } else if ([m[@"type"] isEqual:@"result"]) {
                say(truthy_of(m[@"is_error"]) ? @"error" : @"result", string_of(m[@"result"]) ?: @"done");
            }
        }
    };
    err.fileHandleForReading.readabilityHandler = ^(NSFileHandle* h) {
        NSData* d = h.availableData;
        if (!d.length) {
            h.readabilityHandler = nil;
            return;
        }
        NSString* s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        if (s.length)
            say(@"warn", [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]);
    };
    t.terminationHandler = ^(NSTask* task) {
        int code = task.terminationStatus;
        dispatch_async(dispatch_get_main_queue(), ^{
            g_running = false;
            g_run = nil;
            if (code)
                debug_console_add(@"agent", @"error",
                                  [NSString stringWithFormat:@"agent: claude -p exited with %d", code]);
            debug_agents_changed();
        });
    };
    NSError* e = nil;
    if (![t launchAndReturnError:&e]) {
        debug_console_add(@"agent", @"error",
                          [@"agent: couldn't start claude: " stringByAppendingString:e.localizedDescription ?: @"?"]);
        return;
    }
    NSData* prompt = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle* w = input.fileHandleForWriting;
    (void)fcntl(w.fileDescriptor, F_SETNOSIGPIPE, 1);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [w writeData:prompt error:nil];
        [w closeAndReturnError:nil];
    });
    g_run = t;
    g_running = true;
    debug_console_add(@"agent", @"input", text);
}

void agent_stop(void) {
    [g_run terminate];
}
