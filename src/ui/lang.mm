// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "engine/vm/lib.h"
#include "ui/ui.h"

static NSString* g_language = @"en";
static NSDictionary<NSString*, NSString*>* g_strings = @{};

static NSString* base_language(NSString* tag) {
    return [tag componentsSeparatedByCharactersInSet:[NSCharacterSet
                                                         characterSetWithCharactersInString:@"-_"]][0].lowercaseString;
}

static NSString* strings_path(NSString* language);

static NSString* wanted_language(void) {
    if (![g_config.language isEqualToString:@"auto"])
        return g_config.language;
    for (NSString* l in NSLocale.preferredLanguages) {
        NSString* b = base_language(l);
        if ([b isEqualToString:@"en"] || [NSFileManager.defaultManager fileExistsAtPath:strings_path(b)])
            return b;
    }
    return @"en";
}

static NSString* strings_path(NSString* language) {
    NSString* name = [NSString stringWithFormat:@"lang/%@.json", language];
    NSString* own = [ui_dir() stringByAppendingPathComponent:name];
    if ([NSFileManager.defaultManager fileExistsAtPath:own])
        return own;
    return [default_ui_dir() stringByAppendingPathComponent:name];
}

static NSDictionary<NSString*, NSString*>* read_strings(NSString* language) {
    if ([language isEqualToString:@"en"])
        return @{};
    NSString* path = strings_path(language);
    NSData* data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        rexui_log([NSString stringWithFormat:@"lang: no %@", path.stringByAbbreviatingWithTildeInPath]);
        return @{};
    }
    NSError* error;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![obj isKindOfClass:NSDictionary.class]) {
        rexui_log([NSString stringWithFormat:@"lang: %@: %@", path.lastPathComponent,
                                             error.userInfo[NSDebugDescriptionErrorKey] ?: error.localizedDescription ?: @"not an object"]);
        return @{};
    }
    NSMutableDictionary* out = [NSMutableDictionary dictionary];
    for (NSString* k in obj) {
        id v = obj[k];
        if ([k isKindOfClass:NSString.class] && [v isKindOfClass:NSString.class] && [v length])
            out[k] = v;
    }
    rexui_log([NSString stringWithFormat:@"lang: %@, %lu strings", language, (unsigned long)out.count]);
    return out;
}

static NSString* locale_of(NSString* language) {
    for (NSString* l in g_config.locales) {
        if ([base_language(l) isEqualToString:language])
            return l;
    }
    for (NSString* l in NSLocale.preferredLanguages) {
        if ([base_language(l) isEqualToString:language])
            return l;
    }
    return language;
}

void set_lang(RXDoc* doc) {
    NSString* locale = locale_of(g_language);
    doc_call(doc, @"setLang", @[@{@"language": g_language, @"locale": locale, @"strings": g_strings}]);
}

void lang_check(void) {
    static NSDate* last_mtime;
    static bool loaded;
    NSString* language = wanted_language();
    NSDate* mtime =
        [NSFileManager.defaultManager attributesOfItemAtPath:strings_path(language) error:nil].fileModificationDate;
    if (loaded && [language isEqualToString:g_language] && (mtime == last_mtime || [mtime isEqual:last_mtime]))
        return;
    loaded = true;
    last_mtime = mtime;
    g_language = language;
    g_strings = read_strings(language);
    for (RXDoc* doc in g_docs) {
        if (doc.ctx)
            set_lang(doc);
    }
}

static bool g_misses;

static void missed(NSString* text) {
    static NSMutableSet<NSString*>* seen;
    if (!g_strings.count || g_strings[text] || [seen containsObject:text])
        return;
    if (!seen)
        seen = [NSMutableSet set];
    [seen addObject:text];
    rexui_log_file([NSString stringWithFormat:@"lang: no %@ for \"%@\"", g_language, text]);
}

void lang_misses_install(void) {
    g_misses = [[[NSUserDefaults alloc] initWithSuiteName:rexui_suite()] boolForKey:@"langMisses"];
    if (!g_misses)
        return;
    rx::engine::vm::lib::qstr_miss = [](const char16_t* p, size_t n) noexcept {
        NSString* t = [NSString stringWithCharacters:(const unichar*)p length:n];
        dispatch_async(dispatch_get_main_queue(), ^{
            missed(t);
        });
    };
    rexui_log(@"lang: untranslated texts logged (langMisses)");
}

NSString* tr(NSString* text) {
    NSString* t = g_strings[text];
    if (!t && g_misses)
        missed(text);
    return t ?: text;
}
