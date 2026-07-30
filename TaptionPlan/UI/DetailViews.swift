import SwiftUI

struct QuickActionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let item: QuickActionItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(Color(red: 0.84, green: 0.84, blue: 0.86))
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 14)

            Text(item.title)
                .font(.system(size: 16, weight: .bold))
                .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.time)
                    .font(.system(size: 15, weight: .bold))
                Text(item.context)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.tpSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Color.tpBackground, in: RoundedRectangle(cornerRadius: 13))
            .padding(.bottom, 12)

            Button {
                dismiss()
                Task { @MainActor in
                    model.detail = .memo
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "note.text")
                        .font(.system(size: 15))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("메모 2개")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(Color.tpInk)
                        Text("마지막 기록 · 오늘 16:40")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.tpSecondary)
                    }
                    Spacer()
                    Text("보기")
                        .font(.system(size: 9.5, weight: .bold))
                }
                .foregroundStyle(Color.tpStudyDark)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(
                    Color(red: 0.95, green: 0.94, blue: 0.97),
                    in: RoundedRectangle(cornerRadius: 12)
                )
            }
            .buttonStyle(.plain)
            .padding(.bottom, 10)

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 8
            ) {
                actionButton("play.fill", "시작", style: .primary)
                actionButton("checkmark", "했어요")
                actionButton("clock", "30분 미루기", style: .health)
                actionButton("location.north", "다음 빈 시간")
                actionButton("note.text", "메모") {
                    dismiss()
                    Task { @MainActor in model.detail = .memo }
                }
                actionButton("arrow.counterclockwise", "오늘은 건너뜀")
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 28)
        .presentationDetents([.height(390)])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(22)
    }

    private enum ActionStyle {
        case regular
        case primary
        case health
    }

    private func actionButton(
        _ icon: String,
        _ title: String,
        style: ActionStyle = .regular,
        action: @escaping () -> Void = {}
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(style == .primary ? Color.white : style == .health ? Color(red: 0.55, green: 0.20, blue: 0.16) : Color.tpInk)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    style == .primary ? Color.tpInk : style == .health ? Color.tpExercise : Color(red: 0.94, green: 0.94, blue: 0.95),
                    in: RoundedRectangle(cornerRadius: 12)
                )
        }
        .buttonStyle(.plain)
    }
}

struct MemoDetailView: View {
    @Bindable var model: AppModel
    @State private var selectedTag = "결정"
    @State private var memo = ""

