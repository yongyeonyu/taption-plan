import SwiftData
import SwiftUI

struct AddPlanSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var title = ""
    @State private var category = PlanCategory.study
    @State private var durationMinutes = 60
    @State private var path: [AddRoute] = []
    @State private var selectedDetent: PresentationDetent = .height(330)
    @FocusState private var titleFocused: Bool

    var body: some View {
        NavigationStack(path: $path) {
            rootSheet
                .navigationDestination(for: AddRoute.self) { route in
                    switch route {
                    case .category:
                        CategoryPickerScreen(
                            selection: $category,
                            onSelect: {
                                path.removeLast()
                                selectedDetent = .height(330)
                            },
                            onCustom: { path.append(.customCategory) },
                            onCancel: {
                                path.removeLast()
                                selectedDetent = .height(330)
                            }
                        )
                    case .customCategory:
                        CustomCategoryScreen {
                            category = .hobby
                            path.removeAll()
                            selectedDetent = .height(330)
                        } onCancel: {
                            path.removeLast()
                        }
                    case .time:
                        TimeSliderScreen(durationMinutes: $durationMinutes) {
                            path.removeLast()
                            selectedDetent = .height(330)
                        }
                    }
                }
                .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.height(330), .large], selection: $selectedDetent)
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(22)
        .onAppear {
            titleFocused = true
        }
    }

    private var rootSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(Color(red: 0.84, green: 0.84, blue: 0.86))
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 14)

            HStack(spacing: 0) {
                TextField("계획 이름", text: $title)
                    .font(.system(size: 17, weight: .semibold))
                    .focused($titleFocused)
                    .submitLabel(.done)
                    .onSubmit(addPlan)

                if !title.isEmpty {
                    Button {
                        title = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.tpSecondary.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 9)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.tpInk).frame(height: 2)
            }
            .padding(.bottom, 8)

            Button {
                titleFocused = false
                selectedDetent = .large
                path.append(.category)
            } label: {
                HStack(spacing: 8) {
                    Text("대분류")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.tpSecondary)
                    Spacer()
                    Label(category.rawValue, systemImage: category.systemImage)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.tpInk)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(red: 0.68, green: 0.68, blue: 0.70))
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 10)
                .overlay {
                    VStack {
                        Rectangle().fill(Color.tpLine).frame(height: 0.5)
                        Spacer()
                        Rectangle().fill(Color.tpLine).frame(height: 0.5)
                    }
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 7) {
                DraftChip(title: "오늘 21:00", selected: true)
                DraftChip(title: "30분", selected: durationMinutes == 30)
                    .onTapGesture { durationMinutes = 30 }
                DraftChip(title: "1시간", selected: durationMinutes == 60)
                    .onTapGesture { durationMinutes = 60 }
                DraftChip(title: "2시간", selected: durationMinutes == 120)
                    .onTapGesture { durationMinutes = 120 }
                DraftChip(title: "슬라이더…")
                    .onTapGesture {
                        titleFocused = false
                        selectedDetent = .large
                        path.append(.time)
                    }
            }
            .padding(.top, 10)

            HStack(spacing: 7) {
                Text("최근")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.tpSecondary)
                DraftChip(title: "러닝")
                DraftChip(title: "영어 공부")
                DraftChip(title: "독서")
            }
            .padding(.top, 6)

            HStack(spacing: 7) {
                Text("상위 목표")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.tpSecondary)
                DraftChip(title: "자격증 취득", selected: true)
                DraftChip(title: "없음")
                Spacer()
            }
            .padding(.top, 6)

            Spacer(minLength: 0)

            HStack {
                Button("취소") { dismiss() }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                Spacer()
                Button("추가", action: addPlan)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.tpSecondary : Color.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.tpLine : Color.tpInk,
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(Color.white)
    }

    private func addPlan() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }

        let startAt = Date.now
        modelContext.insert(
            PlanItem(
                title: cleanTitle,
                startAt: startAt,
                endAt: startAt.addingTimeInterval(TimeInterval(durationMinutes * 60)),
                category: category
            )
        )
        dismiss()
    }
}

private enum AddRoute: Hashable {
    case category
    case customCategory
    case time
}

