// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "web/profile.h"

#include <sqlite3.h>
#include <vector>

NSString* cookie_file(NSString* spec) {
    NSString* as = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"];
    NSDictionary* roots = @{
        @"zen": [as stringByAppendingPathComponent:@"zen/Profiles"],
        @"firefox": [as stringByAppendingPathComponent:@"Firefox/Profiles"]
    };
    NSString* dir = roots[spec.lowercaseString] ?: spec.stringByExpandingTildeInPath;
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* direct = [dir stringByAppendingPathComponent:@"cookies.sqlite"];
    if ([dir.lastPathComponent isEqualToString:@"cookies.sqlite"])
        return dir;
    if ([fm fileExistsAtPath:direct])
        return direct;
    NSString* best = nil;
    NSDate* newest = nil;
    for (NSString* p in [fm contentsOfDirectoryAtPath:dir error:nil]) {
        NSString* f = [[dir stringByAppendingPathComponent:p] stringByAppendingPathComponent:@"cookies.sqlite"];
        NSDate* m = [fm attributesOfItemAtPath:f error:nil].fileModificationDate;
        if (m && (!newest || [m compare:newest] == NSOrderedDescending))
            newest = m, best = f;
    }
    return best;
}

static bool unlz4(const uint8_t* in, size_t n, std::vector<uint8_t>& out, size_t want) {
    out.clear();
    out.reserve(want);
    size_t i = 0;
    auto more = [&](size_t& len) {
        uint8_t b;
        do {
            if (i >= n)
                return false;
            b = in[i++];
            len += b;
        } while (b == 255);
        return true;
    };
    while (i < n) {
        uint8_t token = in[i++];
        size_t lit = token >> 4;
        if (lit == 15 && !more(lit))
            return false;
        if (lit > n - i || lit > want - out.size())
            return false;
        out.insert(out.end(), in + i, in + i + lit);
        i += lit;
        if (i >= n)
            break;
        if (i + 2 > n)
            return false;
        size_t off = in[i] | (size_t(in[i + 1]) << 8);
        i += 2;
        size_t len = token & 15;
        if (len == 15 && !more(len))
            return false;
        len += 4;
        if (off == 0 || off > out.size() || len > want - out.size())
            return false;
        size_t from = out.size() - off;
        for (size_t k = 0; k < len; k++)
            out.push_back(out[from + k]);
    }
    return out.size() == want;
}

NSDictionary* read_session_store(NSString* profile) {
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* file = nil;
    for (NSString* rel in @[@"sessionstore-backups/recovery.jsonlz4", @"sessionstore.jsonlz4"]) {
        NSString* f = [profile stringByAppendingPathComponent:rel];
        if ([fm fileExistsAtPath:f]) {
            file = f;
            break;
        }
    }
    if (!file)
        return nil;
    NSString* tmp = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"rexui-session-%@", NSUUID.UUID.UUIDString]];
    [fm createDirectoryAtPath:tmp withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions: @0700} error:nil];
    NSString* copy = [tmp stringByAppendingPathComponent:@"s.jsonlz4"];
    NSData* raw = [fm copyItemAtPath:file toPath:copy error:nil] ? [NSData dataWithContentsOfFile:copy] : nil;
    [fm removeItemAtPath:tmp error:nil];
    const uint8_t* b = (const uint8_t*)raw.bytes;
    if (raw.length < 12 || memcmp(b, "mozLz40\0", 8) != 0)
        return nil;
    size_t want = b[8] | (size_t(b[9]) << 8) | (size_t(b[10]) << 16) | (size_t(b[11]) << 24);
    std::vector<uint8_t> json;
    if (want > (256u << 20) || !unlz4(b + 12, raw.length - 12, json, want))
        return nil;
    id store = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytesNoCopy:json.data()
                                                                            length:json.size()
                                                                      freeWhenDone:NO]
                                               options:0
                                                 error:nil];
    return [store isKindOfClass:NSDictionary.class] ? store : nil;
}

