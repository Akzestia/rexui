// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include <mach-o/dyld.h>
#include <unistd.h>

#include <chrono>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "common/json.h"
#include "engine/base/arena.h"
#include "engine/base/utf.h"
#include "engine/core/doc.h"
#include "engine/sema/check.h"
#include "engine/sema/perf.h"
#include "engine/syntax/js.h"
#include "engine/syntax/rui.h"

namespace {

bool read_file(const char* path, std::string& out) {
    FILE* f = std::fopen(path, "rb");
    if (!f)
        return false;
    char buf[65536];
    for (size_t k; (k = std::fread(buf, 1, sizeof buf, f)) > 0;)
        out.append(buf, k);
    std::fclose(f);
    return true;
}

static std::string kit_dir() {
    char buf[4096];
    uint32_t n = sizeof buf;
    if (_NSGetExecutablePath(buf, &n) != 0)
        return "src/ui/kit";
    char real[PATH_MAX];
    std::string p = realpath(buf, real) ? real : buf;
    for (int up = 0; up < 2; up++) {
        size_t s = p.rfind('/');
        if (s == std::string::npos)
            return "src/ui/kit";
        p.resize(s);
    }
    return p + "/src/ui/kit";
}

static std::string kit_path(std::string p) {
    if (p.rfind("rexui/", 0) == 0)
        return kit_dir() + p.substr(5);
    if (p.rfind("rexshared/", 0) == 0)
        return kit_dir() + "/../../../distros/shared" + p.substr(9);
    return p;
}

class Files final : public rx::engine::sema::Reader {
  public:
    bool read(std::string_view path, std::string_view& text) override {
        std::string p = kit_path(std::string(path));
        if (auto it = texts_.find(p); it != texts_.end()) {
            if (!it->second)
                return false;
            text = *it->second;
            return true;
        }
        std::string real = p;
        if (real == "~" || real.starts_with("~/"))
            real = std::string(std::getenv("HOME") ? std::getenv("HOME") : "") + real.substr(1);
        std::string src;
        if (!read_file(real.c_str(), src)) {
            texts_[p] = nullptr;
            return false;
        }
        store_.push_back(std::move(src));
        texts_[p] = &store_.back();
        text = store_.back();
        return true;
    }
    std::string_view text_of(std::string_view path) const {
        auto it = texts_.find(std::string(path));
        return it == texts_.end() || !it->second ? std::string_view{} : std::string_view(*it->second);
    }
    void add(std::string path, const std::string* src) { texts_[std::move(path)] = src; }