private struct CategoryPickerScreen: View {
    @Binding var selection: PlanCategory
    let onSelect: () -> Void
    let onCustom: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            pickerHeader("대분류 선택", trailing: "취소", action: onCancel)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    Text("영어 공부에 가장 가까운 대분류 하나를 선택하세요. 선택 후 항목 추가 화면으로 바로 돌아갑니다.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.tpSecondary)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                        spacing: 8
                    ) {
                        ForEach(PlanCategory.allCases) { category in
                            Button {
                                selection = category
                            } label: {
                                Label(category.rawValue, systemImage: category.systemImage)
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundStyle(Color.tpInk)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(category.color, in: RoundedRectangle(cornerRadius: 10))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(
                                                selection == category ? Color.tpInk : Color.tpLine,
                                                lineWidth: selection == category ? 2 : 1
                                            )
                                    }
                            }
                            .buttonStyle(.plain)
                        }

                        Button(action: onCustom) {
                            Label("직접 추가", systemImage: "plus")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(Color.tpSecondary)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.tpSecondary.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                }
                        }
                        .buttonStyle(.plain)
                    }

                    Button(action: onSelect) {
                        Text("\(selection.rawValue)으로 선택")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Color.tpInk, in: RoundedRectangle(cornerRadius: 13))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .background(Color.tpBackground)
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct CustomCategoryScreen: View {
    @State private var name = "봉사"
    @State private var selectedIcon = "person.2"
    @State private var selectedColor = 1

    let onSave: () -> Void
    let onCancel: () -> Void

    private let icons = [
        "briefcase", "building.2", "book", "graduationcap", "target", "medal",
        "stroller", "person.2", "shield", "heart.text.square", "dumbbell", "moon",
        "camera", "music.note", "airplane", "mappin.and.ellipse", "house", "fork.knife",
        "cup.and.saucer", "pawprint", "bag", "leaf", "calendar", "note.text",
    ]
    private let colors: [Color] = [
        .tpProject, Color(red: 0.85, green: 0.90, blue: 0.78), .tpExercise,
        .tpTravel, .tpStudy, .tpRelationship,
    ]

    var body: some View {
        VStack(spacing: 0) {
            pickerHeader("새 대분류", trailing: "취소", action: onCancel)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 9) {
                    HStack(spacing: 9) {
                        Image(systemName: selectedIcon)
                            .font(.system(size: 18))
                            .foregroundStyle(Color(red: 0.33, green: 0.46, blue: 0.24))
                            .frame(width: 34, height: 34)
                            .background(colors[selectedColor], in: RoundedRectangle(cornerRadius: 11))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("미리보기")
                                .font(.system(size: 9.5))
                                .foregroundStyle(Color.tpSecondary)
                            Text(name.isEmpty ? "새 대분류" : name)
                                .font(.system(size: 14, weight: .bold))
                        }
                        Spacer()
                    }
                    .padding(13)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 15))

                    HStack {
                        Text("이름")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.tpSecondary)
                        TextField("대분류 이름", text: $name)
                            .font(.system(size: 13, weight: .bold))
                            .multilineTextAlignment(.trailing)
                    }
                    .padding(11)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 9) {
                        Text("아이콘 · 24개")
                            .font(.system(size: 11, weight: .bold))
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 5) {
                            ForEach(icons, id: \.self) { icon in
                                Button {
                                    selectedIcon = icon
                                } label: {
                                    Image(systemName: icon)
                                        .font(.system(size: 15))
                                        .foregroundStyle(selectedIcon == icon ? Color.white : Color.tpSecondary)
                                        .frame(maxWidth: .infinity, minHeight: 31)
                                        .background(
                                            selectedIcon == icon ? Color.tpInk : Color(red: 0.94, green: 0.94, blue: 0.95),
                                            in: RoundedRectangle(cornerRadius: 9)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(11)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 13))

                    VStack(alignment: .leading, spacing: 9) {
                        Text("색상")
                            .font(.system(size: 11, weight: .bold))
                        HStack {
                            ForEach(colors.indices, id: \.self) { index in
                                Button {
                                    selectedColor = index
                                } label: {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(colors[index])
                                        .frame(width: 31, height: 31)
                                        .overlay {
                                            if selectedColor == index {
                                                RoundedRectangle(cornerRadius: 10)
                                                    .stroke(Color.tpInk, lineWidth: 2)
                                                    .padding(-3)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                if index != colors.indices.last { Spacer() }
                            }
                        }
                    }
                    .padding(11)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 13))

                    Button(action: onSave) {
                        Text("대분류 추가")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Color.tpInk, in: RoundedRectangle(cornerRadius: 13))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .background(Color.tpBackground)
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct TimeSliderScreen: View {
    @Binding var durationMinutes: Int
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            pickerHeader("시간 선택", trailing: "완료", action: onDone)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.tpStudyDark).frame(width: 12, height: 12)
                    Text("영어 공부").font(.system(size: 16, weight: .bold))
                }

                HStack(alignment: .firstTextBaseline) {
                    Text("21:00 → 22:00")
                        .font(.system(size: 24, weight: .black))
                    Spacer()
                    Text("\(durationMinutes / 60)시간")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.tpSecondary)
                }

                GeometryReader { proxy in
                    ZStack {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color(red: 0.96, green: 0.96, blue: 0.97))
                        HStack(spacing: 0) {
                            ForEach(0..<24, id: \.self) { index in
                                Rectangle()
                                    .fill(index.isMultiple(of: 4) ? Color(red: 0.85, green: 0.85, blue: 0.87) : Color(red: 0.93, green: 0.93, blue: 0.94))
                                    .frame(width: 0.5)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.tpStudy)
                            .frame(width: proxy.size.width * 0.18, height: 38)
                            .position(x: proxy.size.width * 0.55, y: 28)
                        sliderHandle.position(x: proxy.size.width * 0.46, y: 28)
                        sliderHandle.position(x: proxy.size.width * 0.64, y: 28)
                        Text("21:00")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.tpInk, in: RoundedRectangle(cornerRadius: 10))
                            .position(x: proxy.size.width * 0.46, y: -5)
                    }
                }
                .frame(height: 56)
                .padding(.horizontal, 6)
                .padding(.top, 18)

                HStack {
                    ForEach(["18", "19", "20", "21", "22", "23", "24"], id: \.self) {
                        Text($0).frame(maxWidth: .infinity)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(Color.tpSecondary)

                Slider(value: Binding(
                    get: { Double(durationMinutes) },
                    set: { durationMinutes = Int($0.rounded() / 10) * 10 }
                ), in: 30...180, step: 10)
                .tint(.tpStudyDark)

                HStack(spacing: 6) {
                    hint("슬라이드", "1분 단위\n이동")
                    hint("빠르게", "10분 단위\n반올림 스냅")
                    hint("꾹 누르기", "확대되어\n미세 조정")
                }

                Button(action: onDone) {
                    Text("완료")
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color.tpInk, in: RoundedRectangle(cornerRadius: 13))
                }
                .buttonStyle(.plain)
            }
            .padding(18)
            Spacer()
        }
        .background(Color.white)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var sliderHandle: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(.white)
            .frame(width: 15, height: 30)
            .shadow(color: .black.opacity(0.30), radius: 3, y: 1)
            .overlay {
                Capsule().fill(Color(red: 0.79, green: 0.79, blue: 0.81)).frame(width: 2.5, height: 14)
            }
    }

    private func hint(_ title: String, _ caption: String) -> some View {
        VStack(spacing: 3) {
            Text(title).font(.system(size: 11, weight: .bold))
            Text(caption)
                .font(.system(size: 9.5))
                .foregroundStyle(Color.tpSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(Color(red: 0.96, green: 0.96, blue: 0.97), in: RoundedRectangle(cornerRadius: 11))
    }
}

private func pickerHeader(
    _ title: String,
    trailing: String,
    action: @escaping () -> Void
) -> some View {
    HStack {
        Text(title)
            .font(.system(size: 19, weight: .bold))
        Spacer()
        Button(trailing, action: action)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.tpSecondary)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 12)
    .background(Color.white)
    .overlay(alignment: .bottom) { Rectangle().fill(Color.tpLine).frame(height: 0.5) }
}

#Preview {
    AddPlanSheet()
        .modelContainer(for: PlanItem.self, inMemory: true)
}
