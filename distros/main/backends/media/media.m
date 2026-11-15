// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: GPL-3.0-only
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#include "rexui_backend.h"
#include "web/profile.h"

#import <AudioToolbox/AudioToolbox.h>
#include <CommonCrypto/CommonDigest.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/CoreAudio.h>
#include <dlfcn.h>
#include <stdio.h>
#include <sys/sysctl.h>

typedef void (*RegisterFn)(dispatch_queue_t);
typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*GetPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*GetPidFn)(dispatch_queue_t, void (^)(int));
typedef void (*GetClientFn)(dispatch_queue_t, void (^)(id));
typedef void (*GetClientsFn)(dispatch_queue_t, void (^)(CFArrayRef));
typedef CFStringRef (*ClientStringFn)(id);
typedef Boolean (*SendCommandFn)(int, CFDictionaryRef);
typedef void (*SetElapsedFn)(double);

static RegisterFn mr_register;
static GetInfoFn mr_info;
static GetPlayingFn mr_playing;
static GetPidFn mr_pid;
static GetClientFn mr_client;
static GetClientsFn mr_clients;
static ClientStringFn mr_client_parent, mr_client_bundle, mr_client_name;
static SendCommandFn mr_send;
static SetElapsedFn mr_seek;

enum { kPlay = 0, kPause = 1, kToggle = 2, kNext = 4, kPrevious = 5, kShuffle = 6, kRepeat = 7 };

static NSDictionary* g_info;
static bool g_playing;
static NSString *g_player = @"", *g_bundle = @"";
static NSString* g_artwork = @"";
static NSArray* g_players = @[];
static NSDictionary* g_sent = @{};
static bool g_ready;
static NSDictionary* g_saved;
static double g_empty_since;
static NSString* g_synced_for;
static double g_sync_until;
static double g_sync_shown;
static NSMutableDictionary<NSString*, NSString*>* g_covers;

static NSString* const kOsu = @"sh.ppy.osu.lazer";
static NSDictionary* g_osu;
static double g_osu_at;
static double g_mr_at;
static bool g_mr_held;
static NSMutableDictionary<NSString*, NSNumber*>* g_osu_stars;

static bool osu_shown(void) {
    return g_osu.count && (g_osu_at > g_mr_at || !g_info.count || !(g_playing || g_mr_held));
}

static NSArray<NSString*>* muted_bundles(void);

static NSString* g_lyrics_for;
static NSArray<NSDictionary*>* g_lyrics = @[];
static NSString* g_lyrics_state = @"";

static void err(NSString* s) {
    fprintf(stderr, "rexui-media: %s\n", s.UTF8String);
}

static NSString* cache_dir(NSString* name) {
    NSString* d = [NSHomeDirectory()
        stringByAppendingPathComponent:[@"Library/Caches/rexui" stringByAppendingPathComponent:name]];
    [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

static uint64_t fnv(NSData* d) {
    uint64_t h = 1469598103934665603ull;
    const uint8_t* p = (const uint8_t*)d.bytes;
    for (NSUInteger i = 0; i < d.length; i++)
        h = (h ^ p[i]) * 1099511628211ull;
    return h;
}

static NSString* save_artwork(NSData* data, NSString* mime) {
    if (!data.length)
        return @"";
    NSString* ext = [mime containsString:@"png"] ? @"png" : @"jpg";
    NSString* dir = cache_dir(@"media");
    NSString* path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%016llx.%@", fnv(data), ext]];
    NSFileManager* fm = NSFileManager.defaultManager;
    if ([fm fileExistsAtPath:path])
        return path;
    [data writeToFile:path atomically:YES];
    NSArray<NSURL*>* files = [fm contentsOfDirectoryAtURL:[NSURL fileURLWithPath:dir]
                               includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                                                  options:NSDirectoryEnumerationSkipsHiddenFiles
                                                    error:nil];
    files = [files filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSURL* u, NSDictionary*) {
                       return [@[@"jpg", @"png"] containsObject:u.pathExtension.lowercaseString];
                   }]];
    files = [files sortedArrayUsingComparator:^NSComparisonResult(NSURL* a, NSURL* b) {
        NSDate *da, *db;
        [a getResourceValue:&da forKey:NSURLContentModificationDateKey error:nil];
        [b getResourceValue:&db forKey:NSURLContentModificationDateKey error:nil];
        return [db compare:da];
    }];
    for (NSUInteger i = 50; i < files.count; i++)
        [fm removeItemAtURL:files[i] error:nil];
    return path;
}

static NSString* app_icon(NSString* bundle) {
    if (!bundle.length)
        return @"";
    NSString* path =
        [cache_dir(@"media/icons") stringByAppendingPathComponent:[bundle stringByAppendingPathExtension:@"png"]];
    if ([NSFileManager.defaultManager fileExistsAtPath:path])
        return path;
    NSURL* url = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:bundle];
    if (!url)
        return @"";
    NSImage* icon = [NSWorkspace.sharedWorkspace iconForFile:url.path];
    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                    pixelsWide:64
                                                                    pixelsHigh:64
                                                                 bitsPerSample:8
                                                               samplesPerPixel:4
                                                                      hasAlpha:YES
                                                                      isPlanar:NO
                                                                colorSpaceName:NSDeviceRGBColorSpace
                                                                   bytesPerRow:0
                                                                  bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [icon drawInRect:NSMakeRect(0, 0, 64, 64)];
    [NSGraphicsContext restoreGraphicsState];
    NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [png writeToFile:path atomically:YES] ? path : @"";
}

static double number(NSString* key) {
    id v = g_info[key];
    return [v isKindOfClass:NSNumber.class] ? [v doubleValue] : 0;
}
static NSString* string(NSString* key) {
    id v = g_info[key];
    return [v isKindOfClass:NSString.class]
        ? [v stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        : @"";
}

static NSString* plain(NSString* s) {
    return s.precomposedStringWithCompatibilityMapping ?: @"";
}

static double position_at(NSDictionary* info, NSDate* when, bool moving) {
    id e = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"], at = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    id r = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"], d = info[@"kMRMediaRemoteNowPlayingInfoDuration"];
    double elapsed = [e isKindOfClass:NSNumber.class] ? [e doubleValue] : 0;
    double rate = [r isKindOfClass:NSNumber.class] ? [r doubleValue] : 0;
    if (moving && [at isKindOfClass:NSDate.class])
        elapsed += [when timeIntervalSinceDate:at] * (rate > 0 ? rate : 1);
    double duration = [d isKindOfClass:NSNumber.class] ? [d doubleValue] : 0;
    if (duration > 0)
        elapsed = MIN(elapsed, duration);
    return MAX(0, elapsed);
}

static double position(void) {
    return position_at(g_info, NSDate.date, g_playing);
}

static NSString* track_key(NSDictionary* d) {
    id t = d[@"kMRMediaRemoteNowPlayingInfoTitle"], a = d[@"kMRMediaRemoteNowPlayingInfoArtist"];
    return [NSString stringWithFormat:@"%@\n%@", [t isKindOfClass:NSString.class] ? t : @"",
                                      [a isKindOfClass:NSString.class] ? a : @""];
}

static bool web_player(NSString* bundle) {
    NSString* b = bundle.lowercaseString ?: @"";
    for (NSString* web in @[
             @"zen", @"firefox", @"mozilla", @"chrome", @"chromium", @"safari", @"webkit", @"thebrowser", @"brave",
             @"edge", @"vivaldi", @"opera", @"superlogical.rex"
         ]) {
        if ([b containsString:web])
            return true;
    }
    return false;
}

static bool page_sound(NSDictionary* d, NSString* bundle) {
    id a = d[@"kMRMediaRemoteNowPlayingInfoArtist"], b = d[@"kMRMediaRemoteNowPlayingInfoAlbum"];
    return d.count && web_player(bundle) && !([a isKindOfClass:NSString.class] && [a length])
        && !([b isKindOfClass:NSString.class] && [b length]);
}

