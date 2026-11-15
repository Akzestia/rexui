// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include <CoreFoundation/CoreFoundation.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "engine/vm/lib.h"

namespace rx::engine::vm::lib {

Value os_case(Rt& rt, Str* s, bool upper) noexcept {
    CFMutableStringRef m = CFStringCreateMutable(kCFAllocatorDefault, 0);
    if (!m)
        return rt.fail(ErrorKind::internal, "out of memory");
    CFStringAppendCharacters(m, reinterpret_cast<const UniChar*>(s->units), s->length);
    if (upper)
        CFStringUppercase(m, nullptr);
    else
        CFStringLowercase(m, nullptr);
    CFIndex n = CFStringGetLength(m);
    char16_t* buf = rt.arena.array<char16_t>(static_cast<size_t>(n) + 1);
    if (!buf) {
        CFRelease(m);
        return rt.fail(ErrorKind::internal, "out of memory");
    }
    CFStringGetCharacters(m, CFRangeMake(0, n), reinterpret_cast<UniChar*>(buf));
    CFRelease(m);
    Str* r = rt.str({buf, static_cast<size_t>(n)});
    return r ? val(r) : Value::undefined();
}

namespace {
CFLocaleRef locale_of(Str* tag) {
    if (!tag)
        return CFLocaleCreate(kCFAllocatorDefault, CFSTR("en_US"));
    CFStringRef t =
        CFStringCreateWithCharacters(kCFAllocatorDefault, reinterpret_cast<const UniChar*>(tag->units), tag->length);
    if (!t)
        return nullptr;
    CFStringRef id = CFLocaleCreateCanonicalLocaleIdentifierFromString(kCFAllocatorDefault, t);
    CFRelease(t);
    if (!id)
        return nullptr;
    CFLocaleRef l = CFLocaleCreate(kCFAllocatorDefault, id);
    CFRelease(id);
    return l;
}
Value to_value(Rt& rt, CFStringRef s) {
    if (!s)
        return rt.fail(ErrorKind::internal, "out of memory");
    CFIndex n = CFStringGetLength(s);
    char16_t* buf = rt.arena.array<char16_t>(static_cast<size_t>(n) + 1);
    if (!buf) {
        CFRelease(s);
        return rt.fail(ErrorKind::internal, "out of memory");
    }
    CFStringGetCharacters(s, CFRangeMake(0, n), reinterpret_cast<UniChar*>(buf));
    CFRelease(s);
    Str* r = rt.str({buf, static_cast<size_t>(n)});
    return r ? val(r) : Value::undefined();
}
}

extern "C" {
struct UCollator;
UCollator* ucol_open(const char* loc, int* status);
int ucol_strcoll(const UCollator* c, const uint16_t* a, int32_t al, const uint16_t* b, int32_t bl);
void ucol_setAttribute(UCollator* c, int attr, int value, int* status);
int32_t uloc_forLanguageTag(const char* tag, char* locale, int32_t cap, int32_t* parsed, int* status);
}

namespace {
enum {
    k_ucol_alternate = 1,
    k_ucol_case_level = 3,
    k_ucol_normalization = 4,
    k_ucol_strength = 5,
    k_ucol_numeric = 7,
    k_ucol_off = 16,
    k_ucol_on = 17,
    k_ucol_tertiary = 2,
    k_ucol_non_ignorable = 21
};
struct Coll {
    char tag[32];
    UCollator* c;
};
Coll g_colls[8];
uint32_t g_n_colls = 0;
UCollator* collator(const char* tag) {
    for (uint32_t k = 0; k < g_n_colls; k++)
        if (!std::strcmp(g_colls[k].tag, tag))
            return g_colls[k].c;
    char id[64];
    int status = 0;
    int32_t parsed = 0;
    uloc_forLanguageTag(tag, id, sizeof id, &parsed, &status);
    if (status > 0)
        std::snprintf(id, sizeof id, "%s", "root");
    status = 0;
    UCollator* c = ucol_open(id, &status);
    if (!c || status > 0)
        return nullptr;
    ucol_setAttribute(c, k_ucol_strength, k_ucol_tertiary, &status);
    ucol_setAttribute(c, k_ucol_case_level, k_ucol_off, &status);
    ucol_setAttribute(c, k_ucol_alternate, k_ucol_non_ignorable, &status);
    ucol_setAttribute(c, k_ucol_numeric, k_ucol_off, &status);
    ucol_setAttribute(c, k_ucol_normalization, k_ucol_on, &status);
    if (g_n_colls < 8) {
        std::snprintf(g_colls[g_n_colls].tag, sizeof g_colls[g_n_colls].tag, "%s", tag);
        g_colls[g_n_colls++].c = c;
    }
    return c;
}
}

Value os_compare(Rt& rt, Str* a, Str* b, Value locales) noexcept {
    Str* tag = nullptr;
    if (locales.is(Kind::string))
        tag = locales.as<Str>();
    else if (locales.is(Kind::array) && locales.as<Arr>()->length && locales.as<Arr>()->items[0].is(Kind::string))
        tag = locales.as<Arr>()->items[0].as<Str>();
    char t[32] = "en-US";
    if (tag) {
        uint32_t n = 0;
        for (; n < tag->length && n < 31; n++)
            t[n] = static_cast<char>(tag->units[n] < 0x80 ? tag->units[n] : '?');
        t[n] = 0;
    }
    UCollator* c = collator(t);
    if (!c)
        return rt.fail(ErrorKind::range, "Incorrect locale information provided");
    int r = ucol_strcoll(c, reinterpret_cast<const uint16_t*>(a->units), static_cast<int32_t>(a->length),
                         reinterpret_cast<const uint16_t*>(b->units), static_cast<int32_t>(b->length));
    return Value::num(r < 0 ? -1 : r > 0 ? 1 : 0);
}

size_t os_zone_name(Rt&, double utc_ms, char16_t* out, size_t cap) noexcept {
    CFTimeZoneRef tz = CFTimeZoneCopyDefault();
    CFLocaleRef en = CFLocaleCreate(kCFAllocatorDefault, CFSTR("en_US"));
    if (!tz || !en) {
        if (tz)
            CFRelease(tz);
        if (en)
            CFRelease(en);
        return 0;
    }
    CFAbsoluteTime at = utc_ms / 1000 - kCFAbsoluteTimeIntervalSince1970;
    bool dst = CFTimeZoneIsDaylightSavingTime(tz, at);
    CFStringRef name;
    CFStringRef id = CFTimeZoneGetName(tz);
    static constexpr const char* k_utc[] = {"UTC",       "Etc/UTC",       "Etc/UCT", "UCT",
                                            "Universal", "Etc/Universal", "Zulu",    "Etc/Zulu"};
    bool utc = false;
    char idb[32];
    if (id && CFStringGetCString(id, idb, sizeof idb, kCFStringEncodingASCII))
        for (const char* u : k_utc)
            utc = utc || !std::strcmp(idb, u);
    if (const char* env = std::getenv("TZ"); env && !utc)
        for (const char* u : k_utc)
            utc = utc || !std::strcmp(env, u) || (env[0] == ':' && !std::strcmp(env + 1, u));
    if (utc)
        name = CFStringCreateWithCString(kCFAllocatorDefault, "Coordinated Universal Time", kCFStringEncodingASCII);
    else
        name = CFTimeZoneCopyLocalizedName(tz, dst ? kCFTimeZoneNameStyleDaylightSaving : kCFTimeZoneNameStyleStandard,
                                           en);
    size_t n = 0;
    if (name) {
        CFIndex len = CFStringGetLength(name);
        n = static_cast<size_t>(len) < cap ? static_cast<size_t>(len) : cap;
        CFStringGetCharacters(name, CFRangeMake(0, static_cast<CFIndex>(n)), reinterpret_cast<UniChar*>(out));
        CFRelease(name);
    }
    CFRelease(tz);
    CFRelease(en);
    return n;
}

Value os_format_date(Rt& rt, double t, Str* locale, const char* skeleton, int date_style, int time_style,
                     bool two_digit_hour) noexcept {
    CFLocaleRef loc = locale_of(locale);
    if (!loc)
        return rt.fail(ErrorKind::range, "Incorrect locale information provided");
    static constexpr CFDateFormatterStyle k_styles[] = {kCFDateFormatterNoStyle, kCFDateFormatterShortStyle,
                                                        kCFDateFormatterMediumStyle, kCFDateFormatterLongStyle,
                                                        kCFDateFormatterFullStyle};
    CFDateFormatterRef f;
    if (date_style || time_style) {
        f = CFDateFormatterCreate(kCFAllocatorDefault, loc, k_styles[date_style], k_styles[time_style]);
    } else {
        CFStringRef skel = CFStringCreateWithCString(kCFAllocatorDefault, skeleton, kCFStringEncodingASCII);
        CFStringRef pattern =
            skel ? CFDateFormatterCreateDateFormatFromTemplate(kCFAllocatorDefault, skel, 0, loc) : nullptr;
        if (skel)
            CFRelease(skel);
        if (!pattern) {
            CFRelease(loc);
            return rt.fail(ErrorKind::internal, "no date pattern for the skeleton");
        }
        CFMutableStringRef p = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, pattern);
        CFRelease(pattern);
        if (two_digit_hour && p) {
            CFIndex n = CFStringGetLength(p);
            bool quoted = false;
            for (CFIndex k = 0; k < n; k++) {
                UniChar c = CFStringGetCharacterAtIndex(p, k);
                if (c == '\'')
                    quoted = !quoted;
                if (quoted || !(c == 'h' || c == 'H' || c == 'k' || c == 'K'))
                    continue;
                bool single = (k == 0 || CFStringGetCharacterAtIndex(p, k - 1) != c)
                    && (k + 1 >= n || CFStringGetCharacterAtIndex(p, k + 1) != c);
                if (single) {
                    UniChar d[1] = {c};
                    CFStringRef one = CFStringCreateWithCharacters(kCFAllocatorDefault, d, 1);
                    CFStringInsert(p, k, one);
                    CFRelease(one);
                    n++, k++;
                }
            }
        }
        f = CFDateFormatterCreate(kCFAllocatorDefault, loc, kCFDateFormatterNoStyle, kCFDateFormatterNoStyle);
        if (f && p)
            CFDateFormatterSetFormat(f, p);
        if (p)
            CFRelease(p);
    }
    CFRelease(loc);
    if (!f)
        return rt.fail(ErrorKind::internal, "no date formatter");
    CFDateRef start = CFDateCreate(kCFAllocatorDefault, -8.64e12 - kCFAbsoluteTimeIntervalSince1970);
    if (start) {
        CFDateFormatterSetProperty(f, kCFDateFormatterGregorianStartDate, start);
        CFRelease(start);
    }
    CFStringRef s = CFDateFormatterCreateStringWithAbsoluteTime(kCFAllocatorDefault, f,
                                                                t / 1000 - kCFAbsoluteTimeIntervalSince1970);
    CFRelease(f);
    Value v = to_value(rt, s);
    if (v.is(Kind::string)) {
        Str* x = v.as<Str>();
        for (uint32_t k = 0; k < x->length; k++)
            if (x->units[k] == 0x202F)
                x->units[k] = ' ';
    }
    return v;
}

}

namespace rx::engine::vm::re {

char16_t os_upper_unit(char16_t c) noexcept {
    CFMutableStringRef m = CFStringCreateMutable(kCFAllocatorDefault, 0);
    if (!m)
        return c;
    UniChar u = c;
    CFStringAppendCharacters(m, &u, 1);
    CFStringUppercase(m, nullptr);
    char16_t out = c;
    if (CFStringGetLength(m) == 1)
        out = CFStringGetCharacterAtIndex(m, 0);
    CFRelease(m);
    return out;
}

}
