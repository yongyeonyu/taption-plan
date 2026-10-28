import Foundation

/// 화면 시험에서만 쓰는 하루 재생 배속 조절.
///
/// 하루 재생은 24초짜리다. 시험이 「멈춤」을 찾고 스크린샷을 붙이고 하단 단추를
/// 세는 사이에 재생이 스스로 끝나 버려, `testPlayTogglesInOneSlotAndMapMoveCancelsIt`이
/// 시각에 따라 실패했다(2026-10-28 두 번). 시험은 `-slowDayPlayback` 인자로
/// 배속을 10분의 1로 늦춰 그 경합을 없앤다. 인자가 없으면 1이라 실사용 배속은 그대로다.
///
/// `durationSeconds`(HUD의 "하루 24초" 글자)는 건드리지 않는다. 시험이 그 글자를
/// 찾아 재생 중임을 확인하기 때문이다. 그래서 시험 모드에서만 HUD 글자와 실제
/// 길이가 어긋나는데, 시험은 글자를 확인용으로만 쓴다.
enum MapHomeDayPlaybackTestHooks {
    static var rateScale: Double {
        ProcessInfo.processInfo.arguments.contains("-slowDayPlayback") ? 0.1 : 1
    }
}