NSArray<NSDictionary*>* read_history(NSString* profile, NSString* like, int limit) {
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* db = [profile stringByAppendingPathComponent:@"places.sqlite"];
    if (![fm fileExistsAtPath:db])
        return @[];
    NSString* tmp = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"rexui-places-%@", NSUUID.UUID.UUIDString]];
    [fm createDirectoryAtPath:tmp withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions: @0700} error:nil];
    NSString* copy = [tmp stringByAppendingPathComponent:@"places.sqlite"];
    NSMutableArray* out = [NSMutableArray array];
    if ([fm copyItemAtPath:db toPath:copy error:nil]) {
        NSString* wal = [db stringByAppendingString:@"-wal"];
        if ([fm fileExistsAtPath:wal])
            [fm copyItemAtPath:wal toPath:[copy stringByAppendingString:@"-wal"] error:nil];
        sqlite3* sql = nullptr;
        if (sqlite3_open_v2(copy.fileSystemRepresentation, &sql, SQLITE_OPEN_READONLY, nullptr) == SQLITE_OK) {
            const char* q = "SELECT url, title FROM moz_places WHERE url LIKE ?1 AND title IS NOT NULL AND title != '' "
                            "ORDER BY last_visit_date DESC LIMIT ?2";
            sqlite3_stmt* st = nullptr;
            if (sqlite3_prepare_v2(sql, q, -1, &st, nullptr) == SQLITE_OK) {
                sqlite3_bind_text(st, 1, like.UTF8String, -1, SQLITE_TRANSIENT);
                sqlite3_bind_int(st, 2, limit);
                while (sqlite3_step(st) == SQLITE_ROW) {
                    const unsigned char *u = sqlite3_column_text(st, 0), *t = sqlite3_column_text(st, 1);
                    if (u && t)
                        [out addObject:@{@"url": @((const char*)u), @"title": @((const char*)t)}];
                }
                sqlite3_finalize(st);
            }
            sqlite3_close(sql);
        }
    }
    [fm removeItemAtPath:tmp error:nil];
    return out;
}

NSArray<NSHTTPCookie*>* read_session_cookies(NSString* profile) {
    NSDictionary* store = read_session_store(profile);
    NSMutableArray* out = [NSMutableArray array];
    for (NSDictionary* c in [store isKindOfClass:NSDictionary.class] ? store[@"cookies"] : nil) {
        if (![c isKindOfClass:NSDictionary.class] || ![c[@"name"] isKindOfClass:NSString.class])
            continue;
        NSDictionary* oa = c[@"originAttributes"];
        if ([oa isKindOfClass:NSDictionary.class]
            && ([oa[@"userContextId"] intValue] != 0 || [oa[@"partitionKey"] length] || [oa[@"firstPartyDomain"] length]
                || [oa[@"privateBrowsingId"] intValue] != 0)) {
            continue;
        }
        NSMutableDictionary* p = [@{
            NSHTTPCookieName: c[@"name"],
            NSHTTPCookieValue: c[@"value"] ?: @"",
            NSHTTPCookieDomain: c[@"host"] ?: @"",
            NSHTTPCookiePath: [c[@"path"] length] ? c[@"path"] : @"/",
        } mutableCopy];
        if ([c[@"secure"] boolValue])
            p[NSHTTPCookieSecure] = @"TRUE";
        if ([c[@"httponly"] boolValue])
            p[@"HttpOnly"] = @"TRUE";
        int same = [c[@"sameSite"] intValue];
        if (same == 1)
            p[NSHTTPCookieSameSitePolicy] = NSHTTPCookieSameSiteLax;
        if (same == 2)
            p[NSHTTPCookieSameSitePolicy] = NSHTTPCookieSameSiteStrict;
        if (NSHTTPCookie* k = [NSHTTPCookie cookieWithProperties:p])
            [out addObject:k];
    }
    return out;
}

