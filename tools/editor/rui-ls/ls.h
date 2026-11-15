// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <deque>
#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "common/json.h"

namespace rui_ls {

using rx::tools::json::J;

struct Element;
struct Component;

struct Member {
    enum Kind { prop, handler, custom, function, id, object, partial } kind = prop;
    std::string name, ptype, params;
    int pos = -1, kend = -1, colon = -1, vpos = -1, vend = -1, ppos = -1;
    Element* node = nullptr;
    std::string vtext;
    bool signal = false;
};

struct Element {
    std::string type;
    int pos = 0, open = -1, end = 0;
    bool closed = false;
    Element* parent = nullptr;
    std::string delegate;
    std::string id;
    int idPos = -1;
    std::vector<Member> members;
    std::vector<Element*> children;
    std::string base;
    Component* comp = nullptr;
};

struct Use {
    std::string path, as;
    bool has_as = false;
    int pos = 0, end = 0, asPos = -1;
};

struct Outline {
    std::deque<Element> store;
    Element* root = nullptr;
    std::vector<std::pair<std::string, Element*>> ids;
    std::vector<Element*> all;
    std::vector<Use> uses;
    long annotated = -1;
    Element* id(const std::string& name) const {
        for (auto& [k, e] : ids)
            if (k == name)
                return e;
        return nullptr;
    }
};

std::unique_ptr<Outline> outline(const std::string& src);

struct Doc {
    std::string uri, text;
    long version = 0;
    long serial = 0;
    std::vector<int> starts;
    std::unique_ptr<Outline> o;
    bool outlined = false;
};

struct Component {
    std::string name, path, uri;
    Doc* d = nullptr;
    std::unique_ptr<Doc> own;
    std::unique_ptr<Outline> own_o;
    Outline* o = nullptr;
};

struct Tok {
    std::string t;
    int s = 0, e = 0;
    std::string text;
    bool dot = false;
};
std::vector<Tok> lex(const std::string& src, int start, int end);

Doc* open(const std::string& uri, const std::string& text, long version);
Doc* doc(const std::string& uri);
void close(const std::string& uri);
std::vector<std::string> open_uris();
Outline* outline_of(Doc* d);

extern bool snippets;

J diagnose(Doc* d);
J hover(Doc* d, const J& pos);
J definition(Doc* d, const J& pos);
J completion(Doc* d, const J& pos);
J signature_help(Doc* d, const J& pos);
J symbols(Doc* d);
struct IdUses {
    std::string name;
    int ws = 0, we = 0;
    std::vector<std::pair<std::pair<int, int>, bool>> uses;
};
bool id_uses(Doc* d, const J& pos, IdUses& out);
J range(Doc* d, int s, int e);

std::string format(const std::string& text, const J& options);
J format_edits(Doc* d, const J& options, long from = 0, long to = -1);

std::string file_of(const std::string& uri);
J to_pos(Doc* d, int off);
int to_off(Doc* d, const J& pos);
size_t u16len(const std::string& s);
void log(const std::string& msg);

}
