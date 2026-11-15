// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <vector>

namespace {

struct Prop {
    std::string name, type, def;
    bool paint = false, js = false;
    std::string values;
};
struct Block {
    bool group = false;
    std::string name;
    std::vector<std::string> bases;
    std::vector<Prop> props;
    std::vector<std::string> objects;
    std::vector<std::pair<std::string, std::string>> signals;
    std::vector<std::string> methods;
    int line = 0;
};

std::string g_file;
[[noreturn]] void fail(int line, const std::string& msg) {
    std::fprintf(stderr, "%s:%d: %s\n", g_file.c_str(), line, msg.c_str());
    std::exit(1);
}

std::string trim(std::string s) {
    size_t a = s.find_first_not_of(" \t"), b = s.find_last_not_of(" \t\r");
    return a == std::string::npos ? "" : s.substr(a, b - a + 1);
}

const std::set<std::string> k_types = {"real", "real?", "string?", "bool", "string", "color", "list", "object", "any"};

std::vector<Block> parse(const std::string& path) {
    std::ifstream f(path);
    if (!f)
        fail(0, "cannot read the schema");
    std::vector<Block> out;
    Block* cur = nullptr;
    std::string raw;
    for (int line = 1; std::getline(f, raw); line++) {
        std::string s = trim(raw);
        if (s.empty() || s[0] == '#')
            continue;
        if (!cur) {
            bool group = s.rfind("group ", 0) == 0, type = s.rfind("type ", 0) == 0;
            if (!group && !type)
                fail(line, "expected `group NAME {` or `type NAME {`");
            if (s.back() != '{')
                fail(line, "a block's line ends with {");
            std::string head = trim(s.substr(group ? 6 : 5, s.size() - (group ? 6 : 5) - 1));
            Block b;
            b.group = group;
            b.line = line;
            size_t colon = head.find(':');
            b.name = trim(head.substr(0, colon));
            if (colon != std::string::npos) {
                std::stringstream bs(head.substr(colon + 1));
                for (std::string x; std::getline(bs, x, ',');)
                    b.bases.push_back(trim(x));
            }
            out.push_back(b);
            cur = &out.back();
            continue;
        }
        if (s == "}") {
            cur = nullptr;
            continue;
        }
        if (s.rfind("signals:", 0) == 0) {
            std::string rest = s.substr(8);
            for (size_t at = 0;;) {
                size_t open = rest.find('(', at);
                if (open == std::string::npos)
                    break;
                size_t close = rest.find(')', open);
                if (close == std::string::npos)
                    fail(line, "a signal's parameters end with )");
                std::string name = trim(rest.substr(at, open - at));
                if (!name.empty() && name[0] == ',')
                    name = trim(name.substr(1));
                cur->signals.push_back({name, trim(rest.substr(open + 1, close - open - 1))});
                at = close + 1;
            }
            continue;
        }
        if (s.rfind("methods:", 0) == 0) {
            std::stringstream ms(s.substr(8));
            for (std::string x; std::getline(ms, x, ',');)
                cur->methods.push_back(trim(x));
            continue;
        }
        if (s.rfind("objects:", 0) == 0) {
            std::stringstream os(s.substr(8));
            for (std::string x; std::getline(os, x, ',');)
                cur->objects.push_back(trim(x));
            continue;
        }
        if (s.rfind("...", 0) == 0) {
            Prop p;
            p.name = s;
            cur->props.push_back(p);
            continue;
        }
        size_t colon = s.find(':'), eq = s.find(" = ");
        if (colon == std::string::npos || eq == std::string::npos || eq < colon)
            fail(line, "expected `name: TYPE = DEFAULT  INVALIDATION`");
        Prop p;
        p.name = trim(s.substr(0, colon));
        p.type = trim(s.substr(colon + 1, eq - colon - 1));
        if (p.type.rfind("enum", 0) == 0 && p.type.back() == ')') {
            size_t open = p.type.find('(');
            if (open == std::string::npos)
                fail(line, "an enum's values are in brackets");
            p.values = p.type.substr(open + 1, p.type.size() - open - 2);
            p.type = p.type[4] == '?' ? "string?" : "string";
        }
        if (!k_types.count(p.type))
            fail(line, "unknown type " + p.type);
        std::string rest = trim(s.substr(eq + 3));
        size_t gap = rest.rfind("  ");
        if (gap == std::string::npos)
            fail(line, "the invalidation class follows the default after two spaces");
        p.def = trim(rest.substr(0, gap));
        std::stringstream ts(rest.substr(gap));
        std::string inval, flag;
        ts >> inval;
        if (inval != "measure" && inval != "paint")
            fail(line, "invalidation is measure or paint, not " + inval);
        p.paint = inval == "paint";
        while (ts >> flag) {
            if (flag == "js")
                p.js = true;
            else
                fail(line, "unknown flag " + flag);
        }
        for (const Prop& q : cur->props)
            if (q.name == p.name)
                fail(line, p.name + " twice in " + cur->name);
        cur->props.push_back(p);
    }
    if (cur)
        fail(cur->line, cur->name + " has no closing }");
    return out;
}

void flatten(const std::map<std::string, const Block*>& groups, const Block& b, std::vector<Prop>& out) {
    for (const std::string& base : b.bases) {
        auto it = groups.find(base);
        if (it == groups.end())
            fail(b.line, "no group " + base);
        flatten(groups, *it->second, out);
    }
    for (const Prop& p : b.props) {
        if (p.name.rfind("...", 0) == 0) {
            auto it = groups.find(p.name.substr(3));
            if (it == groups.end())
                fail(b.line, "no group " + p.name.substr(3));
            flatten(groups, *it->second, out);
            continue;
        }
        bool replaced = false;
        for (size_t k = 0; k < out.size() && !replaced; k++)
            if (out[k].name == p.name) {
                if (out[k].def == "unset")
                    out.erase(out.begin() + static_cast<long>(k));
                else
                    out[k] = p, replaced = true;
                break;
            }
        if (!replaced)
            out.push_back(p);
    }
}

std::string ident(const std::string& name) {
    std::string s;
    for (char c : name)
        s += (c == '.') ? '_' : c;
    return s;
}

std::string cstr(const std::string& s) {
    std::string o = "\"";
    for (char c : s) {
        if (c == '"' || c == '\\')
            o += '\\';
        o += c;
    }
    return o + "\"";
}

uint32_t fnv(uint32_t seed, const std::string& s) {
    uint32_t h = 2166136261u ^ seed;
    for (unsigned char c : s)
        h = (h ^ c) * 16777619u;
    return h;
}

}

