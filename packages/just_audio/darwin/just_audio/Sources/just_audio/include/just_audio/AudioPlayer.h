#import <AVFoundation/AVFoundation.h>
#if TARGET_OS_OSX
#import <FlutterMacOS/FlutterMacOS.h>
#else
#import <Flutter/Flutter.h>
#endif

@interface AudioPlayer : NSObject<AVPlayerItemMetadataOutputPushDelegate>

@property (readonly, nonatomic) AVQueuePlayer *player;
@property (readonly, nonatomic) float speed;
@property (copy, nonatomic) void (^mixPreparationEvent)(NSDictionary *event);

- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar playerId:(NSString*)idParam loadConfiguration:(NSDictionary *)loadConfiguration useLazyPreparation:(BOOL)useLazyPreparation;
- (void)dispose:(BOOL)calledFromDealloc;
- (NSDictionary *)mixNativeTiming;
- (NSArray<NSString *> *)mixHoldUpcoming:(NSArray<NSString *> *)sourceIds;
- (BOOL)mixReplaceUpcoming:(NSDictionary *)request;
- (BOOL)mixRetirePlayed:(NSDictionary *)request;

@end

enum ProcessingState {
    psIdle,
    psLoading,
    psBuffering,
    psReady,
    psCompleted
};

enum LoopMode {
    lmLoopOff,
    lmLoopOne,
    lmLoopAll
};
