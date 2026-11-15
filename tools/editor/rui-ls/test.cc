// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include <fcntl.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <functional>
#include <regex>
#include <set>

#include "engine/base/arena.h"
#include "engine/syntax/rui.h"
#include "ls.h"
#include "model.h"

extern char** environ;
using namespace rui_ls;
namespace fs = std::filesystem;

namespace {

int failed = 0;
void check(const std::string& name, bool ok, const std::string& detail = "") {
    if (ok)
        std::printf("PASS %s\n", name.c_str());
    else {
        failed++;
        std::printf("FAIL %s%s\n", name.c_str(), detail.empty() ? "" : (" :: " + detail).c_str());
    }
}
std::string read(const std::string& p) {
    FILE* f = std::fopen(p.c_str(), "rb");
    if (!f)
        return "";
    std::string out;
    char b[65536];
    size_t n;
    while ((n = std::fread(b, 1, sizeof b, f)) > 0)
        out.append(b, n);
    std::fclose(f);
    return out;
}
std::string joinl(const std::vector<std::string>& xs, const std::string& sep = "\n") {
    std::string r;
    for (size_t i = 0; i < xs.size(); i++)
        r += (i ? sep : "") + xs[i];
    return r;
}
J parse(const std::string& text) {
    rx::engine::Arena arena;
    auto f = rx::engine::rui::parse(text, arena);
    if (!f)
        return J(nullptr);
    std::string out;
    rx::engine::rui::dump(**f, out);
    return J::parse(out);
}
void engine_signals(const rx::engine::rui::Element& e, std::vector<std::string>& out) {
    for (uint32_t k = 0; k < e.signals.size; k++)
        out.push_back(std::string(e.signals[k].name));
    for (uint32_t k = 0; k < e.children.size; k++)
        engine_signals(*e.children[k], out);
    for (uint32_t k = 0; k < e.objects.size; k++)
        engine_signals(*e.objects[k].node, out);
}
std::string engine_signals(const std::string& text) {
    rx::engine::Arena arena;
    auto f = rx::engine::rui::parse(text, arena);
    if (!f)
        return "(no parse)";
    std::vector<std::string> out;
    engine_signals(*(*f)->root, out);
    std::sort(out.begin(), out.end());
    return joinl(out, ",");
}
void outline_signals(const Element* el, std::vector<std::string>& out) {
    for (const Member& m : el->members)
        if (m.signal)
            out.push_back(m.name);
    for (const Element* c : el->children)
        outline_signals(c, out);
}
std::string outline_signals(const Element* root) {
    std::vector<std::string> out;
    outline_signals(root, out);
    std::sort(out.begin(), out.end());
    return joinl(out, ",");
}
J strict(const J& n) {
    std::vector<std::string> kids, members;
    for (const J& c : n["children"].a)
        kids.push_back(strict(c).dump());
    for (const J& o : n["objects"].a)
        kids.push_back(strict(o["node"]).dump());
    std::sort(kids.begin(), kids.end());
    for (const char* k : {"props", "handlers", "custom", "functions"})
        for (const J& m : n[k].a)
            members.push_back(m["name"].text());
    std::sort(members.begin(), members.end());
    J ks = J::array();
    for (auto& k : kids)
        ks.push(J(k));
    return J::object({{"type", n["type"]}, {"id", n["id"]}, {"kids", ks}, {"members", J(joinl(members, ","))}});
}
J loose(const Element* el) {
    std::vector<std::string> kids, members;
    for (const Element* c : el->children)
        kids.push_back(loose(c).dump());
    std::sort(kids.begin(), kids.end());
    for (const Member& m : el->members)
        if (!m.signal
            && (m.kind == Member::prop || m.kind == Member::handler || m.kind == Member::custom
                || m.kind == Member::function))
            members.push_back(m.name);
    std::sort(members.begin(), members.end());
    J ks = J::array();
    for (auto& k : kids)
        ks.push(J(k));
    return J::object({{"type", J(el->type)},
                      {"id", el->id.empty() ? J(nullptr) : J(el->id)},
                      {"kids", ks},
                      {"members", J(joinl(members, ","))}});
}
std::string squash(const std::string& t) {
    std::string r;
    bool sp = false;
    for (char c : t) {
        bool w = c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v';
        if (w) {
            if (!sp)
                r += ' ';
            sp = true;
        } else
            r += c, sp = false;
    }
    return r;
}
J strip(const J& v) {
    if (v.is_str())
        return J(squash(v.str()));
    if (v.is_arr()) {
        J a = J::array();
        for (const J& x : v.a)
            a.push(strip(x));
        return a;
    }
    if (v.is_obj()) {
        J o = J::object();
        for (auto& [k, x] : v.o)
            if (k != "line" && k != "pos")
                o.set(k, strip(x));
        return o;
    }
    return v;
}
std::string tree(const std::string& t) {
    return strip(parse(t)).dump();
}

std::vector<std::string> lines_of(const J& diags) {
    std::vector<std::string> out;
    for (const J& x : diags.a)
        out.push_back(std::to_string(static_cast<long>(x["range"]["start"]["line"].num()) + 1) + ": "
                      + x["message"].text());
    return out;
}
std::vector<std::string> labels(const J& items) {
    std::vector<std::string> out;
    for (const J& x : items.a)
        out.push_back(x["label"].text());
    return out;
}
bool has(const std::vector<std::string>& xs, const std::string& x) {
    return std::find(xs.begin(), xs.end(), x) != xs.end();
}
J pos(int line, int ch) {
    return J::object({{"line", J(line)}, {"character", J(ch)}});
}

struct Server {
    pid_t pid = 0;
    int in = -1, out = -1;
    std::string buf;
    std::map<std::string, J> diagnostics;
    long next = 1;
    bool start(const std::string& bin, const std::string& repo) {
        int to[2], from[2];
        if (pipe(to) || pipe(from))
            return false;
        posix_spawn_file_actions_t fa;
        posix_spawn_file_actions_init(&fa);
        posix_spawn_file_actions_adddup2(&fa, to[0], 0);
        posix_spawn_file_actions_adddup2(&fa, from[1], 1);
        posix_spawn_file_actions_addclose(&fa, to[1]);
        posix_spawn_file_actions_addclose(&fa, from[0]);
        std::string r = "--repo";
        char* args[] = {const_cast<char*>(bin.c_str()), r.data(), const_cast<char*>(repo.c_str()), nullptr};
        int e = posix_spawn(&pid, bin.c_str(), &fa, nullptr, args, environ);
        posix_spawn_file_actions_destroy(&fa);
        close(to[0]), close(from[1]);
        in = to[1], out = from[0];
        return e == 0;
    }
    void write_msg(J msg) {
        J m = J::object({{"jsonrpc", J("2.0")}});
        for (auto& [k, v] : msg.o)
            m.set(k, v);
        std::string s = m.dump();
        std::string all = "Content-Length: " + std::to_string(s.size()) + "\r\n\r\n" + s;
        for (size_t at = 0; at < all.size();) {
            ssize_t n = ::write(in, all.data() + at, all.size() - at);
            if (n <= 0)
                return;
            at += static_cast<size_t>(n);
        }
    }
    bool read_msg(J& msg) {
        for (;;) {
            size_t head = buf.find("\r\n\r\n");
            if (head != std::string::npos) {
                size_t cl = buf.find("Content-Length: ");
                size_t len = std::strtoul(buf.c_str() + cl + 16, nullptr, 10);
                if (buf.size() >= head + 4 + len) {
                    msg = J::parse(buf.substr(head + 4, len));
                    buf.erase(0, head + 4 + len);
                    if (msg["method"] == "textDocument/publishDiagnostics")
                        diagnostics[msg["params"]["uri"].text()] = msg["params"]["diagnostics"];
                    return true;
                }
            }
            char chunk[65536];
            ssize_t n = ::read(out, chunk, sizeof chunk);
            if (n <= 0)
                return false;
            buf.append(chunk, static_cast<size_t>(n));
        }
    }
    J request(const std::string& method, J params) {
        long id = next++;
        write_msg(J::object({{"id", J(id)}, {"method", J(method)}, {"params", params}}));
        J msg;
        while (read_msg(msg))
            if (msg["id"] == static_cast<double>(id))
                return msg;
        return J();
    }
    void notify(const std::string& method, J params) {
        write_msg(J::object({{"method", J(method)}, {"params", params}}));
    }
    J diagnostics_of(const std::string& uri) {
        diagnostics.erase(uri);
        J msg;
        while (!diagnostics.count(uri) && read_msg(msg)) {
        }
        return diagnostics[uri];
    }
};

J at(const std::string& text, const std::string& marker) {
    std::string bare = marker;
    bare.erase(bare.find('|'), 1);
    size_t k = text.find(bare);
    if (k == std::string::npos)
        return pos(0, 0);
    size_t off = k + marker.find('|');
    std::string before = text.substr(0, off);
    size_t nl = before.rfind('\n');
    int line = static_cast<int>(std::count(before.begin(), before.end(), '\n'));
    return pos(line, static_cast<int>(u16len(nl == std::string::npos ? before : before.substr(nl + 1))));
}

}

