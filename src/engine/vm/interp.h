// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <cstdint>

#include "engine/vm/code.h"
#include "engine/vm/runtime.h"

namespace rx::engine::vm {

struct Env {
    Cell h;
    Env* parent;
    uint32_t size;
    Value slots[1];
};

struct Iter {
    Cell h;
    Value src;
    uint32_t at;
};

class Host {
  public:
    virtual Value get(Rt& rt, Str* name) noexcept = 0;
    virtual bool set(Rt& rt, Str* name, Value v) noexcept = 0;
    virtual Value base(Rt&, Str*) noexcept { return Value::undefined(); }

  protected:
    ~Host() = default;
};

class Vm {
  public:
    Vm(Rt& rt, Host& host) noexcept : rt(rt), host(host) { rt.vm = this; }
    ~Vm() {
        if (rt.vm == this)
            rt.vm = nullptr;
    }
    Rt& rt;
    Host& host;
    int64_t budget = 100000000;
    uint32_t depth = 0;
    static constexpr uint32_t k_max_depth = 200;

    Value run(const Code* code, const Value* args = nullptr, uint32_t argc = 0, Host* in = nullptr) noexcept;
    Value call(Value fn, Value receiver, const Value* args, uint32_t argc) noexcept;

    Native* native = nullptr;

    Value* stack = nullptr;
    uint32_t sp = 0, cap = 0;
};

Value run_code(Vm& vm, const Code* code, Env* env, Value callee, const Value* args, uint32_t argc, Host* host) noexcept;

}