  private:
    std::deque<std::string> store_;
    std::map<std::string, const std::string*> texts_;
};

void line_col(std::string_view src, uint32_t pos, uint32_t& line, uint32_t& col) {
    line = 1;
    size_t start = 0;
    for (size_t k = 0; k < pos && k < src.size(); k++)
        if (src[k] == '\n')
            line++, start = k + 1;
    col = static_cast<uint32_t>(rx::engine::utf::utf16_len(src.substr(start, pos > start ? pos - start : 0))) + 1;
}

std::string base_name(const char* p) {
    const char* s = std::strrchr(p, '/');
    return s ? s + 1 : p;
}

enum class Mode { report, first, stats };

int check(int argc, char** argv, Mode mode, bool json, bool warnings, bool from_stdin = false, bool perf = false) {
    int failed = 0;
    std::string out;
    std::set<std::string> printed;
    rx::engine::sema::Stats total;
    for (int k = 0; k < argc; k++) {
        std::string src;
        out.clear();
        if (from_stdin) {
            char chunk[65536];
            for (size_t m; (m = std::fread(chunk, 1, sizeof chunk, stdin)) > 0;)
                src.append(chunk, m);
        } else if (!read_file(argv[k], src)) {
            std::printf("%s: cannot read the file\n", argv[k]);
            failed++;
            continue;
        }
        Files files;
        files.add(argv[k], &src);
        rx::engine::Arena arena;
        std::string name = base_name(argv[k]);
        auto r = rx::engine::sema::check(argv[k], name, src, files, arena);
        if (perf)
            if (auto tree = rx::engine::rui::parse(src, arena))
                for (const auto& d : rx::engine::sema::perf(**tree, argv[k], name, arena))
                    (void)r.diags.push(arena, d);
        total.units += r.stats.units;
        total.elements += r.stats.elements;
        total.templates += r.stats.templates;
        total.components += r.stats.components;
        for (int c = 0; c < static_cast<int>(rx::engine::sema::Class::count_); c++)
            total.classes[c] += r.stats.classes[c];
        bool bad = false;
        if (mode == Mode::first) {
            for (const auto& d : r.diags) {
                if (!d.load)
                    continue;
                out += std::string(d.file) + ":" + std::to_string(d.line) + ": " + std::string(d.msg);
                if (!d.used_at.empty())
                    out += " (used at " + std::string(d.used_at) + ")";
                break;
            }
            if (out.empty()) {
                size_t comps = 0;
                for (std::string_view p : r.components)
                    comps += !files.text_of(p).empty();
                out = name + ": ok"
                    + (comps ? " (with " + std::to_string(comps) + " component file" + (comps == 1 ? ")" : "s)") : "");
            }
            std::printf("%s\n", out.c_str());
            continue;
        }
        for (const auto& d : r.diags) {
            bool err = d.severity == rx::engine::sema::Severity::error;
            if (!err && !warnings && !(perf && d.perf))
                continue;
            bad = bad || err;
            uint32_t line, col;
            std::string_view text = d.path == std::string_view(argv[k]) ? std::string_view(src) : files.text_of(d.path);
            line_col(text, d.pos, line, col);
            if (mode == Mode::stats)
                continue;
            if (json) {
                out = "{\"file\":";
                rx::engine::rui::json_string(d.file, out);
                out += ",\"path\":";
                rx::engine::rui::json_string(d.path, out);
                out += ",\"line\":" + std::to_string(line) + ",\"col\":" + std::to_string(col);
                out += ",\"pos\":" + std::to_string(rx::engine::utf::utf16_len(text.substr(0, d.pos)));
                out += std::string(",\"severity\":\"") + (err ? "error" : "warning") + "\"";
                out += std::string(",\"subset\":") + (d.subset ? "true" : "false");
                out += std::string(",\"template\":") + (d.in_template ? "true" : "false");
                out += std::string(",\"perf\":") + (d.perf ? "true" : "false");
                out += ",\"message\":";
                rx::engine::rui::json_string(d.msg, out);
                out += ",\"usedAt\":";
                rx::engine::rui::json_string(d.used_at, out);
                out += "}";
            } else {
                out = std::string(d.file) + ":" + std::to_string(line) + ":" + std::to_string(col) + ": "
                    + (err ? "error" : "warning") + ": " + std::string(d.msg);
                if (!d.used_at.empty())
                    out += " (used at " + std::string(d.used_at) + ")";
            }
            if (printed.insert(out).second)
                std::printf("%s\n", out.c_str());
        }
        if (bad)
            failed++;
        else if (mode == Mode::report && !json) {
            size_t comps = 0;
            for (std::string_view p : r.components)
                comps += !files.text_of(p).empty();
            std::printf(
                "%s: ok%s\n", name.c_str(),
                comps ? (" (with " + std::to_string(comps) + " component file" + (comps == 1 ? ")" : "s)")).c_str()
                      : "");
        }
    }
    if (mode == Mode::stats) {
        std::printf("{\"files\":%d,\"elements\":%u,\"templates\":%u,\"component uses\":%u,\"units\":%u", argc,
                    total.elements, total.templates, total.components, total.units);
        for (int c = 0; c < static_cast<int>(rx::engine::sema::Class::count_); c++)
            std::printf(",\"%s\":%u", rx::engine::sema::class_name(static_cast<rx::engine::sema::Class>(c)),
                        total.classes[c]);
        std::printf(",\"failed\":%d}\n", failed);
        return 0;
    }
    if (mode == Mode::report && !json)
        std::printf("failed %d\n", failed);
    return failed ? 1 : 0;
}

int ast(int argc, char** argv) {
    std::string out;
    for (int k = 0; k < argc; k++) {
        std::string src;
        out.clear();
        out += "{\"file\":";
        rx::engine::rui::json_string(argv[k], out);
        if (!read_file(argv[k], src)) {
            out += ",\"error\":\"cannot read the file\",\"line\":0,\"pos\":0}";
        } else {
            rx::engine::Arena arena;
            auto f = rx::engine::rui::parse(src, arena);
            if (f) {
                out += ",\"ast\":";
                rx::engine::rui::dump(**f, out);
                out += "}";
            } else {
                out += ",\"error\":";
                rx::engine::rui::json_string(f.error().msg, out);
                out += ",\"line\":" + std::to_string(f.error().line);
                out += ",\"pos\":"
                    + std::to_string(rx::engine::utf::utf16_len(std::string_view(src).substr(0, f.error().pos))) + "}";
            }
        }
        out += "\n";
        std::fwrite(out.data(), 1, out.size(), stdout);
    }
    return 0;
}

namespace unit_jobs {
using rx::tools::json::J;
uint32_t seed = 1;
uint32_t rnd(uint32_t n) {
    seed = (seed * 1103515245u + 12345u) & 0x7fffffffu;
    return seed % n;
}
const char* const k_chars[] = {
    "(",         ")",     "[",       "]",   "{",   "}",      ",",   ";",     ".",        "=",      "=>",     "...",
    "?",         ":",     "?.",      "??",  "+",   "-",      "*",   "/",     "%",        "!",      "<",      ">",
    "&&",        "||",    "\"",      "'",   "`",   "${",     "\n",  " ",     "let ",     "const ", "var ",   "return ",
    "if ",       "else ", "for ",    "of ", "in ", "while ", "do ", "break", "continue", "try ",   "catch ", "finally ",
    "function ", "new ",  "typeof ", "x",   "1",   "0x",     ".5",  "e",     "_",        "\\",     "/re/",   "/[/]/g",
    "a.b",       "++",    "--",      "**",  "= 1", "//",     "/*",  "*/"};
std::u16string u16(std::string_view s) {
    std::u16string out;
    for (size_t i = 0; i < s.size();) {
        unsigned char c = static_cast<unsigned char>(s[i]);
        uint32_t cp;
        size_t n = c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4;
        cp = n == 1 ? c : n == 2 ? c & 0x1Fu : n == 3 ? c & 0x0Fu : c & 0x07u;
        for (size_t k = 1; k < n && i + k < s.size(); k++)
            cp = (cp << 6) | (static_cast<unsigned char>(s[i + k]) & 0x3Fu);
        i += n;
        if (cp >= 0x10000)
            out += static_cast<char16_t>(0xD800 + ((cp - 0x10000) >> 10)),
                out += static_cast<char16_t>(0xDC00 + ((cp - 0x10000) & 0x3FF));
        else
            out += static_cast<char16_t>(cp);
    }
    return out;
}
std::u16string mutate(const std::u16string& s) {
    uint32_t at = rnd(static_cast<uint32_t>(s.size()) + 1), k = rnd(3);
    if (k == 0)
        return s.substr(0, at);
    if (k == 1)
        return s.substr(0, at) + (at < s.size() ? s.substr(at + 1) : std::u16string());
    return s.substr(0, at) + u16(k_chars[rnd(sizeof k_chars / sizeof k_chars[0])]) + s.substr(at);
}
std::string ascii_json(const std::u16string& s) {
    static const char* hex = "0123456789abcdef";
    std::string out = "\"";
    for (char16_t c : s) {
        if (c == '"')
            out += "\\\"";
        else if (c == '\\')
            out += "\\\\";
        else if (c >= 0x20 && c < 0x7F)
            out += static_cast<char>(c);
        else
            out += std::string("\\u") + hex[(c >> 12) & 15] + hex[(c >> 8) & 15] + hex[(c >> 4) & 15] + hex[c & 15];
    }
    return out + "\"";
}
int nmut = 0;
void emit(const char* kind, const std::u16string& params, const std::u16string& text) {
    std::printf("[\"unit\",\"%s\",%s,%s]\n", kind, ascii_json(params).c_str(), ascii_json(text).c_str());
}
void unit(const char* kind, const std::u16string& params, const std::u16string& text) {
    emit(kind, params, text);
    for (int m = 0; m < nmut; m++) {
        if (!std::strcmp(kind, "function") && rnd(4) == 0)
            emit(kind, mutate(params), text);
        else
            emit(kind, params, mutate(text));
    }
}
void walk(const J& n) {
    for (const J& p : n["props"].a)
        unit("value", u"", u16(p["expr"].text()));
    for (const J& c : n["custom"].a)
        if (!c["expr"].is_null())
            unit("value", u"", u16(c["expr"].text()));
    for (const J& h : n["handlers"].a)
        unit("handler", u"", u16(h["body"].text()));
    for (const J& f : n["functions"].a)
        unit("function", u16(f["params"].text()), u16(f["body"].text()));
    for (const J& c : n["children"].a)
        walk(c);
    for (const J& o : n["objects"].a)
        walk(o["node"]);
}
int run(int argc, char** argv) {
    if (argc < 2)
        return std::fprintf(stderr, "rexui-check --unit-jobs <mutants> <seed> <file.rui>...\n"), 2;
    nmut = std::atoi(argv[0]);
    seed = static_cast<uint32_t>(std::atoi(argv[1]));
    if (!seed)
        seed = 1;
    for (int k = 2; k < argc; k++) {
        std::string src;
        if (!read_file(argv[k], src))
            continue;
        rx::engine::Arena arena;
        auto tree = rx::engine::rui::parse(src, arena);
        if (!tree)
            continue;
        std::string json;
        rx::engine::rui::dump(**tree, json);
        walk(J::parse(json));
    }
    return 0;
}
}

int units(bool verbose) {
    std::string in, buf;
    char chunk[65536];
    for (size_t k; (k = std::fread(chunk, 1, sizeof chunk, stdin)) > 0;)
        in.append(chunk, k);
    size_t at = 0, total = 0, agree = 0, subset = 0, ours = 0, theirs = 0;
    while (at < in.size()) {
        size_t nl = in.find('\n', at);
        if (nl == std::string::npos)
            break;
        char kind[16];
        int ok = 0;
        size_t plen = 0, tlen = 0;
        std::string head = in.substr(at, nl - at);
        if (std::sscanf(head.c_str(), "%15s %d %zu %zu", kind, &ok, &plen, &tlen) != 4)
            break;
        at = nl + 1;
        std::string_view params(in.data() + at, plen), text(in.data() + at + plen, tlen);
        at += plen + tlen + 1;
        buf.assign(params);
        buf.append(text);
        rx::engine::Arena arena;
        auto len = [](size_t v) { return static_cast<uint32_t>(v); };
        std::expected<rx::engine::js::Node*, rx::engine::js::Error> r;
        if (!std::strcmp(kind, "function"))
            r = rx::engine::js::parse_function(buf, 0, len(plen), len(plen), len(tlen), arena);
        else
            r = rx::engine::js::parse(
                buf, len(plen), len(tlen),
                !std::strcmp(kind, "value") ? rx::engine::js::Goal::value : rx::engine::js::Goal::handler, arena);
        total++;
        bool mine = r.has_value();
        if (mine == (ok != 0)) {
            agree++;
            continue;
        }
        if (!mine && r.error().subset) {
            if (verbose && subset < 60)
                std::printf("SUBSET %s: %.*s\n  text: %.*s\n", kind, static_cast<int>(r.error().msg.size()),
                            r.error().msg.data(), static_cast<int>(tlen < 200 ? tlen : 200), text.data());
            subset++;
            continue;
        }
        (mine ? ours : theirs)++;
        if (ours + theirs <= 40) {
            std::printf("DIFF %s: jsc %s, rexui-check %s%s%.*s\n  params: %.*s\n  text: %.*s\n", kind,
                        ok ? "compiles" : "rejects", mine ? "accepts" : "rejects", mine ? "" : ": ",
                        mine ? 0 : static_cast<int>(r.error().msg.size()), mine ? "" : r.error().msg.data(),
                        static_cast<int>(plen), params.data(), static_cast<int>(tlen < 300 ? tlen : 300), text.data());
        }
    }
    std::printf("units: %zu, %zu agree, %zu outside the subset (rejected here only), %zu accepted here only, %zu "
                "rejected here only\n",
                total, agree, subset, ours, theirs);
    return ours || theirs ? 1 : 0;
}

int bench(int n, int argc, char** argv) {
    std::deque<std::string> srcs;
    size_t bytes = 0;
    for (int k = 0; k < argc; k++) {
        srcs.emplace_back();
        if (!read_file(argv[k], srcs.back()))
            return std::fprintf(stderr, "rexui-check: cannot read %s\n", argv[k]), 1;
        bytes += srcs.back().size();
    }
    Files files;
    for (int k = 0; k < argc; k++)
        files.add(argv[k], &srcs[static_cast<size_t>(k)]);
    double best = 1e30, best_parse = 1e30;
    for (int round = 0; round < n; round++) {
        auto t0 = std::chrono::steady_clock::now();
        for (int k = 0; k < argc; k++) {
            rx::engine::Arena arena;
            (void)rx::engine::rui::parse(srcs[static_cast<size_t>(k)], arena);
        }
        auto t1 = std::chrono::steady_clock::now();
        for (int k = 0; k < argc; k++) {
            rx::engine::Arena arena;
            (void)rx::engine::sema::check(argv[k], base_name(argv[k]), srcs[static_cast<size_t>(k)], files, arena);
        }
        auto t2 = std::chrono::steady_clock::now();
        best_parse = std::min(best_parse, std::chrono::duration<double>(t1 - t0).count());
        best = std::min(best, std::chrono::duration<double>(t2 - t1).count());
    }
    std::printf("{\"files\":%d,\"bytes\":%zu,\"structure_ms\":%.3f,\"structure_mb_s\":%.1f,\"check_ms\":%.3f,\"check_"
                "mb_s\":%.1f}\n",
                argc, bytes, best_parse * 1e3, static_cast<double>(bytes) / best_parse / 1e6, best * 1e3,
                static_cast<double>(bytes) / best / 1e6);
    return 0;
}

}