static std::string deps_normal(const std::string& text) {
    std::string out, line;
    std::istringstream in(text);
    while (std::getline(in, line)) {
        while (!line.empty() && (line.back() == ' ' || line.back() == '\t' || line.back() == '\r'))
            line.pop_back();
        size_t first = line.find_first_not_of(" \t");
        if (first == std::string::npos || line[first] == '#')
            continue;
        if (line.rfind("feature ", 0) == 0)
            line = line.substr(0, line.find(':'));
        out += line + "\n";
    }
    return out;
}

static void deps_xor(std::string& s) {
    uint32_t x = 0x2545F491u;
    for (char& c : s) {
        x ^= x << 13, x ^= x >> 17, x ^= x << 5;
        c = static_cast<char>(static_cast<uint8_t>(c) ^ static_cast<uint8_t>(x));
    }
}

static const char* k_b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static bool deps_decode(const std::string& text, std::string& plain) {
    size_t end = text.find_last_not_of(" \t\r\n");
    if (text.rfind("RXD1\n", 0) != 0 || end == std::string::npos || end < 5)
        return false;
    std::string b = text.substr(5, end - 4);
    if (b.size() % 4)
        return false;
    plain.clear();
    for (size_t i = 0; i < b.size(); i += 4) {
        uint32_t n = 0;
        int pad = 0;
        for (int j = 0; j < 4; j++) {
            char c = b[i + j];
            const char* p = c ? std::strchr(k_b64, c) : nullptr;
            if (c == '=' && i + 4 == b.size() && j >= 2) {
                pad++;
                n <<= 6;
                continue;
            }
            if (!p || pad)
                return false;
            n = n << 6 | static_cast<uint32_t>(p - k_b64);
        }
        plain += static_cast<char>(n >> 16);
        if (pad < 2)
            plain += static_cast<char>((n >> 8) & 0xFF);
        if (pad < 1)
            plain += static_cast<char>(n & 0xFF);
    }
    deps_xor(plain);
    return true;
}