    private let tags = ["결정", "아이디어", "막힘", "다음 할 일"]

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(title: "액션 메모", trailing: "완료", trailingColor: Color(red: 0.20, green: 0.47, blue: 0.72)) {
                model.detail = nil
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("프로젝트 · 오늘 09:00–12:00")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(Color.tpProjectDark)
                        Text("신제품 기획")
                            .font(.system(size: 16, weight: .bold))
                        Text("2026년 출시 목표 › 이번 주 기획안 확정")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.tpSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .draftCard(radius: 15)

                    HStack(spacing: 5) {
                        ForEach(tags, id: \.self) { tag in
                            Button {
                                selectedTag = tag
                            } label: {
                                Text(tag)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(selectedTag == tag ? Color(red: 0.36, green: 0.27, blue: 0.49) : Color.tpSecondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 7)
                                    .background(
                                        selectedTag == tag ? Color.tpStudy : Color(red: 0.92, green: 0.92, blue: 0.93),
                                        in: RoundedRectangle(cornerRadius: 9)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    VStack(spacing: 8) {
                        memoEntry("09:20", tag: "결정", body: "첫 버전은 iPhone부터 출시하고 기능을 단계적으로 연다.")
                        memoEntry("14:10", tag: "아이디어", body: "위젯의 현재선 위에서 고양이가 짧게 달리게 한다.")
                        memoEntry("16:40", tag: "다음 할 일", body: "위치·날씨 권한 안내 문구와 개인정보 범위를 확인한다.")
                    }

                    VStack(spacing: 8) {
                        TextField("이 액션 아이템에 짧은 메모 남기기…", text: $memo, axis: .vertical)
                            .font(.system(size: 11))
                            .lineLimit(2...3)
                            .padding(.horizontal, 2)
                            .frame(minHeight: 40, alignment: .top)

                        Rectangle().fill(Color(red: 0.93, green: 0.93, blue: 0.95)).frame(height: 0.5)

                        HStack(spacing: 7) {
                            memoTool("mic", "음성")
                            memoTool("photo", "사진")
                            Spacer()
                            memoTool("plus", "추가", dark: true)
                        }
                    }
                    .padding(10)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 15))
                    .overlay {
                        RoundedRectangle(cornerRadius: 15)
                            .stroke(Color(red: 0.89, green: 0.89, blue: 0.91), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.07), radius: 8, y: 5)
                }
                .padding(12)
            }
            .background(Color.tpBackground)
        }
    }

    private func memoEntry(_ time: String, tag: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text(time)
                .font(.system(size: 9))
                .foregroundStyle(Color.tpSecondary)
                .frame(width: 38, alignment: .trailing)
                .padding(.top, 9)

            VStack(alignment: .leading, spacing: 3) {
                Text(tag)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.tpStudyDark)
                Text(body)
                    .font(.system(size: 11))
                    .lineSpacing(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .draftCard(radius: 12)
        }
    }

    private func memoTool(_ icon: String, _ title: String, dark: Bool = false) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(dark ? Color.white : Color.tpSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(dark ? Color.tpInk : Color(red: 0.94, green: 0.94, blue: 0.95))
            .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

struct CatPickerView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(title: "달리는 고양이", trailing: "완료") {
                model.detail = nil
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 9) {
                    Text("모양만 달라지고, 일정 위를 달리는 위치와 속도는 모두 같습니다.")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.tpSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)

                    VStack(spacing: 0) {
                        ZStack {
                            Rectangle()
                                .fill(.black.opacity(0.08))
                                .frame(height: 1)
                                .offset(y: 14)
                            RunningCatView(coat: model.selectedCatCoat)
                        }
                        .frame(height: 45)

                        Text("\(model.selectedCatCoat.rawValue) · 위젯 미리보기")
                            .font(.system(size: 11, weight: .bold))
                            .padding(.top, 7)
                        Text("선택한 모습이 홈 위젯 · 잠금 화면 · 앱에 함께 적용")
                            .font(.system(size: 7.5))
                            .foregroundStyle(Color.tpSecondary)
                            .padding(.top, 2)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(
                        LinearGradient(
                            colors: [
                                Color(red: 1.00, green: 0.97, blue: 0.91),
                                Color(red: 0.94, green: 0.91, blue: 0.97),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 15)
                    )

                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible())],
                        spacing: 6
                    ) {
                        ForEach(CatCoat.allCases) { coat in
                            Button {
                                model.selectedCatCoat = coat
                            } label: {
                                HStack(spacing: 9) {
                                    CatFaceView(coat: coat)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(coat.rawValue)
                                            .font(.system(size: 9.5, weight: .bold))
                                            .foregroundStyle(Color.tpInk)
                                        Text(coat.caption)
                                            .font(.system(size: 6.8))
                                            .foregroundStyle(Color.tpSecondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8)
                                .frame(maxWidth: .infinity, minHeight: 59)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(
                                            model.selectedCatCoat == coat ? Color.tpInk : Color(red: 0.89, green: 0.89, blue: 0.91),
                                            lineWidth: model.selectedCatCoat == coat ? 2 : 1
                                        )
                                }
                                .overlay(alignment: .topTrailing) {
                                    if model.selectedCatCoat == coat {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 8, weight: .black))
                                            .foregroundStyle(.white)
                                            .frame(width: 15, height: 15)
                                            .background(Color.tpInk, in: Circle())
                                            .padding(5)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Button {
                        model.detail = nil
                    } label: {
                        Text("\(model.selectedCatCoat.rawValue)로 적용")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.tpInk, in: RoundedRectangle(cornerRadius: 13))
                    }
                    .buttonStyle(.plain)

                    Label(
                        "설정에서 언제든 바꿀 수 있습니다. ‘동작 줄이기’가 켜지면 선택한 고양이가 정지 자세로 표시됩니다.",
                        systemImage: "paintpalette"
                    )
                    .font(.system(size: 7.3))
                    .foregroundStyle(Color.tpSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 12)
            }
            .background(Color.tpBackground)
        }
    }
}

struct InferenceDetailView: View {
    @Bindable var model: AppModel