static NSDictionary* merged(NSDictionary* d, NSDictionary* was) {
    if (!d.count || !was.count || ![track_key(d) isEqualToString:track_key(was)])
        return d;
    NSMutableDictionary* m = [d mutableCopy];
    for (NSString* k in @[
             @"kMRMediaRemoteNowPlayingInfoDuration", @"kMRMediaRemoteNowPlayingInfoArtworkData",
             @"kMRMediaRemoteNowPlayingInfoArtworkMIMEType", @"kMRMediaRemoteNowPlayingInfoAlbum"
         ]) {
        if (!m[k] && was[k])
            m[k] = was[k];
    }
    if (!m[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] && was[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]) {
        id at = m[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
        NSDate* when = [at isKindOfClass:NSDate.class] ? at : NSDate.date;
        id r = was[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"];
        bool moving = [r isKindOfClass:NSNumber.class] && [r doubleValue] > 0;
        m[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] = @(position_at(was, when, moving));
        m[@"kMRMediaRemoteNowPlayingInfoTimestamp"] = when;
    }
    return m;
}

static NSNumber* yes(bool b) {
    return b ? @YES : @NO;
}
static NSNumber* tenths(double x) {
    return [NSDecimalNumber decimalNumberWithString:[NSString stringWithFormat:@"%.1f", x]];
}

static NSInteger lyric_line(void) {
    double t = position() + 0.1;
    NSInteger lo = 0, hi = (NSInteger)g_lyrics.count;
    while (lo < hi) {
        NSInteger mid = (lo + hi) / 2;
        if ([g_lyrics[mid][@"t"] doubleValue] <= t)
            lo = mid + 1;
        else
            hi = mid;
    }
    return lo - 1;
}

static void lyrics_for_track(void);
static void save_info(void);
static void end_sync(void);
static void refresh(void);

static bool g_own_repeat;
static NSString* g_own_repeat_bundle;
static CFAbsoluteTime g_looped_at;

static double osu_position(NSDictionary* o);

static int player_repeat(void) {
    return (int)MAX(0, number(@"kMRMediaRemoteNowPlayingInfoRepeatMode") - 1);
}

static void emit(void) {
    if (!g_ready)
        return;
    if (g_own_repeat && ![g_bundle isEqualToString:g_own_repeat_bundle])
        g_own_repeat = false;
    lyrics_for_track();
    bool active = g_info.count > 0;
    NSDictionary* state = @{
        @"active": yes(active),
        @"playing": yes(active && (g_playing || g_sync_until > 0 || CFAbsoluteTimeGetCurrent() < g_sync_shown)),
        @"title": string(@"kMRMediaRemoteNowPlayingInfoTitle"),
        @"artist": string(@"kMRMediaRemoteNowPlayingInfoArtist"),
        @"album": string(@"kMRMediaRemoteNowPlayingInfoAlbum"),
        @"duration": tenths(number(@"kMRMediaRemoteNowPlayingInfoDuration")),
        @"position": tenths(position()),
        @"artwork": active ? g_artwork : @"",
        @"player": active ? g_player : @"",
        @"bundle": active ? g_bundle : @"",
        @"playerIcon": active ? app_icon(g_bundle) : @"",
        @"players": g_players,
        @"shuffle": yes(number(@"kMRMediaRemoteNowPlayingInfoShuffleMode") > 1),
        @"repeat": @(g_own_repeat ? 1 : player_repeat()),
        @"lyrics": g_lyrics,
        @"lyricsState": g_lyrics_state,
        @"line": @(lyric_line()),
        @"seekable": yes(number(@"kMRMediaRemoteNowPlayingInfoDuration") > 0),
        @"difficulty": @"",
        @"rank": @"",
        @"rankSilver": @NO,
        @"stars": @0,
        @"best": NSNull.null,
        @"muted": muted_bundles(),
    };
    if (g_osu.count) {
        NSMutableDictionary* m = [state mutableCopy];
        if (![[g_players valueForKey:@"bundle"] containsObject:kOsu])
            m[@"players"] = [g_players arrayByAddingObject:g_osu[@"entry"]];
        if (osu_shown())
            [m addEntriesFromDictionary:@{
                @"active": @YES,
                @"playing": g_osu[@"anchor"][@"running"],
                @"title": g_osu[@"title"],
                @"artist": g_osu[@"artist"],
                @"album": g_osu[@"album"],
                @"duration": tenths([g_osu[@"length"] doubleValue]),
                @"position": tenths(osu_position(g_osu)),
                @"seekable": @NO,
                @"difficulty": g_osu[@"difficulty"],
                @"rank": g_osu[@"rank"],
                @"rankSilver": g_osu[@"rankSilver"],
                @"stars": [NSDecimalNumber
                    decimalNumberWithString:[NSString stringWithFormat:@"%.2f",
                                                                       [g_osu_stars [[g_osu [@"beatmap"] stringValue]]
                                                                           doubleValue]]],
                @"best": g_osu[@"best"],
                @"artwork": g_osu[@"artwork"],
                @"player": g_osu[@"entry"][@"name"],
                @"bundle": kOsu,
                @"playerIcon": g_osu[@"entry"][@"icon"],
                @"shuffle": @NO,
                @"repeat": @0,
                @"lyrics": @[],
                @"lyricsState": @"",
                @"line": @-1,
            }];
        state = m;
    }
    NSMutableDictionary* changed = [NSMutableDictionary dictionary];
    for (NSString* k in state) {
        if (![state[k] isEqual:g_sent[k]])
            changed[k] = state[k];
    }
    if (!changed.count)
        return;
    g_sent = state;
    NSData* json = [NSJSONSerialization dataWithJSONObject:changed options:NSJSONWritingSortedKeys error:nil];
    rexui_state_json((const char*)json.bytes, json.length);
}

static NSArray<NSDictionary*>* parse_lrc(NSString* lrc) {
    NSMutableArray<NSDictionary*>* out = [NSMutableArray array];
    double offset = 0;
    NSRegularExpression* stamp = [NSRegularExpression regularExpressionWithPattern:@"^\\[(\\d+):(\\d+(?:[.:]\\d+)?)\\]"
                                                                           options:0
                                                                             error:nil];
    for (NSString* raw in [lrc componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString* line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([line.lowercaseString hasPrefix:@"[offset:"]) {
            offset = [[line substringWithRange:NSMakeRange(8, line.length - 9)] doubleValue] / 1000;
            continue;
        }
        NSMutableArray<NSNumber*>* times = [NSMutableArray array];
        NSTextCheckingResult* m;
        while ((m = [stamp firstMatchInString:line options:0 range:NSMakeRange(0, line.length)])) {
            double sec =
                [[[line substringWithRange:[m rangeAtIndex:2]] stringByReplacingOccurrencesOfString:@":"
                                                                                         withString:@"."] doubleValue];
            [times addObject:@([[line substringWithRange:[m rangeAtIndex:1]] intValue] * 60 + sec)];
            line = [line substringFromIndex:m.range.length];
        }
        NSString* text = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        for (NSNumber* t in times)
            [out addObject:@{@"t": tenths(MAX(0, t.doubleValue - offset)), @"text": text}];
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
        return [a[@"t"] compare:b[@"t"]];
    }];
    return out;
}

static NSString* query(NSDictionary<NSString*, NSString*>* items) {
    NSURLComponents* c = [NSURLComponents new];
    NSMutableArray* q = [NSMutableArray array];
    for (NSString* k in items)
        [q addObject:[NSURLQueryItem queryItemWithName:k value:items[k]]];
    c.queryItems = q;
    return c.percentEncodedQuery;
}

static void get_json(NSString* url, void (^done)(id json)) {
    NSMutableURLRequest* r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    [r setValue:@"rexui (a Rex terminal panel; https://superlogical.com/rex)" forHTTPHeaderField:@"User-Agent"];
    r.timeoutInterval = 10;
    [[NSURLSession.sharedSession dataTaskWithRequest:r
                                   completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
                                       id json = data && ((NSHTTPURLResponse*)response).statusCode == 200
                                           ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]
                                           : nil;
                                       if (error)
                                           err([NSString stringWithFormat:@"lyrics: %@", error.localizedDescription]);
                                       dispatch_async(dispatch_get_main_queue(), ^{
                                           done(json);
                                       });
                                   }] resume];
}

static void set_lyrics(NSString* key, NSArray* lines) {
    if (![key isEqualToString:g_lyrics_for])
        return;
    g_lyrics = lines ?: @[];
    g_lyrics_state = g_lyrics.count ? @"found" : @"none";
    emit();
}

static void lyrics_for_track(void) {
    NSString *title = string(@"kMRMediaRemoteNowPlayingInfoTitle"),
             *artist = string(@"kMRMediaRemoteNowPlayingInfoArtist");
    NSString* album = string(@"kMRMediaRemoteNowPlayingInfoAlbum");
    double duration = number(@"kMRMediaRemoteNowPlayingInfoDuration");
    NSString* key =
        title.length ? [NSString stringWithFormat:@"%@\n%@\n%@\n%.0f", title, artist, album, duration] : @"";
    if ([key isEqualToString:g_lyrics_for ?: @""])
        return;
    g_lyrics_for = key;
    g_lyrics = @[];
    g_lyrics_state = key.length ? @"loading" : @"";
    if (!key.length)
        return;

    NSData* k = [key dataUsingEncoding:NSUTF8StringEncoding];
    NSString* file =
        [cache_dir(@"lyrics") stringByAppendingPathComponent:[NSString stringWithFormat:@"%016llx.lrc", fnv(k)]];
    NSDictionary* attrs = [NSFileManager.defaultManager attributesOfItemAtPath:file error:nil];
    if (attrs) {
        NSString* lrc = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil] ?: @"";
        if (lrc.length || -attrs.fileModificationDate.timeIntervalSinceNow < 86400) {
            g_lyrics = parse_lrc(lrc);
            g_lyrics_state = g_lyrics.count ? @"found" : @"none";
            return;
        }
    }
    void (^keep)(NSString*) = ^(NSString* lrc) {
        [lrc ?: @"" writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
        set_lyrics(key, parse_lrc(lrc ?: @""));
    };
    NSMutableDictionary* exact = [@{@"track_name": plain(title), @"artist_name": plain(artist)} mutableCopy];
    if (album.length)
        exact[@"album_name"] = plain(album);
    if (duration > 0)
        exact[@"duration"] = [NSString stringWithFormat:@"%.0f", duration];
    get_json([@"https://lrclib.net/api/get?" stringByAppendingString:query(exact)], ^(id got) {
        if (![key isEqualToString:g_lyrics_for])
            return;
        NSString* synced = [got isKindOfClass:NSDictionary.class] ? got[@"syncedLyrics"] : nil;
        if ([synced isKindOfClass:NSString.class] && synced.length)
            return keep(synced);
        NSDictionary* loose =
            artist.length ? @{@"track_name": plain(title), @"artist_name": plain(artist)} : @{@"q": plain(title)};
        get_json([@"https://lrclib.net/api/search?" stringByAppendingString:query(loose)], ^(id found) {
            if (![key isEqualToString:g_lyrics_for])
                return;
            for (NSDictionary* o in [found isKindOfClass:NSArray.class] ? found : @[]) {
                if (![o isKindOfClass:NSDictionary.class] || ![o[@"syncedLyrics"] isKindOfClass:NSString.class])
                    continue;
                double d = [o[@"duration"] isKindOfClass:NSNumber.class] ? [o[@"duration"] doubleValue] : 0;
                if (duration > 0 && fabs(d - duration) > 3)
                    continue;
                return keep(o[@"syncedLyrics"]);
            }
            if (!found && !got)
                return set_lyrics(key, @[]);
            keep(@"");
        });
    });
}

static NSSet<NSString*>* words(NSString* s, NSString* artist) {
    s = plain(s).lowercaseString;
    for (NSString* cut in @[@"|", @"·", @" ft.", @" feat."]) {
        NSRange r = [s rangeOfString:cut];
        if (r.location != NSNotFound && r.location > 0)
            s = [s substringToIndex:r.location];
    }
    s = [s stringByReplacingOccurrencesOfString:@"[\\(\\[\\{][^\\)\\]\\}]*[\\)\\]\\}]"
                                     withString:@" "
                                        options:NSRegularExpressionSearch
                                          range:NSMakeRange(0, s.length)];
    NSMutableSet* out = [NSMutableSet set];
    for (NSString* w in [s componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet]) {
        if (w.length >= 3)
            [out addObject:w];
    }
    NSArray* theirs = [plain(artist).lowercaseString
        componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet];
    if (out.count > 1)
        [out minusSet:[NSSet setWithArray:theirs]];
    return out;
}

static NSString* youtube_id(NSString* link) {
    NSURLComponents* u = [NSURLComponents componentsWithString:link];
    NSString* host = u.host.lowercaseString ?: @"";
    if ([host isEqualToString:@"youtu.be"])
        return u.path.lastPathComponent.length ? u.path.lastPathComponent : nil;
    if (![host hasSuffix:@"youtube.com"])
        return nil;
    if ([u.path hasPrefix:@"/shorts/"] || [u.path hasPrefix:@"/live/"])
        return u.path.lastPathComponent;
    for (NSURLQueryItem* q in u.queryItems) {
        if ([q.name isEqualToString:@"v"] && q.value.length)
            return q.value;
    }
    return nil;
}

