import SwiftUI
import TaptionPlanStore
import UIKit

/// 계획표 위의 「조각 서랍」(AIT1116A01). 미정 일정이 있을 때만 나타난다.
/// 「끼우기」는 미정을 계획으로 바꾸고(되돌리기 가능), 새 조각이 올라오면 딸깍 들어온다.
struct TravelPuzzleDrawer: View {
    @Bindable var model: AppModel
    let tripID: String
    let language: MapHomeLanguage

    @State private var seen: Set<String>?
    @State private var arrived: Set<String> = []
    @State private var fitted: TravelPuzzlePiece?
    @State private var isOpen = true

    private var items: [TravelTripItem] { model.settings.travelTripItems ?? [] }
    private var pieces: [TravelPuzzlePiece] { TravelPuzzle.pieces(items: items, tripID: tripID) }

    var body: some View {
        let pieces = self.pieces
        Group {
            if !pieces.isEmpty || fitted != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if !pieces.isEmpty { header(count: pieces.count) }
                    if isOpen {
                        ScrollView {
                            VStack(spacing: 6) {
                                ForEach(pieces) { piece in
                                    row(piece)
                                        .transition(.asymmetric(insertion: .scale(scale: 0.85).combined(with: .opacity), removal: .opacity))
                                }
                            }
                        }
                        .frame(maxHeight: 150)
                    }
                    if let fitted { undoRow(fitted) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.tpCard.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 8)
                .accessibilityIdentifier("travelPuzzleDrawer")
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.65), value: pieces.map(\.id))
        .onChange(of: pieces.map(\.id)) { _, _ in noticeArrivals(pieces) }
        .onAppear { if seen == nil { seen = Set(pieces.map(\.id)) } }
    }

    private func header(count: Int) -> some View {
        Button { withAnimation(.snappy) { isOpen.toggle() } } label: {
            HStack(spacing: 6) {
                Image(systemName: "puzzlepiece.extension").foregroundStyle(Color.tpAccent)
                Text(language.runtimeText("조각 \(count)개 · 눌러서 일정에 끼우세요", "\(count) pieces · tap to fit into the plan"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Spacer(minLength: 0)
                Image(systemName: isOpen ? "chevron.up" : "chevron.down").foregroundStyle(Color.tpSecondary)
            }
            .frame(minHeight: 32)
        }
        .buttonStyle(.plain)
    }

    private func row(_ piece: TravelPuzzlePiece) -> some View {
        let conflicts = TravelPuzzle.conflicts(of: piece, items: items, tripID: tripID)
        return HStack(spacing: 8) {
            Image(systemName: TripImportItem.Kind(rawValue: piece.kind)?.symbol ?? "mappin")
                .foregroundStyle(Color.tpAccent).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: piece.title)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .semibold))
                    .foregroundStyle(Color.tpInk).lineLimit(1)
                Text(Self.timeText(piece, conflicts: conflicts, language: language))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .medium))
                    .foregroundStyle(conflicts.isEmpty ? Color.tpSecondary : Color.orange).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(conflicts.isEmpty ? language.text("끼우기", "Fit in") : language.text("그래도 끼우기", "Fit anyway")) { fit(piece) }
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .bold))
                .buttonStyle(.borderedProminent).controlSize(.small).tint(Color.tpAccent)
                .accessibilityIdentifier("travelPuzzleFit")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.tpBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.tpSecondary.opacity(arrived.contains(piece.id) ? 0.9 : 0.5), style: StrokeStyle(lineWidth: arrived.contains(piece.id) ? 2 : 1, dash: [4, 3]))
        }
    }

    private func undoRow(_ piece: TravelPuzzlePiece) -> some View {
        HStack {
            Text(language.runtimeText("「\(piece.title)」을(를) 끼웠어요", "Fitted \"\(piece.title)\""))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .semibold))
                .foregroundStyle(Color.tpInk).lineLimit(1)
            Spacer(minLength: 0)
            Button(language.text("되돌리기", "Undo")) { undo(piece) }
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .bold))
                .foregroundStyle(Color.tpAccent).buttonStyle(.plain).frame(minHeight: 32)
                .accessibilityIdentifier("travelPuzzleUndo")
        }
    }

    static func timeText(_ piece: TravelPuzzlePiece, conflicts: [TravelTripItem], language: MapHomeLanguage) -> String {
        var style = Date.FormatStyle(locale: language.locale, timeZone: TimeZone(secondsFromGMT: piece.utcOffsetSeconds) ?? .gmt).month().day().hour().minute()
        style.timeZone = TimeZone(secondsFromGMT: piece.utcOffsetSeconds) ?? .gmt
        let time = piece.start.formatted(style)
        guard let first = conflicts.first else { return time }
        return language.runtimeText("\(time) · 「\(first.title)」와 겹쳐요", "\(time) · overlaps \"\(first.title)\"")
    }

    private func fit(_ piece: TravelPuzzlePiece) {
        model.setTripItemStatus(.planned, tripID: tripID, itemID: piece.id)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.snappy) { fitted = piece }
    }

    private func undo(_ piece: TravelPuzzlePiece) {
        model.setTripItemStatus(.tentative, tripID: tripID, itemID: piece.id)
        withAnimation(.snappy) { fitted = nil }
    }

    private func noticeArrivals(_ pieces: [TravelPuzzlePiece]) {
        let new = TravelPuzzle.arrivals(previous: seen, current: pieces)
        seen = Set(pieces.map(\.id))
        guard !new.isEmpty else { return }
        arrived = new
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            arrived = []
        }
    }
}
