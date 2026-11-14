import Foundation

// 등록부 동작 6묶음 — 시스템 (ACT1114A09)과 승인 항목을 바로 실행으로 (APV1114A16)의 읽기 쪽.
// 적용(`apply`)은 앱의 `AssistantCommandRunner.swift`에 있다(RMN1114A25). 권한 켜기·앱 잠금·PIN·전부 지우기는 넣지 않는다(대표 결정).

extension AssistantOperations {
    public static let system: [any AssistantOperationReading.Type] = [RefreshNow.self, StopTracking.self, DisconnectCalendar.self, RestoreFromBackup.self]

    /// 새로고침 단추와 iCloud 「지금 동기화」가 하는 일. 바뀌는 설정이 없어 되돌릴 것도 없다.
    public struct RefreshNow: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "refreshNow", fields: ["target"], counter: .settings, changes: 0,
            title: { $0.text("새로고침·iCloud 동기화 실행", "Refresh or run the iCloud sync") },
            guide: #""target":"records|cloud"} (what the refresh buttons do: records re-reads today's connected data, cloud starts an iCloud sync; changes no settings, nothing to undo)"#
        )

        public enum Target: String, Sendable { case records, cloud }
        public let target: Target

        public init?(fields: AssistantFields) {
            guard let target: Target = fields.choice("target") else { return nil }
            self.target = target
        }
    }

    /// 걷기·달리기 추적 끝내기(설정과 상세 패널의 「종료」와 같은 함수). 끝낸 기록은 남고 되돌릴 수 없다.
    public struct StopTracking: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "stopTracking", fields: [], counter: .edits,
            title: { $0.text("걷기·달리기 추적 끝내기", "Stop walk or run tracking") },
            guide: #"} (ends the walk or run I am tracking and saves it as a record; only when I asked; cannot be undone)"#
        )

        public init?(fields: AssistantFields) {}
    }

    /// 캘린더 연결 끊기: 기기 캘린더는 설정의 스위치를 끄는 것과, 구글은 「연결 끊기」와 같은 함수. 다시 잇기는 사용자가 한다.
    public struct DisconnectCalendar: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "disconnectCalendar", fields: ["calendar"], counter: .settings, deletes: true,
            title: { $0.text("캘린더 연결 끊기", "Disconnect calendars") },
            guide: #""calendar":"device|google"} (stops reading a calendar: device removes every iOS calendar from the app, google signs my Google account out; the events stay in the calendars; connecting again is done by me in the app; only when I asked; cannot be undone)"#
        )

        public enum Source: String, Sendable { case device, google }
        public let source: Source

        public init?(fields: AssistantFields) {
            guard let source: Source = fields.choice("calendar") else { return nil }
            self.source = source
        }
    }

    /// 백업에서 복원(대표 결정 2026-11-14): 백업 비밀번호가 필요하므로 AI는 「데이터 보호」 화면만 열고, 복원은 사용자가 그 화면에서 한다.
    /// 「지우는 일」 묶음에 있고 사용자가 켜기 전에는 꺼져 있다.
    public struct RestoreFromBackup: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "restoreFromBackup", fields: [], counter: .settings, deletes: true, startsOff: true, changes: 0,
            title: { $0.text("백업에서 복원 화면 열기", "Open restore from backup") },
            guide: #"} (opens the data protection screen so I can restore from a backup myself; I type the backup password in the app, never ask me for it; off until I switch it on under what the AI may do)"#
        )

        public init?(fields: AssistantFields) {}
    }
}

// 승인 요청(`requestApproval`)의 종류마다 하나씩이고 스위치가 꺼져 있으면 거절된다.
// 자료 공유를 넓히거나 보관을 늘리거나 되돌릴 수 없는 것은 사용자가 켜기 전에는 꺼져 있다. 전부 지우기·PIN 바꾸기는 승인 요청으로만 한다(대표 결정).
extension AssistantOperations {
    public static let direct: [any AssistantOperationReading.Type] = [
        LowerShareLevel.self, RaiseShareLevel.self, ShortenRetention.self, ExtendRetention.self, TurnOffHealth.self, OpenBackup.self,
    ]

