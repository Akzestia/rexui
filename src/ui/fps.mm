// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "ui/ui.h"

@interface RXFpsMeter : NSObject
@property(nonatomic) uint32_t tick;
@property(nonatomic, weak) NSView* view;
@property(nonatomic) int ticks;
@property(nonatomic) double since;
@end

@implementation RXFpsMeter
@end
static void meter_tick(id owner, const RXFrame*) {
    ((RXFpsMeter*)owner).ticks++;
}

static RXFpsMeter* g_meter;
int g_fps;

void fps_update(void) {
    bool wanted = false;
    NSMutableArray<RXDoc*>* readers = [NSMutableArray array];
    for (RXDoc* doc in g_docs) {
        if (doc.ctx && doc.wants_fps && [doc_call(doc, @"wantsFps", @[]) boolValue])
            [readers addObject:doc];
    }
    wanted = readers.count > 0;
    NSWindow* w = wanted ? dock_window() : nil;
    NSView* chrome = w ? chrome_of(w) : nil;
    if (!chrome || g_meter.view != chrome) {
        ui_clock_remove(g_meter.tick);
        g_meter = nil;
    }
    if (!chrome)
        return;
    double now = CACurrentMediaTime();
    if (!g_meter) {
        g_meter = [RXFpsMeter new];
        g_meter.view = chrome;
        g_meter.since = now;
        g_meter.tick = ui_clock_add(RX_TICK_METER, 120, chrome, g_meter, meter_tick);
        return;
    }
    g_fps = (int)lround(g_meter.ticks / MAX(0.001, now - g_meter.since));
    g_meter.ticks = 0;
    g_meter.since = now;
    for (RXDoc* doc in readers)
        doc_call(doc, @"setRex", @[@{@"fps": @(g_fps)}]);
}