static bool deps_list(const std::string& plain, std::string& why) {
    static const std::set<std::string> kinds = {"objc",   "method",  "ivar", "subclass", "part",   "type",    "read",
                                                "vtable", "witness", "code", "pref",     "system", "resource"};
    std::istringstream in(plain);
    std::string line;
    int features = 0, n = 0;
    while (std::getline(in, line)) {
        n++;
        std::istringstream words(line);
        std::string k, id;
        words >> k;
        if (line.rfind("feature ", 0) == 0) {
            words >> id;
            if (id.empty())
                return why = "line " + std::to_string(n) + ": a feature without its id", false;
            features++;
            continue;
        }
        if (k == "|")
            words >> k;
        if (!features || !kinds.count(k)) {
            std::string shown = line.substr(0, 40);
            for (char& c : shown)
                c = c >= 0x20 && c < 0x7f ? c : '?';
            why = "line " + std::to_string(n) + ": not a feature or an entry (\"" + shown + "\")";
            return false;
        }
    }
    if (!features)
        return why = "no feature", false;
    if (plain.back() != '\n')
        return why = "its last line cut short", false;
    return true;
}

static int deps_main(const char* in_path, const char* out_path) {
    std::ifstream in(in_path, std::ios::binary);
    if (!in)
        return std::fprintf(stderr, "rxgen: no %s\n", in_path), 1;
    std::stringstream ss;
    ss << in.rdbuf();
    std::string text = ss.str(), plain, why;
    bool encoded = text.rfind("RXD1\n", 0) == 0;
    if (encoded) {
        if (!deps_decode(text, plain))
            return std::fprintf(
                       stderr,
                       "rxgen: %s is RXD1 but doesn't decode (base64): not as rxgen --deps or strip.py wrote it\n",
                       in_path),
                   1;
    } else {
        plain = deps_normal(text);
    }
    if (!deps_list(plain, why))
        return std::fprintf(stderr, "rxgen: %s%s isn't a list deps.swift reads: %s\n", in_path,
                            encoded ? " (decoded)" : "", why.c_str()),
               1;
    std::ofstream o(out_path, std::ios::binary);
    o << plain;
    return o ? 0 : (std::fprintf(stderr, "rxgen: can't write %s\n", out_path), 1);
}