static NSString* browser_profile(NSString* bundle) {
    NSString* spec = [bundle containsString:@"zen"] ? @"zen" : [bundle containsString:@"firefox"] ? @"firefox" : nil;
    return spec ? cookie_file(spec).stringByDeletingLastPathComponent : nil;
}

static NSString* browser_video(NSString* bundle, NSString* title) {
    NSString* profile = browser_profile(bundle);
    if (!profile)
        return nil;
    NSString* want = plain(title).lowercaseString;
    for (NSString* like in @[@"https://www.youtube.com/watch?%", @"https://music.youtube.com/watch?%"]) {
        for (NSDictionary* e in read_history(profile, like, 100)) {
            NSString* video = youtube_id(e[@"url"]);
            if (video && [plain(e[@"title"]).lowercaseString containsString:want])
                return video;
        }
    }
    NSDictionary* store = read_session_store(profile);
    id windows = store[@"windows"];
    NSMutableArray<NSArray*>* histories = [NSMutableArray array];
    for (NSDictionary* w in [windows isKindOfClass:NSArray.class] ? windows : @[]) {
        id tabs = [w isKindOfClass:NSDictionary.class] ? w[@"tabs"] : nil;
        for (NSDictionary* tab in [tabs isKindOfClass:NSArray.class] ? tabs : @[]) {
            if (![tab isKindOfClass:NSDictionary.class] || ![tab[@"entries"] isKindOfClass:NSArray.class])
                continue;
            NSArray* entries = tab[@"entries"];
            NSInteger i = [tab[@"index"] respondsToSelector:@selector(integerValue)] ? [tab[@"index"] integerValue] - 1
                                                                                     : (NSInteger)entries.count - 1;
            NSMutableArray* pages = [NSMutableArray array];
            if (i >= 0 && i < (NSInteger)entries.count)
                [pages addObject:entries[i]];
            for (NSInteger k = (NSInteger)entries.count - 1; k >= 0; k--) {
                if (k != i)
                    [pages addObject:entries[k]];
            }
            [histories addObject:pages];
        }
    }
    for (int pass = 0; pass < 2; pass++) {
        for (NSArray* pages in histories) {
            for (NSDictionary* e in pass == 0 ? [pages subarrayWithRange:NSMakeRange(0, MIN(1u, pages.count))]
                                              : pages) {
                if (![e isKindOfClass:NSDictionary.class] || ![e[@"url"] isKindOfClass:NSString.class]
                    || ![e[@"title"] isKindOfClass:NSString.class])
                    continue;
                NSString* video = youtube_id(e[@"url"]);
                if (video && [plain(e[@"title"]).lowercaseString containsString:want])
                    return video;
            }
        }
    }
    return nil;
}

static NSString* covers_path(void) {
    return [cache_dir(@"media") stringByAppendingPathComponent:@"covers.plist"];
}

static NSString* remember_cover(NSString* key, NSString* path) {
    if (key.length && path.length && ![g_covers[key] isEqualToString:path]) {
        g_covers[key] = path;
        [g_covers writeToFile:covers_path() atomically:YES];
    }
    return path;
}

static void load_covers(void) {
    g_covers = [NSMutableDictionary dictionary];
    NSDictionary* d = [NSDictionary dictionaryWithContentsOfFile:covers_path()];
    for (NSString* k in d) {
        NSString* p = d[k];
        if ([k isKindOfClass:NSString.class] && [p isKindOfClass:NSString.class] &&
            [NSFileManager.defaultManager fileExistsAtPath:p])
            g_covers[k] = p;
    }
}

static NSString* g_cover_for;
static int g_cover_tries;
static bool g_cover_busy;

static void use_cover(NSString* key, NSData* data, NSString* mime) {
    if (!data.length || ![key isEqualToString:track_key(g_info)] || g_artwork.length)
        return;
    g_artwork = remember_cover(key, save_artwork(data, mime));
    save_info();
    emit();
}

static void get_data(NSString* url, void (^done)(NSData* data)) {
    [[NSURLSession.sharedSession dataTaskWithURL:[NSURL URLWithString:url]
                               completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
                                   NSData* ok = !error && ((NSHTTPURLResponse*)response).statusCode == 200 ? data : nil;
                                   dispatch_async(dispatch_get_main_queue(), ^{
                                       done(ok);
                                   });
                               }] resume];
}

static void itunes_cover(NSString* key, NSString* title, NSString* artist) {
    NSSet* mine = words(title, artist);
    if (!mine.count)
        return;
    NSString* term =
        [NSString stringWithFormat:@"%@ %@", plain(artist), [mine.allObjects componentsJoinedByString:@" "]];
    get_json([@"https://itunes.apple.com/search?"
                 stringByAppendingString:query(@{@"term": term, @"entity": @"song", @"limit": @"5"})],
             ^(id got) {
                 NSArray* results =
                     [got isKindOfClass:NSDictionary.class] && [got[@"results"] isKindOfClass:NSArray.class]
                     ? got[@"results"]
                     : @[];
                 if (getenv("REXUI_MEDIA_DEBUG"))
                     err([NSString
                         stringWithFormat:@"cover: itunes \"%@\": %lu results", term, (unsigned long)results.count]);
                 for (NSDictionary* r in results) {
                     if (![r isKindOfClass:NSDictionary.class] || ![r[@"trackName"] isKindOfClass:NSString.class]
                         || ![r[@"artworkUrl100"] isKindOfClass:NSString.class])
                         continue;
                     NSMutableSet* both = [words(r[@"trackName"], @"") mutableCopy];
                     [both intersectSet:mine];
                     if (both.count < MIN(2u, mine.count))
                         continue;
                     NSString* url = [r[@"artworkUrl100"] stringByReplacingOccurrencesOfString:@"100x100bb"
                                                                                    withString:@"600x600bb"];
                     return get_data(url, ^(NSData* data) {
                         use_cover(key, data, @"image/jpeg");
                     });
                 }
             });
}

static void cover_for_track(void) {
    NSString *title = string(@"kMRMediaRemoteNowPlayingInfoTitle"),
             *artist = string(@"kMRMediaRemoteNowPlayingInfoArtist");
    NSString *key = track_key(g_info), *bundle = g_bundle;
    if (!title.length || g_artwork.length || g_cover_busy)
        return;
    if (![key isEqualToString:g_cover_for ?: @""])
        g_cover_for = key, g_cover_tries = 0;
    if (g_cover_tries >= 15)
        return;
    int tries = ++g_cover_tries;
    bool browser = browser_profile(bundle) != nil;
    g_cover_busy = true;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString* video = browser_video(bundle, title);
        dispatch_async(dispatch_get_main_queue(), ^{
            g_cover_busy = false;
            if (getenv("REXUI_MEDIA_DEBUG"))
                err([NSString stringWithFormat:@"cover: tab video %@ (try %d)", video, tries]);
            if (video) {
                g_cover_tries = 15;
                NSString* base = [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/", video];
                get_data([base stringByAppendingString:@"maxresdefault.jpg"], ^(NSData* data) {
                    if (data.length)
                        return use_cover(key, data, @"image/jpeg");
                    get_data([base stringByAppendingString:@"hqdefault.jpg"], ^(NSData* data) {
                        use_cover(key, data, @"image/jpeg");
                    });
                });
            } else {
                if (tries == (browser ? 4 : 1) && !page_sound(g_info, bundle))
                    itunes_cover(key, title, artist);
                if (browser && tries < 4)
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                        if ([key isEqualToString:track_key(g_info)])
                            cover_for_track();
                    });
            }
        });
    });
}

static NSString* app_name(NSString* bundle) {
    NSRunningApplication* p = [NSRunningApplication runningApplicationsWithBundleIdentifier:bundle].firstObject;
    NSURL* url = p.bundleURL ?: [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:bundle];
    NSString* name =
        p.localizedName ?: [[NSFileManager.defaultManager displayNameAtPath:url.path] stringByDeletingPathExtension];
    return name.length ? name : bundle;
}

static void now_player(void (^done)(NSString* name, NSString* bundle)) {
    mr_pid(dispatch_get_main_queue(), ^(int pid) {
        NSRunningApplication* app = pid > 0 ? [NSRunningApplication runningApplicationWithProcessIdentifier:pid] : nil;
        NSString *name = app.localizedName ?: @"", *bundle = app.bundleIdentifier ?: @"";
        if (!mr_client)
            return done(name, bundle);
        mr_client(dispatch_get_main_queue(), ^(id client) {
            NSString* parent = client && mr_client_parent ? (__bridge NSString*)mr_client_parent(client) : nil;
            if (!parent.length)
                return done(name, bundle);
            done(app_name(parent), parent);
        });
    });
}

static void refresh_players(void) {
    if (!mr_clients || !mr_client_bundle)
        return;
    mr_clients(dispatch_get_main_queue(), ^(CFArrayRef list) {
        NSMutableArray* players = [NSMutableArray array];
        NSMutableSet* seen = [NSMutableSet set];
        for (id c in (__bridge NSArray*)list) {
            NSString* parent = mr_client_parent ? (__bridge NSString*)mr_client_parent(c) : nil;
            NSString* bundle = parent.length ? parent : (__bridge NSString*)mr_client_bundle(c);
            if (!bundle.length || [seen containsObject:bundle])
                continue;
            [seen addObject:bundle];
            NSString* name = parent.length ? app_name(parent)
                : mr_client_name           ? (__bridge NSString*)mr_client_name(c)
                                           : nil;
            [players addObject:@{
                @"name": name.length ? name : app_name(bundle),
                @"bundle": bundle,
                @"icon": app_icon(bundle)
            }];
        }
        g_players = players;
        emit();
    });
}

@interface RXMute : NSObject
@property(copy) NSString* bundle;
@property AudioObjectID tap, device;
@property AudioDeviceIOProcID proc;
@property(strong) CATapDescription* desc;
@end
@implementation RXMute
@end

static NSMutableSet<NSString*>* g_muted;
static NSMutableDictionary<NSString*, RXMute*>* g_mutes;

static NSArray<NSString*>* muted_bundles(void) {
    return [g_muted.allObjects sortedArrayUsingSelector:@selector(compare:)] ?: @[];
}