    private let modes: [(String, String)] = [
        ("figure.walk", "걷기"), ("figure.run", "달리기"), ("bicycle", "자전거"),
        ("bus", "버스"), ("tram", "지하철"), ("car.side", "택시"),
        ("car", "자가용"), ("train.side.front.car", "기차"), ("airplane", "비행기"),
        ("ferry", "배"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(title: "자동 추정 상세", trailing: "완료") {
                model.detail = .locationTimeline
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    Text("이동은 아래 10종류만 사용합니다. 센서가 직접 구분하지 못하는 수단은 여러 신호를 합쳐 신뢰도와 함께 표시합니다.")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.tpSecondary)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 5) {
                        ForEach(Array(modes.enumerated()), id: \.offset) { _, mode in
                            VStack(spacing: 4) {
                                Image(systemName: mode.0)
                                    .font(.system(size: 15))
                                    .foregroundStyle(Color.tpTransitDark)
                                Text(mode.1)
                                    .font(.system(size: 7.5, weight: .bold))
                                    .foregroundStyle(Color(red: 0.40, green: 0.27, blue: 0.11))
                            }
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color(red: 0.89, green: 0.89, blue: 0.91), lineWidth: 1)
                            }
                        }
                    }

                    inferenceCard(
                        icon: "tram",
                        iconColor: .tpTransitDark,
                        iconBackground: .tpTransit,
                        time: "08:18–08:56",
                        title: "지하철 · 38분",
                        confidence: "높음",
                        high: true,
                        signals: ["역 진입", "GPS 약화", "상대고도 −18m", "철도 경로 일치", "전후 보행"],
                        yes: "맞아요",
                        no: "다른 수단"
                    )

                    inferenceCard(
                        icon: "building.2",
                        iconColor: .tpPlaceDark,
                        iconBackground: .tpPlace,
                        time: "11:03 · 같은 건물 안",
                        title: "회사 9층 → 10층",
                        confidence: "중간",
                        high: false,
                        signals: ["상대고도 +3.1m", "1층 ≈ 3m", "10층 정지 2h 48m", "기준층 확인됨"],
                        yes: "10층 맞아요",
                        no: "층 수정"
                    )

                    Label(
                        "iPhone GPS·모션·기압이 기본 · Apple Watch 운동·경로·활동 데이터는 권한을 받은 경우에만 보조",
                        systemImage: "applewatch"
                    )
                    .font(.system(size: 7.5))
                    .foregroundStyle(Color.tpSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    privacyCard
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 12)
            }
            .background(Color.tpBackground)
        }
    }

    private func inferenceCard(
        icon: String,
        iconColor: Color,
        iconBackground: Color,
        time: String,
        title: String,
        confidence: String,
        high: Bool,
        signals: [String],
        yes: String,
        no: String
    ) -> some View {
        VStack(spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(iconColor)
                    .frame(width: 29, height: 29)
                    .background(iconBackground, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(time)
                        .font(.system(size: 8))
                        .foregroundStyle(Color.tpSecondary)
                    Text(title)
                        .font(.system(size: 11, weight: .bold))
                }
                Spacer()
                Text(confidence)
                    .font(.system(size: 7.5, weight: .black))
                    .foregroundStyle(high ? Color(red: 0.18, green: 0.46, blue: 0.28) : Color(red: 0.61, green: 0.41, blue: 0.11))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        high
                            ? Color(red: 0.92, green: 0.96, blue: 0.93)
                            : Color(red: 1.00, green: 0.95, blue: 0.85),
                        in: RoundedRectangle(cornerRadius: 7)
                    )
            }

            ChipFlowLayout(spacing: 4) {
                ForEach(signals, id: \.self) { signal in
                    Text(signal)
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(Color.tpSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(
                            Color(red: 0.94, green: 0.94, blue: 0.95),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                }
            }

            HStack(spacing: 6) {
                Text(yes)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(Color.tpInk, in: RoundedRectangle(cornerRadius: 9))
                Text(no)
                    .foregroundStyle(Color.tpSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        Color(red: 0.94, green: 0.94, blue: 0.95),
                        in: RoundedRectangle(cornerRadius: 9)
                    )
            }
            .font(.system(size: 8.5, weight: .bold))
        }
        .padding(10)
        .draftCard()
    }

    private var privacyCard: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock")
                .font(.system(size: 15))
                .foregroundStyle(Color.tpPlaceDark)
            VStack(alignment: .leading, spacing: 2) {
                Text("모르면 확정하지 않음")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Text("‘차량 추정’ 또는 ‘층 미확인’으로 남기고 한 번 탭해 수정")
                    .font(.system(size: 8))
                    .foregroundStyle(Color.tpSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(Color(red: 0.89, green: 0.89, blue: 0.91), lineWidth: 1)
        }
    }
}

