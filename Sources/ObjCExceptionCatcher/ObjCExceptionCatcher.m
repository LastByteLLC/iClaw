#import "ObjCExceptionCatcher.h"

BOOL ObjCTryCatch(void (NS_NOESCAPE ^_Nonnull block)(void),
                  NSError *_Nullable *_Nullable outError) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"ObjCException"
                                            code:1
                                        userInfo:@{
                NSLocalizedDescriptionKey: exception.reason ?: exception.name
            }];
        }
        return NO;
    }
}
