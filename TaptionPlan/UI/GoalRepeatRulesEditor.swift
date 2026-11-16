import SwiftUI

struct GoalRepeatRulesEditor: View {
    @Binding var rules: [GoalRepeatRule]

    private let weekdayOrder: [(value: Int, label: String)] = [
        (2, "월"), (3, "화"), (4, "수"), (5, "목"),
        (6, "금"), (7, "토"), (1, "일"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.regular) {
            HStack(spacing: TaptionSpacing.snug) {
                Text("반복")
                    .font(.taption(size: 10.5, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Text("요일별 · 시간별")
                    .font(.taption(size: 7.5, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
            }

            if rules.isEmpty {
                Text("예: 주중 23:00 취침 → 다음날 06:30 기상, 주말 01:00 → 10:00")
                    .font(.taption(size: 8.5, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: TaptionSpacing.snug) {
                presetButton("주중", weekdays: [2, 3, 4, 5, 6],
                             start: 23 * 60, end: 6 * 60 + 30)
                presetButton("주말", weekdays: [7, 1],
                             start: 1 * 60, end: 10 * 60)
                presetButton("매일", weekdays: [1, 2, 3, 4, 5, 6, 7],
                             start: 9 * 60, end: 10 * 60)
            }

            ForEach(rules.indices, id: \.self) { index in
                repeatRuleCard(
                    rule: ruleBinding(index),
                    index: index
                )
            }
        }
        .padding(11)
        .draftCard(radius: 13)
    }

    private func presetButton(
        _ title: String,
        weekdays: Set<Int>,
        start: Int,
        end: Int
    ) -> some View {
        Button {
            rules.append(
                GoalRepeatRule(
                    name: title,
                    weekdays: weekdays,
                    startMinuteOfDay: start,
                    endMinuteOfDay: end
                )
            )
        } label: {
            Label(title, systemImage: "repeat")
                .font(.taption(size: 8.5, weight: .bold))
                .foregroundStyle(Color.tpInk)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    Color.tpFieldFill,
                    in: RoundedRectangle(cornerRadius: TaptionRadius.control)
                )
        }
        .buttonStyle(.plain)
    }

    private func repeatRuleCard(
        rule: Binding<GoalRepeatRule>,
        index: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.cozy) {
            HStack(spacing: TaptionSpacing.snug) {
                Text(GoalRepeatRuleFormatter.summary(rule.wrappedValue))
                    .font(.taption(size: 9.5, weight: .bold))
                    .foregroundStyle(Color.tpInk)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button {
                    rules.remove(at: index)
                } label: {
                    Image(systemName: "trash")
                        .font(.taption(size: 9.5, weight: .bold))
                        .foregroundStyle(Color.red.opacity(0.78))
                }
                .accessibilityLabel("반복 규칙 삭제")
                .buttonStyle(.plain)
            }

            TextField("반복 이름 · 예: 주중 수면", text: nameBinding(rule))
                .font(.taption(size: 9.5, weight: .semibold))
                .textInputAutocapitalization(.sentences)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(Color.tpCard, in: RoundedRectangle(cornerRadius: TaptionRadius.small))

            HStack(spacing: TaptionSpacing.tight) {
                ForEach(weekdayOrder, id: \.value) { day in
                    Button {
                        toggle(day.value, in: rule)
                    } label: {
                        Text(day.label)
                            .font(.taption(size: 8.5, weight: .black))
                            .foregroundStyle(
                                rule.wrappedValue.weekdays.contains(day.value)
                                    ? Color.white
                                    : Color.tpSecondary
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                rule.wrappedValue.weekdays.contains(day.value)
                                    ? Color.tpInk
                                    : Color.white,
                                in: RoundedRectangle(cornerRadius: TaptionRadius.small)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: TaptionSpacing.regular) {
                repeatTimePicker(
                    title: "시작",
                    selection: timeBinding(rule, isStart: true)
                )
                repeatTimePicker(
                    title: "종료",
                    selection: timeBinding(rule, isStart: false)
                )
            }
        }
        .padding(9)
        .background(
            Color.tpFieldFill,
            in: RoundedRectangle(cornerRadius: TaptionRadius.compact)
        )
    }

    private func repeatTimePicker(
        title: String,
        selection: Binding<Date>
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.taption(size: 8.2, weight: .bold))
                .foregroundStyle(Color.tpSecondary)
            DatePicker(
                title,
                selection: selection,
                displayedComponents: .hourAndMinute
            )
            .labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.tpCard, in: RoundedRectangle(cornerRadius: TaptionRadius.small))
    }

    private func ruleBinding(_ index: Int) -> Binding<GoalRepeatRule> {
        Binding(
            get: { rules[index] },
            set: { rules[index] = $0 }
        )
    }

    private func nameBinding(
        _ rule: Binding<GoalRepeatRule>
    ) -> Binding<String> {
        Binding(
            get: { rule.wrappedValue.name ?? "" },
            set: { newValue in
                var value = rule.wrappedValue
                let clean = newValue.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                value.name = clean.isEmpty ? nil : clean
                rule.wrappedValue = value
            }
        )
    }

    private func timeBinding(
        _ rule: Binding<GoalRepeatRule>,
        isStart: Bool
    ) -> Binding<Date> {
        Binding(
            get: {
                date(fromMinute: isStart
                     ? rule.wrappedValue.startMinuteOfDay
                     : rule.wrappedValue.endMinuteOfDay)
            },
            set: { date in
                var value = rule.wrappedValue
                let minute = minuteOfDay(from: date)
                if isStart {
                    value.startMinuteOfDay = minute
                } else {
                    value.endMinuteOfDay = minute
                }
                rule.wrappedValue = value
            }
        )
    }

    private func toggle(
        _ weekday: Int,
        in rule: Binding<GoalRepeatRule>
    ) {
        var value = rule.wrappedValue
        if value.weekdays.contains(weekday) {
            value.weekdays.remove(weekday)
        } else {
            value.weekdays.insert(weekday)
        }
        rule.wrappedValue = value
    }

    private func date(fromMinute minute: Int) -> Date {
        let clamped = min(23 * 60 + 59, max(0, minute))
        let calendar = Calendar.autoupdatingCurrent
        return calendar.date(
            bySettingHour: clamped / 60,
            minute: clamped % 60,
            second: 0,
            of: .now
        ) ?? .now
    }

    private func minuteOfDay(from date: Date) -> Int {
        let calendar = Calendar.autoupdatingCurrent
        return calendar.component(.hour, from: date) * 60
            + calendar.component(.minute, from: date)
    }
}

enum GoalRepeatRuleFormatter {
    static func summary(_ rules: [GoalRepeatRule]?) -> String? {
        let rules = rules ?? []
        guard !rules.isEmpty else { return nil }
        let visible = rules.prefix(2).map(summary)
        let suffix = rules.count > 2 ? " 외 \(rules.count - 2)개" : ""
        return visible.joined(separator: " · ") + suffix
    }

    static func summary(_ rule: GoalRepeatRule) -> String {
        let name = rule.name.map { "\($0) · " } ?? ""
        let start = timeText(rule.startMinuteOfDay)
        let end = timeText(rule.endMinuteOfDay)
        let endPrefix = rule.endMinuteOfDay <= rule.startMinuteOfDay
            ? "다음날 "
            : ""
        return "\(name)\(weekdayText(rule.weekdays)) \(start)→\(endPrefix)\(end)"
    }

    static func weekdayText(_ weekdays: Set<Int>) -> String {
        let normalized = Set(weekdays.filter { (1...7).contains($0) })
        if normalized == [1, 2, 3, 4, 5, 6, 7] { return "매일" }
        if normalized == [2, 3, 4, 5, 6] { return "주중" }
        if normalized == [1, 7] { return "주말" }
        let labels = [
            2: "월", 3: "화", 4: "수", 5: "목",
            6: "금", 7: "토", 1: "일",
        ]
        return [2, 3, 4, 5, 6, 7, 1]
            .filter { normalized.contains($0) }
            .compactMap { labels[$0] }
            .joined(separator: "·")
    }

    static func timeText(_ minute: Int) -> String {
        let clamped = min(23 * 60 + 59, max(0, minute))
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }
}