static NSString* muted_path(void) {
    return [cache_dir(@"media") stringByAppendingPathComponent:@"muted.plist"];
}

static pid_t parent_of(pid_t pid) {
    struct kinfo_proc kp;
    size_t len = sizeof kp;
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    if (sysctl(mib, 4, &kp, &len, NULL, 0) != 0 || len == 0)
        return 0;
    return kp.kp_eproc.e_ppid;
}

static NSArray<NSNumber*>* audio_objects(void) {
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyProcessObjectList, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &size) != noErr || !size)
        return @[];
    NSMutableData* d = [NSMutableData dataWithLength:size];
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, d.mutableBytes) != noErr)
        return @[];
    NSMutableArray* out = [NSMutableArray array];
    const AudioObjectID* ids = (const AudioObjectID*)d.bytes;
    for (UInt32 i = 0; i < size / sizeof(AudioObjectID); i++)
        [out addObject:@(ids[i])];
    return out;
}

static NSArray<NSNumber*>* processes_of(NSString* bundle) {
    static auto responsible = (pid_t(*)(pid_t))dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
    NSMutableSet<NSNumber*>* apps = [NSMutableSet set];
    for (NSRunningApplication* a in [NSRunningApplication runningApplicationsWithBundleIdentifier:bundle])
        [apps addObject:@(a.processIdentifier)];
    NSString* under = [bundle stringByAppendingString:@"."];
    NSMutableArray<NSNumber*>* out = [NSMutableArray array];
    for (NSNumber* o in audio_objects()) {
        AudioObjectID obj = o.unsignedIntValue;
        AudioObjectPropertyAddress a = {kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain};
        pid_t pid = 0;
        UInt32 size = sizeof pid;
        if (AudioObjectGetPropertyData(obj, &a, 0, NULL, &size, &pid) != noErr)
            continue;
        a.mSelector = kAudioProcessPropertyBundleID;
        CFStringRef b = NULL;
        size = sizeof b;
        NSString* bid = AudioObjectGetPropertyData(obj, &a, 0, NULL, &size, &b) == noErr && b
            ? (__bridge_transfer NSString*)b
            : @"";
        bool mine = [bid isEqualToString:bundle] || [bid hasPrefix:under]
            || (responsible && [apps containsObject:@(responsible(pid))]);
        for (pid_t p = pid, n = 0; !mine && p > 1 && n < 8; p = parent_of(p), n++)
            mine = [apps containsObject:@(p)];
        if (mine)
            [out addObject:o];
    }
    return [out sortedArrayUsingSelector:@selector(compare:)];
}

static void save_mutes(void) {
    [muted_bundles() writeToFile:muted_path() atomically:YES];
}

static void untap(NSString* bundle) {
    RXMute* m = g_mutes[bundle];
    if (!m)
        return;
    if (m.proc) {
        AudioDeviceStop(m.device, m.proc);
        AudioDeviceDestroyIOProcID(m.device, m.proc);
    }
    if (m.device)
        AudioHardwareDestroyAggregateDevice(m.device);
    if (m.tap)
        AudioHardwareDestroyProcessTap(m.tap);
    [g_mutes removeObjectForKey:bundle];
}

static bool tap_muted(NSString* bundle, NSArray<NSNumber*>* processes) {
    if (g_mutes[bundle])
        return true;
    RXMute* m = [RXMute new];
    m.bundle = bundle;
    CATapDescription* d = [[CATapDescription alloc] initStereoMixdownOfProcesses:processes];
    d.UUID = [NSUUID UUID];
    d.name = [@"rexui-media mute " stringByAppendingString:bundle];
    d.privateTap = YES;
    d.muteBehavior = CATapMuted;
    m.desc = d;
    AudioObjectID tap = kAudioObjectUnknown;
    OSStatus st = AudioHardwareCreateProcessTap(d, &tap);
    if (st != noErr) {
        err([NSString stringWithFormat:@"muting %@: no tap (%d)", bundle, (int)st]);
        return false;
    }
    m.tap = tap;
    g_mutes[bundle] = m;
    NSDictionary* agg = @{
        @kAudioAggregateDeviceNameKey: d.name,
        @kAudioAggregateDeviceUIDKey: [@"rexui-media-mute-" stringByAppendingString:d.UUID.UUIDString],
        @kAudioAggregateDeviceIsPrivateKey: @YES,
        @kAudioAggregateDeviceIsStackedKey: @NO,
        @kAudioAggregateDeviceTapAutoStartKey: @YES,
        @kAudioAggregateDeviceTapListKey:
            @[@{@kAudioSubTapDriftCompensationKey: @YES,
                @kAudioSubTapUIDKey: d.UUID.UUIDString}],
    };
    AudioObjectID device = kAudioObjectUnknown;
    AudioDeviceIOProcID proc = NULL;
    if ((st = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)agg, &device)) != noErr
        || (m.device = device,
            st = AudioDeviceCreateIOProcIDWithBlock(&proc, device, NULL,
                                                    ^(const AudioTimeStamp*, const AudioBufferList*,
                                                      const AudioTimeStamp*, AudioBufferList*, const AudioTimeStamp*){
                                                    }))
            != noErr
        || (m.proc = proc, st = AudioDeviceStart(device, proc)) != noErr) {
        err([NSString stringWithFormat:@"muting %@: the tap's device failed (%d)", bundle, (int)st]);
        untap(bundle);
        return false;
    }
    err([NSString stringWithFormat:@"%@ muted (%lu audio processes)", bundle, (unsigned long)d.processes.count]);
    return true;
}

static void sync_mutes(void) {
    for (NSString* b in g_mutes.allKeys) {
        if (![g_muted containsObject:b])
            untap(b);
    }
    for (NSString* b in g_muted) {
        NSArray* now = processes_of(b);
        RXMute* m = g_mutes[b];
        if (!m) {
            if (now.count)
                tap_muted(b, now);
            continue;
        }
        if (!now.count || [now isEqualToArray:m.desc.processes])
            continue;
        m.desc.processes = now;
        CATapDescription* d = m.desc;
        AudioObjectPropertyAddress a = {kAudioTapPropertyDescription, kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain};
        OSStatus st = AudioObjectSetPropertyData(m.tap, &a, 0, NULL, sizeof d, &d);
        if (st != noErr)
            err([NSString stringWithFormat:@"%@: its tap took no new processes (%d)", m.bundle, (int)st]);
    }
}

static void set_muted(NSString* bundle, bool on) {
    if (on == [g_muted containsObject:bundle])
        return emit();
    if (on)
        [g_muted addObject:bundle];
    else
        [g_muted removeObject:bundle];
    sync_mutes();
    if (on && !g_mutes[bundle])
        err([NSString stringWithFormat:@"%@ muted (no sound from it yet)", bundle]);
    if (!on)
        err([NSString stringWithFormat:@"%@ unmuted", bundle]);
    save_mutes();
    emit();
}

static void start_mutes(void) {
    g_muted = [NSMutableSet set];
    g_mutes = [NSMutableDictionary dictionary];
    for (NSString* b in [NSArray arrayWithContentsOfFile:muted_path()]) {
        if ([b isKindOfClass:NSString.class] && b.length)
            [g_muted addObject:b];
    }
    sync_mutes();
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyProcessObjectList, kAudioObjectPropertyScopeGlobal,
                                    kAudioObjectPropertyElementMain};
    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &a, dispatch_get_main_queue(),
                                        ^(UInt32, const AudioObjectPropertyAddress*) {
                                            if (g_muted.count)
                                                sync_mutes();
                                        });
}

static dispatch_queue_t g_osu_queue;
static NSString* g_osu_log;
static unsigned long long g_osu_log_read;
static NSString* g_osu_name;
static double g_osu_name_at;
static double g_osu_base = NAN, g_osu_extra, g_osu_since;
static bool g_osu_running, g_osu_loop;
static bool g_osu_rescan;
static NSMutableDictionary<NSString*, NSDictionary*>* g_osu_maps;
static NSMutableDictionary<NSString*, NSDictionary*>* g_osu_replays;
static NSMutableSet<NSString*>* g_osu_other;
static NSArray<NSDictionary*>* g_osu_files;
static NSDictionary<NSString*, NSString*>* g_osu_best;
static NSDictionary<NSString*, NSDictionary*>* g_osu_top;
static double g_osu_scanned;
static NSString* g_osu_for;
static NSDictionary* g_osu_map;
static double g_osu_length;
static NSString* g_osu_bg;
static NSDictionary* g_osu_info;
static NSString* g_osu_fetched;
static bool g_osu_busy;

typedef struct {
    const uint8_t* next_in;
    size_t avail_in;
    uint64_t total_in;
    uint8_t* next_out;
    size_t avail_out;
    uint64_t total_out;
    void *allocator, *internal, *reserved_ptr[4];
    uint64_t reserved_int[2];
    size_t reserved_size[2];
    int reserved_enum[2];
} lzma_stream;
extern "C" int lzma_alone_decoder(lzma_stream*, uint64_t memlimit);
extern "C" int lzma_code(lzma_stream*, int action);
extern "C" void lzma_end(lzma_stream*);

static NSData* unlzma(const uint8_t* p, size_t n) {
    lzma_stream s = {};
    if (lzma_alone_decoder(&s, 64 << 20))
        return nil;
    NSMutableData* out = [NSMutableData dataWithLength:64 * 1024];
    s.next_in = p;
    s.avail_in = n;
    int r;
    do {
        if (s.total_out == out.length)
            out.length *= 2;
        s.next_out = (uint8_t*)out.mutableBytes + s.total_out;
        s.avail_out = out.length - s.total_out;
        r = lzma_code(&s, 3);
    } while (r == 0);
    lzma_end(&s);
    if (r != 1)
        return nil;
    out.length = s.total_out;
    return out;
}

static NSString* md5_hex(NSData* d) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    unsigned char h[CC_MD5_DIGEST_LENGTH];
    CC_MD5(d.bytes, (CC_LONG)d.length, h);
#pragma clang diagnostic pop
    NSMutableString* s = [NSMutableString string];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++)
        [s appendFormat:@"%02x", h[i]];
    return s;
}

static NSString* osu_home(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/osu"];
}

