#import "./include/just_audio/JustAudioPlugin.h"
#import "./include/just_audio/AudioPlayer.h"
#import "./include/just_audio/BetterEventChannel.h"
#import "MixMethodResult.h"
#import <AVFoundation/AVFoundation.h>
#include <TargetConditionals.h>

@implementation JustAudioPlugin {
    NSObject<FlutterPluginRegistrar>* _registrar;
    NSMutableDictionary<NSString *, AudioPlayer *> *_players;
    BetterEventChannel *_preparationEvents;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
    FlutterMethodChannel* channel = [FlutterMethodChannel
        methodChannelWithName:@"com.ryanheise.just_audio.methods"
              binaryMessenger:[registrar messenger]];
    JustAudioPlugin* instance = [[JustAudioPlugin alloc] initWithRegistrar:registrar];
    [registrar addMethodCallDelegate:instance channel:channel];
}

- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    self = [super init];
    NSAssert(self, @"super init cannot be nil");
    _registrar = registrar;
    _players = [[NSMutableDictionary alloc] init];
    _preparationEvents = [[BetterEventChannel alloc]
        initWithName:@"com.ryanheise.just_audio.preparations" messenger:[registrar messenger]];
    return self;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    //NSLog(@"plugin method: %@", call.method);
    if ([@"init" isEqualToString:call.method]) {
        NSDictionary *request = (NSDictionary *)call.arguments;
        NSString *playerId = (NSString *)request[@"id"];
        NSDictionary *loadConfiguration = (NSDictionary *)request[@"audioLoadConfiguration"];
        BOOL useLazyPreparation = [((NSNumber *)request[@"useLazyPreparation"]) boolValue];
        if ([_players objectForKey:playerId] != nil) {
            FlutterError *flutterError = [FlutterError errorWithCode:@"error" message:@"Platform player already exists" details:nil];
            result(flutterError);
        } else {
            AudioPlayer* player = [[AudioPlayer alloc] initWithRegistrar:_registrar playerId:playerId loadConfiguration:loadConfiguration useLazyPreparation:useLazyPreparation];
            __weak JustAudioPlugin *weakSelf = self;
            player.mixPreparationEvent = ^(NSDictionary *event) {
                JustAudioPlugin *strongSelf = weakSelf;
                if (strongSelf) [strongSelf->_preparationEvents sendEvent:event];
            };
            [_players setValue:player forKey:playerId];
            result(nil);
        }
    } else if ([@"disposePlayer" isEqualToString:call.method]) {
        NSDictionary *request = (NSDictionary *)call.arguments;
        NSString *playerId = request[@"id"];
        [_players[playerId] dispose:NO];
        [_players setValue:nil forKey:playerId];
        result(@{});
    } else if ([@"disposeAllPlayers" isEqualToString:call.method]) {
        for (NSString *playerId in _players) {
            [_players[playerId] dispose:NO];
        }
        [_players removeAllObjects];
        result(@{});
    }
#if TARGET_OS_IOS
    else if ([@"mixHoldUpcoming" isEqualToString:call.method]) {
        NSDictionary *request = call.arguments;
        NSArray *held = [_players[request[@"playerId"]] mixHoldUpcoming:request[@"sourceIds"]];
        result(held ?: @[]);
    }
    else if ([@"mixReplaceUpcoming" isEqualToString:call.method]) {
        NSDictionary *request = call.arguments;
        AudioPlayer *player = _players[request[@"playerId"]];
        result(MixBooleanResult(player != nil && [player mixReplaceUpcoming:request]));
    }
    else if ([@"mixRetirePlayed" isEqualToString:call.method]) {
        NSDictionary *request = call.arguments;
        AudioPlayer *player = _players[request[@"playerId"]];
        result(MixBooleanResult(player != nil && [player mixRetirePlayed:request]));
    }
    else if ([@"mixGetNativeTiming" isEqualToString:call.method]) {
        // Mix Player owns one audio player, including the background wrapper.
        // Refuse ambiguous data instead of inspecting an unrelated player.
        result(_players.count == 1 ? [_players.allValues.firstObject mixNativeTiming] : nil);
    }
#endif
    else {
        result(FlutterMethodNotImplemented);
    }
}

- (void)dealloc {
    [_preparationEvents dispose];
    for (NSString *playerId in _players) {
        [_players[playerId] dispose:YES];
    }
    [_players removeAllObjects];
}

@end