namespace sidefx {
inline constexpr double k_tick_budget_ms = 20;
inline constexpr double k_turn_budget_ms = 25;
using rx::engine::core::Doc;
using rx::engine::core::Sink;
using rx::engine::vm::Value;

bool has_command(const std::string& json) {
    return (json.size() > 2 && json[0] == '"') || (json.size() > 2 && json[0] == '[');
}

struct Rec final : Sink {
    std::string home;
    std::map<uint32_t, std::string> types;
    std::map<uint32_t, std::map<std::string, std::string>> props;
    std::vector<std::string> acts, logs;
    std::deque<std::string> texts;
    std::vector<uint32_t> pending;
    std::vector<std::string> answers;
    Doc* doc = nullptr;
    std::string json_or_undefined(const std::map<std::string, std::string>& m, const std::string& k) {
        auto it = m.find(k);
        return it == m.end() ? "undefined" : it->second;
    }
    void create(uint32_t uid, std::string_view type, uint32_t) override {
        types[uid] = std::string(type);
        props[uid] = {};
    }
    void set(Doc& d, uint32_t uid, std::string_view name, Value v) override {
        std::string k(name), j(d.json(v));
        auto& p = props[uid];
        std::string was = json_or_undefined(p, k);
        p[k] = j;
        const std::string& type = types[uid];
        std::string cmd = json_or_undefined(p, "command");
        if (type == "Process" && k == "running" && j == "true" && was != "true" && has_command(cmd))
            acts.push_back("start " + cmd);
        if (type == "Process" && k == "command" && json_or_undefined(p, "running") != "false" && has_command(j)
            && was != j)
            acts.push_back("start " + j);
        if (type == "Drawer" && k == "open" && j == "true")
            acts.push_back("drawer opened");
    }
    void call(uint32_t, std::string_view method, std::string_view arg) override {
        if (method != "destroy")
            acts.push_back("call " + std::string(method) + " " + std::string(arg));
    }
    void send(uint32_t uid, std::string_view line) override {
        acts.push_back("send to " + json_or_undefined(props[uid], "command") + ": " + std::string(line));
    }
    void log(std::string_view msg, std::string_view) override { logs.emplace_back(msg); }
    bool source(std::string_view path, std::string_view& text) override {
        std::string p = kit_path(std::string(path));
        if (p.size() < 4 || p.substr(p.size() - 4) != ".rui")
            return false;
        if (p[0] == '~')
            p = home + p.substr(1);
        FILE* f = std::fopen(p.c_str(), "rb");
        if (!f)
            return false;
        std::string t;
        char b[65536];
        size_t n;
        while ((n = std::fread(b, 1, sizeof b, f)) > 0)
            t.append(b, n);
        std::fclose(f);
        texts.push_back(std::move(t));
        text = texts.back();
        return true;
    }
    Value parsed(Doc& d, const std::string& json) {
        Value v = Value::null();
        d.parse(json, v);
        return v;
    }
    Value later(Doc& d, const std::string& json) {
        Value v = Value::null();
        uint32_t h = d.promise(v);
        if (h)
            pending.push_back(h), answers.push_back(json);
        return v;
    }
    void settle(Doc& d) {
        std::vector<uint32_t> hs;
        std::vector<std::string> as;
        hs.swap(pending), as.swap(answers);
        for (size_t i = 0; i < hs.size(); i++)
            d.settle(hs[i], as[i], false);
    }
    Value api(Doc& d, std::string_view, std::string_view name, const Value* args, uint32_t argc) override {
        std::string op = argc && args[0].is(rx::engine::vm::Kind::string) ? std::string(d.json(args[0])) : "";
        if (op.size() >= 2)
            op = op.substr(1, op.size() - 2);
        std::string a = argc > 1 ? std::string(d.json(args[1])) : "undefined";
        auto in = [&](std::initializer_list<const char*> ops) {
            for (const char* o : ops)
                if (op == o)
                    return true;
            return false;
        };
        if (name == "rex") {
            if (op == "run") {
                std::string rest = "[";
                for (uint32_t i = 1; i < argc; i++) {
                    std::string j(d.json(args[i]));
                    rest += (i > 1 ? "," : "") + (j == "undefined" ? std::string("null") : j);
                }
                acts.push_back("rex.run " + rest + "]");
            }
            return op == "menu" ? Value::boolean(true) : Value::null();
        }
        if (name == "debug") {
            if (in({"toggle", "pick", "edit", "eval"}))
                acts.push_back("debug." + op + " " + a);
            return op == "tree" ? parsed(d, "[]") : Value::null();
        }
        if (name == "notices") {
            if (in({"post", "play", "badge", "reveal", "clear", "dismiss"}))
                acts.push_back("notices." + op + " " + a);
            return op == "post" ? parsed(d, "\"sidefx\"") : Value::null();
        }
        if (name == "activity") {
            if (op == "markSeen")
                acts.push_back("activity.markSeen " + a);
            return Value::num(0);
        }
        if (name == "rexstate") {
            if (in({"timeScale", "openDirectory", "back", "api"}))
                acts.push_back("rex." + op + " " + a);
            return op == "api" ? later(d, "null") : Value::null();
        }
        if (name == "diagnostics") {
            if (op == "call" || op == "reveal")
                acts.push_back("diagnostics." + op + " " + a);
            return op == "call" ? later(d, "null") : Value::null();
        }
        if (name == "windows") {
            if (op == "open")
                acts.push_back("windows.open " + a);
            return Value::null();
        }
        if (name == "files") {
            if (in({"copy", "move", "trash", "rename", "mkdir", "undo", "open", "finder"}))
                acts.push_back("files." + op + " " + a);
            if (op == "places") {
                std::string esc;
                for (char c : home)
                    esc += (c == '"' || c == '\\') ? std::string("\\") + c : std::string(1, c);
                return parsed(
                    d, "{\"home\":\"" + esc + "\",\"favourites\":[],\"volumes\":[],\"trash\":\"" + esc + "/.Trash\"}");
            }
            if (op == "list") {
                std::string path = "undefined";
                if (argc > 1 && args[1].is_cell()) {
                    std::string j(d.json(args[1]));
                    size_t at = j.find("\"path\":");
                    if (at != std::string::npos) {
                        size_t e = at + 7;
                        if (e < j.size() && j[e] == '"') {
                            size_t q = e + 1;
                            while (q < j.size() && j[q] != '"')
                                q += j[q] == '\\' ? 2 : 1;
                            path = j.substr(e, q - e + 1);
                        }
                    }
                }
                return later(d,
                             "{" + (path == "undefined" ? std::string() : "\"path\":" + path + ",")
                                 + "\"name\":\"\",\"parent\":\"\",\"entries\":[]}");
            }
            if (op == "search")
                return later(d, "[]");
            if (op == "apps")
                return parsed(d, "[]");
            if (in({"copy", "move", "trash", "undo", "rename", "mkdir", "read"}))
                return later(d, "null");
            return Value::null();
        }
        return Value::null();
    }
};

bool is_backend(const std::string& a) {
    if (a.rfind("start ", 0) != 0)
        return false;
    size_t i = 6;
    if (i < a.size() && a[i] == '[')
        i++;
    if (i >= a.size() || a[i] != '"')
        return false;
    size_t j = i + 1;
    while (j < a.size() && a[j] != '"' && a[j] != '/')
        j++;
    return j < a.size() && a[j] == '"' && j > i + 1;
}

void list(const char* what, const std::vector<std::string>& xs) {
    std::printf("  %s: ", what);
    if (xs.empty())
        std::printf("none\n");
    else {
        for (const std::string& x : xs)
            std::printf("\n    %s", x.c_str());
        std::printf("\n");
    }
}

int run(int n, char** files) {
    const char* h = std::getenv("HOME");
    for (int i = 0; i < n; i++) {
        std::string path = files[i], src;
        std::string abs = path;
        if (!abs.empty() && abs[0] != '/') {
            char cwd[4096];
            abs = std::string(getcwd(cwd, sizeof cwd) ? cwd : ".") + "/" + path;
        }
        FILE* f = std::fopen(abs.c_str(), "rb");
        if (f) {
            char b[65536];
            size_t k;
            while ((k = std::fread(b, 1, sizeof b, f)) > 0)
                src.append(b, k);
            std::fclose(f);
        }
        std::string shown = path;
        for (int parts = 0, at = static_cast<int>(path.size()); at-- > 0;)
            if (path[static_cast<size_t>(at)] == '/' && ++parts == 3) {
                shown = path.substr(static_cast<size_t>(at) + 1);
                break;
            }
        std::string name = abs.substr(abs.rfind('/') + 1);
        Rec rec;
        rec.home = h ? h : "";
        Doc doc(rec);
        rec.doc = &doc;
        doc.rt().test_now = -1;
        const auto t0 = std::chrono::steady_clock::now();
        std::string err = f ? std::string(doc.load(src, name, path)) : "cannot read the file";
        rec.settle(doc);
        const double load_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        std::vector<std::string> backends, at_load;
        for (const std::string& a : rec.acts)
            (is_backend(a) ? backends : at_load).push_back(a);
        rec.acts.clear();
        if (err.empty())
            for (auto& [uid, type] : rec.types)
                if (type == "Process" && doc.alive(uid)) {
                    doc.line(uid, "{\"state\":{}}");
                    rec.settle(doc);
                }
        std::printf("== %s%s\n", shown.c_str(), err.empty() ? "" : (" ERROR " + err).c_str());
        std::printf("  backends started: %zu\n", backends.size());
        list("other actions at load", at_load);
        list("actions on backend lines", rec.acts);
        for (const std::string& l : rec.logs)
            std::printf("  log: %s\n", l.c_str());
        if (!err.empty())
            continue;
        int once = 0, ticks = 0;
        double tick_ms = 0, worst = load_ms;
        for (int repeating = 0; repeating < 2; repeating++) {
            for (auto& [uid, type] : rec.types) {
                if (type != "Timer" || !doc.alive(uid))
                    continue;
                auto& p = rec.props[uid];
                if (rec.json_or_undefined(p, "running") == "false"
                    || (rec.json_or_undefined(p, "repeat") != "false") != (repeating == 1))
                    continue;
                const std::string iv = rec.json_or_undefined(p, "interval");
                const double every = iv == "undefined" ? 1000 : std::atof(iv.c_str());
                const int times =
                    repeating ? std::max(1, static_cast<int>(std::min(1000.0, 1000.0 / std::max(1.0, every)))) : 1;
                for (int k = 0; k < times; k++) {
                    const auto t1 = std::chrono::steady_clock::now();
                    doc.emit(uid, "triggered", "[]");
                    rec.settle(doc);
                    const double ms =
                        std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t1).count();
                    worst = std::max(worst, ms);
                    if (repeating)
                        tick_ms += ms, ticks++;
                    else
                        once++;
                }
            }
        }
        std::printf("  time: load %.1f ms; %d one-shot Timer%s after; a second of its repeating Timers %.1f ms (%d "
                    "ticks); its longest "
                    "turn %.1f ms\n",
                    load_ms, once, once == 1 ? "" : "s", tick_ms, ticks, worst);
        if (tick_ms > k_tick_budget_ms)
            std::printf("  time: its Timers take over the %.0f ms a second a file is held to (budget_engine_ms): a "
                        "longer interval, or "
                        "running only while shown\n",
                        k_tick_budget_ms);
        if (worst > k_turn_budget_ms)
            std::printf("  time: a turn of its over %.0f ms holds every dock's frames: its load (a Drawer's lazy, a "
                        "Loader) or a "
                        "Timer's handler split up\n",
                        k_turn_budget_ms);
    }
    return 0;
}
}