struct LocationTimelineView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            DraftTopBar(
                title: "7월 30일 목요일",
                trailing: "2026",
                selectedScale: .day,
                onScaleChange: {
                    model.selectedScale = $0
                    model.detail = nil
                }
            )

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Button {
                        model.detail = .inference
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "mappin.and.ellipse")
                                .foregroundStyle(Color(red: 0.18, green: 0.54, blue: 0.36))
                            Text("위치·이동 추정 중")
                                .fontWeight(.bold)
                            Spacer()
                            Text("GPS · 모션 · 기압 · Watch")
                                .font(.system(size: 9.5))
                                .foregroundStyle(Color.tpSecondary)
                        }
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color(red: 0.14, green: 0.37, blue: 0.49))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            Color(red: 0.93, green: 0.97, blue: 0.98),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.top, 9)
                    .padding(.bottom, 7)

                    compactTimeAxis

                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            placeRow
                            moveRow
                            projectRow
                        }
                        currentLocationLine
                    }
                    .frame(height: 208)

                    routeDock
                        .padding(.horizontal, 8)
                        .padding(.top, 9)

                    HStack(spacing: 6) {
                        Image(systemName: "lock")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.tpPlaceDark)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("센서 결과는 신뢰도와 함께 기기 안에서 정리")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.tpInk)
                            Text("정확한 주소·원시 좌표는 기본 타임라인에 표시하지 않음")
                                .font(.system(size: 8))
                        }
                    }
                    .foregroundStyle(Color.tpSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 11))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11)
                            .stroke(Color(red: 0.89, green: 0.89, blue: 0.91), lineWidth: 1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }
            .background(Color.white)
        }
    }

    private var compactTimeAxis: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 50)
            ForEach(["06", "09", "12", "15", "18", "21"], id: \.self) { label in
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.tpSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 28)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.tpLine).frame(height: 0.5) }
    }

    private var placeRow: some View {
        HStack(spacing: 0) {
            rowLabel("위치", color: .tpPlaceDark)
            GeometryReader { proxy in
                locationBar("집", 0, 0.14, proxy)
                locationBar("회사·9F", 0.26, 0.13, proxy)
                Rectangle()
                    .fill(Color.tpPlaceDark)
                    .frame(width: 2, height: 64)
                    .position(x: proxy.size.width * 0.395, y: 39)
                Text("↑ 1F")
                    .font(.system(size: 6.5, weight: .black))
                    .foregroundStyle(Color.tpPlaceDark)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.white, in: RoundedRectangle(cornerRadius: 7))
                    .overlay { RoundedRectangle(cornerRadius: 7).stroke(Color.tpPlaceDark.opacity(0.35)) }
                    .position(x: proxy.size.width * 0.36, y: 13)
                locationBar("회사·10F", 0.41, 0.25, proxy)
                locationBar("", 0.74, 0.08, proxy)
                locationBar("집", 0.91, 0.09, proxy)
            }
        }
        .frame(height: 78)
        .background(Color(red: 0.98, green: 0.99, blue: 1.00))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.tpLine.opacity(0.5)).frame(height: 0.5) }
    }

    private var moveRow: some View {
        HStack(spacing: 0) {
            rowLabel("이동", color: .tpTransitDark)
            GeometryReader { proxy in
                moveBar("figure.walk", 0.14, 0.04, proxy)
                moveBar("tram", 0.18, 0.06, proxy)
                moveBar("figure.walk", 0.245, 0.035, proxy)
                moveBar("car.side", 0.67, 0.06, proxy)
                moveBar("figure.walk", 0.83, 0.035, proxy)
                moveBar("car", 0.86, 0.05, proxy, dashed: true)
            }
        }
        .frame(height: 70)
        .background(Color(red: 1.00, green: 0.99, blue: 0.97))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.tpLine.opacity(0.5)).frame(height: 0.5) }
    }

    private var projectRow: some View {
        HStack(spacing: 0) {
            rowLabel("프로젝트", color: .tpProjectDark, compact: true)
            GeometryReader { proxy in
                simpleBar("신제품 기획", start: 0.27, length: 0.24, proxy: proxy)
                simpleBar("회의", start: 0.53, length: 0.12, proxy: proxy)
            }
        }
        .frame(height: 60)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.tpLine.opacity(0.5)).frame(height: 0.5) }
    }

    private var currentLocationLine: some View {
        GeometryReader { proxy in
            let x = proxy.size.width * 0.6125
            Rectangle()
                .fill(Color.tpNow)
                .frame(width: 2, height: proxy.size.height)
                .position(x: x, y: proxy.size.height / 2)
            Text("14:15")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.tpNow, in: Capsule())
                .position(x: x, y: 7)
        }
    }

    private var routeDock: some View {
        VStack(spacing: 0) {
            HStack {
                Text("오늘 움직인 경로")
                    .font(.system(size: 10.5, weight: .bold))
                Spacer()
                HStack(spacing: 3) {
                    Circle().fill(Color(red: 0.27, green: 0.83, blue: 0.51)).frame(width: 5, height: 5)
                    Text("위 시간축과 실시간 동기화")
                }
                .font(.system(size: 7.5))
                .foregroundStyle(Color(red: 0.56, green: 0.94, blue: 0.72))
            }
            .padding(.bottom, 4)

            HStack {
                ForEach(["06", "09", "12", "15", "18", "21"], id: \.self) { label in
                    Text(label).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.system(size: 6))
            .foregroundStyle(Color(red: 0.41, green: 0.41, blue: 0.44))

            GeometryReader { proxy in
                Rectangle()
                    .fill(Color(red: 0.27, green: 0.27, blue: 0.29))
                    .frame(height: 1)
                    .position(x: proxy.size.width / 2, y: 28)

                routeSegment(.tpPlaceDark, 0, 0.135, proxy)
                routeSegment(.tpTransitDark, 0.135, 0.014, proxy)
                routeSegment(Color(red: 0.95, green: 0.77, blue: 0.44), 0.149, 0.047, proxy)
                routeSegment(.tpTransitDark, 0.196, 0.009, proxy)
                routeSegment(.tpPlaceDark, 0.205, 0.135, proxy)
                routeSegment(Color(red: 0.56, green: 0.79, blue: 0.90), 0.34, 0.01, proxy)
                routeSegment(.tpPlaceDark, 0.35, 0.20, proxy)

                routeNode("집\n08:02", 0.135, above: true, proxy)
                routeNode("역삼역\n08:14", 0.149, above: false, proxy)
                routeNode("을지로입구\n08:56", 0.196, above: true, proxy)
                routeNode("회사·9F\n09:05", 0.205, above: false, proxy)
                routeNode("회사·10F\n11:03", 0.35, above: false, proxy)

                Rectangle()
                    .fill(Color.tpNow)
                    .frame(width: 2, height: 49)
                    .position(x: proxy.size.width * 0.55, y: 31)
                Circle()
                    .fill(Color.tpNow)
                    .frame(width: 12, height: 12)
                    .position(x: proxy.size.width * 0.55, y: 28)
                Text("14:15")
                    .font(.system(size: 6, weight: .black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.tpNow, in: RoundedRectangle(cornerRadius: 6))
                    .position(x: proxy.size.width * 0.60, y: 7)
            }
            .frame(height: 62)

            HStack {
                Text("길이 = 실제 시간 · 빨간 선 = 현재")
                Spacer()
                Text("밀면 위 간트도 함께 이동 ›")
                    .foregroundStyle(Color(red: 0.78, green: 0.78, blue: 0.80))
            }
            .font(.system(size: 6.8))
            .foregroundStyle(Color(red: 0.56, green: 0.56, blue: 0.58))
            .padding(.top, 6)
            .overlay(alignment: .top) {
                Rectangle().fill(Color(red: 0.19, green: 0.19, blue: 0.21)).frame(height: 0.5)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 10)
        .background(Color(red: 0.09, green: 0.09, blue: 0.10), in: RoundedRectangle(cornerRadius: 15))
        .shadow(color: .black.opacity(0.16), radius: 9, y: 6)
    }

    private func rowLabel(_ title: String, color: Color, compact: Bool = false) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 8, height: 8)
            Text(title)
                .font(.system(size: compact ? 9 : 10.5, weight: .semibold))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .padding(.leading, compact ? 4 : 8)
        .frame(width: 50, alignment: .leading)
    }

    private func locationBar(_ title: String, _ start: CGFloat, _ length: CGFloat, _ proxy: GeometryProxy) -> some View {
        Text(title)
            .font(.system(size: 9.5, weight: .black))
            .foregroundStyle(Color(red: 0.14, green: 0.37, blue: 0.49))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: max(17, proxy.size.width * length), height: 32)
            .background(Color.tpPlace, in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).stroke(Color.tpPlaceDark.opacity(0.35)) }
            .position(x: proxy.size.width * start + max(17, proxy.size.width * length) / 2, y: 31)
    }

    private func moveBar(_ icon: String, _ start: CGFloat, _ length: CGFloat, _ proxy: GeometryProxy, dashed: Bool = false) -> some View {
        Image(systemName: icon)
            .font(.system(size: 11))
            .foregroundStyle(Color(red: 0.44, green: 0.29, blue: 0.09))
            .frame(width: max(14, proxy.size.width * length), height: 29)
            .background(Color.tpTransit.opacity(dashed ? 0.68 : 1), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Color.tpTransitDark.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 2] : []))
            }
            .position(x: proxy.size.width * start + max(14, proxy.size.width * length) / 2, y: 32)
    }

    private func simpleBar(_ title: String, start: CGFloat, length: CGFloat, proxy: GeometryProxy) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Color.tpInk.opacity(0.64))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(width: max(18, proxy.size.width * length), height: 26, alignment: .leading)
            .background(Color.tpProject, in: RoundedRectangle(cornerRadius: 7))
            .position(x: proxy.size.width * start + max(18, proxy.size.width * length) / 2, y: 29)
    }

    private func routeSegment(_ color: Color, _ start: CGFloat, _ length: CGFloat, _ proxy: GeometryProxy) -> some View {
        Capsule()
            .fill(color)
            .frame(width: max(2, proxy.size.width * length), height: 7)
            .position(x: proxy.size.width * start + max(2, proxy.size.width * length) / 2, y: 28)
    }

    private func routeNode(_ title: String, _ position: CGFloat, above: Bool, _ proxy: GeometryProxy) -> some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.09, green: 0.09, blue: 0.10))
                .overlay { Circle().stroke(.white, lineWidth: 2) }
                .frame(width: 11, height: 11)
            Text(title)
                .font(.system(size: 6))
                .multilineTextAlignment(.center)
                .fixedSize()
                .offset(y: above ? -19 : 19)
        }
        .position(x: proxy.size.width * position, y: 28)
    }
}

