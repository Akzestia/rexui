// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <cstdint>
#include <expected>
#include <string_view>

#include "engine/base/arena.h"

namespace rx::engine::rui {

inline constexpr uint32_t k_max_depth = 256;

struct Use {
    std::string_view path, as;
    uint32_t line, pos;
    bool has_as;
};
struct Member {
    std::string_view name;
    std::string_view value;
    std::string_view type;
    uint32_t line, pos, value_pos;
    bool has_value;
    bool readonly;
};
struct Function {
    std::string_view name, params, body;
    uint32_t line, pos, params_pos, body_pos;
};
struct Signal {
    std::string_view name, params;
    uint32_t line, pos;
};
struct Element;
struct Object {
    std::string_view name;
    Element* node;
    uint32_t line, pos;
};
struct Element {
    std::string_view type;
    uint32_t line, pos;
    std::string_view id;
    uint32_t id_pos;
    bool has_id;
    List<Member> props, handlers, custom;
    List<Function> functions;
    List<Signal> signals;
    List<Element*> children;
    List<Object> objects;
};
struct File {
    std::string_view src;
    List<Use> uses;
    Element* root;
};

struct Error {
    uint32_t line, pos;
    std::string_view msg;
};

std::expected<File*, Error> parse(std::string_view src, Arena& arena) noexcept;

template<class Out>
void dump(const File& f, Out& out);
template<class Out>
void json_string(std::string_view s, Out& out);

}

#include "engine/syntax/rui_dump.h"
