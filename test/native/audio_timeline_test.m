#import "MixAudioTimeline.h"
#include <stdio.h>
#include <stdlib.h>

static unsigned checks = 0;
#define CHECK(condition) do { \
    checks++; \
    if (!(condition)) { \
        fprintf(stderr, "Native timing check failed at line %d: %s\n", __LINE__, #condition); \
        exit(1); \
    } \
} while (0)

static CMTime seconds(double value) { return CMTimeMakeWithSeconds(value, 1000000); }

static void testDurations(void) {
    CMTimeRange window = CMTimeRangeMake(kCMTimeZero, seconds(473));
    MixDurationSelection vod = MixSelectDuration(seconds(237), window, YES);
    CHECK(vod.source == MixDurationItem);
    CHECK(MixTimeMicroseconds(vod.time) == 237000000);
    CHECK(MixTimeMicroseconds(MixSelectDuration(seconds(237.125), window, YES).time) == 237125000);
    // Live/DVR keeps the seekable window, even when the item has a value.
    MixDurationSelection live = MixSelectDuration(seconds(237), window, NO);
    CHECK(live.source == MixDurationSeekable);
    CHECK(MixTimeMicroseconds(live.time) == 473000000);
    CHECK(MixSelectDuration(kCMTimeIndefinite, window, YES).source == MixDurationSeekable);
    CHECK(MixSelectDuration(seconds(237), kCMTimeRangeInvalid, YES).source == MixDurationItem);
    CHECK(MixSelectDuration(seconds(237), kCMTimeRangeInvalid, NO).source == MixDurationItem);
    CMTime invalid[] = {kCMTimeInvalid, kCMTimeIndefinite, kCMTimePositiveInfinity,
        kCMTimeNegativeInfinity, kCMTimeZero, CMTimeMake(-1, 1)};
    for (unsigned i = 0; i < sizeof(invalid) / sizeof(invalid[0]); i++) {
        CHECK(MixSelectDuration(invalid[i], window, YES).source == MixDurationSeekable);
        MixDurationSelection unknown = MixSelectDuration(invalid[i], kCMTimeRangeInvalid, YES);
        CHECK(unknown.source == MixDurationUnknown);
        CHECK(MixTimeMicroseconds(unknown.time) == -1);
    }
    CHECK(MixTimeMicroseconds(kCMTimeZero) == 0);
    CHECK(MixTimeMicroseconds(kCMTimeIndefinite) == -1);
    CHECK(MixTimeMicroseconds(kCMTimePositiveInfinity) == -1);
    CHECK(MixTimeMicroseconds(CMTimeMake(-1, 1)) == -1);
    CHECK(MixSelectDuration(seconds(237),
        CMTimeRangeMake(kCMTimeIndefinite, seconds(473)), NO).source == MixDurationItem);
}

static void testNotificationOrder(BOOL kvoFirst, BOOL equalDurations) {
    MixCompletionTracker *tracker = [MixCompletionTracker new];
    NSArray *items = @[[NSObject new], [NSObject new], [NSObject new]];
    NSArray *order = @[@0, @1, @2];
    double lengths[] = {237, equalDurations ? 237 : 235, equalDurations ? 237 : 239};
    for (NSInteger ended = 0; ended < 3; ended++) {
        NSInteger next = MixSuccessorIndex(order, ended, 0);
        NSInteger actual = kvoFirst ? next : ended;
        NSInteger stored = kvoFirst && next >= 0 ? next : ended;
        CHECK([tracker acceptItem:items[ended] endedIndex:ended storedIndex:stored
            actualIndex:actual successorIndex:next seeking:NO]);
        if (next >= 0) stored = next;
        CHECK(![tracker acceptItem:items[ended] endedIndex:ended storedIndex:stored
            actualIndex:actual successorIndex:next seeking:NO]);
        // Both notification orders select the successor, never its successor.
        NSInteger eventIndex = MixPlaybackIndex(stored, actual, 3, !kvoFirst && next >= 0);
        CHECK(eventIndex == (next >= 0 ? next : ended));
        if (next >= 0) {
            CHECK(MixTimeMicroseconds(MixSelectDuration(seconds(lengths[eventIndex]),
                CMTimeRangeMake(kCMTimeZero, seconds(473)), YES).time) ==
                (int64_t)(lengths[next] * 1000000));
        }
    }
}

static void testSeekAndReload(void) {
    MixCompletionTracker *tracker = [MixCompletionTracker new];
    NSObject *item = [NSObject new];
    CHECK(![tracker acceptItem:item endedIndex:0 storedIndex:2 actualIndex:2
        successorIndex:1 seeking:NO]);
    CHECK(![tracker acceptItem:item endedIndex:0 storedIndex:0 actualIndex:0
        successorIndex:1 seeking:YES]);
    CHECK([tracker acceptItem:item endedIndex:0 storedIndex:0 actualIndex:0
        successorIndex:1 seeking:NO]);
    [tracker resetItem:item];
    CHECK([tracker acceptItem:item endedIndex:0 storedIndex:0 actualIndex:0
        successorIndex:1 seeking:NO]);
    [tracker reset];
    CHECK([tracker acceptItem:item endedIndex:0 storedIndex:1 actualIndex:1
        successorIndex:1 seeking:NO]);
    CHECK(![tracker acceptItem:[NSObject new] endedIndex:-1 storedIndex:0 actualIndex:0
        successorIndex:1 seeking:NO]);
    CHECK(MixPlaybackIndex(2, 0, 3, YES) == 2);
    CHECK(MixPlaybackIndex(0, 1, 3, NO) == 1);
    CHECK(MixPlaybackIndex(0, -1, 3, NO) == 0);
    CHECK(MixPlaybackIndex(0, 0, 0, NO) == -1);
    CHECK(MixSuccessorIndex(@[@2, @0, @1], 2, 0) == 0);
    CHECK(MixSuccessorIndex(@[@0, @1, @2], 2, 0) == -1);
    CHECK(MixSuccessorIndex(@[@0, @1, @2], 2, 2) == 0);
    CHECK(MixSuccessorIndex(@[@0, @1, @2], 1, 1) == 1);
    CHECK(MixSuccessorIndex(@[], 0, 0) == -1);
}

int main(void) {
    @autoreleasepool {
        testDurations();
        for (int kvo = 0; kvo < 2; kvo++) {
            for (int equal = 0; equal < 2; equal++) testNotificationOrder(kvo, equal);
        }
        testSeekAndReload();
        printf("Native audio timing: %u checks passed\n", checks);
    }
    return 0;
}
