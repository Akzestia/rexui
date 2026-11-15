// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <cstddef>
#include <span>

#include "core/term/vt.h"

namespace rx::term {

struct LinkSpan {
    bool on = false;
    int line0 = 0, col0 = 0, line1 = 0, col1 = 0;
};

const Cell* line_cells(const Terminal& t, int line);
bool line_wraps(const Terminal& t, int line);

LinkSpan hyperlink_at(const Terminal& t, int line, int col);

LinkSpan url_at(const Terminal& t, int line, int col, std::span<char> uri, size_t* len);

}
