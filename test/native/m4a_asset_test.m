#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <math.h>

static void Require(BOOL value, NSString *message) {
    if (!value) {
        fprintf(stderr, "%s\n", message.UTF8String);
        exit(1);
    }
}

static double ReadDuration(NSURL *url) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{
        AVURLAssetPreferPreciseDurationAndTimingKey: @YES,
    }];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    AVPlayer *player = [AVPlayer playerWithPlayerItem:item];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15];
    double duration = NAN;
    while ([deadline timeIntervalSinceNow] > 0) {
        Require(item.status != AVPlayerItemStatusFailed, @"AVFoundation rejected the fixture");
        duration = CMTimeGetSeconds(item.duration);
        if (item.status == AVPlayerItemStatusReadyToPlay && isfinite(duration) && duration > 0) break;
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    Require(item.status == AVPlayerItemStatusReadyToPlay && isfinite(duration) && duration > 0,
        @"AVFoundation duration did not become ready");
    [player replaceCurrentItemWithPlayerItem:nil];
    return duration;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        Require(argc == 4, @"Expected original file, normalized file and HTTP base URL");
        NSString *original = [NSString stringWithUTF8String:argv[1]];
        NSString *normalized = [NSString stringWithUTF8String:argv[2]];
        NSString *base = [NSString stringWithUTF8String:argv[3]];
        for (NSNumber *remote in @[@NO, @YES]) {
            NSURL *bad = remote.boolValue
                ? [NSURL URLWithString:[base stringByAppendingString:@"/dash-tone.m4a"]]
                : [NSURL fileURLWithPath:original];
            NSURL *good = remote.boolValue
                ? [NSURL URLWithString:[base stringByAppendingString:@"/normalized.m4a"]]
                : [NSURL fileURLWithPath:normalized];
            double before = ReadDuration(bad);
            double after = ReadDuration(good);
            printf("AVFoundation %s: original %.6f s, normalized %.6f s\n",
                remote.boolValue ? "HTTP ranges" : "local file", before, after);
            Require(fabs(after - 6.023220) < 0.1, @"Normalized fragmented AAC duration is incorrect");
        }
        puts("Native M4A local/HTTP duration checks passed");
    }
    return 0;
}
