// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "ui/ui.h"

#import <AVFoundation/AVFoundation.h>

@interface RXVideoLayer : RXLayer
@property(nonatomic, strong) AVPlayerLayer* player_layer;
@property(nonatomic, strong) AVQueuePlayer* player;
@property(nonatomic, strong) AVPlayerLooper* looper;
@property(nonatomic, copy) NSString* loaded;
@property(nonatomic, weak) RXNode* node;
@property(nonatomic, strong) id ticks;
@property(nonatomic, strong) id ended;
@property(nonatomic) AVPlayerItemStatus told;
@end

@implementation RXVideoLayer
- (void)layoutSublayers {
    [super layoutSublayers];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.player_layer.frame = self.bounds;
    [CATransaction commit];
}
- (void)dealloc {
    if (_ticks)
        [_player removeTimeObserver:_ticks];
    if (_ended)
        [NSNotificationCenter.defaultCenter removeObserver:_ended];
    [_player pause];
}
@end

CALayer* make_video(RXNode* n) {
    RXVideoLayer* l = [RXVideoLayer layer];
    l.node = n;
    l.masksToBounds = YES;
    l.player_layer = (AVPlayerLayer*)still([AVPlayerLayer layer]);
    l.player_layer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    [l addSublayer:l.player_layer];
    return l;
}

static NSURL* video_url(RXNode* n, NSString* source) {
    if ([source hasPrefix:@"http://"] || [source hasPrefix:@"https://"] || [source hasPrefix:@"file://"])
        return [NSURL URLWithString:source];
    NSString* path = source.stringByExpandingTildeInPath;
    if (!path.isAbsolutePath)
        path = [doc_dir(n) stringByAppendingPathComponent:path];
    return [NSURL fileURLWithPath:path];
}

static void watch_stop(RXVideoLayer* l) {
    if (l.ticks)
        [l.player removeTimeObserver:l.ticks];
    l.ticks = nil;
    if (l.ended)
        [NSNotificationCenter.defaultCenter removeObserver:l.ended];
    l.ended = nil;
}
static void watch_start(RXVideoLayer* l, RXNode* n) {
    if (!l.player || l.ticks || !flag(n, @"wantsStatus", false))
        return;
    __weak RXVideoLayer* weak = l;
    __weak RXNode* weak_node = n;
    l.told = AVPlayerItemStatusUnknown;
    if (n.doc.ctx)
        doc_call(n.doc, @"update", @[@(n.uid), @{@"status": @"loading"}]);
    l.ticks = [l.player
        addPeriodicTimeObserverForInterval:CMTimeMake(1, 4)
                                     queue:dispatch_get_main_queue()
                                usingBlock:^(CMTime t) {
                                    RXVideoLayer* v = weak;
                                    RXNode* m = weak_node;
                                    if (!v || !m || !m.doc.ctx)
                                        return;
                                    AVPlayerItem* item = v.player.currentItem;
                                    const double pos = CMTIME_IS_NUMERIC(t) ? CMTimeGetSeconds(t) : 0;
                                    const double dur =
                                        item && CMTIME_IS_NUMERIC(item.duration) ? CMTimeGetSeconds(item.duration) : 0;
                                    NSMutableDictionary* now =
                                        [@{@"position": @(pos),
                                           @"duration": @(dur)} mutableCopy];
                                    const AVPlayerItemStatus st = item.status;
                                    if (st != v.told) {
                                        v.told = st;
                                        now[@"status"] = st == AVPlayerItemStatusReadyToPlay ? @"ready"
                                            : st == AVPlayerItemStatusFailed                 ? @"error"
                                                                                             : @"loading";
                                    }
                                    doc_call(m.doc, @"update", @[@(m.uid), now]);
                                    if (now[@"status"] && st == AVPlayerItemStatusFailed)
                                        doc_call(m.doc, @"emit", @[
                                            @(m.uid), @"failed", @[item.error.localizedDescription ?: @"could not play"]
                                        ]);
                                }];
    l.ended =
        [NSNotificationCenter.defaultCenter addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification* note) {
                                                        RXVideoLayer* v = weak;
                                                        RXNode* m = weak_node;
                                                        if (v && m && m.doc.ctx && note.object == v.player.currentItem)
                                                            doc_call(m.doc, @"emit", @[@(m.uid), @"ended", @[]]);
                                                    }];
}
void video_wants_status(RXNode* n) {
    RXVideoLayer* l = (RXVideoLayer*)n.layer;
    if ([l isKindOfClass:RXVideoLayer.class])
        watch_start(l, n);
}
void video_seek(RXNode* n, double seconds) {
    RXVideoLayer* l = (RXVideoLayer*)n.layer;
    if ([l isKindOfClass:RXVideoLayer.class])
        [l.player seekToTime:CMTimeMakeWithSeconds(seconds, 600)
             toleranceBefore:kCMTimeZero
              toleranceAfter:kCMTimeZero];
}

static void play_state(RXVideoLayer* l, RXNode* n) {
    if (!l.player)
        return;
    l.player.muted = flag(n, P::muted, true);
    bool on = flag(n, P::playing, true) && node_on_screen(n);
    if (on)
        l.player.rate = MAX(0.05, num(n, P::rate, 1));
    else
        [l.player pause];
}

void video_apply(RXNode* n, NSString* name) {
    RXVideoLayer* l = (RXVideoLayer*)n.layer;
    if (![l isKindOfClass:RXVideoLayer.class])
        return;
    if ([name isEqualToString:@"source"] || [name isEqualToString:@"loop"]) {
        NSString* source = str(n, P::source, @"");
        NSString* key = [NSString stringWithFormat:@"%@|%d", source, flag(n, P::loop, true)];
        if ([key isEqualToString:l.loaded])
            return;
        l.loaded = key;
        watch_stop(l);
        [l.player pause];
        l.looper = nil;
        l.player = nil;
        l.player_layer.player = nil;
        if (!source.length)
            return;
        AVPlayerItem* item = [AVPlayerItem playerItemWithURL:video_url(n, source)];
        l.player = [AVQueuePlayer queuePlayerWithItems:@[]];
        l.player.preventsDisplaySleepDuringVideoPlayback = NO;
        if (flag(n, P::loop, true))
            l.looper = [AVPlayerLooper playerLooperWithPlayer:l.player templateItem:item];
        else
            [l.player insertItem:item afterItem:nil];
        l.player_layer.player = l.player;
        watch_start(l, n);
    } else if ([name isEqualToString:@"fit"]) {
        NSString* fit = str(n, P::fit, @"cover");
        l.player_layer.videoGravity = [fit isEqualToString:@"contain"] ? AVLayerVideoGravityResizeAspect
            : [fit isEqualToString:@"fill"]                            ? AVLayerVideoGravityResize
                                                                       : AVLayerVideoGravityResizeAspectFill;
        return;
    }
    play_state(l, n);
}

void video_placed(RXNode* n) {
    RXVideoLayer* l = (RXVideoLayer*)n.layer;
    if ([l isKindOfClass:RXVideoLayer.class])
        play_state(l, n);
}

void video_stop(RXNode* n) {
    RXVideoLayer* l = (RXVideoLayer*)n.layer;
    if (![l isKindOfClass:RXVideoLayer.class])
        return;
    watch_stop(l);
    [l.player pause];
    l.looper = nil;
    l.player = nil;
    l.player_layer.player = nil;
    l.loaded = nil;
}
