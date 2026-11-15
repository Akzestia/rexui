// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <cstdint>
#include <string_view>

#include "engine/base/arena.h"
#include "engine/syntax/js.h"
#include "engine/syntax/rui.h"

namespace rx::engine::sema {

enum class Severity : uint8_t { error, warning };

struct Diagnostic {
    Severity severity;
    bool subset;
    bool in_template;
    bool load;
    bool perf;
    std::string_view file;
    std::string_view path;
    uint32_t line;
    uint32_t pos;
    std::string_view msg;
    std::string_view used_at;
};

enum class Class : uint8_t { constant, lang, alias, expr, dynamic, block, handler, function, count_ };
const char* class_name(Class c) noexcept;

struct Stats {
    uint32_t units = 0;
    uint32_t classes[static_cast<int>(Class::count_)] = {};
    uint32_t elements = 0, templates = 0, components = 0;
};

class Reader {
  public:
    virtual bool read(std::string_view path, std::string_view& text) = 0;

  protected:
    ~Reader() = default;
};

struct Result {
    List<Diagnostic> diags;
    List<std::string_view> components;
    Stats stats;
};

Result check(std::string_view path, std::string_view name, std::string_view src, Reader& reader, Arena& arena) noexcept;

}