static NSString* osu_dir(void) {
    NSString* ini = [NSString stringWithContentsOfFile:[osu_home() stringByAppendingPathComponent:@"storage.ini"]
                                              encoding:NSUTF8StringEncoding
                                                 error:nil];
    for (NSString* line in [ini componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound)
            continue;
        NSCharacterSet* space = NSCharacterSet.whitespaceCharacterSet;
        NSString* v = [[line substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:space];
        if ([[[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:space] isEqualToString:@"FullPath"]
            && v.length)
            return v;
    }
    return osu_home();
}

static NSString* osu_song(NSString* name) {
    NSRange r = [name rangeOfString:@" [" options:NSBackwardsSearch];
    return [name hasSuffix:@"]"] && r.location != NSNotFound ? [name substringToIndex:r.location] : name;
}

static const void* find(const char* p, size_t n, const char* what) {
    return memmem(p, n, what, strlen(what));
}

static void osu_line(const char* p, size_t n, double t) {
    const char* m;
    if ((m = (const char*)find(p, n, "Game-wide working beatmap updated to "))) {
        size_t at = m - p + 37;
        NSString* name = [[[NSString alloc] initWithBytes:p + at length:n - at encoding:NSUTF8StringEncoding]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!name)
            return;
        if (!g_osu_name || ![osu_song(name) isEqualToString:osu_song(g_osu_name)])
            g_osu_base = NAN, g_osu_extra = 0, g_osu_since = t, g_osu_running = true, g_osu_loop = true;
        g_osu_name = name;
        g_osu_name_at = t;
    } else if ((m = (const char*)find(p, n, "GameplayClockContainer seeking to "))) {
        g_osu_base = strtod(m + 34, NULL) / 1000;
        g_osu_extra = 0, g_osu_since = t, g_osu_loop = false;
    } else if (find(p, n, "GameplayClockContainer started via call to StartGameplayClock")) {
        if (g_osu_running)
            g_osu_extra += t - g_osu_since;
        g_osu_since = t, g_osu_running = true;
    } else if (find(p, n, "GameplayClockContainer stopped via call to StopGameplayClock")) {
        if (g_osu_running)
            g_osu_extra += t - g_osu_since;
        g_osu_since = t, g_osu_running = false;
    } else if (find(p, n, "resume to SoloSongSelect#")) {
        if (!g_osu_running)
            g_osu_base = NAN, g_osu_extra = 0, g_osu_since = t, g_osu_running = true, g_osu_loop = true;
        g_osu_rescan = true;
    } else if (find(p, n, "exit from ") && find(p, n, "Player#")) {
        g_osu_rescan = true;
    }
}

static void osu_read_log(NSString* dir) {
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* newest;
    NSDate* newest_at;
    for (NSString* logs in [NSSet setWithArray:@[
             [dir stringByAppendingPathComponent:@"logs"], [osu_home() stringByAppendingPathComponent:@"logs"]
         ]]) {
        for (NSString* f in [fm contentsOfDirectoryAtPath:logs error:nil]) {
            if (![f hasSuffix:@".runtime.log"])
                continue;
            NSString* p = [logs stringByAppendingPathComponent:f];
            NSDate* m = [fm attributesOfItemAtPath:p error:nil].fileModificationDate;
            if (m && (!newest_at || [m compare:newest_at] == NSOrderedDescending))
                newest = p, newest_at = m;
        }
    }
    NSFileHandle* h = newest ? [NSFileHandle fileHandleForReadingAtPath:newest] : nil;
    if (!h)
        return;
    unsigned long long size = [h seekToEndOfFile];
    if (![newest isEqualToString:g_osu_log] || size < g_osu_log_read) {
        g_osu_log = newest, g_osu_log_read = 0, g_osu_name = nil;
        g_osu_base = NAN, g_osu_extra = 0, g_osu_running = false;
    }
    if (size > g_osu_log_read) {
        [h seekToFileOffset:g_osu_log_read];
        NSData* data = [h readDataOfLength:(NSUInteger)(size - g_osu_log_read)];
        const char *p = (const char*)data.bytes, *end = p + data.length;
        while (p < end) {
            const char* nl = (const char*)memchr(p, '\n', end - p);
            if (!nl)
                break;
            auto num = [&](int at, int n) {
                int v = 0;
                for (int i = 0; i < n; i++)
                    v = v * 10 + (p[at + i] - '0');
                return v;
            };
            if (nl - p > 19 && p[4] == '-' && p[10] == ' ' && p[13] == ':') {
                struct tm tm = {};
                tm.tm_year = num(0, 4) - 1900, tm.tm_mon = num(5, 2) - 1, tm.tm_mday = num(8, 2);
                tm.tm_hour = num(11, 2), tm.tm_min = num(14, 2), tm.tm_sec = num(17, 2);
                osu_line(p, nl - p, (double)timegm(&tm) - kCFAbsoluteTimeIntervalSince1970);
            }
            g_osu_log_read += nl + 1 - p;
            p = nl + 1;
        }
    }
    [h closeFile];
}

static NSDictionary* osu_parse(NSData* data) {
    NSString* text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text)
        return nil;
    NSMutableDictionary* m = [NSMutableDictionary dictionary];
    __block NSString* section = @"";
    [text enumerateLinesUsingBlock:^(NSString* raw, BOOL* stop) {
        NSString* line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([line hasPrefix:@"["]) {
            section = line;
            *stop = [line isEqualToString:@"[TimingPoints]"] || [line isEqualToString:@"[HitObjects]"];
            return;
        }
        NSRange c = [line rangeOfString:@":"];
        NSString* k = c.location != NSNotFound ? [line substringToIndex:c.location] : nil;
        NSString* v = k ? [[line substringFromIndex:c.location + 1]
                              stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
                        : nil;
        if ([section isEqualToString:@"[Metadata]"] && k) {
            m[k] = v;
        } else if ([section isEqualToString:@"[General]"]
                   && ([k isEqualToString:@"AudioFilename"] || [k isEqualToString:@"PreviewTime"])) {
            m[k] = v;
        } else if ([section isEqualToString:@"[Events]"] && !m[@"bg"]) {
            NSArray<NSString*>* f = [line componentsSeparatedByString:@","];
            if (f.count >= 3 && ([f[0] isEqualToString:@"0"] || [f[0] isEqualToString:@"Background"]))
                m[@"bg"] =
                    [f[2] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\" "]];
        }
    }];
    for (NSString* k in @[
             @"Title", @"TitleUnicode", @"Artist", @"ArtistUnicode", @"Creator", @"Version", @"Source", @"BeatmapID",
             @"BeatmapSetID", @"bg", @"AudioFilename"
         ]) {
        if (!m[k])
            m[k] = @"";
    }
    double preview = m[@"PreviewTime"] ? [m[@"PreviewTime"] doubleValue] : -1;
    m[@"preview"] = @(preview >= 0 ? preview / 1000 : -1);
    NSString* last = [[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                         componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]
                         .lastObject;
    NSArray<NSString*>* f = [last componentsSeparatedByString:@","];
    double end = f.count > 3 ? f[2].doubleValue : 0;
    if (f.count > 5 && (f[3].intValue & 8))
        end = MAX(end, f[5].doubleValue);
    m[@"end"] = @(end / 1000);
    m[@"md5"] = md5_hex(data);
    NSString* name =
        [[NSString stringWithFormat:@"%@ - %@ %@", m[@"Artist"], m[@"Title"],
                                    [m[@"Creator"] length] ? [NSString stringWithFormat:@"(%@)", m[@"Creator"]] : @""]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if ([m[@"Version"] length])
        name = [NSString stringWithFormat:@"%@ [%@]", name, m[@"Version"]];
    m[@"name"] = name;
    return m;
}

static NSDictionary* osu_replay(NSData* d) {
    const uint8_t *p = (const uint8_t*)d.bytes, *end = p + d.length;
    int32_t version = 0;
    if (d.length < 8)
        return nil;
    memcpy(&version, p + 1, 4);
    if (p[0] > 3 || p[5] != 0x0b || version < 20000000 || version >= 40000000)
        return nil;
    __block const uint8_t* at = p + 5;
    NSString* (^string)(void) = ^NSString*(void) {
        if (at >= end)
            return nil;
        if (*at++ == 0)
            return @"";
        uint64_t n = 0;
        for (int shift = 0; at < end && shift < 64; shift += 7) {
            uint8_t b = *at++;
            n |= (uint64_t)(b & 0x7f) << shift;
            if (!(b & 0x80))
                break;
        }
        if (n > (uint64_t)(end - at))
            return nil;
        NSString* s = [[NSString alloc] initWithBytes:at length:(NSUInteger)n encoding:NSUTF8StringEncoding];
        at += n;
        return s ?: @"";
    };
    NSString* md5 = string();
    if (!md5.length || !string() || !string() || end - at < 23)
        return nil;
    uint16_t counts[6];
    int32_t score;
    uint16_t combo;
    memcpy(counts, at, 12), memcpy(&score, at + 12, 4), memcpy(&combo, at + 16, 2);
    at += 12 + 11;
    if (!string() || end - at < 12)
        return nil;
    int64_t ticks;
    memcpy(&ticks, at, 8);
    at += 8;
    NSMutableDictionary* r = [@{
        @"md5": md5,
        @"rank": @"",
        @"score": @(score),
        @"combo": @(combo),
        @"mods": @[],
        @"played": @((ticks - 621355968000000000LL) / 10000000.0),
        @"stats": @{@"great": @(counts[0]), @"ok": @(counts[1]), @"meh": @(counts[2]), @"miss": @(counts[5])},
        @"max": @{@"great": @(counts[0] + counts[1] + counts[2] + counts[5])},
    } mutableCopy];
    int32_t n;
    memcpy(&n, at, 4);
    at += 4;
    if (n < 0 || n > end - at || end - at - n < 8)
        return r;
    at += n + 8;
    if (end - at >= 4) {
        memcpy(&n, at, 4);
        at += 4;
        NSData* json = n > 0 && n <= end - at ? unlzma(at, n) : nil;
        NSDictionary* info = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
        if (![info isKindOfClass:NSDictionary.class])
            return r;
        if ([info[@"rank"] isKindOfClass:NSString.class])
            r[@"rank"] = info[@"rank"];
        if ([info[@"statistics"] isKindOfClass:NSDictionary.class])
            r[@"stats"] = info[@"statistics"];
        if ([info[@"maximum_statistics"] isKindOfClass:NSDictionary.class])
            r[@"max"] = info[@"maximum_statistics"];
        NSMutableArray* mods = [NSMutableArray array];
        for (NSDictionary* m in [info[@"mods"] isKindOfClass:NSArray.class] ? info[@"mods"] : @[]) {
            if ([m isKindOfClass:NSDictionary.class] && [m[@"acronym"] isKindOfClass:NSString.class])
                [mods addObject:m[@"acronym"]];
        }
        r[@"mods"] = mods;
    }
    return r;
}

static NSDictionary* osu_score(NSDictionary* r) {
    NSDictionary *st = r[@"stats"], *mx = r[@"max"];
    NSDictionary<NSString*, NSNumber*>* points = @{
        @"perfect": @315,
        @"great": @300,
        @"good": @200,
        @"ok": @100,
        @"meh": @50,
        @"small_tick_hit": @10,
        @"large_tick_hit": @30,
        @"slider_tail_hit": @150,
    };
    double got = 0, all = 0;
    for (NSString* k in points)
        got += points[k].doubleValue * [st[k] doubleValue], all += points[k].doubleValue * [mx[k] doubleValue];
    long most = 0;
    for (NSString* k in @[@"perfect", @"great", @"large_tick_hit", @"slider_tail_hit"])
        most += [mx[k] longValue];
    NSMutableArray* counts = [NSMutableArray array];
    for (NSArray* c in @[@[@"great", @"GREAT"], @[@"ok", @"OK"], @[@"meh", @"MEH"], @[@"miss", @"MISS"]])
        [counts addObject:@{@"kind": c[0], @"label": c[1], @"value": st[c[0]] ?: @0, @"max": @-1}];
    for (NSArray* c in @[
             @[@"large_tick_hit", @"SLIDER TICK"], @[@"slider_tail_hit", @"SLIDER END"],
             @[@"large_bonus", @"SPINNER BONUS"], @[@"small_bonus", @"SPINNER SPIN"]
         ]) {
        if ([mx[c[0]] longValue] > 0)
            [counts addObject:@{@"kind": c[0], @"label": c[1], @"value": st[c[0]] ?: @0, @"max": mx[c[0]]}];
    }
    NSDateFormatter* f = [NSDateFormatter new];
    f.dateStyle = NSDateFormatterLongStyle, f.timeStyle = NSDateFormatterShortStyle;
    NSString* rank = r[@"rank"];
    return @{
        @"rank": [rank hasPrefix:@"X"] ? @"SS"
            : [rank hasPrefix:@"S"]    ? @"S"
                                       : rank,
        @"rankSilver": @([rank hasSuffix:@"H"]),
        @"score": r[@"score"],
        @"accuracy": @(all > 0 ? floor(got / all * 10000) / 10000 : 0),
        @"combo": r[@"combo"],
        @"maxCombo": @(most),
        @"mods": r[@"mods"],
        @"counts": counts,
        @"played": [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:[r[@"played"] doubleValue]]],
    };
}

static NSArray<NSString*>* ranks(void) {
    return @[@"D", @"C", @"B", @"A", @"S", @"SH", @"X", @"XH"];
}

static void osu_scan(NSString* dir) {
    double now = CFAbsoluteTimeGetCurrent();
    if (now - g_osu_scanned < 10)
        return;
    g_osu_scanned = now;
    if (!g_osu_maps)
        g_osu_maps = [NSMutableDictionary dictionary], g_osu_replays = [NSMutableDictionary dictionary],
        g_osu_other = [NSMutableSet set];
    NSURL* root = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"files"] isDirectory:YES];
    NSDirectoryEnumerator* e =
        [NSFileManager.defaultManager enumeratorAtURL:root
                           includingPropertiesForKeys:@[NSURLCreationDateKey, NSURLIsRegularFileKey]
                                              options:NSDirectoryEnumerationSkipsHiddenFiles
                                         errorHandler:nil];
    NSMutableArray<NSDictionary*>* files = [NSMutableArray array];
    NSMutableDictionary *maps = [NSMutableDictionary dictionary], *replays = [NSMutableDictionary dictionary];
    for (NSURL* u in e) {
        NSNumber* regular;
        NSDate* born;
        [u getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
        [u getResourceValue:&born forKey:NSURLCreationDateKey error:nil];
        if (!regular.boolValue)
            continue;
        NSString* p = u.path;
        [files addObject:@{@"path": p, @"born": @(born.timeIntervalSinceReferenceDate)}];
        if ([g_osu_other containsObject:p])
            continue;
        if (g_osu_maps[p] || g_osu_replays[p]) {
            if (g_osu_maps[p])
                maps[p] = g_osu_maps[p];
            else
                replays[p] = g_osu_replays[p];
            continue;
        }
        NSFileHandle* h = [NSFileHandle fileHandleForReadingAtPath:p];
        NSData* head = [h readDataOfLength:20];
        [h closeFile];
        NSUInteger bom = head.length >= 3 && !memcmp(head.bytes, "\xEF\xBB\xBF", 3) ? 3 : 0;
        const uint8_t* b = (const uint8_t*)head.bytes;
        NSDictionary *m = nil, *r = nil;
        if (head.length >= bom + 17 && !memcmp(b + bom, "osu file format v", 17))
            m = osu_parse([NSData dataWithContentsOfFile:p]);
        else if (head.length >= 8 && b[0] <= 3 && b[5] == 0x0b)
            r = osu_replay([NSData dataWithContentsOfFile:p]);
        if (m)
            maps[p] = m;
        else if (r)
            replays[p] = r;
        else
            [g_osu_other addObject:p];
    }
    [files sortUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
        return [a[@"born"] compare:b[@"born"]];
    }];
    g_osu_files = files;
    g_osu_maps = maps;
    g_osu_replays = replays;
    NSMutableDictionary *best = [NSMutableDictionary dictionary], *top = [NSMutableDictionary dictionary];
    for (NSDictionary* r in replays.objectEnumerator) {
        NSUInteger i = [ranks() indexOfObject:r[@"rank"]];
        if (i == NSNotFound)
            continue;
        if (!best[r[@"md5"]] || i > [ranks() indexOfObject:best[r[@"md5"]]])
            best[r[@"md5"]] = r[@"rank"];
        if (!top[r[@"md5"]] || [r[@"score"] intValue] > [top[r[@"md5"]][@"score"] intValue])
            top[r[@"md5"]] = r;
    }
    g_osu_best = best;
    g_osu_top = top;
}

