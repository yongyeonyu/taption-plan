import SwiftData
import SwiftUI

struct AddPlanSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var title = ""
    @State private var category = PlanCategory.project
    @State private var durationMinutes = 60

    var body: some View {
        NavigationStack {
            Form {
                Section("계획") {
                    TextField("계획명", text: $title)
                        .textInputAutocapitalization(.sentences)

                    Picker("대분류", selection: $category) {
                        ForEach(PlanCategory.allCases) { category in
                            Label(category.rawValue, systemImage: category.systemImage)
                                .tag(category)
                        }
                    }
                }

                Section("시간") {
                    DatePicker("시작", selection: .constant(Date.now), displayedComponents: [.date, .hourAndMinute])

                    Picker("길이", selection: $durationMinutes) {
                        Text("30분").tag(30)
                        Text("1시간").tag(60)
                        Text("2시간").tag(120)
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Text("키보드는 계획명을 입력할 때만 사용하고, 분류와 시간은 터치로 선택합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("새 계획")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("추가") {
                        addPlan()
                    }
                    .fontWeight(.semibold)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func addPlan() {
        let startAt = Date.now
        let plan = PlanItem(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            startAt: startAt,
            endAt: startAt.addingTimeInterval(TimeInterval(durationMinutes * 60)),
            category: category
        )
        modelContext.insert(plan)
        dismiss()
    }
}

#Preview {
    AddPlanSheet()
        .modelContainer(for: PlanItem.self, inMemory: true)
}
