#import "MixMethodResult.h"
#import <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>

static unsigned checks = 0;
#define CHECK(condition) do { \
    checks++; \
    if (!(condition)) { \
        fprintf(stderr, "Native method result check failed at line %d: %s\n", __LINE__, #condition); \
        exit(1); \
    } \
} while (0)

static void checkResult(BOOL applied, BOOL expected) {
    NSNumber *result = MixBooleanResult(applied);
    // StandardMethodCodec checks this type ID before encoding true/false.
    CHECK(CFGetTypeID((__bridge CFTypeRef)result) == CFBooleanGetTypeID());
    CHECK(result.boolValue == expected);
}

static void checkPreparationEvents(void) {
    // Exercise the event payload builder used by AudioPlayer, including its
    // nested ready field. Dart compares this field to true, so integer 1 fails.
    NSInteger readyStatus = 1;
    NSInteger failedStatus = 2;
    for (NSNumber *status in @[@(readyStatus), @(failedStatus)]) {
        BOOL ready = status.integerValue == readyStatus;
        NSInteger errorCode = ready ? 0 : -1004;
        NSDictionary *event = MixPreparationEvent(@"next-source", 1,
            status.integerValue == readyStatus, errorCode);
        CHECK([event[@"sourceId"] isEqualToString:@"next-source"]);
        CHECK([event[@"index"] integerValue] == 1);
        CHECK([event[@"code"] integerValue] == errorCode);
        CHECK(CFGetTypeID((__bridge CFTypeRef)event[@"ready"]) == CFBooleanGetTypeID());
        CHECK([event[@"ready"] boolValue] == ready);
        CHECK(CFGetTypeID((__bridge CFTypeRef)event[@"index"]) != CFBooleanGetTypeID());
        CHECK(CFGetTypeID((__bridge CFTypeRef)event[@"code"]) != CFBooleanGetTypeID());
    }
    NSNumber *legacyReady = @(readyStatus == 1);
    CHECK(legacyReady.boolValue);
    CHECK(CFGetTypeID((__bridge CFTypeRef)legacyReady) != CFBooleanGetTypeID());
}

int main(void) {
    @autoreleasepool {
        // Success, a refused mutation and a missing player must all be bools.
        BOOL playerExists = YES;
        checkResult(playerExists && YES, YES);
        checkResult(playerExists && NO, NO);
        playerExists = NO;
        checkResult(playerExists && YES, NO);

        // The old boxing passes a value-only check but reaches Dart as an int.
        NSNumber *legacyResult = @(playerExists && YES);
        CHECK(!legacyResult.boolValue);
        CHECK(CFGetTypeID((__bridge CFTypeRef)legacyResult) != CFBooleanGetTypeID());
        checkPreparationEvents();
        printf("Native method result checks passed: %u\n", checks);
    }
    return 0;
}
