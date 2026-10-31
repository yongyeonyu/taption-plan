// 워치 공유 모델은 `Packages/TaptionWatchSync`에 있다(명령 프로토콜·outbox/spool·행동 규칙·언어 설정).
// 이 파일은 앱·위젯·워치·워치 위젯 전체에 패키지를 다시 내보내, 쓰는 파일마다 import를 늘리지 않게 한다.
// CoreML 행동 모델(`TaptionWatchBehaviorML`)은 워치 앱만 링크한다.
@_exported import TaptionWatchSync
