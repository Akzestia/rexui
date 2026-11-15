// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#import <AppKit/AppKit.h>

@interface RXHostChrome : NSView
@property(nonatomic, strong) NSView* panes;
@end

void stub_set_bindings(NSArray<NSDictionary*>* bindings);

void stub_calls(void (*each)(const char* name, unsigned long count, void* ctx), void* ctx);
