// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "ui/ui.h"

#include "core/text/highlight.h"

#include <memory>
#include <string>
#include <vector>

using rx::text::Token;
static constexpr int kKinds = static_cast<int>(Token::count_);

static std::u16string u16(NSString* s) {
    std::u16string out(s.length, u'\0');
    [s getCharacters:reinterpret_cast<unichar*>(out.data()) range:NSMakeRange(0, s.length)];
    return out;
}

static constexpr NSUInteger k_file_most = 1 << 20, k_words_most = 16384, k_rules_most = 32, k_text_most = 64;

struct FileSpec {
    std::vector<std::u16string> text;
    std::vector<std::u16string_view> line_comments, line_strings, keywords, types, values, calls, call_after,
        key_before;
    std::vector<rx::text::BlockSpec> blocks;
    std::vector<rx::text::StringSpec> strings;
    std::vector<rx::text::PairSpec> attributes;
    std::vector<rx::text::SigilSpec> sigils;
    FileSpec() { text.reserve(k_words_most * 3 + k_rules_most * 16 + 8); }
    std::u16string_view keep(NSString* s) {
        if (text.size() == text.capacity())
            return {};
        text.push_back(u16(s));
        return text.back();
    }
};

static bool text_ok(id v) {
    return [v isKindOfClass:NSString.class] && [v length] > 0 && [v length] <= k_text_most;
}
static char16_t one_char(id v) {
    return [v isKindOfClass:NSString.class] && [v length] == 1 ? [v characterAtIndex:0] : 0;
}

