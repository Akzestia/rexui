// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <cstdint>
#include <string_view>

#include "gen/rx_props.h"

namespace rx::engine::core {

template<class F>
constexpr void each_default(rx::schema::Elem et, F&& f) noexcept {
    namespace sch = rx::schema;
    const bool list =
        et == sch::Elem::List || et == sch::Elem::Grid || et == sch::Elem::Stack || et == sch::Elem::Panes;
    const sch::Span sp = sch::k_elem_props[static_cast<int>(et)];
    for (uint32_t k = sp.first; k < uint32_t(sp.first) + sp.count; k++) {
        const sch::PropDef& d = sch::k_prop_defs[k];
        bool seen = false;
        for (uint32_t j = sp.first; j < k && !seen; j++)
            seen = sch::k_prop_defs[j].prop == d.prop;
        if (seen || d.js || d.def == sch::Def::unset || (list && d.prop == sch::Prop::model))
            continue;
        f(d);
    }
}

}