static NSDictionary* osu_find(NSString* name) {
    for (NSDictionary* m in g_osu_maps.objectEnumerator) {
        if ([m[@"name"] isEqualToString:name])
            return m;
    }
    for (NSDictionary* m in g_osu_maps.objectEnumerator) {
        if ([name hasPrefix:[NSString stringWithFormat:@"%@ - %@ (", m[@"Artist"], m[@"Title"]]]
            && (![m[@"Version"] length] || [name hasSuffix:[NSString stringWithFormat:@"[%@]", m[@"Version"]]]))
            return m;
    }
    return nil;
}

static bool file_is(NSString* path, NSString* ext) {
    NSFileHandle* h = [NSFileHandle fileHandleForReadingAtPath:path];
    NSData* d = [h readDataOfLength:4];
    [h closeFile];
    const uint8_t* b = (const uint8_t*)d.bytes;
    if (d.length < 4)
        return false;
    ext = ext.lowercaseString;
    if ([ext isEqualToString:@"png"])
        return !memcmp(b, "\x89PNG", 4);
    if ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"])
        return !memcmp(b, "\xFF\xD8\xFF", 3);
    if ([ext isEqualToString:@"ogg"])
        return !memcmp(b, "OggS", 4);
    if ([ext isEqualToString:@"wav"])
        return !memcmp(b, "RIFF", 4);
    if ([ext isEqualToString:@"mp3"])
        return !memcmp(b, "ID3", 3) || (b[0] == 0xFF && (b[1] & 0xE0) == 0xE0);
    return false;
}

static NSArray<NSString*>* osu_burst(NSDictionary* map) {
    int set = [map[@"BeatmapSetID"] intValue];
    BOOL (^mine)(NSDictionary*) = ^BOOL(NSDictionary* o) {
        if (set > 0)
            return [o[@"BeatmapSetID"] intValue] == set;
        return [o[@"Artist"] isEqual:map[@"Artist"]] && [o[@"Title"] isEqual:map[@"Title"]] &&
            [o[@"Creator"] isEqual:map[@"Creator"]];
    };
    NSArray<NSDictionary*>* files = g_osu_files;
    NSInteger lo = -1, hi = -1, n = (NSInteger)files.count;
    for (NSInteger i = 0; i < n; i++) {
        NSDictionary* o = g_osu_maps[files[i][@"path"]];
        if (o && mine(o))
            hi = i, lo = lo < 0 ? i : lo;
    }
    if (lo < 0)
        return nil;
    double (^born)(NSInteger) = ^double(NSInteger i) {
        return [files[i][@"born"] doubleValue];
    };
    BOOL (^other)(NSInteger) = ^BOOL(NSInteger i) {
        NSDictionary* o = g_osu_maps[files[i][@"path"]];
        return o && !mine(o);
    };
    while (lo > 0 && born(lo) - born(lo - 1) < 0.25 && !other(lo - 1))
        lo--;
    while (hi + 1 < n && born(hi + 1) - born(hi) < 0.25 && !other(hi + 1))
        hi++;
    if (hi - lo > 300)
        return nil;
    NSMutableArray* out = [NSMutableArray array];
    for (NSInteger i = lo; i <= hi; i++) {
        if (!g_osu_maps[files[i][@"path"]])
            [out addObject:files[i][@"path"]];
    }
    return out;
}

static double ogg_length(NSString* path) {
    NSData* d = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    const char* p = (const char*)d.bytes;
    size_t n = d.length;
    if (n < 64)
        return 0;
    double rate = 0, skip = 0;
    const char *v = (const char*)memmem(p, MIN(n, 512), "\x01vorbis", 7),
               *o = (const char*)memmem(p, MIN(n, 512), "OpusHead", 8);
    uint32_t r = 0;
    uint16_t pre = 0;
    if (v && v + 16 <= p + n)
        memcpy(&r, v + 12, 4), rate = r;
    else if (o && o + 12 <= p + n)
        memcpy(&pre, o + 10, 2), rate = 48000, skip = pre;
    for (size_t i = n - 14, lo = n > 65536 ? n - 65536 : 0; i > lo; i--) {
        if (memcmp(p + i, "OggS", 4))
            continue;
        int64_t g;
        memcpy(&g, p + i + 6, 8);
        return rate > 0 && g > 0 ? (g - skip) / rate : 0;
    }
    return 0;
}

