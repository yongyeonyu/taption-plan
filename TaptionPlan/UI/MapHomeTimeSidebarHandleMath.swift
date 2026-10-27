import CoreGraphics

/// 시간 사이드바 손잡이(선택 시각)의 세로 위치.
///
/// 창을 세로로 끄는 동안에만 손잡이를 트랙 가운데에 붙인다. 그때는 창이 손가락을
/// 따라 움직이고 선택 시각은 가운데 시각으로 다시 계산되므로, 가운데에 고정해야
/// 손잡이가 손가락 밑에 머문다.
///
/// 확대만 했을 때까지 가운데에 붙이면, 선택 시각이 창의 가운데가 아닐 때(시간이
/// 흘러 지금이 창 아래쪽으로 내려갔거나, 자정·지금 경계에서 창이 밀린 경우)
/// 손잡이는 가운데에 있는데 그 자리의 눈금은 다른 시각을 가리킨다. 지도는 선택
/// 시각을, 사이드바는 창의 가운데 시각을 보여 주던 원인이다(대표 지적, 2026-10-27).
enum MapHomeTimeSidebarHandleMath {
    static func y(
        minute: Int,
        window: ClosedRange<Int>,
        trackHeight: CGFloat,
        verticalInset: CGFloat,
        isViewportDragging: Bool
    ) -> CGFloat {
        guard !isViewportDragging else { return verticalInset + trackHeight / 2 }
        return verticalInset + trackHeight * MapHomeTimeSidebarMath.position(
            minute: minute,
            window: window
        )
    }
}

/// 시간선 창을 진단에 남긴다. 확대 단계·손잡이 위치·「현재 위치」 되돌림은
/// 화면으로만 확인할 수 있었으므로 다음 로그에서 값으로 판정한다(2026-10-28).
///
/// `handle_ratio`는 화면이 손잡이를 그리는 비율과 같은 함수로 만든다. 로그의
/// 값과 눈에 보이는 위치가 어긋나면 그 자체가 버그다.
enum MapHomeTimelineWindowRecord {
    struct Payload: Equatable {
        let fields: [String: String]
        let metrics: [String: Double]
    }

    static func payload(
        source: String,
        startMinute: Int,
        durationMinutes: Int,
        selectedMinute: Int?
    ) -> Payload {
        let window = startMinute...(startMinute + durationMinutes)
        return Payload(
            fields: [
                "source": source,
                "window": "\(window.lowerBound)-\(window.upperBound)",
                "selected": selectedMinute.map(String.init) ?? "none",
            ],
            metrics: [
                "start_minute": Double(startMinute),
                "duration_minutes": Double(durationMinutes),
                "handle_ratio": selectedMinute.map {
                    Double(MapHomeTimeSidebarMath.position(minute: $0, window: window))
                } ?? -1,
            ]
        )
    }

    static func write(
        source: String,
        startMinute: Int,
        durationMinutes: Int,
        selectedMinute: Int?
    ) {
        let payload = payload(
            source: source,
            startMinute: startMinute,
            durationMinutes: durationMinutes,
            selectedMinute: selectedMinute
        )
        TaptionPlanDiagnosticsLogger.shared.record(
            "timeline_window",
            fields: payload.fields,
            metrics: payload.metrics
        )
    }
}
