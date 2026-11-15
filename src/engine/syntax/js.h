// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <cstdint>
#include <expected>
#include <string_view>

#include "engine/base/arena.h"

namespace rx::engine::js {

enum class K : uint8_t {
    num,
    str,
    tmpl,
    tagged,
    regex,
    ident,
    null_,
    true_,
    false_,
    array,
    hole,
    object,
    prop,
    spread,
    arrow,
    func,
    unary,
    update,
    binary,
    logical,
    assign,
    cond,
    call,
    new_,
    member,
    index,
    seq,
    paren,
    array_pat,
    object_pat,
    rest,
    default_,
    var,
    declarator,
    if_,
    for_,
    for_in,
    for_of,
    while_,
    do_while,
    switch_,
    case_,
    return_,
    break_,
    continue_,
    try_,
    block,
    expr_stmt,
    empty,
    func_decl,
    block_body,
};

enum : uint8_t {
    f_computed = 1,
    f_shorthand = 2,
    f_method = 4,
    f_expr_body = 8,
    f_prefix = 16,
    f_optional = 32,
    f_chain = 64
};

enum class Op : uint8_t {
    none,
    add,
    sub,
    mul,
    div,
    mod,
    exp,
    eq,
    ne,
    seq,
    sne,
    lt,
    gt,
    le,
    ge,
    shl,
    shr,
    ushr,
    band,
    bor,
    bxor,
    in,
    instanceof,
    and_,
    or_,
    nullish,
    neg,
    plus,
    not_,
    bnot,
    typeof_,
    void_,
    delete_,
    inc,
    dec,
    assign,
    add_a,
    sub_a,
    mul_a,
    div_a,
    mod_a,
    exp_a,
    shl_a,
    shr_a,
    ushr_a,
    band_a,
    bor_a,
    bxor_a,
    and_a,
    or_a,
    nullish_a,
    var_,
    let_,
    const_,
};

struct Node {
    K kind;
    Op op;
    uint8_t flags;
    uint32_t pos, end;
    Node *a, *b, *c, *d;
    Node* next;
    std::string_view text;
    std::string_view flags_text;
    double num;
    void* ref;
};

struct Error {
    uint32_t pos;
    std::string_view msg;
    bool subset;
};

enum class Goal : uint8_t {
    value,
    handler,
    params,
    body,
};

std::expected<Node*, Error> parse(std::string_view file, uint32_t pos, uint32_t len, Goal goal, Arena& arena) noexcept;

std::expected<Node*, Error> parse_function(std::string_view file, uint32_t params_pos, uint32_t params_len,
                                           uint32_t body_pos, uint32_t body_len, Arena& arena) noexcept;

const char* op_name(Op op) noexcept;
const char* kind_name(K k) noexcept;

}
