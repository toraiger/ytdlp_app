#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <math.h>

static void Require(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "%s\n", message.UTF8String);
        exit(1);
    }
}

static void PumpRunLoop(void) {
    const NSTimeInterval pollInterval = 0.01; // Allow asynchronous AVFoundation callbacks.
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:pollInterval]];
}

static void WaitForReady(AVPlayerItem *item) {
    const NSTimeInterval loadTimeout = 15;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:loadTimeout];
    while ([deadline timeIntervalSinceNow] > 0) {
        Require(item.status != AVPlayerItemStatusFailed, @"AVFoundation rejected fixture");
        double duration = CMTimeGetSeconds(item.duration);
        if ((item.status == AVPlayerItemStatusReadyToPlay) && isfinite(duration) && (duration > 0)) return;
        PumpRunLoop();
    }
    Require(NO, @"AVFoundation item did not become ready");
}

static double InspectAsset(NSURL *url, BOOL seek, double expected, double tolerance) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{
        AVURLAssetPreferPreciseDurationAndTimingKey: @YES,
    }];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    AVPlayer *player = [AVPlayer playerWithPlayerItem:item];
    WaitForReady(item);
    double duration = CMTimeGetSeconds(item.duration);
    if (seek) {
        const int32_t seekTimescale = 1000; // Millisecond seek resolution.
        const double midpointFraction = 0.5;
        const NSTimeInterval seekTimeout = 10;
        double target = expected * midpointFraction;
        __block BOOL finished = NO;
        __block BOOL succeeded = NO;
        [player seekToTime:CMTimeMakeWithSeconds(target, seekTimescale)
            toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero
            completionHandler:^(BOOL completed) {
                succeeded = completed;
                finished = YES;
            }];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seekTimeout];
        while ((!finished) && ([deadline timeIntervalSinceNow] > 0)) PumpRunLoop();
        Require(finished && succeeded, @"Normalized M4A seek failed");
        Require(fabs(CMTimeGetSeconds(item.currentTime) - target) <= tolerance,
            @"Normalized M4A seek position is incorrect");
    }
    [player replaceCurrentItemWithPlayerItem:nil];
    return duration;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        const int expectedArgumentCount = 3;
        Require(argc == expectedArgumentCount, @"Expected manifest and HTTP base URL");
        NSString *manifestPath = [NSString stringWithUTF8String:argv[1]];
        NSString *directory = manifestPath.stringByDeletingLastPathComponent;
        NSString *baseURL = [NSString stringWithUTF8String:argv[2]];
        NSArray *cases = [NSJSONSerialization JSONObjectWithData:
            [NSData dataWithContentsOfFile:manifestPath] options:0 error:NULL];
        Require(cases.count > 0, @"Missing native M4A cases");
        for (NSDictionary *fixture in cases) {
            double expected = [fixture[@"expectedSeconds"] doubleValue];
            double tolerance = [fixture[@"toleranceSeconds"] doubleValue];
            for (NSNumber *remote in @[@NO, @YES]) {
                NSURL *(^fixtureURL)(NSString *) = ^NSURL *(NSString *key) {
                    NSString *filename = fixture[key];
                    return remote.boolValue
                        ? [NSURL URLWithString:[baseURL stringByAppendingFormat:@"/%@", filename]]
                        : [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:filename]];
                };
                double before = InspectAsset(fixtureURL(@"original"), NO, expected, tolerance);
                double after = InspectAsset(fixtureURL(@"normalized"), YES, expected, tolerance);
                printf("AVFoundation %s %s: original %.6f s, normalized %.6f s\n",
                    [fixture[@"name"] UTF8String], remote.boolValue ? "HTTP" : "file", before, after);
                Require(fabs(after - expected) <= tolerance, @"Normalized edited AAC duration is incorrect");
            }
        }
        // Same-length edited and unedited items must remain distinct in a queue.
        const NSUInteger queueSize = 3;
        Require(cases.count >= queueSize, @"Missing queue cases");
        NSMutableArray<AVPlayerItem *> *items = [NSMutableArray array];
        for (NSUInteger itemIndex = 0; itemIndex < queueSize; itemIndex++) {
            NSString *path = [directory stringByAppendingPathComponent:cases[itemIndex][@"normalized"]];
            [items addObject:[AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:path]]];
        }
        AVQueuePlayer *queue = [AVQueuePlayer queuePlayerWithItems:items];
        for (NSUInteger itemIndex = 0; itemIndex < queueSize; itemIndex++) {
            Require(queue.currentItem == items[itemIndex], @"Queue item identity changed incorrectly");
            WaitForReady(queue.currentItem);
            double expected = [cases[itemIndex][@"expectedSeconds"] doubleValue];
            double tolerance = [cases[itemIndex][@"toleranceSeconds"] doubleValue];
            Require(fabs(CMTimeGetSeconds(queue.currentItem.duration) - expected) <= tolerance,
                @"Queue timing belongs to a different item");
            [queue advanceToNextItem];
        }
        Require(queue.currentItem == nil, @"Queue advanced more than once per item");
        puts("Native M4A edits, durations, seeks and three-item queue passed");
    }
    return 0;
}
