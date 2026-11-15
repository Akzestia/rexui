// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <cstdint>
#include <string_view>

#include "engine/base/arena.h"
#include "engine/vm/interp.h"
#include "engine/vm/runtime.h"

namespace rx::engine::core {

using vm::Value;

class Doc;

class Sink {
  public:
    virtual void create(uint32_t uid, std::string_view type, uint32_t parent) = 0;
    virtual void set(Doc& doc, uint32_t uid, std::string_view name, Value v) = 0;
    virtual void call(uint32_t uid, std::string_view method, std::string_view arg) = 0;
    virtual void rows(uint32_t, uint32_t) {}
    virtual void row(uint32_t, uint32_t) {}
    virtual void shift(uint32_t, int32_t) {}
    virtual void send(uint32_t uid, std::string_view line) = 0;
    virtual void log(std::string_view msg, std::string_view level) = 0;
    virtual bool source(std::string_view path, std::string_view& text) = 0;
    virtual Value api(Doc& doc, std::string_view global, std::string_view method, const Value* args, uint32_t argc) = 0;
    virtual bool implies_defaults() const noexcept { return false; }

  protected:
    ~Sink() = default;
};

struct Impl;

struct TreeRow {
    uint32_t uid;
    int32_t depth;
    uint32_t children;
    float width, height;
    uint32_t visible;
};

class Doc {
  public:
    explicit Doc(Sink& sink) noexcept;
    ~Doc();
    Doc(const Doc&) = delete;
    Doc& operator=(const Doc&) = delete;

    bool ok() const noexcept { return impl_ != nullptr; }

    std::string_view load(std::string_view src, std::string_view name, std::string_view path) noexcept;

    void emit(uint32_t uid, std::string_view signal, std::string_view json_args) noexcept;
    void line(uint32_t uid, std::string_view text) noexcept;
    void message(uint32_t uid, std::string_view text) noexcept;
    void input(uint32_t uid, std::string_view text) noexcept;
    void update(uint32_t uid, std::string_view json_values) noexcept;
    void toggle(uint32_t uid) noexcept;
    void window(uint32_t uid, uint32_t first, uint32_t count) noexcept;
    bool set_global(std::string_view name, std::string_view json) noexcept;
    bool replay(std::string_view method, std::string_view json_args, std::string_view& result) noexcept;
    std::string_view where(uint32_t uid) noexcept;
    bool alive(uint32_t uid) const noexcept;
    uint32_t promise(Value& out) noexcept;
    void settle(uint32_t handle, std::string_view json, bool rejected) noexcept;
    std::string_view used() noexcept;
    std::string_view debug(std::string_view op, std::string_view json_args) noexcept;
    std::string_view snapshot() noexcept;
    uint32_t restore(std::string_view json) noexcept;
    std::string_view value(uint32_t uid, std::string_view name) noexcept;
    bool parse(std::string_view json, Value& out) noexcept;
    Value tree_rows(Doc& target, const TreeRow* rows, size_t count) noexcept;
    bool wants(std::string_view global, std::string_view key) const noexcept;

    std::string_view json(Value v) noexcept;
    vm::Rt& rt() noexcept;

    struct Stats {
        uint64_t evals = 0, calls = 0;
        size_t heap = 0;
        size_t perm = 0;
        uint64_t collections = 0;
    };
    Stats stats() const noexcept;
    void collect() noexcept;
    void collect_always(bool always) noexcept;

  private:
    Impl* impl_;
};

}