static bool names_read(const std::string& h_path, const std::string& mm_path, std::vector<std::string>& ids,
                       std::vector<std::string>& names, std::string& why) {
    std::ifstream hf(h_path), mf(mm_path);
    if (!hf || !mf)
        return why = "can't read " + (hf ? mm_path : h_path), false;
    std::string h, line;
    while (std::getline(hf, line))
        h += line.substr(0, line.find("//")) + " ";
    size_t e = h.find("enum {"), close = e == std::string::npos ? e : h.find('}', e);
    if (close == std::string::npos)
        return why = h_path + ": no enum { ... }", false;
    std::stringstream body(h.substr(e + 6, close - e - 6));
    for (std::string x; std::getline(body, x, ',');) {
        x = trim(x);
        if (x.empty())
            continue;
        if (x.rfind("RXN_", 0) != 0
            || x.find_first_not_of("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_")
                != std::string::npos)
            return why = h_path + ": an id that isn't RXN_<name> alone (" + x + ")", false;
        ids.push_back(x);
    }
    if (ids.empty() || ids.back() != "RXN_COUNT")
        return why = h_path + ": no RXN_COUNT last", false;
    ids.pop_back();
    std::map<std::string, std::string> by;
    for (int n = 1; std::getline(mf, line); n++) {
        if (size_t cm = line.find("//"); cm != std::string::npos)
            line.erase(cm);
        size_t c = line.find("case RXN_");
        if (c == std::string::npos)
            continue;
        const int at = n;
        for (std::string more; line.find(';', c) == std::string::npos && n < at + 6 && std::getline(mf, more); n++) {
            if (size_t cm = more.find("//"); cm != std::string::npos)
                more.erase(cm);
            line += " " + more;
        }
        size_t colon = line.find(':', c), q = colon == std::string::npos ? colon : line.find('"', colon);
        if (q == std::string::npos)
            return why = mm_path + ":" + std::to_string(at) + ": not `case RXN_x: return RX_NAME(\"...\");`", false;
        std::string id = trim(line.substr(c + 5, colon - c - 5)), lit, call = line.substr(colon, q - colon);
        bool x = call.find("RX_NAME_X(") != std::string::npos;
        if (!x && call.find("RX_NAME(") == std::string::npos)
            return why = mm_path + ":" + std::to_string(at) + ": not `case RXN_x: return RX_NAME(\"...\");`", false;
        size_t i = q + 1;
        for (;;) {
            for (; i < line.size() && line[i] != '"'; i++) {
                if (line[i] != '\\') {
                    lit += line[i];
                    continue;
                }
                if (!x || i + 3 >= line.size())
                    return why = mm_path + ":" + std::to_string(at) + ": an escape", false;
                lit += static_cast<char>((line[i + 1] - '0') * 64 + (line[i + 2] - '0') * 8 + (line[i + 3] - '0'));
                i += 3;
            }
            if (i >= line.size())
                return why = mm_path + ":" + std::to_string(at) + ": a literal left open", false;
            size_t next = line.find_first_not_of(" \t", i + 1);
            if (next == std::string::npos || line[next] != '"')
                break;
            i = next + 1;
        }
        if (x)
            deps_xor(lit);
        for (char ch : lit)
            if (ch < 0x21 || ch > 0x7e || ch == '"' || ch == '\\')
                return why = mm_path + ":" + std::to_string(at)
                           + ": a name that isn't printable ASCII without a quote or backslash",
                       false;
        if (by.count(id))
            return why = mm_path + ":" + std::to_string(at) + ": " + id + " twice", false;
        by[id] = lit;
    }
    for (const std::string& id : ids) {
        if (!by.count(id))
            return why = mm_path + ": no case for " + id, false;
        names.push_back(by[id]);
    }
    if (by.size() != ids.size())
        return why = mm_path + ": a case for an id names.h hasn't", false;
    return true;
}

static int names_main(const std::string& h_path, const std::string& mm_path, const std::string& dir) {
    std::vector<std::string> ids, names;
    std::string why;
    if (!names_read(h_path, mm_path, ids, names, why))
        return std::fprintf(stderr, "rxgen: %s\n", why.c_str()), 1;
    std::ostringstream s, h;
    s << "// Generated by tools/rxgen --names from src/rex/names.h and names.mm: each of Rex's names a literal where\n"
         "// it's used (rxs(RXN_x) is the literal: no table, no once, no lookup).\n"
         "@inline(__always) func rxs(_ id: Int) -> String {\n    switch id {\n";
    h << "// Generated by tools/rxgen --names from src/rex/names.h and names.mm: RXNS(RXN_x), that name as an "
         "@\"...\"\n"
         "// literal.\n#pragma once\n#define RXNS(id) RXNS_##id\n";
    for (size_t i = 0; i < ids.size(); i++) {
        s << "    case " << i << ": return \"" << names[i] << "\"\n";
        h << "#define RXNS_" << ids[i] << " @\"" << names[i] << "\"\n";
    }
    s << "    default: return \"\"\n    }\n}\n";
    for (auto [file, text] : {std::pair{dir + "/rx_names.swift", s.str()}, std::pair{dir + "/rx_names.h", h.str()}}) {
        std::ifstream old(file);
        std::stringstream was;
        was << old.rdbuf();
        if (old && was.str() == text)
            continue;
        std::ofstream out(file);
        out << text;
        if (!out)
            return std::fprintf(stderr, "rxgen: can't write %s\n", file.c_str()), 1;
    }
    return 0;
}

