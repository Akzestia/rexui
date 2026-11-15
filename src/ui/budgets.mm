// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "ui/ui.h"

@interface RXBudget : NSObject
@property(nonatomic) double t, ms;
@property(nonatomic) bool said_ms, said_layers;
@end
@implementation RXBudget
@end

static int g_said;
int budgets_said(void) {
    return g_said;
}

void budgets_check(void) {
    static NSMapTable<RXDoc*, RXBudget*>* seen = [NSMapTable weakToStrongObjectsMapTable];
    const double now = CACurrentMediaTime();
    for (RXDoc* d in g_docs) {
        if (!d.ctx)
            continue;
        RXBudget* b = [seen objectForKey:d];
        if (!b)
            [seen setObject:(b = [RXBudget new]) forKey:d];
        NSString* file = d.path.lastPathComponent ?: @"?";
        const double ms = num_of(dict_of(doc_call(d, @"stats", @[]))[@"ms"]);
        if (b.t > 0 && now - b.t > 1 && g_config.budget_engine_ms > 0 && !b.said_ms) {
            const double rate = MAX(0, ms - b.ms) / (now - b.t);
            if (rate > g_config.budget_engine_ms) {
                b.said_ms = true, g_said++;
                NSString* text = [NSString
                    stringWithFormat:@"%@ takes %.1f ms of the engine a second (its budget: %.0f, budget_engine_ms): "
                                     @"what binds or runs that often?",
                                     file, rate, g_config.budget_engine_ms];
                rexui_log([@"budget: " stringByAppendingString:text]);
                debug_console_add(file, @"warn", text);
            }
        }
        b.t = now, b.ms = ms;
        if (g_config.budget_layers > 0 && !b.said_layers) {
            NSUInteger layers = 0;
            for (RXNode* n in d.nodes.objectEnumerator)
                layers += n.layer != nil;
            if (layers > g_config.budget_layers) {
                b.said_layers = true, g_said++;
                NSString* text = [NSString
                    stringWithFormat:
                        @"%@ has %lu layers (its budget: %.0f, budget_layers): a Loader or Drawer { lazy: true } "
                        @"for what isn't shown?",
                        file, (unsigned long)layers, g_config.budget_layers];
                rexui_log([@"budget: " stringByAppendingString:text]);
                debug_console_add(file, @"warn", text);
            }
        }
    }
}