struct WidgetPreviewView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(title: "위젯 미리보기", trailing: "완료") {
                model.detail = nil
            }

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("홈 화면 · 중간 위젯")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.tpInk.opacity(0.55))
                        .padding(.horizontal, 4)

                    widgetCard

                    Text("잠금 화면 · 현재 활동")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.tpInk.opacity(0.55))
                        .padding(.horizontal, 4)
                        .padding(.top, 12)

                    liveCard
                }
                .padding(14)
            }
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.86, green: 0.91, blue: 0.96),
                        Color(red: 0.93, green: 0.90, blue: 0.95),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }

    private var widgetCard: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 5) {
                    Text("지금의 시간표")
                        .font(.system(size: 13, weight: .bold))
                    Text("집중 중")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color(red: 0.57, green: 0.38, blue: 0.08))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(red: 1.00, green: 0.95, blue: 0.85), in: Capsule())
                    Text("\(model.selectedCatCoat.shortName) ▾")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.tpSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.white, in: Capsule())
                        .overlay { Capsule().stroke(Color.tpLine) }
                }
                Spacer()
                Label("23° · 14:05", systemImage: "cloud.sun")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.tpWeatherDark)
            }
            .padding(.bottom, 10)

            GeometryReader { proxy in
                Rectangle().fill(Color.tpLine).frame(height: 0.5).position(x: proxy.size.width / 2, y: 0)
                RunningCatView(coat: model.selectedCatCoat)
                    .position(x: proxy.size.width / 2, y: 19)
                FixedStripeBackground()
                    .frame(width: proxy.size.width * 0.28, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .position(x: proxy.size.width * 0.17, y: 53)
                Text("회의")
                    .font(.system(size: 10.5, weight: .semibold))
                    .position(x: proxy.size.width * 0.12, y: 53)
                RoundedRectangle(cornerRadius: 7).fill(Color.tpExercise)
                    .frame(width: proxy.size.width * 0.37, height: 26)
                    .position(x: proxy.size.width * 0.645, y: 53)
                Text("러닝")
                    .font(.system(size: 10.5, weight: .semibold))
                    .position(x: proxy.size.width * 0.55, y: 53)
                Rectangle().fill(Color.tpNow).frame(width: 2, height: 42)
                    .position(x: proxy.size.width / 2, y: 55)
            }
            .frame(height: 76)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.tpLine).frame(height: 0.5) }

            HStack(spacing: 7) {
                widgetAction("checkmark", "했어요")
                widgetAction("clock", "30분")
                widgetAction("location.north", "다음 빈 시간")
            }
            .padding(.top, 11)
        }
        .padding(14)
        .background(.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 8)
    }

    private func widgetAction(_ icon: String, _ title: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 10, weight: .bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color(red: 0.93, green: 0.93, blue: 0.94), in: RoundedRectangle(cornerRadius: 10))
    }

    private var liveCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("영어 공부").font(.system(size: 13, weight: .bold))
                Spacer()
                Text("38분 남음").font(.system(size: 11)).foregroundStyle(Color(red: 0.78, green: 0.78, blue: 0.80))
            }
            GeometryReader { proxy in
                Capsule().fill(Color(red: 0.21, green: 0.21, blue: 0.23))
                Capsule().fill(Color.tpStudyDark).frame(width: proxy.size.width * 0.62)
            }
            .frame(height: 6)
            .padding(.vertical, 13)
            HStack {
                Text("21:00 → 22:00").font(.system(size: 11))
                Spacer()
                Text("종료")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(Color(red: 0.08, green: 0.08, blue: 0.09), in: RoundedRectangle(cornerRadius: 18))
    }
}

