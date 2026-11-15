// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include <poll.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <set>
#include <string>

#include "ls.h"
#include "model.h"

using namespace rui_ls;

namespace {

void send(J msg) {
    J m = J::object();
    m.set("jsonrpc", J("2.0"));
    for (auto& [k, v] : msg.o)
        m.set(k, std::move(v));
    std::string s = m.dump();
    std::string head = "Content-Length: " + std::to_string(s.size()) + "\r\n\r\n";
    std::fwrite(head.data(), 1, head.size(), stdout);
    std::fwrite(s.data(), 1, s.size(), stdout);
    std::fflush(stdout);
}

std::set<std::string> pending;

void publish(const std::string& uri) {
    Doc* d = doc(uri);
    if (!d)
        return;
    J diags = diagnose(d);
    send(J::object({{"method", J("textDocument/publishDiagnostics")},
                    {"params", J::object({{"uri", J(uri)}, {"version", J(d->version)}, {"diagnostics", diags}})}}));
}

J initialize(const J& params) {
    snippets = params["capabilities"]["textDocument"]["completion"]["completionItem"]["snippetSupport"].truthy();
    (void)docs();
    return J::parse(
        R"({"capabilities":{"textDocumentSync":{"openClose":true,"change":1},"hoverProvider":true,"definitionProvider":true,)"
        R"("referencesProvider":true,"documentHighlightProvider":true,"documentSymbolProvider":true,"renameProvider":{"prepareProvider":true},)"
        R"("completionProvider":{"triggerCharacters":["."]},"signatureHelpProvider":{"triggerCharacters":["(",","]},"documentFormattingProvider":true,"documentRangeFormattingProvider":true},)"
        R"("serverInfo":{"name":"rui-ls","version":"0.2.0"}})");
}

bool valid_name(const std::string& n) {
    if (n.empty() || !(std::isalpha(static_cast<unsigned char>(n[0])) || n[0] == '_' || n[0] == '$'))
        return false;
    for (char c : n)
        if (!(std::isalnum(static_cast<unsigned char>(c)) || c == '_' || c == '$'))
            return false;
    return true;
}

J answer(const std::string& method, const J& p, J& error) {
    if (method == "initialize")
        return initialize(p);
    if (method == "shutdown")
        return J(nullptr);
    Doc* d = doc(p["textDocument"]["uri"].text());
    if (!d)
        return J(nullptr);
    if (method == "textDocument/hover")
        return hover(d, p["position"]);
    if (method == "textDocument/definition")
        return definition(d, p["position"]);
    if (method == "textDocument/completion") {
        J r = J::object();
        r.set("isIncomplete", J(false));
        r.set("items", completion(d, p["position"]));
        return r;
    }
    if (method == "textDocument/signatureHelp")
        return signature_help(d, p["position"]);
    if (method == "textDocument/documentSymbol")
        return symbols(d);
    if (method == "textDocument/formatting")
        return format_edits(d, p["options"]);
    if (method == "textDocument/rangeFormatting")
        return format_edits(d, p["options"], static_cast<long>(p["range"]["start"]["line"].num()),
                            static_cast<long>(p["range"]["end"]["line"].num()));
    IdUses u;
    bool found = method.find("textDocument/") == 0 && id_uses(d, p["position"], u);
    if (method == "textDocument/references") {
        if (!found)
            return J(nullptr);
        J out = J::array();
        for (auto& [r, decl] : u.uses)
            if (!decl || !(p["context"]["includeDeclaration"] == false))
                out.push(J::object({{"uri", J(d->uri)}, {"range", range(d, r.first, r.second)}}));
        return out;
    }
    if (method == "textDocument/documentHighlight") {
        if (!found)
            return J(nullptr);
        J out = J::array();
        for (auto& [r, decl] : u.uses)
            out.push(J::object({{"range", range(d, r.first, r.second)}, {"kind", J(decl ? 3 : 2)}}));
        return out;
    }
    if (method == "textDocument/prepareRename")
        return found ? J::object({{"range", range(d, u.ws, u.we)}, {"placeholder", J(u.name)}}) : J(nullptr);
    if (method == "textDocument/rename") {
        if (!found)
            return J(nullptr);
        std::string name = p["newName"].text();
        if (!valid_name(name)) {
            error = J::object({{"code", J(-32602)}, {"message", J(name + " isn't a name")}});
            return J();
        }
        J edits = J::array();
        for (auto& [r, decl] : u.uses)
            edits.push(J::object({{"range", range(d, r.first, r.second)}, {"newText", J(name)}}));
        return J::object({{"changes", J::object({{d->uri, edits}})}});
    }
    error = J::object({{"code", J(-32601)}, {"message", J("no " + method)}});
    return J();
}

void notification(const std::string& method, const J& p) {
    if (method == "exit")
        std::exit(0);
    if (method == "textDocument/didOpen") {
        open(p["textDocument"]["uri"].text(), p["textDocument"]["text"].text(),
             static_cast<long>(p["textDocument"]["version"].num()));
        pending.insert(p["textDocument"]["uri"].text());
    } else if (method == "textDocument/didChange") {
        const J& changes = p["contentChanges"];
        if (changes.size())
            open(p["textDocument"]["uri"].text(), changes[changes.size() - 1]["text"].text(),
                 static_cast<long>(p["textDocument"]["version"].num()));
        for (auto& uri : open_uris())
            pending.insert(uri);
    } else if (method == "textDocument/didSave") {
        for (auto& uri : open_uris())
            pending.insert(uri);
    } else if (method == "textDocument/didClose") {
        std::string uri = p["textDocument"]["uri"].text();
        close(uri);
        pending.erase(uri);
        send(J::object({{"method", J("textDocument/publishDiagnostics")},
                        {"params", J::object({{"uri", J(uri)}, {"diagnostics", J::array()}})}}));
    }
}

void dispatch(const J& msg) {
    std::string method = msg["method"].text();
    if (!msg["id"].is_undef() && msg.has("method")) {
        J error;
        J result = answer(method, msg["params"], error);
        J reply = J::object();
        reply.set("id", msg["id"]);
        if (!error.is_undef())
            reply.set("error", std::move(error));
        else
            reply.set("result", result.is_undef() ? J(nullptr) : std::move(result));
        send(std::move(reply));
    } else if (msg.has("method")) {
        notification(method, msg["params"]);
    }
}

int format_files(int argc, char** argv) {
    bool ok;
    J options = J::parse("{\"tabSize\":4,\"insertSpaces\":true}", &ok);
    int changed = 0, failed = 0;
    for (int k = 0; k < argc; k++) {
        FILE* in = std::fopen(argv[k], "rb");
        if (!in) {
            std::fprintf(stderr, "rui-ls: can't read %s\n", argv[k]);
            failed++;
            continue;
        }
        std::string text;
        char b[65536];
        for (size_t n; (n = std::fread(b, 1, sizeof b, in)) > 0;)
            text.append(b, n);
        std::fclose(in);
        std::string out = format(text, options);
        if (out == text)
            continue;
        FILE* f = std::fopen(argv[k], "wb");
        if (!f || std::fwrite(out.data(), 1, out.size(), f) != out.size()) {
            std::fprintf(stderr, "rui-ls: can't write %s\n", argv[k]);
            failed++;
        } else {
            changed++;
        }
        if (f)
            std::fclose(f);
    }
    std::printf("%d of %d formatted\n", changed, argc);
    return failed ? 1 : 0;
}

}

int main(int argc, char** argv) {
    if (argc >= 2 && !std::strcmp(argv[1], "--format"))
        return format_files(argc - 2, argv + 2);
    std::string self = argv[0];
    g_repo = self.find('/') == std::string::npos ? "." : dirname(dirname(self));
    for (int k = 1; k + 1 < argc; k++)
        if (!std::strcmp(argv[k], "--repo"))
            g_repo = argv[k + 1];
    std::string buf;
    char chunk[65536];
    for (;;) {
        for (;;) {
            size_t head = buf.find("\r\n\r\n");
            if (head == std::string::npos)
                break;
            std::string h = buf.substr(0, head);
            size_t cl = h.find("Content-Length:");
            if (cl == std::string::npos)
                cl = h.find("content-length:");
            if (cl == std::string::npos) {
                buf.erase(0, head + 4);
                continue;
            }
            size_t len = std::strtoul(h.c_str() + cl + 15, nullptr, 10);
            if (buf.size() < head + 4 + len)
                break;
            std::string body = buf.substr(head + 4, len);
            buf.erase(0, head + 4 + len);
            bool ok;
            J msg = J::parse(body, &ok);
            if (!ok) {
                log("rui-ls: bad message");
                continue;
            }
            dispatch(msg);
        }
        struct pollfd pfd = {0, POLLIN, 0};
        int r = poll(&pfd, 1, pending.empty() ? -1 : 80);
        if (r == 0) {
            auto due = pending;
            pending.clear();
            for (auto& uri : due)
                publish(uri);
            continue;
        }
        ssize_t n = read(0, chunk, sizeof chunk);
        if (n <= 0)
            return 0;
        buf.append(chunk, static_cast<size_t>(n));
    }
}
