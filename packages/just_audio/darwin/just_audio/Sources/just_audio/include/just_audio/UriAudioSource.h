#import "IndexedAudioSource.h"
#import "LoadControl.h"
#import "MixAudioTimeline.h"
#import <AVFoundation/AVFoundation.h>
#if TARGET_OS_OSX
#import <FlutterMacOS/FlutterMacOS.h>
#else
#import <Flutter/Flutter.h>
#endif

@interface UriAudioSource : IndexedAudioSource

@property (readonly, nonatomic) NSString *uri;

- (instancetype)initWithId:(NSString *)sid uri:(NSString *)uri loadControl:(LoadControl *)loadControl headers:(NSDictionary *)headers options:(NSDictionary *)options;
- (instancetype)initWithId:(NSString *)sid uri:(NSString *)uri loadControl:(LoadControl *)loadControl headers:(NSDictionary *)headers options:(NSDictionary *)options preferItemDuration:(BOOL)preferItemDuration;
- (MixDurationSelection)mixDurationForItem:(AVPlayerItem *)item;

@end