struct OnboardingView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 5) {
                    Capsule().fill(Color.tpInk).frame(width: 34, height: 4)
                    Capsule().fill(Color(red: 0.85, green: 0.85, blue: 0.87)).frame(width: 22, height: 4)
                    Text("1 / 2 · 나에게 맞게 시작")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Color.tpSecondary)
                }

                Text("나와 비슷한 시작점을\n골라보세요")
                    .font(.system(size: 20, weight: .bold))
                Text("대표 조합만 먼저 보여드립니다. 선택한 뒤 언제든 역할·상황·목표를 바꿀 수 있습니다.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.tpSecondary)

                VStack(spacing: 7) {
                    personaCard("briefcase", second: "stroller", title: "회사원 + 육아", tags: ["역할 · 회사원", "상황 · 육아"], caption: "회의 · 집중업무 · 등하원 · 가족 일정", selected: true)
                    personaCard("graduationcap", second: "target", title: "학생 + 수능", tags: ["역할 · 학생", "목표 · 수능"], caption: "수업 · 과목 공부 · 기출 · 모의고사")
                    personaCard("briefcase", second: "medal", title: "회사원 + 자격증", tags: ["역할 · 회사원", "목표 · 자격증"], caption: "회의 · 집중업무 · 강의 · 문제풀이")
                    personaCard("plus", second: nil, title: "직접 조합", tags: [], caption: "역할 · 상황 · 목표를 각각 골라 만들기")
                }

                Button {
                    model.detail = .templateReview
                } label: {
                    Text("회사원 + 육아로 시작")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Color.tpInk, in: RoundedRectangle(cornerRadius: 13))
                }
                .buttonStyle(.plain)
            }
            .padding(14)
        }
        .background(Color.tpBackground)
        .safeAreaInset(edge: .top) {
            HStack {
                Button("닫기") { model.detail = nil }
                Spacer()
            }
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color.tpSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(Color.tpBackground)
        }
    }

    private func personaCard(
        _ icon: String,
        second: String?,
        title: String,
        tags: [String],
        caption: String,
        selected: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: -5) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.tpProjectDark)
                    .frame(width: 30, height: 30)
                    .background(Color.tpProject, in: RoundedRectangle(cornerRadius: 10))
                if let second {
                    Image(systemName: second)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.tpRelationshipDark)
                        .frame(width: 30, height: 30)
                        .background(Color.tpRelationship, in: RoundedRectangle(cornerRadius: 10))
                        .overlay { RoundedRectangle(cornerRadius: 10).stroke(.white, lineWidth: 2) }
                }
            }
            .frame(width: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .bold))
                HStack(spacing: 4) {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 7.5, weight: .black))
                            .foregroundStyle(tag.contains("역할") ? Color(red: 0.24, green: 0.44, blue: 0.53) : Color(red: 0.58, green: 0.32, blue: 0.47))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(tag.contains("역할") ? Color(red: 0.91, green: 0.95, blue: 0.97) : Color(red: 0.97, green: 0.91, blue: 0.95), in: Capsule())
                    }
                }
                Text(caption)
                    .font(.system(size: 8.5))
                    .foregroundStyle(Color.tpSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(minHeight: second == nil ? 52 : 72)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(selected ? Color.tpInk : Color.tpLine, lineWidth: selected ? 2 : 1)
        }
    }
}