NSArray<NSHTTPCookie*>* read_cookies(NSString* db) {
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* tmp = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"rexui-cookies-%@", NSUUID.UUID.UUIDString]];
    [fm createDirectoryAtPath:tmp withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions: @0700} error:nil];
    NSString* copy = [tmp stringByAppendingPathComponent:@"cookies.sqlite"];
    NSMutableArray* out = [NSMutableArray array];
    if ([fm copyItemAtPath:db toPath:copy error:nil]) {
        NSString* wal = [db stringByAppendingString:@"-wal"];
        if ([fm fileExistsAtPath:wal])
            [fm copyItemAtPath:wal toPath:[copy stringByAppendingString:@"-wal"] error:nil];
        sqlite3* sql = nullptr;
        if (sqlite3_open_v2(copy.fileSystemRepresentation, &sql, SQLITE_OPEN_READONLY, nullptr) == SQLITE_OK) {
            const char* q = "SELECT name, value, host, path, expiry, isSecure, isHttpOnly, sameSite FROM moz_cookies "
                            "WHERE originAttributes = ''";
            sqlite3_stmt* st = nullptr;
            if (sqlite3_prepare_v2(sql, q, -1, &st, nullptr) == SQLITE_OK) {
                double now = NSDate.date.timeIntervalSince1970;
                while (sqlite3_step(st) == SQLITE_ROW) {
                    auto text = [&](int i) {
                        const unsigned char* t = sqlite3_column_text(st, i);
                        return t ? @((const char*)t) : @"";
                    };
                    double expiry = (double)sqlite3_column_int64(st, 4);
                    if (expiry > 1e11)
                        expiry /= 1000;
                    if (expiry <= now)
                        continue;
                    NSMutableDictionary* p = [@{
                        NSHTTPCookieName: text(0),
                        NSHTTPCookieValue: text(1),
                        NSHTTPCookieDomain: text(2),
                        NSHTTPCookiePath: text(3).length ? text(3) : @"/",
                        NSHTTPCookieExpires: [NSDate dateWithTimeIntervalSince1970:expiry],
                    } mutableCopy];
                    if (sqlite3_column_int(st, 5))
                        p[NSHTTPCookieSecure] = @"TRUE";
                    if (sqlite3_column_int(st, 6))
                        p[@"HttpOnly"] = @"TRUE";
                    int same = sqlite3_column_int(st, 7);
                    if (same == 1)
                        p[NSHTTPCookieSameSitePolicy] = NSHTTPCookieSameSiteLax;
                    if (same == 2)
                        p[NSHTTPCookieSameSitePolicy] = NSHTTPCookieSameSiteStrict;
                    if (NSHTTPCookie* c = [NSHTTPCookie cookieWithProperties:p])
                        [out addObject:c];
                }
                sqlite3_finalize(st);
            }
            sqlite3_close(sql);
        }
    }
    [fm removeItemAtPath:tmp error:nil];
    return out;
}

static bool unsnappy(const uint8_t* in, size_t n, std::vector<uint8_t>& out) {
    size_t i = 0, want = 0;
    for (int shift = 0; i < n && shift < 35; shift += 7) {
        uint8_t b = in[i++];
        want |= size_t(b & 0x7f) << shift;
        if (!(b & 0x80))
            break;
    }
    out.clear();
    out.reserve(want);
    while (i < n) {
        uint8_t tag = in[i++];
        size_t len, off = 0;
        switch (tag & 3) {
        case 0: {
            len = (tag >> 2) + 1;
            if (len > 60) {
                size_t bytes = len - 60;
                if (i + bytes > n)
                    return false;
                len = 0;
                for (size_t k = 0; k < bytes; k++)
                    len |= size_t(in[i + k]) << (8 * k);
                len += 1;
                i += bytes;
            }
            if (i + len > n)
                return false;
            out.insert(out.end(), in + i, in + i + len);
            i += len;
            continue;
        }
        case 1:
            if (i >= n)
                return false;
            len = 4 + ((tag >> 2) & 7);
            off = (size_t(tag >> 5) << 8) | in[i++];
            break;
        case 2:
            if (i + 2 > n)
                return false;
            len = (tag >> 2) + 1;
            off = in[i] | (size_t(in[i + 1]) << 8);
            i += 2;
            break;
        default:
            if (i + 4 > n)
                return false;
            len = (tag >> 2) + 1;
            off = in[i] | (size_t(in[i + 1]) << 8) | (size_t(in[i + 2]) << 16) | (size_t(in[i + 3]) << 24);
            i += 4;
        }
        if (off == 0 || off > out.size())
            return false;
        size_t from = out.size() - off;
        for (size_t k = 0; k < len; k++)
            out.push_back(out[from + k]);
    }
    return out.size() == want;
}

