#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

typedef NS_ENUM(NSInteger, MixDurationSource) {
    MixDurationUnknown,
    MixDurationItem,
    MixDurationSeekable,
};

typedef struct {
    CMTime time;
    MixDurationSource source;
} MixDurationSelection;

FOUNDATION_EXPORT MixDurationSelection MixSelectDuration(
    CMTime itemDuration, CMTimeRange seekableRange, BOOL preferItem);
// Negative means unknown. Zero remains valid for a playback position.
FOUNDATION_EXPORT int64_t MixTimeMicroseconds(CMTime time);
FOUNDATION_EXPORT NSInteger MixPlaybackIndex(
    NSInteger stored, NSInteger actual, NSUInteger count, BOOL pending);
// loopMode follows just_audio's off=0 / one=1 / all=2 values.
FOUNDATION_EXPORT NSInteger MixSuccessorIndex(
    NSArray<NSNumber *> *order, NSInteger ended, NSInteger loopMode);

@interface MixCompletionTracker : NSObject
- (void)reset;
- (void)resetItem:(id)item;
- (BOOL)acceptItem:(id)item
       endedIndex:(NSInteger)ended
      storedIndex:(NSInteger)stored
      actualIndex:(NSInteger)actual
   successorIndex:(NSInteger)successor
          seeking:(BOOL)seeking;
@end