int dump(int argc, char** argv) {
    for (int k = 2; k < argc; k++) {
        std::string f = argv[k], text = read(f);
        Doc* d = open("file://" + f, text, 1);
        std::printf("%s\n",
                    J::object({{"file", J(f)}, {"diagnostics", diagnose(d)}, {"symbols", symbols(d)}}).dump().c_str());
        auto lines = std::count(text.begin(), text.end(), '\n') + 1;
        size_t a = 0;
        for (long L = 0; L < lines; L++) {
            size_t nl = text.find('\n', a);
            std::string l = text.substr(a, nl == std::string::npos ? std::string::npos : nl - a);
            a = nl == std::string::npos ? text.size() : nl + 1;
            for (size_t c = 0; c <= u16len(l); c += 5) {
                J p = pos(static_cast<int>(L), static_cast<int>(c));
                J items = completion(d, p), labs = J::array();
                for (const J& x : items.a)
                    labs.push(J::array({x["label"], x["kind"], x["detail"], x["sortText"]}));
                std::printf("%s\n",
                            J::object({{"at", J(std::to_string(L) + ":" + std::to_string(c))},
                                       {"hover", hover(d, p)},
                                       {"definition", definition(d, p)},
                                       {"completion", labs}})
                                .dump()
                                .c_str());
            }
        }
    }
    return 0;
}

