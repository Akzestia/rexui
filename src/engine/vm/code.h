// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <cstdint>
#include <string_view>

#include "engine/vm/value.h"

namespace rx::engine::vm {

#define RX_OPS(X)                                                                                                     \
    X(loadk)                                                                                       \
    X(undef)                                                                                       \
    X(mov)                                                                                                 \
    X(add) X(sub) X(mul) X(div) X(mod) X(exp) X(shl) X(shr) X(ushr) X(band) X(bor) X(bxor)           \
    X(eq) X(ne) X(seq) X(sne) X(lt) X(gt) X(le) X(ge) X(in)                                                           \
    X(neg) X(plus) X(not_) X(bnot) X(typeof_) X(tonum)                                                  \
    X(tostr)                                                                                     \
    X(jmp)                                                                                            \
    X(jf) X(jt)                                                                  \
    X(jnullish) X(jnotnullish)                                                                                        \
    X(getprop)                                                                        \
    X(getidx)                                                                                           \
    X(setprop)                                                                                  \
    X(setidx)                                               \
    X(del)                                             \
    X(newarr)                                                                             \
    X(apush) X(ahole) X(aspread)                                \
    X(newobj)                                                                                             \
    X(oput)                                                         \
    X(oputk)                                                                         \
    X(ospread)                                                            \
    X(orest)               \
    X(getname) X(setname)                            \
    X(getbase)              \
    X(newenv)                                               \
    X(popenv) X(copyenv)              \
    X(getenv)                                                                           \
    X(getenvchk)                                          \
    X(setenv)                                                                           \
    X(chk)              \
    X(closure)                                   \
    X(call)                          \
    X(callspread)                                         \
    X(newcall)                                             \
    X(ret)                                                                                              \
    X(tryenter)                                                      \
    X(tryleave)                                                                                                       \
    X(keys)                                                                     \
    X(iter)                                                          \
    X(next)            \
    X(regex)                                              \
    X(argc)                                                                        \
    X(rest)                                                                \
    X(arg)                                                             \
    X(throwtdz)                                         \
    X(fail_)       \
    X(halt)

enum class Op : uint8_t {
#define RX_ENUM(n) n,
    RX_OPS(RX_ENUM)
#undef RX_ENUM
        count_
};

struct Ins {
    Op op;
    uint8_t pad;
    uint16_t a, b, c;
};
static_assert(sizeof(Ins) == 8);

struct Code {
    const Ins *ins;
    uint32_t n_ins;
    const Value *consts;
    uint32_t n_consts;
    const Code *const *children;
    uint32_t n_children;
    uint16_t n_regs;
    uint16_t n_params;
    const uint32_t *pos;
    const uint32_t *ends;
    std::string_view src;
    Str *name;
    bool has_env;
    uint16_t env_size;
};

}
