// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "ui/ui.h"

#import <IOKit/ps/IOPSKeys.h>
#import <IOKit/ps/IOPowerSources.h>

static bool g_low, g_battery;
static NSProcessInfoThermalState g_thermal = NSProcessInfoThermalStateNominal;

static NSString* thermal_name(NSProcessInfoThermalState t) {
    switch (t) {
    case NSProcessInfoThermalStateFair:
        return @"fair";
    case NSProcessInfoThermalStateSerious:
        return @"serious";
    case NSProcessInfoThermalStateCritical:
        return @"critical";
    default:
        return @"nominal";
    }
}

static bool on_battery(void) {
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    if (!info)
        return false;
    CFStringRef type = IOPSGetProvidingPowerSourceType(info);
    const bool battery = type && CFStringCompare(type, CFSTR(kIOPMBatteryPowerKey), 0) == kCFCompareEqualTo;
    CFRelease(info);
    return battery;
}

bool power_saving_now(void) {
    return g_config.power_saving && (g_low || g_battery || g_thermal >= NSProcessInfoThermalStateSerious);
}

double power_shader_scale(void) {
    if (!g_config.power_saving)
        return 1;
    if (g_thermal >= NSProcessInfoThermalStateCritical)
        return 0;
    return power_saving_now() ? 0.5 : 1;
}

static NSDictionary* power_state(void) {
    return @{
        @"low": @(g_low),
        @"battery": @(g_battery),
        @"thermal": thermal_name(g_thermal),
        @"saving": @(power_saving_now())
    };
}

void set_power(RXDoc* doc) {
    if (doc.ctx)
        doc_call(doc, @"setPower", @[power_state()]);
}

static void power_changed(void) {
    const bool low = NSProcessInfo.processInfo.lowPowerModeEnabled, battery = on_battery();
    const NSProcessInfoThermalState thermal = NSProcessInfo.processInfo.thermalState;
    if (low == g_low && battery == g_battery && thermal == g_thermal)
        return;
    const bool was = power_saving_now();
    g_low = low, g_battery = battery, g_thermal = thermal;
    rexui_log_file([NSString stringWithFormat:@"power: low power %d, on battery %d, thermal %@: saving %d", low,
                                              battery, thermal_name(thermal), power_saving_now()]);
    for (RXDoc* doc in [g_docs copy])
        set_power(doc);
    if (was != power_saving_now() || thermal >= NSProcessInfoThermalStateCritical
        || thermal == NSProcessInfoThermalStateSerious)
        shaders_power_changed();
}

void power_init(void) {
    if (const char* f = getenv("REXUI_POWER_FIXED")) {
        if (strcmp(f, "critical") == 0)
            g_thermal = NSProcessInfoThermalStateCritical;
        return;
    }
    g_low = NSProcessInfo.processInfo.lowPowerModeEnabled;
    g_battery = on_battery();
    g_thermal = NSProcessInfo.processInfo.thermalState;
    NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in
         @[NSProcessInfoPowerStateDidChangeNotification, NSProcessInfoThermalStateDidChangeNotification])
        [nc addObserverForName:name
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification*) {
                        power_changed();
                    }];
    if (CFRunLoopSourceRef src = IOPSNotificationCreateRunLoopSource(
            [](void*) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    power_changed();
                });
            },
            nullptr)) {
        CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopDefaultMode);
        CFRelease(src);
    }
}

void power_pretend(bool low, bool battery, int thermal) {
    const bool was = power_saving_now();
    g_low = low, g_battery = battery, g_thermal = (NSProcessInfoThermalState)thermal;
    for (RXDoc* doc in [g_docs copy])
        set_power(doc);
    if (was != power_saving_now() || thermal >= NSProcessInfoThermalStateSerious)
        shaders_power_changed();
}
