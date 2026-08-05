#import "WatchObjCExceptionCatcher.h"

NSErrorDomain const WatchObjCExceptionDomain = @"WatchObjCException";

@implementation WatchObjCExceptionCatcher

+ (BOOL)catching:(NS_NOESCAPE void (^)(void))block error:(NSError **)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSString *reason = exception.reason ?: @"";
            *error = [NSError
                errorWithDomain:WatchObjCExceptionDomain
                           code:0
                       userInfo:@{
                           NSLocalizedDescriptionKey:
                               [NSString stringWithFormat:@"%@: %@",
                                                          exception.name,
                                                          reason],
                           NSLocalizedFailureReasonErrorKey: exception.name,
                       }];
        }
        return NO;
    }
}

@end