namespace load_check {
using rx::engine::core::Doc;
int run(int n, char** files) {
    int failed = 0;
    const char* h = std::getenv("HOME");
    for (int i = 0; i < n; i++) {
        std::string path = files[i], src;
        FILE* f = std::fopen(path.c_str(), "rb");
        if (!f) {
            std::printf("%s: cannot read the file\n", path.c_str());
            failed++;
            continue;
        }
        char b[65536];
        size_t k;
        while ((k = std::fread(b, 1, sizeof b, f)) > 0)
            src.append(b, k);
        std::fclose(f);
        std::string name = path.substr(path.rfind('/') == std::string::npos ? 0 : path.rfind('/') + 1);
        std::string abs = path;
        if (abs[0] != '/') {
            char cwd[4096];
            abs = std::string(getcwd(cwd, sizeof cwd) ? cwd : ".") + "/" + path;
        }
        sidefx::Rec rec;
        rec.home = h ? h : "";
        Doc doc(rec);
        rec.doc = &doc;
        std::string err(doc.load(src, name, abs));
        rec.settle(doc);
        bool bad = false;
        for (const std::string& l : rec.logs) {
            std::printf("%s: %s\n", name.c_str(), l.c_str());
            size_t c = l.find(".rui:");
            bad = bad || (c != std::string::npos && c < l.find(' '));
        }
        const size_t comps = rec.texts.size();
        if (!err.empty())
            std::printf("%s\n", err.c_str());
        else if (!bad)
            std::printf(
                "%s: ok%s\n", name.c_str(),
                comps ? (" (with " + std::to_string(comps) + " component file" + (comps == 1 ? ")" : "s)")).c_str()
                      : "");
        if (!err.empty() || bad)
            failed++;
    }
    std::printf("failed %d\n", failed);
    return failed ? 1 : 0;
}
}