int main(int argc, char** argv) {
    if (argc > 2 && !std::strcmp(argv[1], "--dump")) {
        char wd[4096];
        g_repo = getcwd(wd, sizeof wd) ? wd : ".";
        return dump(argc, argv);
    }
    char cwd[4096];
    const std::string repo = argc > 1 ? argv[1] : getcwd(cwd, sizeof cwd) ? cwd : ".";
    g_repo = repo;
    const J spaces = J::object({{"tabSize", J(4)}, {"insertSpaces", J(true)}});

    auto ruis = [&](std::initializer_list<const char*> dirs) {
        std::vector<std::string> out;
        for (const char* dir : dirs) {
            std::vector<std::string> fsx;
            std::error_code ec;
            for (auto it = fs::directory_iterator(repo + "/" + dir, ec); !ec && it != fs::directory_iterator();
                 it.increment(ec))
                if (it->path().extension() == ".rui")
                    fsx.push_back(it->path().string());
            std::sort(fsx.begin(), fsx.end());
            out.insert(out.end(), fsx.begin(), fsx.end());
        }
        return out;
    };
    std::vector<std::string> examples = ruis({"distros/main", "distros/main/ui", "distros/main/panes"});
    std::vector<std::string> every =
        ruis({"distros/main", "distros/main/ui", "distros/main/panes", "distros/clay", "distros/clay/ui",
              "distros/clay/panes", "distros/endfield", "distros/endfield/ui", "distros/endfield/ui/components",
              "distros/endfield/panes", "distros/shared", "distros/vanilla", "src/ui/devtools", "src/ui/kit",
              "src/ui/panes"});
    auto rel = [&](const std::string& f) { return f.substr(repo.size() + 1); };
    for (const std::string& f : every) {
        std::string text = read(f);
        J diags = diagnose(open("file://" + f, text, 1));
        std::vector<std::string> first;
        for (size_t k = 0; k < diags.size() && k < 3; k++)
            first.push_back(lines_of(diags)[k]);
        check(rel(f) + ": no diagnostics", diags.size() == 0, joinl(first, " | "));
        auto o = outline(text);
        check(rel(f) + ": outline as parse()", o && loose(o->root).dump() == strict(parse(text)).dump());
        check(rel(f) + ": the outline's signals the engine's", o && outline_signals(o->root) == engine_signals(text),
              (o ? outline_signals(o->root) : "") + " / " + engine_signals(text));
    }

    for (const std::string& f : examples) {
        std::string name = rel(f), text = read(f);
        std::string out = format(text, spaces);
        check(name + ": formatting changes only whitespace, the same tree",
              squash(out) == squash(text) && tree(out) == tree(text));
        check(name + ": formatting again changes nothing", format(out, spaces) == out);
        std::string shifted;
        size_t a = 0;
        for (;;) {
            size_t nl = text.find('\n', a);
            std::string l = text.substr(a, nl == std::string::npos ? std::string::npos : nl - a);
            shifted += (l.empty() ? l : "   " + l);
            if (nl == std::string::npos)
                break;
            shifted += "\n";
            a = nl + 1;
        }
        check(name + ": shifted right, formatted back", format(shifted, spaces) == out);
        check(name + ": tabs and back",
              format(format(out, J::object({{"tabSize", J(4)}, {"insertSpaces", J(false)}})), spaces) == out);
        check(name + ": formatted already", out == text);
    }
    const std::string messy = joinl({"Dock {",
                                     "side:\"right\"; width: 300   ",
                                     "  property var x:({",
                                     "      a: 1,",
                                     "      b: 2",
                                     "  })",
                                     "        Text {",
                                     "text: x.a > 0",
                                     "    ? \"yes\"",
                                     "    : \"no\"",
                                     " }",
                                     "  WebView { css: `body {",
                                     "   color: red }",
                                     "`; url: \"a\" }",
                                     "    /* a",
                                     "       comment */",
                                     "      function f(a) {",
                                     "  if (a)",
                                     "      return 1",
                                     "  return 2",
                                     "      }",
                                     "onWidthChanged: {",
                                     "console.log(\"w\")",
                                     "}",
                                     "    List { model: 2; delegate: Row {",
                                     "  Text { text: index }",
                                     "    } }",
                                     "}",
                                     "",
                                     ""});
    const std::string tidy = joinl({"Dock {",
                                    "    side: \"right\"; width: 300",
                                    "    property var x: ({",
                                    "        a: 1,",
                                    "        b: 2",
                                    "    })",
                                    "    Text {",
                                    "        text: x.a > 0",
                                    "            ? \"yes\"",
                                    "            : \"no\"",
                                    "    }",
                                    "    WebView { css: `body {",
                                    "   color: red }",
                                    "`; url: \"a\" }",
                                    "    /* a",
                                    "       comment */",
                                    "    function f(a) {",
                                    "        if (a)",
                                    "            return 1",
                                    "        return 2",
                                    "    }",
                                    "    onWidthChanged: {",
                                    "        console.log(\"w\")",
                                    "    }",
                                    "    List { model: 2; delegate: Row {",
                                    "        Text { text: index }",
                                    "    } }",
                                    "}",
                                    ""});
    std::string formatted = format(messy, spaces);
    check("format: members, continuations, blocks, delegates; templates and comments as they are", formatted == tidy,
          "\n" + formatted);
    check("format: a file that doesn't parse is left alone",
          format_edits(open("file:///broken.rui", "Dock {\n  Text {\n", 1), spaces).size() == 0);

    {
        char tmpl[] = "/tmp/rui-ls-XXXXXX";
        std::string root = mkdtemp(tmpl);
        fs::create_directories(root + "/ui");
        fs::create_directories(root + "/kit");
        auto write = [&](const std::string& f, const std::string& t) {
            FILE* w = std::fopen((root + "/" + f).c_str(), "wb");
            std::fwrite(t.data(), 1, t.size(), w);
            std::fclose(w);
        };
        write("ui/Card.rui",
              "Column {\n    id: card\n    property string title: \"x\"\n    function bump() { }\n    Text { text: "
              "card.title }\n    Slot { }\n}\n");
        write("kit/Badge.rui", "Row {\n    property string label: \"\"\n}\n");
        write("kit/Loop.rui", "Column { Loop { } }\n");
        std::vector<std::string> main_lines = {"use \"../kit\" as Kit",
                                               "Dock {",
                                               "    id: app",
                                               "    Column {",
                                               "        Card { id: c; title: \"A\"; Text { text: c.title } }",
                                               "        Kit.Badge { label: c.title; colour: 1 }",
                                               "        Kit.Nope { }",
                                               "        Car { }",
                                               "        Kit.Loop { }",
                                               "        Text { text: c.nope }",
                                               "    }",
                                               "    Text { }",
                                               "}",
                                               ""};
        std::string main = joinl(main_lines);
        std::string uri = "file://" + root + "/ui/main.rui";
        Doc* d = open(uri, main, 1);
        auto diags = lines_of(diagnose(d));
        auto has_d = [&](int line, const std::string& text) {
            for (auto& x : diags)
                if (x.rfind(std::to_string(line) + ": ", 0) == 0 && x.find(text) != std::string::npos)
                    return true;
            return false;
        };
        std::string all = joinl(diags, " | ");
        bool line5 = false;
        for (auto& x : diags)
            line5 = line5 || x.rfind("5:", 0) == 0;
        check("components: a use's property is known, an unknown one isn't",
              !line5 && has_d(6, "Kit.Badge has no property colour"), all);
        check("components: Kit.Nope, no such file", has_d(7, "unknown element Kit.Nope") && has_d(7, "no Nope.rui in"),
              all);
        check("components: Car, did you mean Card", has_d(8, "did you mean Card"), all);
        check("components: one using itself", has_d(9, "uses itself"), all);
        check("components: c.nope of a component", has_d(10, "c (Card) has no property nope"), all);
        check("components: nothing else", diags.size() == 5, all);
        auto at_l = [&](int line, const std::string& word, int k = 0) {
            const std::string& l = main_lines[static_cast<size_t>(line)];
            return pos(line, static_cast<int>(l.find(word)) + k);
        };
        J hc = hover(d, at_l(4, "Card", 1));
        std::string hv = hc["contents"]["value"].text();
        check("components: hover on Card: its file and its own",
              hv.find("Card.rui") != std::string::npos && hv.find("`title`") != std::string::npos
                  && hv.find("Slot") != std::string::npos,
              hv);
        J ht = hover(d, at_l(4, "title", 1));
        check("components: hover on a use's property: the component's line",
              ht["contents"]["value"].text().find("property string title: \"x\"") != std::string::npos,
              ht["contents"]["value"].text());
        J dc = definition(d, at_l(4, "Card", 1));
        auto ends = [](const std::string& s, const std::string& x) {
            return s.size() >= x.size() && s.compare(s.size() - x.size(), x.size(), x) == 0;
        };
        check("components: definition of Card: its file",
              ends(dc["uri"].text(), "/ui/Card.rui") && dc["range"]["start"]["line"] == 0, dc.dump());
        J dt = definition(d, at_l(4, "title", 1));
        check("components: definition of a use's property: in its file",
              ends(dt["uri"].text(), "/ui/Card.rui") && dt["range"]["start"]["line"] == 2, dt.dump());
        J dx = definition(d, at_l(4, "c.title", 3));
        check("components: definition of c.title: in its file",
              ends(dx["uri"].text(), "/ui/Card.rui") && dx["range"]["start"]["line"] == 2, dx.dump());
        auto keys = labels(completion(d, pos(4, static_cast<int>(main_lines[4].find("id:")))));
        check("components: completion of a use's keys has its own (not what it sets)",
              !has(keys, "title") && has(keys, "onTitleChanged") && has(keys, "padding") && !has(keys, "bump"),
              joinl(keys, ","));
        check("components: completion of elements has Card and Kit.Badge",
              has(keys, "Card") && has(keys, "Kit.Badge") && !has(keys, "Slot"), joinl(keys, ","));
        auto vals = labels(completion(d, at_l(4, "c.title", 2)));
        check("components: completion after c. has title and bump", has(vals, "title") && has(vals, "bump"),
              joinl(vals, ","));
        Doc* card = open("file://" + root + "/ui/Card.rui", read(root + "/ui/Card.rui"), 1);
        check("components: a component file, its Slot", diagnose(card).size() == 0, diagnose(card).dump());
        Doc* plain = open("file://" + root + "/ui/plain.rui", "Dock {\n    Slot { }\n}\n", 1);
        check("components: a Slot outside a component",
              diagnose(plain).dump().find("only for a component") != std::string::npos, diagnose(plain).dump());
        Doc* kit = open("file://" + root + "/ui/kit.rui",
                        "use \"nowhere\"\nDock {\n    List { model: 2; delegate: Row { Text { id: t; text: index } } "
                        "}\n    List { model: 2; delegate: Row { Text { id: t } } }\n}\n",
                        1);
        J kd = diagnose(kit);
        check("components: a use of no folder; ids in delegates their own",
              kd.size() == 1 && kd[0]["message"].text().rfind("no folder", 0) == 0, kd.dump());
        Doc* clock =
            open("file://" + root + "/ui/clock.rui",
                 "Dock {\n    property var now: 0\n    Timer { interval: 1000; onTriggered: now = new Date() }\n"
                 "    Timer { interval: 1000; aligned: true; onTriggered: now = new Date() }\n}\n",
                 1);
        J cd = diagnose(clock);
        check("perf: a clock's Timer off the wall clock is a hint at its line, the aligned one nothing",
              cd.size() == 1 && cd[0]["severity"] == 4 && cd[0]["range"]["start"]["line"] == 2
                  && cd[0]["message"].text().find("aligned: true") != std::string::npos,
              cd.dump());
        auto mo = outline(main);
        check("components: outline as parse() with uses and Kit.Card",
              mo && loose(mo->root).dump() == strict(parse(main)).dump());
        check("components: formatting leaves use lines", format(main, spaces) == main, format(main, spaces));
        fs::remove_all(root);
    }

    Server s;
    if (!s.start(repo + "/build/rui-ls", repo)) {
        check("the server starts", false, repo + "/build/rui-ls");
        std::printf("%d failed\n", failed);
        return 1;
    }
    J init = s.request(
        "initialize",
        J::parse(R"({"capabilities":{"textDocument":{"completion":{"completionItem":{"snippetSupport":true}}}}})"));
    bool dot = false;
    for (const J& c : init["result"]["capabilities"]["completionProvider"]["triggerCharacters"].a)
        dot = dot || c == ".";
    check("initialize: rui-ls with completion on .", init["result"]["serverInfo"]["name"] == "rui-ls" && dot);
    s.notify("initialized", J::object());

    const std::string uri = "file:///tmp/probe.rui";
    const std::string text = R"(Dock {
    id: root
    side: "right"; width: 300
    property int count: 0
    function bump(by) { count = count + by }
    Process { id: clock; command: ["date"] }
    Text {
        id: label
        text: clock.state.now + root.count
        font.size: 13
        f
    }
    List {
        model: 3
        delegate: Row { Text { text: modelData + index } }
    }
    Button { onClicked: bump(1) }
    Text { text: theme. }
    Text { text: label.font. }
}
)";
    s.notify(
        "textDocument/didOpen",
        J::object({{"textDocument",
                    J::object({{"uri", J(uri)}, {"languageId", J("rui")}, {"version", J(1)}, {"text", J(text)}})}}));
    J d1 = s.diagnostics_of(uri);
    check("didOpen: a member being typed is a parse error",
          d1.size() == 1 && std::regex_search(d1[0]["message"].text(), std::regex("expected : after f")), d1.dump());

    auto comp = [&](const std::string& marker) {
        return s.request("textDocument/completion",
                         J::object({{"textDocument", J::object({{"uri", J(uri)}})},
                                    {"position", at(text, marker)}}))["result"]["items"];
    };
    J items = comp("        f|");
    auto ls1 = labels(items);
    check("completion: a Text's properties at a member",
          has(ls1, "font.family") && has(ls1, "wrap") && !has(ls1, "text"), joinl(ls1, ","));
    bool row = false;
    for (const J& x : items.a)
        row = row
            || (x["label"] == "Row" && x["insertTextFormat"] == 2
                && x["textEdit"]["newText"].text().rfind("Row {", 0) == 0);
    check("completion: elements as snippets", row);
    check("completion: handlers", has(ls1, "onTextChanged") && has(ls1, "Component.onCompleted"));
    auto ls2 = labels(comp("clock.|state"));
    check("completion: an id's members", has(ls2, "state") && has(ls2, "send") && has(ls2, "running"), joinl(ls2, ","));
    auto ls3 = labels(comp("theme.| }"));
    check("completion: a global's members", has(ls3, "background") && has(ls3, "foreground") && has(ls3, "dark"),
          joinl(ls3, ","));
    auto ls4 = labels(comp("label.font.| }"));
    check("completion: a group's members (font.)", has(ls4, "size") && has(ls4, "mono"), joinl(ls4, ","));
    auto ls5 = labels(comp("text: modelData| + index"));
    bool all5 = true;
    for (const char* k : {"modelData", "index", "clock", "root", "bump", "count"})
        all5 = all5 && has(ls5, k);
    check("completion: in a delegate, modelData, index and the ids", all5, joinl(ls5, ","));
    check("completion: an enum's values in its string", has(labels(comp("side: \"r|ight\"")), "left"));
    check("completion: the root's function from a child", has(labels(comp("bump(|1)")), "bump"));

    {
        J sh =
            s.request("textDocument/signatureHelp",
                      J::object({{"textDocument", J::object({{"uri", J(uri)}})}, {"position", at(text, "bump(|1)")}}));
        check("signature help: a function's parameters",
              sh["result"]["signatures"].size() == 1 && sh["result"]["activeParameter"] == 0, sh.dump());
    }

    auto hov = [&](const std::string& marker) {
        return s
            .request("textDocument/hover",
                     J::object({{"textDocument", J::object({{"uri", J(uri)}})},
                                {"position", at(text, marker)}}))["result"]["contents"]["value"]
            .text();
    };
    auto contains = [](const std::string& h, const std::string& x) { return h.find(x) != std::string::npos; };
    std::string h = hov("    si|de: \"right\"");
    check("hover: a property, its default and README's words", contains(h, "side: \"right\"") && contains(h, "`left`"),
          h);
    h = hov("    Proc|ess {");
    check("hover: an element, its signals", contains(h, "message(message)") && contains(h, "send()"), h);
    h = hov("clock.sta|te.now");
    check("hover: an id's property", contains(h, "Process { state:"), h);
    h = hov("text: clo|ck.state");
    check("hover: an id", contains(h, "Process { id: clock }"), h);
    h = hov("onCli|cked");
    check("hover: a handler, its signal", contains(h, "clicked()"), h);
    h = hov("root.cou|nt");
    check("hover: a property of its own", contains(h, "property int count"), h);

    auto def = [&](const std::string& marker) {
        return s.request(
            "textDocument/definition",
            J::object({{"textDocument", J::object({{"uri", J(uri)}})}, {"position", at(text, marker)}}))["result"];
    };
    J loc = def("text: clo|ck.state");
    check("definition: an id", loc["range"]["start"]["line"] == 5 && loc["range"]["start"]["character"] == 18,
          loc.dump());
    loc = def("onClicked: bu|mp");
    check("definition: a function of the root", loc["range"]["start"]["line"] == 4, loc.dump());
    loc = def("root.cou|nt");
    check("definition: id.property of its own", loc["range"]["start"]["line"] == 3, loc.dump());

    J refs = s.request("textDocument/references",
                       J::object({{"textDocument", J::object({{"uri", J(uri)}})},
                                  {"position", at(text, "id: clo|ck")},
                                  {"context", J::object({{"includeDeclaration", J(true)}})}}));
    check("references: an id", refs["result"].size() == 2, refs["result"].dump());
    J ren = s.request("textDocument/rename",
                      J::object({{"textDocument", J::object({{"uri", J(uri)}})},
                                 {"position", at(text, "clo|ck.state")},
                                 {"newName", J("date")}}));
    bool all_date = ren["result"]["changes"][uri].size() == 2;
    for (const J& e : ren["result"]["changes"][uri].a)
        all_date = all_date && e["newText"] == "date";
    check("rename: an id and its uses", all_date);

    J syms = s.request("textDocument/documentSymbol", J::object({{"textDocument", J::object({{"uri", J(uri)}})}}));
    const J& root = syms["result"][0];
    std::vector<std::string> kids;
    for (const J& c : root["children"].a)
        kids.push_back(c["name"].text());
    check("symbols: the tree, ids in names",
          root["name"] == "Dock root" && has(kids, "Process clock") && has(kids, "Text label") && has(kids, "count"),
          joinl(kids, ","));

    std::string fixed = text;
    fixed.replace(fixed.find("        f\n"), 10, "");
    fixed.replace(fixed.find("theme. }"), 8, "theme.dark }");
    fixed.replace(fixed.find("label.font. }"), 13, "label.font.size }");
    s.notify("textDocument/didChange",
             J::object({{"textDocument", J::object({{"uri", J(uri)}, {"version", J(2)}})},
                        {"contentChanges", J::array({J::object({{"text", J(fixed)}})})}}));
    J d2 = s.diagnostics_of(uri);
    check("didChange: fixed, no diagnostics", d2.size() == 0, d2.dump());
    s.notify(
        "textDocument/didChange",
        J::object({{"textDocument", J::object({{"uri", J(uri)}, {"version", J(3)}})},
                   {"contentChanges",
                    J::array({J::object({{"text", J("Dock {\n    Text { colr: \"red\"; text: clock.x }\n}\n")}})})}}));
    J d3 = s.diagnostics_of(uri);
    check("didChange: an unknown property",
          d3.size() == 1 && d3[0]["message"] == "Text has no property colr (did you mean color?)"
              && d3[0]["range"]["start"]["line"] == 1 && d3[0]["range"]["start"]["character"] == 11,
          d3.dump());

    const std::string furi = "file:///tmp/format.rui";
    s.notify(
        "textDocument/didOpen",
        J::object({{"textDocument",
                    J::object({{"uri", J(furi)}, {"languageId", J("rui")}, {"version", J(1)}, {"text", J(messy)}})}}));
    s.diagnostics_of(furi);
    J fmt = s.request("textDocument/formatting",
                      J::object({{"textDocument", J::object({{"uri", J(furi)}})}, {"options", spaces}}));
    std::vector<std::string> applied;
    {
        size_t a = 0;
        for (;;) {
            size_t nl = messy.find('\n', a);
            applied.push_back(messy.substr(a, nl == std::string::npos ? std::string::npos : nl - a));
            if (nl == std::string::npos)
                break;
            a = nl + 1;
        }
    }
    for (size_t k = fmt["result"].size(); k-- > 0;) {
        const J& e = fmt["result"][k];
        size_t sl = static_cast<size_t>(e["range"]["start"]["line"].num()),
               sc = static_cast<size_t>(e["range"]["start"]["character"].num());
        size_t el = static_cast<size_t>(e["range"]["end"]["line"].num()),
               ec = static_cast<size_t>(e["range"]["end"]["character"].num());
        std::string joined;
        for (size_t L = sl; L <= el; L++)
            joined += (L > sl ? "\n" : "") + applied[L];
        size_t endoff = ec;
        for (size_t L = sl; L < el; L++)
            endoff += applied[L].size() + 1;
        std::string merged = joined.substr(0, sc) + e["newText"].text() + joined.substr(endoff);
        std::vector<std::string> parts;
        size_t a = 0;
        for (;;) {
            size_t nl = merged.find('\n', a);
            parts.push_back(merged.substr(a, nl == std::string::npos ? std::string::npos : nl - a));
            if (nl == std::string::npos)
                break;
            a = nl + 1;
        }
        applied.erase(applied.begin() + static_cast<long>(sl), applied.begin() + static_cast<long>(el) + 1);
        applied.insert(applied.begin() + static_cast<long>(sl), parts.begin(), parts.end());
    }
    check("formatting: the edits make the formatted file", joinl(applied) == tidy, fmt["result"].dump().substr(0, 300));
    J ranged = s.request("textDocument/rangeFormatting",
                         J::object({{"textDocument", J::object({{"uri", J(furi)}})},
                                    {"options", spaces},
                                    {"range", J::object({{"start", pos(7, 0)}, {"end", pos(9, 0)}})}}));
    bool in = ranged["result"].size() == 3;
    for (const J& e : ranged["result"].a)
        in = in && e["range"]["start"]["line"].num() >= 7 && e["range"]["start"]["line"].num() <= 9;
    check("rangeFormatting: only those lines", in, ranged["result"].dump());

    s.request("shutdown", J(nullptr));
    s.notify("exit", J(nullptr));
    int st = 0;
    waitpid(s.pid, &st, 0);
    std::printf("%s\n", failed ? (std::to_string(failed) + " failed").c_str() : "all passed");
    return failed ? 1 : 0;
}
