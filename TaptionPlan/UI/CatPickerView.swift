import SwiftUI

struct CatPickerView: View {
    @Bindable var model: AppModel
    @State private var previewAction: TaptionWidgetCatAction = .running

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(title: "달리는 고양이", trailing: "완료") {
                model.detail = nil
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 9) {
                    Text("좌우 화살표로 위젯에서 사용하는 모든 고양이 동작을 미리 볼 수 있습니다.")
                        .font(.taption(size: 9))
                        .foregroundStyle(Color.tpSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)

                    VStack(spacing: 0) {
                        CatActionPreviewStage(
                            coat: model.selectedCatCoat,
                            action: previewAction,
                            reducesMotion: model.settings.reduceMotion
                        )
                        .id(previewAction)
                        .frame(height: 60)

                        HStack(spacing: 12) {
                            previewArrow(
                                systemImage: "chevron.left",
                                accessibilityLabel: "이전 동작"
                            ) {
                                movePreviewAction(by: -1)
                            }

                            VStack(spacing: 2) {
                                Label(
                                    previewAction.previewTitle,
                                    systemImage: previewAction.previewSystemImage
                                )
                                .font(.taption(size: 11, weight: .bold))
                                .foregroundStyle(Color.tpInk)
                                Text(previewPositionLabel)
                                    .font(.taption(size: 7.5, weight: .semibold))
                                    .foregroundStyle(Color.tpSecondary)
                                    .monospacedDigit()
                            }
                            .frame(maxWidth: .infinity)

                            previewArrow(
                                systemImage: "chevron.right",
                                accessibilityLabel: "다음 동작"
                            ) {
                                movePreviewAction(by: 1)
                            }
                        }
                        .padding(.top, 4)

                        Text("\(model.selectedCatCoat.rawValue) · 위젯 미리보기")
                            .font(.taption(size: 9, weight: .semibold))
                            .foregroundStyle(Color.tpSecondary)
                            .padding(.top, 7)
                        Text("선택한 모습이 홈 위젯 · 잠금 화면 · 앱에 함께 적용")
                            .font(.taption(size: 7.5))
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
                        ForEach(CatCoat.characters) { coat in
                            Button {
                                model.selectCatCoat(coat)
                            } label: {
                                HStack(spacing: 9) {
                                    CatFaceView(coat: coat)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(coat.displayName)
                                            .font(.taption(size: 9.5, weight: .bold))
                                            .foregroundStyle(Color.tpInk)
                                        Text(coat.caption)
                                            .font(.taption(size: 6.8))
                                            .foregroundStyle(Color.tpSecondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8)
                                .frame(maxWidth: .infinity, minHeight: 59)
                                .background(Color.tpCard, in: RoundedRectangle(cornerRadius: TaptionRadius.panel))
                                .overlay {
                                    RoundedRectangle(cornerRadius: TaptionRadius.panel)
                                        .stroke(
                                            model.selectedCatCoat == coat ? Color.tpInk : Color.tpControlStroke,
                                            lineWidth: model.selectedCatCoat == coat ? 2 : 1
                                        )
                                }
                                .overlay(alignment: .topTrailing) {
                                    if model.selectedCatCoat == coat {
                                        Image(systemName: "checkmark")
                                            .accessibilityLabel("선택됨")
                                            .font(.taption(size: 8, weight: .black))
                                            .foregroundStyle(.white)
                                            .frame(width: 15, height: 15)
                                            .background(Color.tpPrimaryFill, in: Circle())
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
                            .font(.taption(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.tpPrimaryFill, in: RoundedRectangle(cornerRadius: TaptionRadius.tile))
                    }
                    .buttonStyle(.plain)

                    Label(
                        "설정에서 언제든 바꿀 수 있습니다. ‘동작 줄이기’가 켜지면 선택한 고양이가 정지 자세로 표시됩니다.",
                        systemImage: "paintpalette"
                    )
                    .font(.taption(size: 7.3))
                    .foregroundStyle(Color.tpSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 12)
            }
            .background(Color.tpBackground)
        }
    }

    private var previewPositionLabel: String {
        guard let index = TaptionWidgetCatAction.allCases.firstIndex(
            of: previewAction
        ) else {
            return ""
        }
        return "\(index + 1) / \(TaptionWidgetCatAction.allCases.count)"
    }

    private func movePreviewAction(by offset: Int) {
        let actions = TaptionWidgetCatAction.allCases
        guard let index = actions.firstIndex(of: previewAction) else {
            previewAction = .running
            return
        }
        let next = (index + offset + actions.count) % actions.count
        previewAction = actions[next]
    }

    private func previewArrow(
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.taption(size: 12, weight: .black))
                .foregroundStyle(Color.tpInk)
                .frame(width: 34, height: 34)
                .background(Color.tpCard.opacity(0.78), in: Circle())
                .overlay { Circle().stroke(Color.tpLine, lineWidth: 1) }
                .taptionTouchTarget(visualWidth: 34, visualHeight: 34)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}
