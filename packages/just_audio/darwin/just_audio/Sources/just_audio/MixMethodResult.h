#import <Foundation/Foundation.h>

// Boxing an Objective-C logical expression with @(...) produces an integer.
// Flutter's StandardMethodCodec needs CFBoolean to decode a Dart bool.
static inline NSNumber *MixBooleanResult(BOOL applied) {
    return applied ? @YES : @NO;
}

// Event-channel fields need the same Boolean encoding as method results.
static inline NSDictionary *MixPreparationEvent(NSString *sourceId, NSInteger index,
        BOOL ready, NSInteger errorCode) {
    return @{
        @"sourceId": sourceId,
        @"index": @(index),
        @"ready": MixBooleanResult(ready),
        @"code": @(errorCode)
    };
}
