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
        printf("Native method result checks passed: %u\n", checks);
    }
    return 0;
}