static std::unique_ptr<rx::text::Lang> lang_from_file(NSString* path) {
    NSDictionary* attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    if (attrs.fileSize > k_file_most) {
        rexui_log([NSString stringWithFormat:@"syntax: %@ is too long", path.lastPathComponent]);
        return nullptr;
    }
    NSData* data = [NSData dataWithContentsOfFile:path];
    NSError* error;
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
    if (![json isKindOfClass:NSDictionary.class]) {
        rexui_log([NSString stringWithFormat:@"syntax: %@ isn't a JSON object: %@", path.lastPathComponent,
                                             error.localizedDescription ?: @"unreadable"]);
        return nullptr;
    }
    NSDictionary* d = json;
    FileSpec f;
    auto list = [&](NSString* key, std::vector<std::u16string_view>& to, NSUInteger most) {
        id v = d[key];
        if (![v isKindOfClass:NSArray.class])
            return;
        for (id s in v)
            if (text_ok(s) && to.size() < most)
                to.push_back(f.keep(s));
    };
    auto dicts = [&](NSString* key, void (^each)(NSDictionary*)) {
        id v = d[key];
        if (![v isKindOfClass:NSArray.class])
            return;
        NSUInteger n = 0;
        for (id r in v)
            if ([r isKindOfClass:NSDictionary.class] && n++ < k_rules_most)
                each(r);
    };
    list(@"lineComments", f.line_comments, k_rules_most);
    list(@"lineStrings", f.line_strings, k_rules_most);
    list(@"keywords", f.keywords, k_words_most);
    list(@"types", f.types, k_words_most);
    list(@"values", f.values, k_words_most);
    list(@"calls", f.calls, k_rules_most);
    list(@"callAfter", f.call_after, k_rules_most);
    list(@"keyBefore", f.key_before, k_rules_most);
    FileSpec* fp = &f;
    dicts(@"blockComments", ^(NSDictionary* r) {
        if (text_ok(r[@"open"]) && text_ok(r[@"close"]))
            fp->blocks.push_back({ fp->keep(r[@"open"]), fp->keep(r[@"close"]), [r[@"nested"] isEqual:@YES] });
    });
    dicts(@"strings", ^(NSDictionary* r) {
        if (text_ok(r[@"open"]) && text_ok(r[@"close"]))
            fp->strings.push_back({
                fp->keep(r[@"open"]), fp->keep(r[@"close"]), one_char(r[@"escape"]), [r[@"multiline"] isEqual:@YES],
                    [r[@"char"] isEqual:@YES],
                    text_ok(r[@"holeOpen"]) && text_ok(r[@"holeClose"]) ? fp->keep(r[@"holeOpen"])
                                                                        : std::u16string_view(),
                    text_ok(r[@"holeOpen"]) && text_ok(r[@"holeClose"]) ? fp->keep(r[@"holeClose"])
                                                                        : std::u16string_view()
            });
    });
    dicts(@"attributes", ^(NSDictionary* r) {
        if (text_ok(r[@"open"]) && text_ok(r[@"close"]))
            fp->attributes.push_back({fp->keep(r[@"open"]), fp->keep(r[@"close"])});
    });
    id sigils = d[@"sigils"];
    if ([sigils isKindOfClass:NSDictionary.class]) {
        static NSDictionary<NSString*, NSNumber*>* kinds = @{
            @"comment": @(int(Token::comment)),
            @"string": @(int(Token::string)),
            @"keyword": @(int(Token::keyword)),
            @"number": @(int(Token::number)),
            @"key": @(int(Token::key)),
            @"call": @(int(Token::call)),
            @"type": @(int(Token::type)),
            @"meta": @(int(Token::meta))
        };
        for (id g in sigils) {
            NSNumber* k = [sigils[g] isKindOfClass:NSString.class] ? kinds[sigils[g]] : nil;
            if (one_char(g) && k && f.sigils.size() < k_rules_most)
                f.sigils.push_back({one_char(g), static_cast<rx::text::Token>(k.intValue)});
        }
    }
    rx::text::Spec s;
    s.line_comments = f.line_comments;
    s.line_strings = f.line_strings;
    s.keywords = f.keywords;
    s.types = f.types;
    s.values = f.values;
    s.calls = f.calls;
    s.call_after = f.call_after;
    s.key_before = f.key_before;
    s.block_comments = f.blocks;
    s.strings = f.strings;
    s.attributes = f.attributes;
    s.sigils = f.sigils;
    s.preprocessor = one_char(d[@"preprocessor"]);
    s.digit_sep = one_char(d[@"digitSeparator"]);
    s.type_case = [d[@"typeCase"] isEqual:@YES];
    s.bit_ints = [d[@"bitInts"] isEqual:@YES];
    s.bang_macros = [d[@"bangMacros"] isEqual:@YES];
    s.long_brackets = [d[@"longBrackets"] isEqual:@YES];
    s.regex = [d[@"regex"] isEqual:@YES];
    s.members = [d[@"members"] isEqual:@YES];
    if (text_ok(d[@"longComment"]))
        s.long_comment = f.keep(d[@"longComment"]);
    if (text_ok(d[@"wordChars"]))
        s.word_chars = f.keep(d[@"wordChars"]);
    if (text_ok(d[@"assign"]))
        s.assign = f.keep(d[@"assign"]);
    s.raw = [d[@"rawStrings"] isEqual:@"cpp"] ? rx::text::Raw::cpp
        : [d[@"rawStrings"] isEqual:@"rust"]  ? rx::text::Raw::rust
                                              : rx::text::Raw::none;
    return std::make_unique<rx::text::Lang>(s);
}

