#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const WatchObjCExceptionDomain;

/// CoreMotion의 `accelerometerDataFromDate:toDate:`는 잘못된 요청에
/// NSError가 아니라 Objective-C 예외로 답한다. Swift에는 이 예외를 잡을
/// 문법이 없어 프로세스가 그대로 끝난다(빌드 29 실기기 크래시).
/// @try/@catch를 가진 얇은 Objective-C 층을 하나 두고 위험한 호출만
/// 여기로 통과시킨다.
///
/// 예외가 Swift 프레임을 거슬러 풀리면 그 프레임의 해제는 건너뛴다.
/// 그러므로 이 층은 마지막 안전망일 뿐이고, 잘못된 요청을 애초에 만들지
/// 않는 것은 `WatchSensorQueryPlan`의 몫이다.
@interface WatchObjCExceptionCatcher : NSObject

/// `block`을 @try 안에서 실행한다. NSException이 올라오면 잡아서
/// `WatchObjCExceptionDomain` NSError로 바꾼다.
+ (BOOL)catching:(NS_NOESCAPE void (^)(void))block error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
