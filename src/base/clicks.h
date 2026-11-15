// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

struct ClickCounter {
    int button = -1, count = 0;
    double at = -1e9, x = 0, y = 0;

    int press(int b, double t, double px, double py, double interval, double slop = 4) {
        const double dx = px - x, dy = py - y;
        if (b == button && t - at <= interval && t >= at && dx * dx + dy * dy <= slop * slop) {
            count++;
        } else {
            button = b, count = 1, x = px, y = py;
        }
        at = t;
        return count;
    }
    int release(int b) const { return b == button && count > 0 ? count : 1; }
};
