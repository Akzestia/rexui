// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#ifdef __clang_analyzer__
#define RX_ASSUME(c)                 \
    do {                             \
        if (!(c))                    \
            __builtin_unreachable(); \
    } while (0)
#define RX_ANALYZER_ZERO = {}
#else
#define RX_ASSUME(c) ((void)0)
#define RX_ANALYZER_ZERO
#endif