static int swift_main(const std::string& h_path, const std::string& mm_path, const std::string& dir, int n,
                      char** files) {
    std::vector<std::string> ids, names;
    std::string why;
    if (!names_read(h_path, mm_path, ids, names, why))
        return std::fprintf(stderr, "rxgen: %s\n", why.c_str()), 1;
    std::map<std::string, std::string> by;
    for (size_t i = 0; i < ids.size(); i++)
        by[ids[i]] = names[i];
    for (int f = 0; f < n; f++) {
        std::string path = files[f];
        std::ifstream in(path, std::ios::binary);
        if (!in)
            return std::fprintf(stderr, "rxgen: no %s\n", path.c_str()), 1;
        std::stringstream ss;
        ss << in.rdbuf();
        std::string src = ss.str(), out = "#sourceLocation(file: \"" + path + "\", line: 1)\n";
        int line = 1;
        for (size_t i = 0; i < src.size();) {
            bool word_start = i == 0 || !(std::isalnum(static_cast<unsigned char>(src[i - 1])) || src[i - 1] == '_');
            if (word_start && src.compare(i, 4, "rxs(") == 0) {
                size_t a = i + 4, b = src.find(')', a);
                std::string id = b == std::string::npos ? "" : trim(src.substr(a, b - a));
                if (!by.count(id))
                    return std::fprintf(
                               stderr, "%s:%d: rxs() of %s: an id of src/rex/names.h, as written, or it's no literal\n",
                               path.c_str(), line, id.empty() ? "nothing" : id.c_str()),
                           1;
                out += "\"" + by[id] + "\"";
                i = b + 1;
                continue;
            }
            if (src[i] == '\n')
                line++;
            out += src[i++];
        }
        std::string file = dir + "/" + path.substr(path.rfind('/') + 1);
        std::ifstream old(file, std::ios::binary);
        std::stringstream was;
        was << old.rdbuf();
        if (old && was.str() == out)
            continue;
        std::ofstream o(file, std::ios::binary);
        o << out;
        if (!o)
            return std::fprintf(stderr, "rxgen: can't write %s\n", file.c_str()), 1;
    }
    return 0;
}