static double audio_length(NSString* path, NSString* ext) {
    ext = ext.lowercaseString;
    if ([ext isEqualToString:@"ogg"])
        return ogg_length(path);
    AudioFileID f;
    if (AudioFileOpenURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], kAudioFileReadPermission,
                         [ext isEqualToString:@"wav"] ? kAudioFileWAVEType : kAudioFileMP3Type, &f))
        return 0;
    Float64 length = 0;
    UInt32 size = sizeof length;
    AudioFileGetProperty(f, kAudioFilePropertyEstimatedDuration, &size, &length);
    AudioFileClose(f);
    return length;
}

static void osu_files_of(NSDictionary* map, double* length, NSString** bg) {
    NSArray<NSString*>* burst = osu_burst(map);
    NSString *audio_ext = [map[@"AudioFilename"] pathExtension], *bg_ext = [map[@"bg"] pathExtension], *song;
    unsigned long long largest = 0;
    *bg = nil;
    bool many = false;
    for (NSString* p in burst) {
        if (audio_ext.length && file_is(p, audio_ext)) {
            unsigned long long size = [NSFileManager.defaultManager attributesOfItemAtPath:p error:nil].fileSize;
            if (size > largest)
                largest = size, song = p;
        } else if (bg_ext.length && file_is(p, bg_ext)) {
            many = *bg != nil;
            if (!many)
                *bg = p;
        }
    }
    if (many)
        *bg = nil;
    *length = song ? audio_length(song, audio_ext) : 0;
    if (*length <= 0)
        *length = [map[@"end"] doubleValue] + 1;
}

static double osu_position(NSDictionary* o) {
    double length = [o[@"length"] doubleValue], preview = [o[@"preview"] doubleValue];
    if (preview < 0)
        preview = length * 0.4;
    NSDictionary* a = o[@"anchor"];
    id base = a[@"base"];
    double p = ([base isKindOfClass:NSNumber.class] ? [base doubleValue] : preview) + [a[@"extra"] doubleValue]
        + ([a[@"running"] boolValue] ? CFAbsoluteTimeGetCurrent() - [a[@"since"] doubleValue] : 0);
    if ([a[@"loop"] boolValue] && length - preview > 1 && p > length)
        p = preview + fmod(p - length, length - preview);
    return length > 0 ? MIN(MAX(p, 0), length) : MAX(p, 0);
}

static NSMutableSet<NSString*>* g_osu_stars_asked;

static NSString* stars_path(void) {
    return [cache_dir(@"osu") stringByAppendingPathComponent:@"stars.plist"];
}

static NSString* osu_token(void) {
    NSString* ini = [NSString stringWithContentsOfFile:[osu_home() stringByAppendingPathComponent:@"game.ini"]
                                              encoding:NSUTF8StringEncoding
                                                 error:nil];
    for (NSString* line in [ini componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (![line hasPrefix:@"Token = "])
            continue;
        NSArray<NSString*>* t = [[line substringFromIndex:8] componentsSeparatedByString:@"|"];
        return t.count >= 2 && t[0].length && t[1].doubleValue > NSDate.date.timeIntervalSince1970 + 30 ? t[0] : nil;
    }
    return nil;
}

static void osu_stars(int beatmap) {
    if (!g_osu_stars) {
        g_osu_stars =
            [[NSDictionary dictionaryWithContentsOfFile:stars_path()] mutableCopy] ?: [NSMutableDictionary dictionary];
        g_osu_stars_asked = [NSMutableSet set];
    }
    NSString *key = @(beatmap).stringValue, *token;
    if (beatmap <= 0 || g_osu_stars[key] || [g_osu_stars_asked containsObject:key] || !(token = osu_token()))
        return;
    [g_osu_stars_asked addObject:key];
    NSMutableURLRequest* r = [NSMutableURLRequest
        requestWithURL:[NSURL URLWithString:[NSString
                                                stringWithFormat:@"https://osu.ppy.sh/api/v2/beatmaps/%d", beatmap]]];
    [r setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [r setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    r.timeoutInterval = 10;
    [[NSURLSession.sharedSession dataTaskWithRequest:r
                                   completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
                                       NSDictionary* got = data && ((NSHTTPURLResponse*)response).statusCode == 200
                                           ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]
                                           : nil;
                                       dispatch_async(dispatch_get_main_queue(), ^{
                                           id stars =
                                               [got isKindOfClass:NSDictionary.class] ? got[@"difficulty_rating"] : nil;
                                           if (![stars isKindOfClass:NSNumber.class])
                                               return [g_osu_stars_asked removeObject:key];
                                           g_osu_stars[key] = @(round([stars doubleValue] * 100) / 100);
                                           [g_osu_stars writeToFile:stars_path() atomically:YES];
                                           emit();
                                       });
                                   }] resume];
}

static void osu_cover(NSString* name, NSData* data, NSString* mime) {
    if (!data.length || ![g_osu[@"name"] isEqualToString:name])
        return;
    NSMutableDictionary* m = [g_osu mutableCopy];
    m[@"artwork"] = remember_cover([@"osu\n" stringByAppendingString:name], save_artwork(data, mime));
    g_osu = m;
    emit();
}

static void osu_tick(void) {
    if (g_osu_busy)
        return;
    if (![NSRunningApplication runningApplicationsWithBundleIdentifier:kOsu].count) {
        if (g_osu) {
            g_osu = g_osu_info = nil;
            dispatch_async(g_osu_queue, ^{
                g_osu_log = nil;
            });
            emit();
        }
        return;
    }
    g_osu_busy = true;
    dispatch_async(g_osu_queue, ^{
        NSString* dir = osu_dir();
        osu_read_log(dir);
        if (g_osu_rescan)
            g_osu_rescan = false, g_osu_scanned = 0, osu_scan(dir);
        NSString* name = [g_osu_name hasPrefix:@"please load a beatmap!"] ? nil : g_osu_name;
        if (getenv("REXUI_MEDIA_OSU"))
            name = @(getenv("REXUI_MEDIA_OSU"));
        if (name && (![name isEqualToString:g_osu_for] || !g_osu_map)) {
            NSDictionary* map = osu_find(name);
            if (!map)
                osu_scan(dir), map = osu_find(name);
            if (![name isEqualToString:g_osu_for] || map) {
                g_osu_for = name, g_osu_map = map, g_osu_length = 0, g_osu_bg = nil;
                NSString* bg;
                if (map)
                    osu_files_of(map, &g_osu_length, &bg), g_osu_bg = bg;
            }
        }
        NSDictionary* map = g_osu_map;
        if (getenv("REXUI_MEDIA_DEBUG"))
            err([NSString stringWithFormat:@"osu: %lu replays, %lu ranked maps; %@ (%@) length %.1f bg %@ best %@ base "
                                           @"%f extra %f running %d loop %d",
                                           (unsigned long)g_osu_replays.count, (unsigned long)g_osu_best.count, name,
                                           map ? @"found" : @"not found", g_osu_length, g_osu_bg.lastPathComponent,
                                           map ? g_osu_best[map[@"md5"]] : nil, g_osu_base, g_osu_extra, g_osu_running,
                                           g_osu_loop]);
        NSString* ini = [NSString stringWithContentsOfFile:[osu_home() stringByAppendingPathComponent:@"framework.ini"]
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
        bool unicode = [ini rangeOfString:@"ShowUnicode = True"].location != NSNotFound;
        NSString* rank = map ? g_osu_best[map[@"md5"]] : nil;
        NSDictionary *info = !name ? nil : @{
            @"name" : name, @"at" : @(g_osu_name_at),
            @"title" : map[unicode && [map[@"TitleUnicode"] length] ? @"TitleUnicode" : @"Title"] ?: name,
            @"artist" : map[unicode && [map[@"ArtistUnicode"] length] ? @"ArtistUnicode" : @"Artist"] ?: @"",
            @"album" : map[@"Source"] ?: @"", @"difficulty" : map[@"Version"] ?: @"",
            @"rank" : [rank hasPrefix:@"X"] ? @"SS" : [rank hasPrefix:@"S"] ? @"S" : rank ?: @"", @"rankSilver" : @([rank hasSuffix:@"H"]),
            @"best" : map && g_osu_top[map[@"md5"]] ? osu_score(g_osu_top[map[@"md5"]]) : NSNull.null, @"beatmap" : @([map[@"BeatmapID"] intValue]),
            @"length" : @(g_osu_length), @"preview" : map[@"preview"] ?: @-1, @"set" : @([map[@"BeatmapSetID"] intValue]), @"bg" : g_osu_bg ?: @"",
            @"anchor" : @{@"base" : isnan(g_osu_base) ? (id)NSNull.null : @(g_osu_base), @"extra" : @(g_osu_extra), @"since" : @(g_osu_since), @"running" : @(g_osu_running), @"loop" : @(g_osu_loop)},
        };
        dispatch_async(dispatch_get_main_queue(), ^{
            g_osu_busy = false;
            if (info == g_osu_info || [info isEqual:g_osu_info])
                return;
            NSString* was = g_osu[@"name"];
            g_osu_info = info;
            if (!info) {
                g_osu = nil;
                return emit();
            }
            bool other = ![info[@"name"] isEqualToString:was];
            if (other)
                g_osu_at = MAX(g_osu_at, [info[@"at"] doubleValue]);
            NSString *name = info[@"name"], *known = g_covers[[@"osu\n" stringByAppendingString:name]];
            NSMutableDictionary* o = [info mutableCopy];
            o[@"artwork"] = known && [NSFileManager.defaultManager fileExistsAtPath:known] ? known : @"";
            o[@"entry"] = @{@"name": app_name(kOsu), @"bundle": kOsu, @"icon": app_icon(kOsu)};
            g_osu = o;
            emit();
            osu_stars([info[@"beatmap"] intValue]);
            if ([o[@"artwork"] length])
                return;
            NSString* bg = info[@"bg"];
            if (bg.length) {
                NSData* local = [NSData dataWithContentsOfFile:bg];
                if (local.length)
                    return osu_cover(name, local, file_is(bg, @"png") ? @"image/png" : @"image/jpeg");
            }
            int set = [info[@"set"] intValue];
            if (set > 0 && ![name isEqualToString:g_osu_fetched]) {
                g_osu_fetched = name;
                get_data([NSString stringWithFormat:@"https://assets.ppy.sh/beatmaps/%d/covers/fullsize.jpg", set],
                         ^(NSData* data) {
                             osu_cover(name, data, @"image/jpeg");
                         });
            }
        });
    });
}

static NSString* saved_path(void) {
    return [cache_dir(@"media") stringByAppendingPathComponent:@"last.plist"];
}

static void save_info(void) {
    NSMutableDictionary* keep = [NSMutableDictionary dictionary];
    for (NSString* k in @[@"Title", @"Artist", @"Album", @"Duration", @"ElapsedTime", @"Timestamp", @"PlaybackRate"]) {
        id v = g_info[[@"kMRMediaRemoteNowPlayingInfo" stringByAppendingString:k]];
        if ([v isKindOfClass:NSString.class] || [v isKindOfClass:NSNumber.class] || [v isKindOfClass:NSDate.class])
            keep[[@"kMRMediaRemoteNowPlayingInfo" stringByAppendingString:k]] = v;
    }
    keep[@"artwork"] = g_artwork;
    if ([keep isEqual:g_saved])
        return;
    g_saved = keep;
    [keep writeToFile:saved_path() atomically:YES];
}

static void got_info(NSDictionary* d, NSString* name, NSString* bundle);

static void refresh(void) {
    mr_info(dispatch_get_main_queue(), ^(CFDictionaryRef info) {
        NSDictionary* d = info ? [(__bridge NSDictionary*)info copy] : @{};
        now_player(^(NSString* name, NSString* bundle) {
            got_info(d, name, bundle);
        });
    });
    refresh_players();
}

static void got_info(NSDictionary* d, NSString* name, NSString* bundle) {
    if (getenv("REXUI_MEDIA_DEBUG")) {
        NSMutableArray* keys = [NSMutableArray array];
        for (NSString* k in d)
            [keys addObject:[k stringByReplacingOccurrencesOfString:@"kMRMediaRemoteNowPlayingInfo" withString:@""]];
        err([NSString
            stringWithFormat:@"info %.3f %@ ts=%@: %@ dur=%@ el=%@ rate=%@", CFAbsoluteTimeGetCurrent(), bundle,
                             d[@"kMRMediaRemoteNowPlayingInfoTimestamp"],
                             [[keys sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","],
                             d[@"kMRMediaRemoteNowPlayingInfoDuration"], d[@"kMRMediaRemoteNowPlayingInfoElapsedTime"],
                             d[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]]);
    }
    NSDictionary* was = g_info;
    if (!d.count && was.count) {
        double t = CFAbsoluteTimeGetCurrent();
        if (!g_empty_since)
            g_empty_since = t;
        if (t - g_empty_since < 1) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                refresh();
            });
            return;
        }
    }
    if (d.count)
        g_empty_since = 0;
    if (!(page_sound(d, bundle) && was.count && !page_sound(was, g_bundle))) {
        g_player = name;
        g_bundle = bundle;
        if (!was.count && d.count && g_saved.count && [track_key(d) isEqualToString:track_key(g_saved)])
            was = g_saved;
        g_info = merged(d, was);
        bool other = ![track_key(g_info) isEqualToString:track_key(was)];
        if (other)
            g_cover_for = nil;
        id art = g_info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
        if ([art isKindOfClass:NSData.class]) {
            g_artwork = save_artwork(art, string(@"kMRMediaRemoteNowPlayingInfoArtworkMIMEType"));
            if (g_info.count)
                remember_cover(track_key(g_info), g_artwork);
        } else if (other || !g_artwork.length) {
            NSString* known = g_info.count ? g_covers[track_key(g_info)] : nil;
            g_artwork = known && [NSFileManager.defaultManager fileExistsAtPath:known] ? known : @"";
            if (g_artwork.length)
                [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate: NSDate.date}
                                               ofItemAtPath:g_artwork
                                                      error:nil];
        }
        if (g_info.count)
            save_info();
        cover_for_track();
        if (g_sync_until > 0 && number(@"kMRMediaRemoteNowPlayingInfoDuration") > 0)
            end_sync();
    }
    mr_playing(dispatch_get_main_queue(), ^(Boolean playing) {
        if (playing && !g_playing)
            g_mr_at = CFAbsoluteTimeGetCurrent();
        g_playing = playing;
        g_ready = true;
        emit();
    });
}

