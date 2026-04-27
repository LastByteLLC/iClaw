#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Executes a block, catching any ObjC NSException and returning it as an NSError.
/// Returns YES on success, NO if an exception was caught.
FOUNDATION_EXPORT BOOL ObjCTryCatch(void (NS_NOESCAPE ^_Nonnull block)(void),
                                    NSError *_Nullable *_Nullable outError);

NS_ASSUME_NONNULL_END