    private static let ifOff = "if this is rejected as disabled I switched it off, so use requestApproval instead"
    private static let startsOffNote = "off until I switch it on under what the AI may do"

    public struct LowerShareLevel: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "lowerShareLevel", fields: ["level"], counter: .settings,
            title: { $0.text("AI 공유 수준 낮추기", "Lower AI sharing") },
            guide: #""level":"off|summary"} (shares less with you right away, no approval card; must be lower than settings.shareLevel; the days the server holds are deleted and sent again at the new level; only when I asked; undoable; \#(ifOff) with request shareLevel)"#
        )

        public let level: AssistantShareLevel

        public init?(fields: AssistantFields) {
            guard let level: AssistantShareLevel = fields.choice("level"), level != .visits else { return nil }
            self.level = level
        }
    }

    /// 더 많이 보내게 하는 일이라 사용자가 켜기 전에는 꺼져 있다.
    public struct RaiseShareLevel: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "raiseShareLevel", fields: ["level"], counter: .settings, startsOff: true,
            title: { $0.text("AI 공유 수준 높이기", "Raise AI sharing") },
            guide: #""level":"summary|visits"} (shares more with you right away; must be higher than settings.shareLevel; only when I asked; undoable; \#(startsOffNote); \#(ifOff) with request shareLevel)"#
        )

        public let level: AssistantShareLevel

        public init?(fields: AssistantFields) {
            guard let level: AssistantShareLevel = fields.choice("level"), level != .off else { return nil }
            self.level = level
        }
    }

    public struct ShortenRetention: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "shortenRetention", fields: ["days"], counter: .settings,
            title: { $0.text("서버 보관 기간 줄이기", "Shorten server retention") },
            guide: #""days":7} (keeps my days on the server for a shorter time, 1 or 7; must be shorter than settings.retentionDays; the days the server holds are deleted and sent again; only when I asked; undoable; \#(ifOff) with request retentionDays)"#
        )

        public let days: AssistantRetention

        public init?(fields: AssistantFields) {
            guard let days = fields.integer("days", in: 1...7).flatMap(AssistantRetention.init(rawValue:)) else { return nil }
            self.days = days
        }
    }

    /// 서버에 더 오래 두는 일이라 사용자가 켜기 전에는 꺼져 있다.
    public struct ExtendRetention: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "extendRetention", fields: ["days"], counter: .settings, startsOff: true,
            title: { $0.text("서버 보관 기간 늘리기", "Extend server retention") },
            guide: #""days":30} (keeps my days on the server for a longer time, 7 or 30; must be longer than settings.retentionDays; only when I asked; undoable; \#(startsOffNote); \#(ifOff) with request retentionDays)"#
        )

        public let days: AssistantRetention

        public init?(fields: AssistantFields) {
            guard let days = fields.integer("days", in: 7...30).flatMap(AssistantRetention.init(rawValue:)) else { return nil }
            self.days = days
        }
    }

    /// 건강 연동 끄기(설정의 스위치와 같은 함수). 가져온 기록이 지워지고 다시 켜기는 사용자가 하므로 되돌릴 수 없다.
    public struct TurnOffHealth: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "turnOffHealth", fields: [], counter: .settings, deletes: true, startsOff: true,
            title: { $0.text("건강 연동 끄기(가져온 기록 삭제)", "Turn off Health sync (removes imported records)") },
            guide: #"} (stops the Health sync right away and removes the records brought from Health and Apple Watch from the app; turning it on again is done by me; only when I asked; cannot be undone; \#(startsOffNote); \#(ifOff) with request healthOff)"#
        )

        public init?(fields: AssistantFields) {}
    }

    /// 백업은 비밀번호가 필요하므로 AI는 「데이터 보호」 화면만 열고, 백업은 사용자가 그 화면에서 한다.
    public struct OpenBackup: AssistantOperationReading {
        public static let spec = AssistantOperationSpec(
            name: "openBackup", fields: [], counter: .settings, changes: 0,
            title: { $0.text("백업 화면 열기", "Open the backup screen") },
            guide: #"} (opens the data protection screen so I can make a backup myself; I type the backup password in the app, never ask me for it; changes no data; \#(ifOff) with request backup)"#
        )

        public init?(fields: AssistantFields) {}
    }
}
