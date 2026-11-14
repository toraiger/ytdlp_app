#import <Foundation/Foundation.h>

// Boxing an Objective-C logical expression with @(...) produces an integer.
// Flutter's StandardMethodCodec needs CFBoolean to decode a Dart bool.
static inline NSNumber *MixBooleanResult(BOOL applied) {
    return applied ? @YES : @NO;
}