int main(int argc, char** argv) {
    if (argc >= 2 && !std::strcmp(argv[1], "--load"))
        return load_check::run(argc - 2, argv + 2);
    if (argc >= 2 && !std::strcmp(argv[1], "--sidefx"))
        return sidefx::run(argc - 2, argv + 2);
    if (argc >= 2 && !std::strcmp(argv[1], "--unit-jobs"))
        return unit_jobs::run(argc - 2, argv + 2);
    if (argc >= 2 && !std::strcmp(argv[1], "--ast"))
        return ast(argc - 2, argv + 2);
    if (argc >= 2 && !std::strcmp(argv[1], "--first"))
        return check(argc - 2, argv + 2, Mode::first, false, false);
    if (argc >= 2 && !std::strcmp(argv[1], "--stats"))
        return check(argc - 2, argv + 2, Mode::stats, false, false);
    if (argc >= 3 && !std::strcmp(argv[1], "--bench"))
        return bench(std::atoi(argv[2]), argc - 3, argv + 3);
    if (argc >= 2 && !std::strcmp(argv[1], "--units"))
        return units(argc > 2 && !std::strcmp(argv[2], "-v"));
    bool json = false, warnings = false, from_stdin = false, perf = false;
    int k = 1;
    for (; k < argc && argv[k][0] == '-'; k++) {
        if (!std::strcmp(argv[k], "--json"))
            json = true;
        else if (!std::strcmp(argv[k], "--warnings"))
            warnings = true;
        else if (!std::strcmp(argv[k], "--stdin"))
            from_stdin = true;
        else if (!std::strcmp(argv[k], "--perf"))
            perf = true;
        else
            break;
    }
    if (from_stdin && argc - k != 1) {
        std::fprintf(stderr, "rexui-check: --stdin takes one path (where the text is from)\n");
        return 2;
    }
    if (k < argc && argv[k][0] != '-')
        return check(argc - k, argv + k, Mode::report, json, warnings, from_stdin, perf);
    std::fprintf(stderr,
                 "usage: rexui-check [--json] [--warnings] [--perf] [--stdin] <file.rui>... | --first | --ast | "
                 "--stats | --load <file.rui>... | --units [-v]\n");
    return 2;
}
