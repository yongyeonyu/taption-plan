import SwiftUI

/// 입체 면의 모양. 원·알약·둥근 사각을 한 타입으로 모은다.
struct TaptionRaisedShape: InsettableShape, Equatable {
    enum Kind: Equatable {
        case circle, capsule
        case rounded(CGFloat)
    }

    var kind: Kind
    var inset: CGFloat = 0

    static let circle = Self(kind: .circle)
    static let capsule = Self(kind: .capsule)
    static func rounded(_ radius: CGFloat) -> Self { Self(kind: .rounded(radius)) }

    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: inset, dy: inset)
        switch kind {
        case .circle: return Path(ellipseIn: box)
        case .capsule: return Path(roundedRect: box, cornerRadius: min(box.width, box.height) / 2, style: .continuous)
        case let .rounded(radius): return Path(roundedRect: box, cornerRadius: max(0, radius - inset), style: .continuous)
        }
    }

    func inset(by amount: CGFloat) -> Self {
        var copy = self
        copy.inset += amount
        return copy
    }
}

/// 면 아래로 빠져나온 바닥 그림자 조각. 면 자리는 비워 반투명 면에 그림자가 비치지 않는다.
struct TaptionRaisedLip: Shape {
    var shape: TaptionRaisedShape
    var drop: CGFloat

    func path(in rect: CGRect) -> Path {
        shape.path(in: rect.offsetBy(dx: 0, dy: drop)).subtracting(shape.path(in: rect))
    }
}

/// 위쪽 광택. 왼쪽 위 원형 단추(`TaptionStickerDisc`)와 같은 비율이다.
struct TaptionRaisedGloss: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let width = rect.width * 0.46, height = side * 0.16
        return Path(ellipseIn: CGRect(x: rect.midX - width / 2, y: rect.minY + side * 0.11, width: width, height: height))
    }
}

/// 하단 메뉴·왼쪽 위 단추와 같은 규칙의 입체 바탕: 빛은 위에서 오고, 위는 밝게 아래는 어둡게,
/// 진한 테두리에 바닥 그림자를 깐다. 흐림 그림자 없이 도형 칠만 쓰므로 재생 중에 다시 계산할 게 없고,
/// 값이 같으면 SwiftUI가 다시 그리지 않는다(ICN1104A01).
struct TaptionRaisedFace: View {
    let shape: TaptionRaisedShape
    /// 비우면 지도가 비치는 유리 면이다.
    var fill: Color? = nil
    /// 비우면 테마의 스티커 테두리 색이다.
    var line: Color? = nil
    var lineWidth: CGFloat = 1.2
    var gloss: Bool = true
    private let palette = TaptionBarPalette.current

    var body: some View {
        ZStack {
            TaptionRaisedLip(shape: shape, drop: 2.6).fill(.black.opacity(0.09))
            TaptionRaisedLip(shape: shape, drop: 1.4).fill(.black.opacity(0.16))
            if let fill {
                shape.fill(LinearGradient(
                    colors: [fill, fill.mix(with: .black, by: 0.1)],
                    startPoint: .top, endPoint: .bottom
                ))
            } else {
                shape.fill(.ultraThinMaterial)
                shape.fill(Color.tpGlassTint)
            }
            if let inner = palette.innerLine {
                shape.strokeBorder(inner, lineWidth: lineWidth + 0.8)
            }
            // 안쪽 가장자리: 위는 빛을 받고 아래는 그늘진다.
            shape.inset(by: lineWidth).strokeBorder(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.55), location: 0),
                        .init(color: .white.opacity(0), location: 0.4),
                        .init(color: .black.opacity(0), location: 0.6),
                        .init(color: .black.opacity(0.12), location: 1)
                    ],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 1
            )
            shape.strokeBorder(line ?? palette.outline, lineWidth: lineWidth)
            if gloss {
                // 어두운 테마에서는 광택이 튀지 않게 낮춘다.
                TaptionRaisedGloss().fill(.white.opacity(palette.innerLine == nil ? 0.6 : 0.3))
            }
        }
    }
}

extension View {
    /// 입체 바탕을 깐다. 뷰 크기와 배치는 바뀌지 않고, 눌리는 영역은 면 자리까지다.
    func taptionRaised(
        _ shape: TaptionRaisedShape,
        fill: Color? = nil,
        line: Color? = nil,
        lineWidth: CGFloat = 1.2,
        gloss: Bool = true
    ) -> some View {
        contentShape(shape)
            .background {
                TaptionRaisedFace(shape: shape, fill: fill, line: line, lineWidth: lineWidth, gloss: gloss)
                    .allowsHitTesting(false)
            }
    }
}
