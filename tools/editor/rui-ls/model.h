// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <string>
#include <utility>
#include <vector>

#include "ls.h"

namespace rui_ls {

extern std::string g_repo;
extern long g_generation;

struct Prop {
    std::string name;
    bool has_default = false;
    std::string default_json;
    bool js = false;
};
struct Type {
    std::string name;
    std::vector<Prop> props;
    std::vector<std::pair<std::string, std::string>> signals;
    std::vector<std::string> methods, objects;
    const Prop* prop(const std::string& n) const;
    const std::string* signal(const std::string& n) const;
    bool has_object(const std::string& n) const;
};
const Type* type_of(const std::string& name);
std::vector<std::string> type_names();
bool signal_params(const Type* t, const std::string& handler, const std::string& type, std::string& params,
                   std::string& why);

struct Docs {
    std::map<std::string, std::pair<std::string, std::string>> elements;
    std::vector<std::pair<std::string, std::string>> members;
    std::string general;
    std::map<std::string, std::string> globals;
    size_t serial = 0;
};
const Docs& docs();
std::string phrase(const std::string& text, const std::string& name);
std::string member_doc(const std::string& member);

struct GlobalMember {
    std::string name;
    bool function;
    std::string detail;
};
const std::vector<std::string>& global_names();
const std::vector<GlobalMember>& global_members(const std::string& name);

struct Name {
    enum Kind { prop, group, method, model, custom, function, element } kind = prop;
    std::string prop_name;
    const Member* member = nullptr;
    Component* comp = nullptr;
};
struct Names {
    std::vector<std::pair<std::string, Name>> v;
    bool has(const std::string& k) const {
        for (auto& p : v)
            if (p.first == k)
                return true;
        return false;
    }
    const Name* get(const std::string& k) const {
        for (auto& p : v)
            if (p.first == k)
                return &p.second;
        return nullptr;
    }
    void set(const std::string& k, const Name& n) {
        for (auto& p : v)
            if (p.first == k)
                return void(p.second = n);
        v.emplace_back(k, n);
    }
    auto begin() const { return v.begin(); }
    auto end() const { return v.end(); }
};
Names type_names(const std::string& type, bool delegate);
Names element_names(const Element* el);
Names comp_names(Component* c);

std::string expand(const std::string& p);
std::string dirname(const std::string& f);
std::string basename(const std::string& f);
bool is_component_file(const std::string& file);
std::string use_dir(const std::string& file, const Use& u);
std::vector<std::string> component_dirs(const std::string& file, const Outline& o, const std::string& type);
Component* load_component(const std::string& p);
Component* find_component(const std::string& file, const Outline& o, const std::string& type);
void annotate(const std::string& file, Outline* o);
std::vector<std::string> cycle_of(Component* c, std::vector<std::string> stack);
std::vector<std::string> components_in(const std::string& dir);
bool exists(const std::string& p);

}