NSURL* origin_url(NSString* site) {
    NSURL* u = [NSURL URLWithString:[site containsString:@"://"] ? site : [@"https://" stringByAppendingString:site]];
    if (!u.host)
        return nil;
    NSString* s = [NSString
        stringWithFormat:@"%@://%@%@/", u.scheme, u.host, u.port ? [NSString stringWithFormat:@":%@", u.port] : @""];
    return [NSURL URLWithString:s];
}

NSDictionary<NSString*, NSString*>* read_storage(NSString* profile, NSURL* origin) {
    NSString* dir = [NSString stringWithFormat:@"%@+++%@%@", origin.scheme, origin.host,
                                               origin.port ? [NSString stringWithFormat:@"+%@", origin.port] : @""];
    NSString* db = [[[profile stringByAppendingPathComponent:@"storage/default"] stringByAppendingPathComponent:dir]
        stringByAppendingPathComponent:@"ls/data.sqlite"];
    NSFileManager* fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:db])
        return nil;
    NSString* tmp = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"rexui-storage-%@", NSUUID.UUID.UUIDString]];
    [fm createDirectoryAtPath:tmp withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions: @0700} error:nil];
    NSString* copy = [tmp stringByAppendingPathComponent:@"data.sqlite"];
    NSMutableDictionary* items = [NSMutableDictionary dictionary];
    if ([fm copyItemAtPath:db toPath:copy error:nil]) {
        NSString* wal = [db stringByAppendingString:@"-wal"];
        if ([fm fileExistsAtPath:wal])
            [fm copyItemAtPath:wal toPath:[copy stringByAppendingString:@"-wal"] error:nil];
        sqlite3* sql = nullptr;
        if (sqlite3_open_v2(copy.fileSystemRepresentation, &sql, SQLITE_OPEN_READONLY, nullptr) == SQLITE_OK) {
            sqlite3_stmt* st = nullptr;
            if (sqlite3_prepare_v2(sql, "SELECT key, conversion_type, compression_type, value FROM data", -1, &st,
                                   nullptr)
                == SQLITE_OK) {
                std::vector<uint8_t> plain;
                while (sqlite3_step(st) == SQLITE_ROW) {
                    const unsigned char* k = sqlite3_column_text(st, 0);
                    const uint8_t* v = (const uint8_t*)sqlite3_column_blob(st, 3);
                    size_t len = size_t(sqlite3_column_bytes(st, 3));
                    if (!k)
                        continue;
                    if (sqlite3_column_int(st, 2) == 1) {
                        if (!unsnappy(v, len, plain))
                            continue;
                        v = plain.data(), len = plain.size();
                    }
                    if (len > 512 * 1024)
                        continue;
                    NSString* value = sqlite3_column_int(st, 1) == 1
                        ? [[NSString alloc] initWithBytes:v length:len encoding:NSUTF8StringEncoding]
                        : [[NSString alloc] initWithBytes:v length:len encoding:NSUTF16LittleEndianStringEncoding];
                    if (value)
                        items[@((const char*)k)] = value;
                }
                sqlite3_finalize(st);
            }
            sqlite3_close(sql);
        }
    }
    [fm removeItemAtPath:tmp error:nil];
    return items;
}
