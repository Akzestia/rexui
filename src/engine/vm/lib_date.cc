// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include <sys/time.h>

#include <cmath>
#include <cstring>
#include <ctime>

#include "engine/vm/gc.h"
#include "engine/vm/lib.h"

namespace rx::engine::vm {

struct DateObj {
    Cell h;
    double t;
};

namespace lib {
namespace {

using sv16 = std::u16string_view;

constexpr double k_day = 86400000.0, k_hour = 3600000.0, k_minute = 60000.0, k_second = 1000.0;

double day(double t) {
    return std::floor(t / k_day);
}
double time_in_day(double t) {
    double r = std::fmod(t, k_day);
    return r < 0 ? r + k_day : r;
}
double day_from_year(double y) {
    return 365 * (y - 1970) + std::floor((y - 1969) / 4) - std::floor((y - 1901) / 100) + std::floor((y - 1601) / 400);
}
double time_from_year(double y) {
    return k_day * day_from_year(y);
}
bool leap(double y) {
    return std::fmod(y, 4) == 0 && (std::fmod(y, 100) != 0 || std::fmod(y, 400) == 0);
}
double year_from_time(double t) {
    double y = std::floor(t / (k_day * 365.2425)) + 1970;
    while (time_from_year(y) > t)
        y--;
    while (time_from_year(y + 1) <= t)
        y++;
    return y;
}
int month_from_time(double t, double y, int& date) {
    int d = static_cast<int>(day(t) - day_from_year(y));
    int l = leap(y) ? 1 : 0;
    static constexpr int k_starts[] = {0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365};
    for (int m = 0; m < 12; m++) {
        int start = k_starts[m] + (m >= 2 ? l : 0), end = k_starts[m + 1] + (m + 1 >= 2 ? l : 0);
        if (d < end) {
            date = d - start + 1;
            return m;
        }
    }
    date = 31;
    return 11;
}
int week_day(double t) {
    int w = static_cast<int>(std::fmod(day(t) + 4, 7));
    return w < 0 ? w + 7 : w;
}
double make_time(double h, double m, double s, double ms) {
    if (!std::isfinite(h) || !std::isfinite(m) || !std::isfinite(s) || !std::isfinite(ms))
        return NAN;
    return std::trunc(h) * k_hour + std::trunc(m) * k_minute + std::trunc(s) * k_second + std::trunc(ms);
}
double make_day(double year, double month, double date) {
    if (!std::isfinite(year) || !std::isfinite(month) || !std::isfinite(date))
        return NAN;
    double y = std::trunc(year), m = std::trunc(month), dt = std::trunc(date);
    double ym = y + std::floor(m / 12);
    if (std::fabs(ym) > 400000)
        return NAN;
    int mn = static_cast<int>(std::fmod(m, 12));
    if (mn < 0)
        mn += 12;
    static constexpr int k_starts[] = {0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334};
    double d = day_from_year(ym) + k_starts[mn] + (mn >= 2 && leap(ym) ? 1 : 0);
    return d + dt - 1;
}
double make_date(double d, double t) {
    if (!std::isfinite(d) || !std::isfinite(t))
        return NAN;
    double tv = d * k_day + t;
    return std::isfinite(tv) ? tv : NAN;
}
double time_clip(double t) {
    if (!std::isfinite(t) || std::fabs(t) > 8.64e15)
        return NAN;
    return std::trunc(t) + 0.0;
}

double offset_at(double utc) {
    if (!std::isfinite(utc))
        return 0;
    time_t s = static_cast<time_t>(std::floor(utc / 1000));
    struct tm tm;
    if (!localtime_r(&s, &tm))
        return 0;
    return static_cast<double>(tm.tm_gmtoff) * 1000;
}
double local_time(double t) {
    return t + offset_at(t);
}
double utc_of(double local) {
    if (!std::isfinite(local))
        return NAN;
    double o = offset_at(local - offset_at(local));
    double candidates[4] = {o, offset_at(local - o), offset_at(local - o - 3 * k_hour),
                            offset_at(local - o + 3 * k_hour)};
    double best = NAN;
    for (double c : candidates)
        if (offset_at(local - c) == c && (best != best || c > best))
            best = c;
    if (best != best)
        best = offset_at(local - o - 3 * k_hour);
    return local - best;
}

DateObj* as_date(Value v) {
    return v.is(Kind::date) ? v.as<DateObj>() : nullptr;
}
Value make(Rt& rt, double t) {
    DateObj* d = rt.arena.make<DateObj>();
    if (!d)
        return rt.fail(ErrorKind::internal, "out of memory");
    d->h = Cell{0, Kind::date, 0, 0};
    d->t = time_clip(t);
    return Value::cell(&d->h);
}
double now_ms() {
    struct timeval tv;
    gettimeofday(&tv, nullptr);
    return std::floor(static_cast<double>(tv.tv_sec) * 1000 + static_cast<double>(tv.tv_usec) / 1000);
}

struct Out {
    char16_t b[160];
    size_t n = 0;
    void put(char c) {
        if (n < sizeof b / sizeof *b)
            b[n++] = static_cast<char16_t>(c);
    }
    void put(const char* s) {
        while (*s)
            put(*s++);
    }
    void put(sv16 s) {
        for (char16_t c : s)
            if (n < sizeof b / sizeof *b)
                b[n++] = c;
    }
    void num(long v, int width) {
        char t[24];
        int k = std::snprintf(t, sizeof t, "%0*ld", width, v);
        for (int q = 0; q < k; q++)
            put(t[q]);
    }
    void year(double y) {
        if (y < 0)
            put('-');
        num(static_cast<long>(std::fabs(y)), 4);
    }
};
constexpr const char* k_days[] = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
constexpr const char* k_months[] = {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};

struct Parts {
    double y;
    int mon, date, wd, h, m, s, ms;
};
Parts parts(double t) {
    Parts p;
    p.y = year_from_time(t);
    p.mon = month_from_time(t, p.y, p.date);
    p.wd = week_day(t);
    double in = time_in_day(t);
    p.h = static_cast<int>(in / k_hour);
    p.m = static_cast<int>(std::fmod(in / k_minute, 60));
    p.s = static_cast<int>(std::fmod(in / k_second, 60));
    p.ms = static_cast<int>(std::fmod(in, 1000));
    return p;
}
void date_part(Out& o, const Parts& p) {
    o.put(k_days[p.wd]);
    o.put(' ');
    o.put(k_months[p.mon]);
    o.put(' ');
    o.num(p.date, 2);
    o.put(' ');
    o.year(p.y);
}
void time_part(Rt& rt, Out& o, double t, const Parts& p) {
    o.num(p.h, 2), o.put(':'), o.num(p.m, 2), o.put(':'), o.num(p.s, 2);
    double off = offset_at(t) / k_minute;
    o.put(" GMT");
    o.put(off < 0 ? '-' : '+');
    long a = static_cast<long>(std::fabs(off));
    o.num(a / 60, 2), o.num(a % 60, 2);
    char16_t name[96];
    size_t n = os_zone_name(rt, t, name, 96);
    if (n) {
        o.put(" (");
        o.put(sv16(name, n));
        o.put(')');
    }
}
Value text(Rt& rt, const Out& o) {
    Str* s = rt.str({o.b, o.n});
    return s ? val(s) : Value::undefined();
}
Value invalid(Rt& rt) {
    return val(rt.str_ascii("Invalid Date"));
}

#define THIS_DATE(method)       \
    Rt& rt = vm.rt;             \
    DateObj* D = as_date(self); \
    if (!D)                     \
    return rt.fail(ErrorKind::type, "Date.prototype.%s called on a value that isn't a Date", method)

Value d_tostring(Vm& vm, Value self, const Value*, uint32_t) {
    THIS_DATE("toString");
    if (D->t != D->t)
        return invalid(rt);
    double lt = local_time(D->t);
    Parts p = parts(lt);
    Out o;
    date_part(o, p);
    o.put(' ');
    time_part(rt, o, D->t, p);
    return text(rt, o);
}
Value d_todatestring(Vm& vm, Value self, const Value*, uint32_t) {
    THIS_DATE("toDateString");
    if (D->t != D->t)
        return invalid(rt);
    Out o;
    date_part(o, parts(local_time(D->t)));
    return text(rt, o);
}
Value d_totimestring(Vm& vm, Value self, const Value*, uint32_t) {
    THIS_DATE("toTimeString");
    if (D->t != D->t)
        return invalid(rt);
    Out o;
    time_part(rt, o, D->t, parts(local_time(D->t)));
    return text(rt, o);
}
Value d_toutcstring(Vm& vm, Value self, const Value*, uint32_t) {
    THIS_DATE("toUTCString");
    if (D->t != D->t)
        return invalid(rt);
    Parts p = parts(D->t);
    Out o;
    o.put(k_days[p.wd]), o.put(", "), o.num(p.date, 2), o.put(' '), o.put(k_months[p.mon]), o.put(' ');
    o.year(p.y);
    o.put(' '), o.num(p.h, 2), o.put(':'), o.num(p.m, 2), o.put(':'), o.num(p.s, 2), o.put(" GMT");
    return text(rt, o);
}
Value d_toisostring(Vm& vm, Value self, const Value*, uint32_t) {
    THIS_DATE("toISOString");
    if (D->t != D->t)
        return rt.fail(ErrorKind::range, "Invalid Date");
    Parts p = parts(D->t);
    Out o;
    if (p.y >= 0 && p.y <= 9999)
        o.num(static_cast<long>(p.y), 4);
    else {
        o.put(p.y < 0 ? '-' : '+');
        o.num(static_cast<long>(std::fabs(p.y)), 6);
    }
    o.put('-'), o.num(p.mon + 1, 2), o.put('-'), o.num(p.date, 2), o.put('T'), o.num(p.h, 2), o.put(':'), o.num(p.m, 2),
        o.put(':');
    o.num(p.s, 2), o.put('.'), o.num(p.ms, 3), o.put('Z');
    return text(rt, o);
}
Value d_tojson(Vm& vm, Value self, const Value*, uint32_t) {
    DateObj* D = as_date(self);
    if (D && D->t != D->t)
        return Value::null();
    if (!D)
        return Value::null();
    return d_toisostring(vm, self, nullptr, 0);
}
Value d_valueof(Vm& vm, Value self, const Value*, uint32_t) {
    THIS_DATE("valueOf");
    return Value::num(D->t);
}

enum class F : uint8_t { year, month, date, day, hours, minutes, seconds, ms };
template<F f, bool utc>
Value d_get(Vm& vm, Value self, const Value*, uint32_t) {
    THIS_DATE("get");
    if (D->t != D->t)
        return Value::num(NAN);
    double t = utc ? D->t : local_time(D->t);
    Parts p = parts(t);
    switch (f) {
    case F::year:
        return Value::num(p.y);
    case F::month:
        return Value::num(p.mon);
    case F::date:
        return Value::num(p.date);
    case F::day:
        return Value::num(p.wd);
    case F::hours:
        return Value::num(p.h);
    case F::minutes:
        return Value::num(p.m);
    case F::seconds:
        return Value::num(p.s);
    case F::ms:
        return Value::num(p.ms);
    }
    return Value::num(NAN);
}
Value d_gettimezoneoffset(Vm& vm, Value self, const Value*, uint32_t) {
    THIS_DATE("getTimezoneOffset");
    if (D->t != D->t)
        return Value::num(NAN);
    return Value::num(-std::trunc(offset_at(D->t) / k_minute) + 0.0);
}
Value d_settime(Vm& vm, Value self, const Value* args, uint32_t argc) {
    THIS_DATE("setTime");
    double t = to_number(rt, arg(args, argc, 0));
    if (rt.failed)
        return Value::undefined();
    D->t = time_clip(t);
    return Value::num(D->t);
}
template<F f, bool utc>
Value d_set(Vm& vm, Value self, const Value* args, uint32_t argc) {
    THIS_DATE("set");
    double a[4];
    uint32_t n = argc < 4 ? argc : 4;
    for (uint32_t k = 0; k < n; k++) {
        a[k] = to_number(rt, args[k]);
        if (rt.failed)
            return Value::undefined();
    }
    double t = D->t;
    if (t != t) {
        if (f != F::year)
            return Value::num(NAN);
        t = 0;
    } else if (!utc)
        t = local_time(t);
    Parts p = parts(t);
    double y = p.y, mo = p.mon, dt = p.date, h = p.h, mi = p.m, s = p.s, ms = p.ms;
    auto at = [&](uint32_t k, double def) { return k < n ? a[k] : def; };
    if (!n)
        a[0] = NAN, n = 1;
    switch (f) {
    case F::year:
        y = a[0], mo = at(1, mo), dt = at(2, dt);
        break;
    case F::month:
        mo = a[0], dt = at(1, dt);
        break;
    case F::date:
        dt = a[0];
        break;
    case F::hours:
        h = a[0], mi = at(1, mi), s = at(2, s), ms = at(3, ms);
        break;
    case F::minutes:
        mi = a[0], s = at(1, s), ms = at(2, ms);
        break;
    case F::seconds:
        s = a[0], ms = at(1, ms);
        break;
    case F::ms:
        ms = a[0];
        break;
    default:
        break;
    }
    double nd = make_date(make_day(y, mo, dt), make_time(h, mi, s, ms));
    D->t = time_clip(utc ? nd : utc_of(nd));
    return Value::num(D->t);
}

struct Scan {
    sv16 s;
    size_t i = 0;
    bool digits(int n, long& v) {
        v = 0;
        for (int k = 0; k < n; k++) {
            if (i >= s.size() || s[i] < '0' || s[i] > '9')
                return false;
            v = v * 10 + (s[i++] - '0');
        }
        return true;
    }
    bool eat(char16_t c) {
        if (i < s.size() && s[i] == c)
            return ++i, true;
        return false;
    }
};
double parse_iso(sv16 s) {
    Scan c{s};
    long y = 0, mo = 1, d = 1, h = 0, mi = 0, sec = 0, ms = 0;
    bool sign = false, neg = false;
    if (c.eat('+'))
        sign = true;
    else if (c.eat('-'))
        sign = neg = true;
    if (sign) {
        if (!c.digits(6, y))
            return NAN;
        if (neg && y == 0)
            return NAN;
        if (neg)
            y = -y;
    } else if (!c.digits(4, y))
        return NAN;
    bool date_only = true;
    if (c.eat('-')) {
        if (!c.digits(2, mo))
            return NAN;
        if (c.eat('-') && !c.digits(2, d))
            return NAN;
    }
    bool has_offset = false;
    double offset = 0;
    if (c.i < s.size() && (s[c.i] == 'T' || s[c.i] == 't')) {
        c.i++;
        date_only = false;
        if (!c.digits(2, h) || !c.eat(':') || !c.digits(2, mi))
            return NAN;
        if (c.eat(':')) {
            if (!c.digits(2, sec))
                return NAN;
            if (c.eat('.') || c.eat(',')) {
                double frac = 0, scale = 100;
                size_t start = c.i;
                while (c.i < s.size() && s[c.i] >= '0' && s[c.i] <= '9') {
                    frac += (s[c.i] - '0') * scale;
                    scale /= 10;
                    c.i++;
                }
                if (c.i == start)
                    return NAN;
                ms = static_cast<long>(std::floor(frac + 1e-9));
            }
        }
        if (c.eat('Z') || c.eat('z'))
            has_offset = true;
        else if (c.i < s.size() && (s[c.i] == '+' || s[c.i] == '-')) {
            bool on = s[c.i++] == '-';
            long oh, om;
            if (!c.digits(2, oh))
                return NAN;
            c.eat(':');
            if (!c.digits(2, om))
                return NAN;
            offset = (oh * 60 + om) * k_minute * (on ? -1 : 1);
            has_offset = true;
        }
    } else if (c.i < s.size() && (s[c.i] == 'Z' || s[c.i] == 'z')) {
        c.i++;
        has_offset = true;
    }
    if (c.i != s.size())
        return NAN;
    if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 24 || mi > 59 || sec > 59)
        return NAN;
    if (h == 24 && (mi || sec || ms))
        return NAN;
    static constexpr int k_len[] = {31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    if (d > k_len[mo - 1] || (mo == 2 && d == 29 && !leap(static_cast<double>(y))))
        return NAN;
    double t = make_date(
        make_day(static_cast<double>(y), static_cast<double>(mo - 1), static_cast<double>(d)),
        make_time(static_cast<double>(h), static_cast<double>(mi), static_cast<double>(sec), static_cast<double>(ms)));
    if (has_offset)
        return t - offset;
    return date_only ? t : utc_of(t);
}
int month_name(sv16 w) {
    if (w.size() < 3)
        return -1;
    static constexpr const char* k_full[] = {"january", "february", "march",     "april",   "may",      "june",
                                             "july",    "august",   "september", "october", "november", "december"};
    for (int m = 0; m < 12; m++) {
        const char* f = k_full[m];
        bool ok = true;
        for (size_t k = 0; k < w.size() && ok; k++)
            ok = f[k] && (w[k] | 0x20) == f[k];
        if (ok && w.size() <= std::strlen(f))
            return m;
    }
    return -1;
}
double parse_legacy(sv16 s) {
    long y = -1, mo = -1, d = -1, h = 0, mi = 0, sec = 0;
    bool have_time = false, has_offset = false, pm = false, am = false;
    double offset = 0;
    size_t i = 0;
    long nums[3];
    int n_nums = 0;
    auto skip = [&] {
        while (i < s.size() && (s[i] == ' ' || s[i] == ',' || s[i] == '\t'))
            i++;
    };
    for (;;) {
        skip();
        if (i >= s.size())
            break;
        char16_t c = s[i];
        if (c == '(') {
            while (i < s.size() && s[i] != ')')
                i++;
            i++;
            continue;
        }
        if ((c | 0x20) >= 'a' && (c | 0x20) <= 'z') {
            size_t b = i;
            while (i < s.size() && (((s[i] | 0x20) >= 'a' && (s[i] | 0x20) <= 'z') || s[i] == '.'))
                i++;
            sv16 w = s.substr(b, i - b);
            auto is = [&](const char* x) {
                if (w.size() != std::strlen(x))
                    return false;
                for (size_t k = 0; k < w.size(); k++)
                    if ((w[k] | 0x20) != x[k])
                        return false;
                return true;
            };
            if (is("gmt") || is("utc") || is("ut") || is("z")) {
                has_offset = true;
                if (i < s.size() && (s[i] == '+' || s[i] == '-')) {
                    bool on = s[i++] == '-';
                    long v = 0;
                    int digits = 0;
                    while (i < s.size() && s[i] >= '0' && s[i] <= '9' && digits < 4)
                        v = v * 10 + (s[i++] - '0'), digits++;
                    if (i < s.size() && s[i] == ':') {
                        i++;
                        long mm = 0;
                        while (i < s.size() && s[i] >= '0' && s[i] <= '9')
                            mm = mm * 10 + (s[i++] - '0');
                        v = v * 100 + mm;
                    } else if (digits <= 2)
                        v *= 100;
                    offset =
                        (static_cast<double>(v / 100) * 60 + static_cast<double>(v % 100)) * k_minute * (on ? -1 : 1);
                }
                continue;
            }
            if (is("am") || is("a.m.")) {
                am = true;
                continue;
            }
            if (is("pm") || is("p.m.")) {
                pm = true;
                continue;
            }
            int m = month_name(w);
            if (m >= 0) {
                mo = m;
                continue;
            }
            static constexpr const char* k_wd[] = {"sun", "mon", "tue", "wed", "thu", "fri", "sat"};
            bool weekday = false;
            for (const char* x : k_wd)
                if (w.size() >= 3 && (w[0] | 0x20) == x[0] && (w[1] | 0x20) == x[1] && (w[2] | 0x20) == x[2])
                    weekday = true;
            if (weekday)
                continue;
            return NAN;
        }
        if (c == '+' || c == '-') {
            if (have_time || n_nums) {
                bool on = c == '-';
                i++;
                long v = 0;
                while (i < s.size() && s[i] >= '0' && s[i] <= '9')
                    v = v * 10 + (s[i++] - '0');
                offset = (static_cast<double>(v / 100) * 60 + static_cast<double>(v % 100)) * k_minute * (on ? -1 : 1);
                has_offset = true;
                continue;
            }
            return NAN;
        }
        if (c >= '0' && c <= '9') {
            long v = 0;
            size_t b = i;
            while (i < s.size() && s[i] >= '0' && s[i] <= '9')
                v = v * 10 + (s[i++] - '0');
            if (i < s.size() && s[i] == ':') {
                h = v;
                i++;
                long t = 0;
                while (i < s.size() && s[i] >= '0' && s[i] <= '9')
                    t = t * 10 + (s[i++] - '0');
                mi = t;
                if (i < s.size() && s[i] == ':') {
                    i++;
                    t = 0;
                    while (i < s.size() && s[i] >= '0' && s[i] <= '9')
                        t = t * 10 + (s[i++] - '0');
                    sec = t;
                }
                have_time = true;
                continue;
            }
            if (i < s.size() && s[i] == '/') {
                long parts3[3] = {v, -1, -1};
                int k = 1;
                while (i < s.size() && s[i] == '/' && k < 3) {
                    i++;
                    long t = 0;
                    while (i < s.size() && s[i] >= '0' && s[i] <= '9')
                        t = t * 10 + (s[i++] - '0');
                    parts3[k++] = t;
                }
                if (i - b > 4 && parts3[0] > 31)
                    y = parts3[0], mo = parts3[1] - 1, d = parts3[2];
                else
                    mo = parts3[0] - 1, d = parts3[1], y = parts3[2];
                continue;
            }
            if (n_nums < 3)
                nums[n_nums++] = v;
            continue;
        }
        return NAN;
    }
    for (int k = 0; k < n_nums; k++) {
        long v = nums[k];
        if (d < 0 && v >= 1 && v <= 31 && !(y < 0 && k == n_nums - 1 && n_nums > 1 && mo >= 0 && d >= 0))
            d = v;
        else if (y < 0)
            y = v;
        else
            return NAN;
    }
    if (mo < 0 || d < 0 || y < 0)
        return NAN;
    if (y < 50)
        y += 2000;
    else if (y < 100)
        y += 1900;
    if (pm && h < 12)
        h += 12;
    if (am && h == 12)
        h = 0;
    double t = make_date(make_day(static_cast<double>(y), static_cast<double>(mo), static_cast<double>(d)),
                         make_time(static_cast<double>(h), static_cast<double>(mi), static_cast<double>(sec), 0));
    (void)have_time;
    return has_offset ? t - offset : utc_of(t);
}
double parse(sv16 s) {
    double t = parse_iso(s);
    if (t == t)
        return time_clip(t);
    return time_clip(parse_legacy(s));
}

Value g_date_parse(Vm& vm, Value, const Value* args, uint32_t argc) {
    Str* s = to_string(vm.rt, arg(args, argc, 0));
    return s ? Value::num(parse(s->view())) : Value::undefined();
}
Value g_date_now(Vm& vm, Value, const Value*, uint32_t) {
    return Value::num(vm.rt.now());
}
Value g_date_utc(Vm& vm, Value, const Value* args, uint32_t argc) {
    Rt& rt = vm.rt;
    double a[7] = {NAN, 0, 1, 0, 0, 0, 0};
    for (uint32_t k = 0; k < argc && k < 7; k++) {
        a[k] = to_number(rt, args[k]);
        if (rt.failed)
            return Value::undefined();
    }
    if (a[0] == a[0]) {
        double yi = std::trunc(a[0]);
        if (yi >= 0 && yi <= 99)
            a[0] = 1900 + yi;
    }
    return Value::num(time_clip(make_date(make_day(a[0], a[1], a[2]), make_time(a[3], a[4], a[5], a[6]))));
}
Value g_date_call(Vm& vm, Value, const Value*, uint32_t) {
    Value d = make(vm.rt, vm.rt.now());
    return vm.rt.failed ? Value::undefined() : d_tostring(vm, d, nullptr, 0);
}
Value g_date_construct(Vm& vm, Value, const Value* args, uint32_t argc) {
    Rt& rt = vm.rt;
    if (argc == 0)
        return make(rt, rt.now());
    if (argc == 1) {
        Value v = args[0];
        if (DateObj* o = as_date(v))
            return make(rt, o->t);
        Value p = to_primitive(rt, v, Hint::none);
        if (rt.failed)
            return Value::undefined();
        if (p.is(Kind::string))
            return make(rt, parse(p.as<Str>()->view()));
        double t = to_number(rt, p);
        return rt.failed ? Value::undefined() : make(rt, t);
    }
    double a[7] = {NAN, 0, 1, 0, 0, 0, 0};
    for (uint32_t k = 0; k < argc && k < 7; k++) {
        a[k] = to_number(rt, args[k]);
        if (rt.failed)
            return Value::undefined();
    }
    if (a[0] == a[0]) {
        double yi = std::trunc(a[0]);
        if (yi >= 0 && yi <= 99)
            a[0] = 1900 + yi;
    }
    double local = make_date(make_day(a[0], a[1], a[2]), make_time(a[3], a[4], a[5], a[6]));
    return make(rt, utc_of(local));
}

enum class Need : uint8_t { date, time, any };
Value locale_format(Vm& vm, Value self, const Value* args, uint32_t argc, Need need, const char* method) {
    THIS_DATE(method);
    (void)method;
    if (D->t != D->t)
        return invalid(rt);
    Value locales = arg(args, argc, 0), options = arg(args, argc, 1);
    Str* locale = nullptr;
    if (locales.is(Kind::string))
        locale = locales.as<Str>();
    else if (locales.is(Kind::array) && locales.as<Arr>()->length && locales.as<Arr>()->items[0].is(Kind::string))
        locale = locales.as<Arr>()->items[0].as<Str>();
    auto opt = [&](const char* name) -> Str* {
        if (!options.is(Kind::object))
            return nullptr;
        Value v = get(rt, options, rt.atom(rt.str_ascii(name)));
        if (v.is_undefined() || rt.failed)
            return nullptr;
        return to_string(rt, v);
    };
    auto is = [](Str* s, const char* w) -> bool {
        if (!s)
            return false;
        size_t len = std::strlen(w);
        if (s->length != len)
            return false;
        for (size_t k = 0; k < len; k++)
            if (s->units[k] != static_cast<char16_t>(w[k]))
                return false;
        return true;
    };
    Str *date_style = opt("dateStyle"), *time_style = opt("timeStyle");
    if (rt.failed)
        return Value::undefined();
    if (need == Need::date && time_style)
        return rt.fail(ErrorKind::type, "timeStyle is not allowed in toLocaleDateString");
    if (need == Need::time && date_style)
        return rt.fail(ErrorKind::type, "dateStyle is not allowed in toLocaleTimeString");
    char skel[64];
    size_t n = 0;
    auto add = [&](const char* f) {
        while (*f && n < sizeof skel - 1)
            skel[n++] = *f++;
    };
    Str *weekday = opt("weekday"), *era = opt("era"), *year = opt("year"), *month = opt("month"), *dayo = opt("day");
    Str *hour = opt("hour"), *minute = opt("minute"), *second = opt("second"), *tzn = opt("timeZoneName");
    Str* hour12 = nullptr;
    Value h12 = options.is(Kind::object) ? get(rt, options, rt.atom(rt.str_ascii("hour12"))) : Value::undefined();
    if (rt.failed)
        return Value::undefined();
    if (!h12.is_undefined())
        hour12 = to_boolean(h12) ? rt.a_true : rt.a_false;
    Str* hc = opt("hourCycle");
    if (!date_style && !time_style) {
        bool any_date = weekday || year || month || dayo, any_time = hour || minute || second;
        bool need_defaults = true;
        if ((need == Need::date || need == Need::any) && any_date)
            need_defaults = false;
        if ((need == Need::time || need == Need::any) && any_time)
            need_defaults = false;
        if (need_defaults && (need == Need::date || need == Need::any))
            year = month = dayo = rt.str_ascii("numeric");
        if (need_defaults && (need == Need::time || need == Need::any))
            hour = minute = second = rt.str_ascii("numeric");
        if (weekday)
            add(is(weekday, "narrow") ? "EEEEE" : is(weekday, "short") ? "EEE" : "EEEE");
        if (era)
            add(is(era, "narrow") ? "GGGGG" : is(era, "short") ? "G" : "GGGG");
        if (year)
            add(is(year, "2-digit") ? "yy" : "y");
        if (month)
            add(is(month, "2-digit")       ? "MM"
                    : is(month, "numeric") ? "M"
                    : is(month, "narrow")  ? "MMMMM"
                    : is(month, "short")   ? "MMM"
                                           : "MMMM");
        if (dayo)
            add(is(dayo, "2-digit") ? "dd" : "d");
        if (hour) {
            const char* c = hour12 ? (hour12 == rt.a_true ? "h" : "H")
                : hc               ? (is(hc, "h11")       ? "K"
                                          : is(hc, "h12") ? "h"
                                          : is(hc, "h23") ? "H"
                                                          : "k")
                                   : "j";
            add(c);
            if (is(hour, "2-digit"))
                add(c);
        }
        if (minute)
            add(is(minute, "2-digit") ? "mm" : "m");
        if (second)
            add(is(second, "2-digit") ? "ss" : "s");
        if (tzn)
            add(is(tzn, "long") ? "zzzz" : "z");
    }
    skel[n] = 0;
    auto style = [&](Str* s) -> int {
        if (!s)
            return 0;
        return is(s, "full") ? 4 : is(s, "long") ? 3 : is(s, "medium") ? 2 : is(s, "short") ? 1 : -1;
    };
    int ds = style(date_style), ts = style(time_style);
    if (ds < 0 || ts < 0)
        return rt.fail(ErrorKind::range, "the dateStyle or timeStyle isn't one of full, long, medium, short");
    bool two_digit_hour = hour && is(hour, "2-digit");
    return os_format_date(rt, D->t, locale, skel, ds, ts, two_digit_hour);
}
Value d_tolocaledatestring(Vm& vm, Value self, const Value* args, uint32_t argc) {
    return locale_format(vm, self, args, argc, Need::date, "toLocaleDateString");
}
Value d_tolocaletimestring(Vm& vm, Value self, const Value* args, uint32_t argc) {
    return locale_format(vm, self, args, argc, Need::time, "toLocaleTimeString");
}
Value d_tolocalestring(Vm& vm, Value self, const Value* args, uint32_t argc) {
    return locale_format(vm, self, args, argc, Need::any, "toLocaleString");
}

}

double date_value(Value d) noexcept {
    return d.as<DateObj>()->t;
}

void install_date(Rt& rt) noexcept {
    struct M {
        const char* name;
        NativeFn fn;
        uint32_t len;
    };
    static constexpr M k[] = {{"toString", d_tostring, 0},
                              {"toDateString", d_todatestring, 0},
                              {"toTimeString", d_totimestring, 0},
                              {"toUTCString", d_toutcstring, 0},
                              {"toGMTString", d_toutcstring, 0},
                              {"toISOString", d_toisostring, 0},
                              {"toJSON", d_tojson, 1},
                              {"valueOf", d_valueof, 0},
                              {"getTime", d_valueof, 0},
                              {"getFullYear", d_get<F::year, false>, 0},
                              {"getMonth", d_get<F::month, false>, 0},
                              {"getDate", d_get<F::date, false>, 0},
                              {"getDay", d_get<F::day, false>, 0},
                              {"getHours", d_get<F::hours, false>, 0},
                              {"getMinutes", d_get<F::minutes, false>, 0},
                              {"getSeconds", d_get<F::seconds, false>, 0},
                              {"getMilliseconds", d_get<F::ms, false>, 0},
                              {"getUTCFullYear", d_get<F::year, true>, 0},
                              {"getUTCMonth", d_get<F::month, true>, 0},
                              {"getUTCDate", d_get<F::date, true>, 0},
                              {"getUTCDay", d_get<F::day, true>, 0},
                              {"getUTCHours", d_get<F::hours, true>, 0},
                              {"getUTCMinutes", d_get<F::minutes, true>, 0},
                              {"getUTCSeconds", d_get<F::seconds, true>, 0},
                              {"getUTCMilliseconds", d_get<F::ms, true>, 0},
                              {"getTimezoneOffset", d_gettimezoneoffset, 0},
                              {"setTime", d_settime, 1},
                              {"setFullYear", d_set<F::year, false>, 3},
                              {"setMonth", d_set<F::month, false>, 2},
                              {"setDate", d_set<F::date, false>, 1},
                              {"setHours", d_set<F::hours, false>, 4},
                              {"setMinutes", d_set<F::minutes, false>, 3},
                              {"setSeconds", d_set<F::seconds, false>, 2},
                              {"setMilliseconds", d_set<F::ms, false>, 1},
                              {"setUTCFullYear", d_set<F::year, true>, 3},
                              {"setUTCMonth", d_set<F::month, true>, 2},
                              {"setUTCDate", d_set<F::date, true>, 1},
                              {"setUTCHours", d_set<F::hours, true>, 4},
                              {"setUTCMinutes", d_set<F::minutes, true>, 3},
                              {"setUTCSeconds", d_set<F::seconds, true>, 2},
                              {"setUTCMilliseconds", d_set<F::ms, true>, 1},
                              {"toLocaleDateString", d_tolocaledatestring, 0},
                              {"toLocaleTimeString", d_tolocaletimestring, 0},
                              {"toLocaleString", d_tolocalestring, 0}};
    for (const M& m : k)
        def(rt, rt.date_proto, m.name, m.fn, m.len);
    rt.date_ctor = rt.native("Date", g_date_call, 7, g_date_construct);
    if (!rt.date_ctor)
        return;
    rt.put(rt.globals, rt.date_ctor->name, val(rt.date_ctor));
    Obj* statics = rt.object();
    if (!statics)
        return;
    def(rt, statics, "now", g_date_now, 0);
    def(rt, statics, "parse", g_date_parse, 1);
    def(rt, statics, "UTC", g_date_utc, 7);
    rt.date_ctor->props = statics;
}

size_t gc_date_size() noexcept {
    return sizeof(DateObj);
}

}
}

namespace rx::engine::vm {
double Rt::now() const noexcept {
    if (test_now >= 0)
        return test_now;
    if (clock)
        return clock(clock_ctx);
    return lib::now_ms();
}
}