static bool name_ok(NSString* name) {
    static NSCharacterSet* bad = [[NSCharacterSet
        characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-#"]
        invertedSet];
    return name.length && name.length <= 32 && [name rangeOfCharacterFromSet:bad].location == NSNotFound;
}

@interface RXSyntaxFile : NSObject {
   @public
    std::unique_ptr<rx::text::Lang> lang;
}
@property(nonatomic, copy) NSString* path;
@property(nonatomic, copy) NSDate* when;
@property(nonatomic, copy) NSString *dir, *name;
@end
@implementation RXSyntaxFile
@end

static NSMutableDictionary<NSString*, RXSyntaxFile*>* g_files;
static std::vector<std::unique_ptr<rx::text::Lang>> g_old_langs;

static NSString* find_file(NSString* dir, NSString* name) {
    NSString* file = [name stringByAppendingPathExtension:@"json"];
    NSString* home = [NSHomeDirectory() stringByAppendingPathComponent:@".config/rex"];
    for (NSString* base in @[dir ?: @"", ui_dir() ?: @"", home]) {
        if (!base.length)
            continue;
        NSString* p = [[base stringByAppendingPathComponent:@"syntax"] stringByAppendingPathComponent:file];
        if ([NSFileManager.defaultManager fileExistsAtPath:p])
            return p;
    }
    return nil;
}

static NSDate* modified(NSString* path) {
    return path ? [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil].fileModificationDate : nil;
}

static const rx::text::Lang* lang_for(RXNode* n, NSString* syntax) {
    if (!name_ok(syntax))
        return nullptr;
    NSString* dir = doc_dir(n) ?: @"";
    NSString* key = [dir stringByAppendingFormat:@"\n%@", syntax];
    if (!g_files)
        g_files = [NSMutableDictionary dictionary];
    RXSyntaxFile* f = g_files[key];
    if (!f) {
        f = [RXSyntaxFile new];
        f.dir = dir, f.name = syntax;
        f.path = find_file(dir, syntax);
        f.when = modified(f.path);
        if (f.path)
            f->lang = lang_from_file(f.path);
        g_files[key] = f;
    }
    if (f->lang)
        return f->lang.get();
    return rx::text::builtin_lang(u16(syntax));
}

static NSArray<NSString*>* candidates(NSString* dir, NSString* name) {
    NSString* file = [name stringByAppendingPathExtension:@"json"];
    NSString* home = [NSHomeDirectory() stringByAppendingPathComponent:@".config/rex"];
    NSMutableArray<NSString*>* out = [NSMutableArray array];
    for (NSString* base in @[dir ?: @"", ui_dir() ?: @"", home])
        if (base.length)
            [out addObject:[[base stringByAppendingPathComponent:@"syntax"] stringByAppendingPathComponent:file]];
    return out;
}

static void syntax_seen(NSDictionary<NSString*, id>* seen) {
    bool any = false;
    for (NSString* key in g_files) {
        RXSyntaxFile* f = g_files[key];
        NSString* path = nil;
        NSDate* when = nil;
        for (NSString* p in candidates(f.dir, f.name))
            if ([seen[p] isKindOfClass:NSDate.class]) {
                path = p, when = seen[p];
                break;
            }
        if ((path == f.path || [path isEqualToString:f.path]) && (when == f.when || [when isEqualToDate:f.when]))
            continue;
        f.path = path, f.when = when;
        if (f->lang)
            g_old_langs.push_back(std::move(f->lang));
        f->lang = path ? lang_from_file(path) : nullptr;
        any = true;
    }
    if (!any)
        return;
    for (RXDoc* doc in g_docs)
        for (RXNode* n in doc.nodes.allValues)
            if ((is_elem(n, E::Text) || is_elem(n, E::TextField) || is_elem(n, E::TextArea))
                && str(n, P::syntax, @"").length)
                apply_color(n);
}

static NSArray<NSString*>* all_candidates(void) {
    NSMutableArray<NSString*>* paths = [NSMutableArray array];
    for (NSString* key in g_files)
        [paths addObjectsFromArray:candidates(g_files[key].dir, g_files[key].name)];
    return paths;
}

void syntax_check(void) {
    static bool out;
    if (out || !g_files.count)
        return;
    out = true;
    stat_files(all_candidates(), ^(NSDictionary<NSString*, id>* seen) {
        out = false;
        syntax_seen(seen);
    });
}

void syntax_check_now(void) {
    NSMutableDictionary<NSString*, id>* seen = [NSMutableDictionary dictionary];
    for (NSString* p in all_candidates())
        seen[p] = modified(p) ?: (id)NSNull.null;
    syntax_seen(seen);
}

static NSArray<NSColor*>* colors_of(RXNode* n, NSColor* base) {
    id given = obj(n, P::syntaxColors);
    NSDictionary* cs = [given isKindOfClass:NSDictionary.class] ? given : @{};
    static NSString* names[kKinds] = {@"comment", @"string", @"keyword", @"number", @"key", @"call", @"type", @"meta"};
    NSMutableArray<NSColor*>* colors = [NSMutableArray array];
    for (int k = 0; k < kKinds; k++)
        [colors addObject:parse_color(cs[names[k]])
                    ?: (k == int(Token::comment) ? [base colorWithAlphaComponent:0.5] : base)];
    return colors;
}

const void* syntax_lang(RXNode* n) {
    NSString* syntax = str(n, P::syntax, @"");
    return syntax.length ? lang_for(n, syntax) : nullptr;
}
NSArray<NSColor*>* syntax_token_colors(RXNode* n, NSColor* base) {
    return colors_of(n, base);
}

@interface RXRuns : NSObject {
   @public
    rx::text::TokenList tokens;
    NSArray<NSColor*>* colors;
    NSColor* base;
    bool plain[kKinds];
}
@end
@implementation RXRuns
@end

void syntax_text(RXNode* n, RXTextLayer* t, NSString* s, NSColor* base) {
    NSString* syntax = str(n, P::syntax, @"");
    const rx::text::Lang* lang = syntax.length && s.length ? lang_for(n, syntax) : nullptr;
    if (!lang) {
        t.runs = nil;
        return;
    }
    RXRuns* r = t.runs ?: [RXRuns new];
    NSArray<NSColor*>* colors = colors_of(n, base);
    const bool repainted = ![colors isEqual:r->colors] || !(base == r->base || [base isEqual:r->base]);
    if (repainted) {
        r->colors = colors, r->base = base;
        for (int k = 0; k < kKinds; k++)
            r->plain[k] = [colors[static_cast<NSUInteger>(k)] isEqual:base];
    }
    std::u16string text(s.length, u'\0');
    [s getCharacters:reinterpret_cast<unichar*>(text.data()) range:NSMakeRange(0, s.length)];
    const bool moved = r->tokens.update(*lang, text);
    if (t.runs != r)
        t.runs = r;
    else if (repainted)
        [t syntaxChanged:true];
    else if (moved)
        [t syntaxChanged:false];
}

static size_t first_run(RXRuns* r, NSUInteger from) {
    const auto runs = r->tokens.runs();
    size_t lo = 0, hi = runs.size();
    while (lo < hi) {
        const size_t mid = (lo + hi) / 2;
        if (runs[mid].at + runs[mid].len <= from)
            lo = mid + 1;
        else
            hi = mid;
    }
    return lo;
}

void syntax_paint(RXRuns* r, NSMutableAttributedString* a, NSUInteger from, NSUInteger to) {
    if (!r)
        return;
    const auto runs = r->tokens.runs();
    const NSUInteger len = a.length;
    for (size_t k = first_run(r, from); k < runs.size() && runs[k].at < to; k++) {
        const int kind = static_cast<int>(runs[k].kind);
        if (r->plain[kind])
            continue;
        const NSUInteger x = MAX(runs[k].at, from), y = MIN(runs[k].at + runs[k].len, to);
        if (y > x && y - from <= len)
            [a addAttribute:NSForegroundColorAttributeName
                      value:r->colors[static_cast<NSUInteger>(kind)]
                      range:NSMakeRange(x - from, y - x)];
    }
}

uint64_t syntax_hash(RXRuns* r, NSUInteger from, NSUInteger to, size_t* cursor, uint64_t h) {
    const auto runs = r->tokens.runs();
    size_t k = *cursor;
    while (k < runs.size() && runs[k].at + runs[k].len <= from)
        k++;
    *cursor = k;
    for (; k < runs.size() && runs[k].at < to; k++) {
        const int kind = static_cast<int>(runs[k].kind);
        if (r->plain[kind])
            continue;
        h = (h ^ (MAX(runs[k].at, from) - from)) * 1099511628211ull;
        h = (h ^ (MIN(runs[k].at + runs[k].len, to) - from)) * 1099511628211ull;
        h = (h ^ static_cast<uint64_t>(kind)) * 1099511628211ull;
    }
    return h;
}

NSUInteger syntax_painted(RXRuns* r) {
    if (!r)
        return 0;
    NSUInteger count = 0;
    for (const auto& run : r->tokens.runs())
        count += !r->plain[static_cast<int>(run.kind)];
    return count;
}

void syntax_field(RXNode* n) {
    [n.editor styleChanged];
}