struct TemplateReviewView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 5) {
                    Capsule().fill(Color(red: 0.85, green: 0.85, blue: 0.87)).frame(width: 22, height: 4)
                    Capsule().fill(Color.tpInk).frame(width: 34, height: 4)
                    Text("2 / 2 · 시작 구성 확인")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Color.tpSecondary)
                }
                Text("이렇게 시작할게요").font(.system(size: 20, weight: .bold))
                Text("모두 제안일 뿐입니다. 지금 끄거나 나중에 다시 바꿀 수 있습니다.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.tpSecondary)

                VStack(alignment: .leading, spacing: 7) {
                    Text("대표 조합").font(.system(size: 8.5)).foregroundStyle(Color.tpSecondary)
                    Text("회사원 + 육아").font(.system(size: 16, weight: .bold))
                    ChipFlowLayout {
                        ForEach(["업무", "돌봄", "이동", "건강", "휴식", "수면"], id: \.self) {
                            Text($0)
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(Color.tpSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(Color(red: 0.94, green: 0.94, blue: 0.95), in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(
                        colors: [Color(red: 0.95, green: 0.94, blue: 0.97), Color(red: 0.97, green: 0.91, blue: 0.94)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 16)
                )

                reviewSection("빠른 추가") {
                    HStack(spacing: 5) {
                        ForEach(["회의", "집중업무", "등하원", "가족 일정"], id: \.self) {
                            Text($0)
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(Color.tpSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(Color(red: 0.94, green: 0.94, blue: 0.95), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }

                reviewSection("연결과 개인정보") {
                    VStack(spacing: 0) {
                        reviewSetting("캘린더 일정 불러오기", value: "나중에 묻기")
                        reviewSetting("건강 수면·운동 비교", value: "나중에 묻기")
                        reviewSetting("위치 오래 머문 장소", value: "끔", off: true)
                        reviewSetting("일정 공유", value: "끔", off: true)
                    }
                }

                Button {
                    model.detail = nil
                } label: {
                    Text("이 구성으로 시작")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Color.tpInk, in: RoundedRectangle(cornerRadius: 13))
                }
                .buttonStyle(.plain)
            }
            .padding(14)
        }
        .background(Color.tpBackground)
    }

    private func reviewSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 10, weight: .bold))
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
    }

    private func reviewSetting(_ title: String, value: String, off: Bool = false) -> some View {
        HStack {
            Text(title).font(.system(size: 9.5)).foregroundStyle(Color.tpSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(off ? Color(red: 0.54, green: 0.36, blue: 0.20) : Color(red: 0.31, green: 0.44, blue: 0.57))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(off ? Color(red: 1.00, green: 0.95, blue: 0.90) : Color(red: 0.92, green: 0.96, blue: 1.00), in: Capsule())
        }
        .padding(.vertical, 6)
        .overlay(alignment: .top) { Rectangle().fill(Color.tpLine.opacity(0.6)).frame(height: 0.5) }
    }
}

private struct DetailHeader: View {
    let title: String
    let trailing: String
    var trailingColor: Color = .tpSecondary
    let action: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(Color.tpInk)
            Spacer()
            Button(trailing, action: action)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(trailingColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(Color.white)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.tpLine).frame(height: 0.5) }
    }
}
