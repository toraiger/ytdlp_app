#import "./include/just_audio/MixAudioTimeline.h"
#include <limits.h>
#include <math.h>

static BOOL MixPositiveTime(CMTime time) {
    return CMTIME_IS_NUMERIC(time) && isfinite(CMTimeGetSeconds(time)) &&
        CMTimeCompare(time, kCMTimeZero) > 0;
}

MixDurationSelection MixSelectDuration(
        CMTime itemDuration, CMTimeRange seekableRange, BOOL preferItem) {
    BOOL validItem = MixPositiveTime(itemDuration);
    BOOL validRange = CMTIMERANGE_IS_VALID(seekableRange) &&
        CMTIME_IS_NUMERIC(seekableRange.start) &&
        isfinite(CMTimeGetSeconds(seekableRange.start)) &&
        MixPositiveTime(seekableRange.duration);
    if (preferItem && validItem) {
        return (MixDurationSelection){itemDuration, MixDurationItem};
    }
    if (validRange) {
        return (MixDurationSelection){seekableRange.duration, MixDurationSeekable};
    }
    if (validItem) {
        return (MixDurationSelection){itemDuration, MixDurationItem};
    }
    return (MixDurationSelection){kCMTimeInvalid, MixDurationUnknown};
}

int64_t MixTimeMicroseconds(CMTime time) {
    if (!CMTIME_IS_NUMERIC(time)) return -1;
    double micros = CMTimeGetSeconds(time) * 1000000.0;
    if (!isfinite(micros) || micros < 0 || micros >= (double)LLONG_MAX) return -1;
    return (int64_t)llround(micros);
}

NSInteger MixPlaybackIndex(NSInteger stored, NSInteger actual, NSUInteger count, BOOL pending) {
    if (!pending && actual >= 0 && actual < (NSInteger)count) return actual;
    if (stored >= 0 && stored < (NSInteger)count) return stored;
    return -1;
}

NSInteger MixSuccessorIndex(NSArray<NSNumber *> *order, NSInteger ended, NSInteger loopMode) {
    NSUInteger position = [order indexOfObject:@(ended)];
    if (ended < 0 || position == NSNotFound || order.count == 0) return -1;
    if (loopMode == 1) return ended;
    if (loopMode == 2) return [order[(position + 1) % order.count] integerValue];
    return position + 1 < order.count ? [order[position + 1] integerValue] : -1;
}

@implementation MixCompletionTracker {
    NSHashTable *_handled;
}
- (instancetype)init {
    self = [super init];
    if (self) {
        _handled = [NSHashTable hashTableWithOptions:
            NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality];
    }
    return self;
}
- (void)reset { [_handled removeAllObjects]; }
- (void)resetItem:(id)item { if (item) [_handled removeObject:item]; }
- (BOOL)acceptItem:(id)item endedIndex:(NSInteger)ended storedIndex:(NSInteger)stored
      actualIndex:(NSInteger)actual successorIndex:(NSInteger)successor seeking:(BOOL)seeking {
    if (!item || ended < 0 || seeking || [_handled containsObject:item]) return NO;
    // KVO may already point to the successor. A distant manual selection must
    // never be moved by a late notification from another item.
    if (actual >= 0 && actual != ended && actual != successor) return NO;
    if (actual < 0 && stored != ended && stored != successor) return NO;
    [_handled addObject:item];
    return YES;
}
@end