static void end_sync(void) {
    if (g_sync_until <= 0)
        return;
    g_sync_until = 0;
    g_sync_shown = CFAbsoluteTimeGetCurrent() + 1;
    mr_send(kPlay, nil);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        refresh();
    });
}

static void start_sync(void) {
    NSString* key = track_key(g_info);
    if (!g_playing || g_sync_until > 0 || number(@"kMRMediaRemoteNowPlayingInfoDuration") > 0 || !g_info.count ||
        [key isEqualToString:g_synced_for ?: @""])
        return;
    g_synced_for = key;
    g_sync_until = CFAbsoluteTimeGetCurrent() + 0.3;
    mr_send(kPause, nil);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        end_sync();
    });
}

static void command(NSDictionary* msg);

static void toggle_repeat(void) {
    if (g_own_repeat) {
        g_own_repeat = false;
        return emit();
    }
    int before = player_repeat();
    NSString* bundle = g_bundle;
    mr_send(kRepeat, nil);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        refresh();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 800 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (player_repeat() != before || !g_info.count || ![g_bundle isEqualToString:bundle])
            return;
        g_own_repeat = true;
        g_own_repeat_bundle = bundle;
        emit();
    });
}

static void own_repeat_tick(void) {
    double d = number(@"kMRMediaRemoteNowPlayingInfoDuration"), now = CFAbsoluteTimeGetCurrent();
    if (!g_own_repeat || d <= 1 || now - g_looped_at < 2)
        return;
    double at = position();
    if (g_playing ? at < d - 0.6 : at < d - 0.3)
        return;
    g_looped_at = now;
    command(@{@"seek": @0});
    if (!g_playing)
        mr_send(kPlay, nil);
}

static void command(NSDictionary* msg) {
    if (![msg isKindOfClass:NSDictionary.class])
        return;
    if ([msg[@"pick"] isKindOfClass:NSString.class]) {
        if ([msg[@"pick"] isEqualToString:kOsu])
            g_osu_at = CFAbsoluteTimeGetCurrent(), g_mr_held = false;
        else
            g_mr_at = CFAbsoluteTimeGetCurrent(), g_mr_held = true;
        return emit();
    }
    if ([msg[@"mute"] isKindOfClass:NSString.class] && [msg[@"mute"] length])
        return set_muted(msg[@"mute"], [msg[@"on"] boolValue]);
    if (osu_shown())
        return;
    NSString* cmd = msg[@"cmd"];
    if ([cmd isKindOfClass:NSString.class] && [cmd isEqualToString:@"repeat"])
        return toggle_repeat();
    NSDictionary<NSString*, NSNumber*>* cmds = @{
        @"play": @(kPlay),
        @"pause": @(kPause),
        @"toggle": @(kToggle),
        @"next": @(kNext),
        @"previous": @(kPrevious),
        @"shuffle": @(kShuffle),
        @"repeat": @(kRepeat),
    };
    if ([cmd isKindOfClass:NSString.class] && cmds[cmd])
        mr_send(cmds[cmd].intValue, nil);
    if ([msg[@"seek"] isKindOfClass:NSNumber.class] && mr_seek) {
        mr_seek([msg[@"seek"] doubleValue]);
        NSMutableDictionary* m = [g_info mutableCopy];
        m[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] = msg[@"seek"];
        m[@"kMRMediaRemoteNowPlayingInfoTimestamp"] = NSDate.date;
        g_info = m;
        emit();
    }
    if ([msg[@"sync"] boolValue])
        return start_sync();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        refresh();
    });
}

extern "C" void rexui_media_main(void) {
    @autoreleasepool {
        rexui_begin();
        void* mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        if (!mr) {
            err(@"cannot load MediaRemote");
            exit(1);
        }
        mr_register = (RegisterFn)dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
        mr_info = (GetInfoFn)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
        mr_playing = (GetPlayingFn)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        mr_pid = (GetPidFn)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationPID");
        mr_client = (GetClientFn)dlsym(mr, "MRMediaRemoteGetNowPlayingClient");
        mr_clients = (GetClientsFn)dlsym(mr, "MRMediaRemoteGetNowPlayingClients");
        mr_client_parent = (ClientStringFn)dlsym(mr, "MRNowPlayingClientGetParentAppBundleIdentifier");
        mr_client_bundle = (ClientStringFn)dlsym(mr, "MRNowPlayingClientGetBundleIdentifier");
        mr_client_name = (ClientStringFn)dlsym(mr, "MRNowPlayingClientGetDisplayName");
        mr_send = (SendCommandFn)dlsym(mr, "MRMediaRemoteSendCommand");
        mr_seek = (SetElapsedFn)dlsym(mr, "MRMediaRemoteSetElapsedTime");
        if (!mr_register || !mr_info || !mr_playing || !mr_pid || !mr_send) {
            err(@"MediaRemote is missing functions this needs");
            exit(1);
        }
        g_info = @{};
        g_saved = [NSDictionary dictionaryWithContentsOfFile:saved_path()];
        load_covers();
        if ([g_saved[@"artwork"] isKindOfClass:NSString.class] && [g_saved[@"artwork"] length])
            remember_cover(track_key(g_saved), g_saved[@"artwork"]);
        g_osu_queue = dispatch_queue_create("rexui-media.osu", DISPATCH_QUEUE_SERIAL);
        start_mutes();

        mr_register(dispatch_get_main_queue());
        for (NSString* name in @[
                 @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                 @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                 @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                 @"kMRMediaRemoteNowPlayingApplicationClientStateDidChange",
             ]) {
            [NSNotificationCenter.defaultCenter addObserverForName:name
                                                            object:nil
                                                             queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(NSNotification* note) {
                                                            refresh();
                                                        }];
        }
        refresh();

        __block int ticks = 0;
        [NSTimer scheduledTimerWithTimeInterval:0.1
                                        repeats:YES
                                          block:^(NSTimer* timer) {
                                              own_repeat_tick();
                                              if (ticks % 10 == 0)
                                                  osu_tick();
                                              if (++ticks % 50 == 0)
                                                  refresh();
                                              else if ((g_playing || osu_shown()) && ticks % 5 == 0)
                                                  emit();
                                              else if (g_playing && g_lyrics.count
                                                       && lyric_line() != [g_sent[@"line"] integerValue])
                                                  emit();
                                          }];

        [NSThread detachNewThreadWithBlock:^{
            const char* m;
            long n;
            while ((n = rexui_read(&m)) >= 0) {
                NSData* d = [NSData dataWithBytes:m length:(NSUInteger)n];
                id msg = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
                dispatch_async(dispatch_get_main_queue(), ^{
                    command(msg);
                });
            }
            exit(0);
        }];
        CFRunLoopRun();
    }
}