int main(int argc, char** argv) {
    if (argc == 4 && std::string(argv[1]) == "--deps")
        return deps_main(argv[2], argv[3]);
    if (argc == 5 && std::string(argv[1]) == "--names")
        return names_main(argv[2], argv[3], argv[4]);
    if (argc >= 5 && std::string(argv[1]) == "--swift")
        return swift_main(argv[2], argv[3], argv[4], argc - 5, argv + 5);
    if (argc != 3) {
        std::fprintf(stderr, "usage: rxgen <elements.rxs> <out dir>\n");
        return 2;
    }
    g_file = argv[1];
    std::string dir = argv[2];
    std::vector<Block> blocks = parse(g_file);
    std::map<std::string, const Block*> groups;
    std::vector<const Block*> types;
    for (const Block& b : blocks)
        (b.group ? groups[b.name] = &b, void() : types.push_back(&b));
    if (types.size() > 64)
        fail(0, "more than 64 element types: Elem masks are 64 bits");

    std::vector<std::string> names;
    std::map<std::string, size_t> index;
    std::map<std::string, std::vector<Prop>> flat;
    for (const Block* t : types) {
        flatten(groups, *t, flat[t->name]);
        for (const Prop& p : flat[t->name])
            if (!index.count(p.name))
                index[p.name] = names.size(), names.push_back(p.name);
    }
    size_t words = (names.size() + 63) / 64;

    size_t slots = 1;
    while (slots < names.size() * 16)
        slots <<= 1;
    uint32_t seed = 0;
    for (;; seed++) {
        std::set<uint32_t> used;
        bool ok = true;
        for (const std::string& n : names)
            if (!used.insert(fnv(seed, n) & (uint32_t)(slots - 1)).second) {
                ok = false;
                break;
            }
        if (ok)
            break;
        if (seed > 100000000)
            fail(0, "no perfect hash found");
    }
    std::vector<int> table(slots, -1);
    for (size_t i = 0; i < names.size(); i++)
        table[fnv(seed, names[i]) & (slots - 1)] = (int)i;

    std::ostringstream h;
    h << "// Generated by tools/rxgen from src/schema/elements.rxs: don't edit.\n#pragma once\n\n#include <cstdint>\n"
         "#include <string_view>\n\nnamespace rx::schema {\n\n";
    h << "enum class Elem : uint8_t {\n";
    for (const Block* t : types)
        h << "    " << t->name << ",\n";
    h << "    count_\n};\n\nenum class Prop : uint16_t {\n";
    for (const std::string& n : names)
        h << "    " << ident(n) << ",\n";
    h << "    count_\n};\n\n";
    h << "enum class Type : uint8_t { real, real_opt, string_opt, boolean, string, color, list, object, any };\n"
         "enum class Inval : uint8_t { measure, paint };\n\n"
         "struct PropInfo {\n    std::string_view name;\n    Type type;\n};\n\n";
    auto type_id = [](const std::string& t) -> std::string {
        if (t == "real?")
            return "Type::real_opt";
        if (t == "string?")
            return "Type::string_opt";
        if (t == "bool")
            return "Type::boolean";
        return "Type::" + t;
    };
    h << "inline constexpr PropInfo k_props[] = {\n";
    for (const std::string& n : names) {
        std::string ty;
        for (const Block* t : types)
            for (const Prop& p : flat[t->name])
                if (p.name == n && ty.empty())
                    ty = p.type;
        h << "    {" << cstr(n) << ", " << type_id(ty) << "},\n";
    }
    h << "};\n\ninline constexpr std::string_view k_elems[] = {";
    for (const Block* t : types)
        h << cstr(t->name) << ", ";
    h << "};\n\n";
    auto bits = [&](const Block* t, auto pick) {
        std::vector<uint64_t> w(words, 0);
        for (const Prop& p : flat[t->name])
            if (pick(p))
                w[index[p.name] / 64] |= 1ull << (index[p.name] % 64);
        std::ostringstream o;
        o << "{";
        for (size_t i = 0; i < words; i++)
            o << (i ? ", " : "") << "0x" << std::hex << w[i] << std::dec << "ull";
        return o.str() + "}";
    };
    h << "inline constexpr int k_words = " << words << ";\n";
    for (const char* what : {"has", "paint", "js"}) {
        h << "inline constexpr uint64_t k_" << what << "[][" << words << "] = {\n";
        for (const Block* t : types) {
            std::string w = what;
            h << "    "
              << bits(t, [&](const Prop& p) { return w == "has" || (w == "paint" && p.paint) || (w == "js" && p.js); })
              << ",  // " << t->name << "\n";
        }
        h << "};\n";
    }
    h << "struct EnumInfo {\n    Elem elem;\n    Prop prop;\n    std::string_view values;\n};\n";
    h << "inline constexpr EnumInfo k_enums[] = {\n";
    for (const Block* t : types)
        for (const Prop& p : flat[t->name])
            if (!p.values.empty())
                h << "    {Elem::" << t->name << ", Prop::" << ident(p.name) << ", " << cstr(p.values) << "},\n";
    h << "    {Elem::count_, Prop::count_, \"\"},\n};\n";
    h << "\ninline constexpr bool has(Elem e, Prop p) { return (k_has[(int)e][(int)p / 64] >> ((int)p % 64)) & 1; }\n"
         "inline constexpr bool paint_only(Elem e, Prop p) { return (k_paint[(int)e][(int)p / 64] >> ((int)p % 64)) & "
         "1; }\n"
         "inline constexpr bool js_only(Elem e, Prop p) { return (k_js[(int)e][(int)p / 64] >> ((int)p % 64)) & 1; "
         "}\n\n";
    h << "struct Span {\n    uint16_t first, count;\n};\nstruct SignalInfo {\n    std::string_view name, "
         "params;\n};\n\n";
    {
        std::ostringstream sig, sigs, met, mets, obj, objs;
        size_t ns = 0, nm = 0, no = 0;
        for (const Block* t : types) {
            sigs << "    {" << ns << ", " << t->signals.size() << "},  // " << t->name << "\n";
            for (auto& [n, p] : t->signals)
                sig << "    {" << cstr(n) << ", " << cstr(p) << "},\n", ns++;
            mets << "    {" << nm << ", " << t->methods.size() << "},\n";
            for (auto& m : t->methods)
                met << "    " << cstr(m) << ",\n", nm++;
            objs << "    {" << no << ", " << t->objects.size() << "},\n";
            for (auto& o : t->objects)
                obj << "    " << cstr(o) << ",\n", no++;
        }
        h << "inline constexpr SignalInfo k_signals[] = {\n" << sig.str() << "    {\"\", \"\"},\n};\n";
        h << "inline constexpr Span k_elem_signals[] = {\n" << sigs.str() << "};\n";
        h << "inline constexpr std::string_view k_methods[] = {\n" << met.str() << "    \"\",\n};\n";
        h << "inline constexpr Span k_elem_methods[] = {\n" << mets.str() << "};\n";
        h << "inline constexpr std::string_view k_objects[] = {\n" << obj.str() << "    \"\",\n};\n";
        h << "inline constexpr Span k_elem_objects[] = {\n" << objs.str() << "};\n\n";
    }
    h << "enum class Def : uint8_t { literal, fresh, unset };\n"
         "struct PropDef {\n    Prop prop;\n    Def def;\n    bool js;\n    std::string_view json;\n};\n\n";
    {
        std::ostringstream defs, spans;
        size_t nd = 0;
        for (const Block* t : types) {
            spans << "    {" << nd << ", " << flat[t->name].size() << "},  // " << t->name << "\n";
            for (const Prop& p : flat[t->name]) {
                std::string kind = "Def::literal", text = p.def;
                if (p.def == "unset")
                    kind = "Def::unset", text = "";
                else if (p.def.rfind("fn ", 0) == 0)
                    kind = "Def::fresh", text = trim(p.def.substr(3));
                defs << "    {Prop::" << ident(p.name) << ", " << kind << ", " << (p.js ? "true" : "false") << ", "
                     << cstr(text) << "},\n";
                nd++;
            }
        }
        h << "inline constexpr PropDef k_prop_defs[] = {\n"
          << defs.str() << "    {Prop::count_, Def::unset, false, \"\"},\n};\n";
        h << "inline constexpr Span k_elem_props[] = {\n" << spans.str() << "};\n\n";
    }
    h << "// A property's name to its Prop: a perfect hash (FNV-1a with seed " << seed << ", " << slots
      << " slots), one probe.\n";
    h << "inline constexpr int16_t k_slots[" << slots << "] = {";
    for (size_t i = 0; i < slots; i++)
        h << (i % 24 ? "" : "\n    ") << table[i] << ",";
    h << "\n};\n";
    h << "inline constexpr bool prop_of(std::string_view name, Prop *out) {\n"
         "    uint32_t x = 2166136261u ^ "
      << seed
      << "u;\n"
         "    for (char c : name) x = (x ^ static_cast<uint8_t>(c)) * 16777619u;\n"
         "    int16_t i = k_slots[x & "
      << (slots - 1)
      << "u];\n"
         "    if (i < 0 || k_props[i].name != name) return false;\n"
         "    *out = (Prop)i;\n    return true;\n}\n\n"
         "inline constexpr bool elem_of(std::string_view name, Elem *out) {\n"
         "    for (int i = 0; i < (int)Elem::count_; i++)\n"
         "        if (k_elems[i] == name) return *out = (Elem)i, true;\n"
         "    return false;\n}\n\n}  // namespace rx::schema\n";

    for (auto [file, text] : {std::pair{dir + "/rx_props.h", h.str()}}) {
        std::ifstream old(file);
        std::stringstream was;
        was << old.rdbuf();
        if (old && was.str() == text)
            continue;
        std::ofstream out(file);
        out << text;
        if (!out)
            fail(0, "cannot write " + file);
    }
    std::printf("rxgen: %zu types, %zu properties, perfect hash seed %u in %zu slots\n", types.size(), names.size(),
                seed, slots);
    return 0;
}
