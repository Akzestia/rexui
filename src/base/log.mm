// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "core/log/log.h"
#include "base/rexui.h"

#include <stdlib.h>

void (*rexui_log_tap)(NSString* msg);

void rexui_log(NSString* msg) {
    rexui_log_file(msg);
    if (rexui_log_tap)
        rexui_log_tap(msg);
}

static void log_start(void) {
    const char* own = getenv("REXUI_LOG");
    NSString* path = own ? @(own) : [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/rexui.log"];
    rx::log::start(path.fileSystemRepresentation);
    atexit([] { rx::log::flush(300); });
}

void rexui_log_file(NSString* msg) {
    if (!msg)
        msg = @"(null)";
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log_start();
    });
    char buf[2048];
    NSUInteger used = 0;
    NSRange rest;
    if ([msg getBytes:buf
                 maxLength:sizeof buf
                usedLength:&used
                  encoding:NSUTF8StringEncoding
                   options:0
                     range:NSMakeRange(0, msg.length)
            remainingRange:&rest]
        && rest.length == 0) {
        rx::log::write({buf, used});
        return;
    }
    const char* s = msg.UTF8String;
    rx::log::write(s ?: "(a line that isn't UTF-8)");
}

NSString* rexui_suite(void) {
    static NSString* s = [] {
        const char* own = getenv("REXUI_SUITE");
        return own && own[0] ? @(own) : @"rexui";
    }();
    return s;
}
