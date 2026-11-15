// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "core/text/lexer.h"

namespace rx::text {

namespace {

using V = std::u16string_view;

constexpr V k_cpp_keywords[] = {u"alignas",
                                u"alignof",
                                u"and",
                                u"and_eq",
                                u"asm",
                                u"auto",
                                u"bitand",
                                u"bitor",
                                u"break",
                                u"case",
                                u"catch",
                                u"class",
                                u"compl",
                                u"concept",
                                u"const",
                                u"consteval",
                                u"constexpr",
                                u"constinit",
                                u"const_cast",
                                u"continue",
                                u"co_await",
                                u"co_return",
                                u"co_yield",
                                u"decltype",
                                u"default",
                                u"delete",
                                u"do",
                                u"dynamic_cast",
                                u"else",
                                u"enum",
                                u"explicit",
                                u"export",
                                u"extern",
                                u"false",
                                u"final",
                                u"for",
                                u"friend",
                                u"goto",
                                u"if",
                                u"import",
                                u"inline",
                                u"module",
                                u"mutable",
                                u"namespace",
                                u"new",
                                u"noexcept",
                                u"not",
                                u"not_eq",
                                u"nullptr",
                                u"NULL",
                                u"operator",
                                u"or",
                                u"or_eq",
                                u"override",
                                u"private",
                                u"protected",
                                u"public",
                                u"register",
                                u"reinterpret_cast",
                                u"requires",
                                u"restrict",
                                u"return",
                                u"sizeof",
                                u"static",
                                u"static_assert",
                                u"static_cast",
                                u"struct",
                                u"switch",
                                u"template",
                                u"this",
                                u"thread_local",
                                u"throw",
                                u"true",
                                u"try",
                                u"typedef",
                                u"typeid",
                                u"typename",
                                u"union",
                                u"using",
                                u"virtual",
                                u"volatile",
                                u"while",
                                u"xor",
                                u"xor_eq"};
constexpr V k_cpp_types[] = {
    u"bool",    u"char",          u"char8_t",    u"char16_t",       u"char32_t",  u"double",    u"float",
    u"int",     u"long",          u"short",      u"signed",         u"unsigned",  u"void",      u"wchar_t",
    u"size_t",  u"ssize_t",       u"ptrdiff_t",  u"intptr_t",       u"uintptr_t", u"nullptr_t", u"int8_t",
    u"int16_t", u"int32_t",       u"int64_t",    u"uint8_t",        u"uint16_t",  u"uint32_t",  u"uint64_t",
    u"string",  u"string_view",   u"u16string",  u"u16string_view", u"vector",    u"span",      u"array",
    u"map",     u"unordered_map", u"set",        u"unordered_set",  u"optional",  u"expected",  u"variant",
    u"tuple",   u"pair",          u"unique_ptr", u"shared_ptr",     u"weak_ptr",  u"atomic",    u"function"};
constexpr V k_slash_line[] = {u"//"};
constexpr BlockSpec k_c_block[] = {{u"/*", u"*/", false}};
constexpr BlockSpec k_nested_block[] = {{u"/*", u"*/", true}};
constexpr StringSpec k_cpp_strings[] = {{u"\"", u"\"", u'\\', false, false}, {u"'", u"'", u'\\', false, false}};
constexpr Spec cpp_spec() {
    Spec s;
    s.line_comments = k_slash_line;
    s.block_comments = k_c_block;
    s.strings = k_cpp_strings;
    s.keywords = k_cpp_keywords;
    s.types = k_cpp_types;
    s.preprocessor = u'#';
    s.digit_sep = u'\'';
    s.type_case = true;
    s.raw = Raw::cpp;
    return s;
}

constexpr V k_rust_keywords[] = {u"as",    u"async", u"await",  u"break",  u"const", u"continue", u"crate",
                                 u"dyn",   u"else",  u"enum",   u"extern", u"false", u"fn",       u"for",
                                 u"gen",   u"if",    u"impl",   u"in",     u"let",   u"loop",     u"macro_rules",
                                 u"match", u"mod",   u"move",   u"mut",    u"pub",   u"ref",      u"return",
                                 u"self",  u"Self",  u"static", u"struct", u"super", u"trait",    u"true",
                                 u"type",  u"union", u"unsafe", u"use",    u"where", u"while",    u"yield"};
constexpr V k_rust_types[] = {u"bool", u"char", u"str", u"f16", u"f32", u"f64", u"f128", u"isize", u"usize"};
constexpr StringSpec k_rust_strings[] = {{u"\"", u"\"", u'\\', true, false}, {u"'", u"'", u'\\', false, true}};
constexpr PairSpec k_rust_attrs[] = {{u"#![", u"]"}, {u"#[", u"]"}};
constexpr V k_rust_calls[] = {u"(", u"::<"};
constexpr V k_fn[] = {u"fn"};
constexpr Spec rust_spec() {
    Spec s;
    s.line_comments = k_slash_line;
    s.block_comments = k_nested_block;
    s.strings = k_rust_strings;
    s.attributes = k_rust_attrs;
    s.keywords = k_rust_keywords;
    s.types = k_rust_types;
    s.calls = k_rust_calls;
    s.call_after = k_fn;
    s.type_case = true;
    s.bit_ints = true;
    s.bang_macros = true;
    s.raw = Raw::rust;
    return s;
}

constexpr V k_zig_keywords[] = {
    u"addrspace",      u"align",       u"allowzero", u"and",      u"anyframe",  u"anytype",  u"asm",
    u"async",          u"await",       u"break",     u"callconv", u"catch",     u"comptime", u"const",
    u"continue",       u"defer",       u"else",      u"enum",     u"errdefer",  u"error",    u"export",
    u"extern",         u"false",       u"fn",        u"for",      u"if",        u"inline",   u"linksection",
    u"noalias",        u"noinline",    u"nosuspend", u"null",     u"opaque",    u"or",       u"orelse",
    u"packed",         u"pub",         u"resume",    u"return",   u"struct",    u"suspend",  u"switch",
    u"test",           u"threadlocal", u"true",      u"try",      u"undefined", u"union",    u"unreachable",
    u"usingnamespace", u"var",         u"volatile",  u"while"};
constexpr V k_zig_types[] = {
    u"anyerror",     u"anyopaque", u"bool",   u"c_char",  u"c_int",       u"c_long",   u"c_longdouble",
    u"c_longlong",   u"c_short",   u"c_uint", u"c_ulong", u"c_ulonglong", u"c_ushort", u"comptime_float",
    u"comptime_int", u"f16",       u"f32",    u"f64",     u"f80",         u"f128",     u"isize",
    u"noreturn",     u"type",      u"usize",  u"void"};
constexpr StringSpec k_zig_strings[] = {{u"\"", u"\"", u'\\', false, false}, {u"'", u"'", u'\\', false, false}};
constexpr V k_zig_line_strings[] = {u"\\\\"};
constexpr SigilSpec k_zig_sigils[] = {{u'@', Token::call}};
constexpr Spec zig_spec() {
    Spec s;
    s.line_comments = k_slash_line;
    s.strings = k_zig_strings;
    s.line_strings = k_zig_line_strings;
    s.sigils = k_zig_sigils;
    s.call_after = k_fn;
    s.keywords = k_zig_keywords;
    s.types = k_zig_types;
    s.type_case = true;
    s.bit_ints = true;
    return s;
}

constexpr V k_odin_keywords[] = {u"asm",     u"auto_cast", u"bit_field", u"bit_set",     u"break",    u"case",
                                 u"cast",    u"context",   u"continue",  u"defer",       u"distinct", u"do",
                                 u"dynamic", u"else",      u"enum",      u"fallthrough", u"false",    u"for",
                                 u"foreign", u"if",        u"import",    u"in",          u"map",      u"matrix",
                                 u"nil",     u"not_in",    u"or_break",  u"or_continue", u"or_else",  u"or_return",
                                 u"package", u"proc",      u"return",    u"struct",      u"switch",   u"transmute",
                                 u"true",    u"union",     u"using",     u"when",        u"where"};
constexpr V k_odin_types[] = {
    u"any",       u"b8",         u"b16",     u"b32",    u"b64",   u"bool",         u"byte",          u"complex32",
    u"complex64", u"complex128", u"cstring", u"f16",    u"f16be", u"f16le",        u"f32",           u"f32be",
    u"f32le",     u"f64",        u"f64be",   u"f64le",  u"i16be", u"i16le",        u"i32be",         u"i32le",
    u"i64be",     u"i64le",      u"i128be",  u"i128le", u"int",   u"quaternion64", u"quaternion128", u"quaternion256",
    u"rawptr",    u"rune",       u"string",  u"typeid", u"u16be", u"u16le",        u"u32be",         u"u32le",
    u"u64be",     u"u64le",      u"u128be",  u"u128le", u"uint",  u"uintptr"};
constexpr StringSpec k_odin_strings[] = {{u"\"", u"\"", u'\\', false, false},
                                         {u"`", u"`", 0, true, false},
                                         {u"'", u"'", u'\\', false, false}};
constexpr PairSpec k_odin_attrs[] = {{u"@(", u")"}};
constexpr SigilSpec k_odin_sigils[] = {{u'#', Token::meta}, {u'@', Token::meta}, {u'$', Token::type}};
constexpr V k_odin_calls[] = {u"(", u":: proc", u"::proc", u": proc"};
constexpr Spec odin_spec() {
    Spec s;
    s.line_comments = k_slash_line;
    s.block_comments = k_nested_block;
    s.strings = k_odin_strings;
    s.attributes = k_odin_attrs;
    s.sigils = k_odin_sigils;
    s.keywords = k_odin_keywords;
    s.types = k_odin_types;
    s.calls = k_odin_calls;
    s.type_case = true;
    s.bit_ints = true;
    return s;
}

constexpr V k_lua_keywords[] = {u"and",      u"break",  u"do",   u"else", u"elseif", u"end",  u"false", u"for",
                                u"function", u"goto",   u"if",   u"in",   u"local",  u"nil",  u"not",   u"or",
                                u"repeat",   u"return", u"then", u"true", u"until",  u"while"};
constexpr V k_lua_line[] = {u"--"};
constexpr StringSpec k_lua_strings[] = {{u"\"", u"\"", u'\\', false, false}, {u"'", u"'", u'\\', false, false}};
constexpr V k_lua_calls[] = {u"(", u"\"", u"'", u"{"};
constexpr Spec lua_spec() {
    Spec s;
    s.line_comments = k_lua_line;
    s.long_comment = u"--";
    s.long_brackets = true;
    s.strings = k_lua_strings;
    s.keywords = k_lua_keywords;
    s.calls = k_lua_calls;
    return s;
}

constexpr V k_js_keywords[] = {u"async",    u"await",    u"break",  u"case",  u"catch",      u"class",   u"const",
                               u"continue", u"default",  u"delete", u"do",    u"else",       u"extends", u"finally",
                               u"for",      u"function", u"if",     u"in",    u"instanceof", u"let",     u"new",
                               u"of",       u"return",   u"switch", u"throw", u"try",        u"typeof",  u"var",
                               u"void",     u"while",    u"yield"};
constexpr V k_js_values[] = {u"false", u"null", u"super", u"this", u"true", u"undefined", u"NaN", u"Infinity"};
constexpr StringSpec k_js_strings[] = {{u"\"", u"\"", u'\\', false, false},
                                       {u"'", u"'", u'\\', false, false},
                                       {u"`", u"`", u'\\', true, false, u"${", u"}"}};
constexpr Spec js_spec() {
    Spec s;
    s.line_comments = k_slash_line;
    s.block_comments = k_c_block;
    s.strings = k_js_strings;
    s.keywords = k_js_keywords;
    s.values = k_js_values;
    s.word_chars = u"$";
    s.regex = true;
    s.members = true;
    return s;
}

constexpr V k_conf_words[] = {u"true", u"false", u"yes", u"no", u"on", u"off"};
constexpr V k_hash_line[] = {u"#"};
constexpr Spec conf_spec() {
    Spec s;
    s.line_comments = k_hash_line;
    s.keywords = k_conf_words;
    s.assign = u"=";
    return s;
}

}

const Lang* builtin_lang(std::u16string_view name) noexcept {
    if (name == u"cpp" || name == u"c++" || name == u"cc" || name == u"cxx" || name == u"hpp" || name == u"h"
        || name == u"c") {
        static const Lang lang(cpp_spec());
        return &lang;
    }
    if (name == u"rust" || name == u"rs") {
        static const Lang lang(rust_spec());
        return &lang;
    }
    if (name == u"zig") {
        static const Lang lang(zig_spec());
        return &lang;
    }
    if (name == u"odin") {
        static const Lang lang(odin_spec());
        return &lang;
    }
    if (name == u"lua") {
        static const Lang lang(lua_spec());
        return &lang;
    }
    if (name == u"js" || name == u"javascript") {
        static const Lang lang(js_spec());
        return &lang;
    }
    if (name == u"conf") {
        static const Lang lang(conf_spec());
        return &lang;
    }
    return nullptr;
}

}
