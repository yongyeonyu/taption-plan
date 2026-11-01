// tools/generate_hwarang_hats.py가 만든 파일. 직접 고치지 않는다.
import CoreGraphics

/// 화랑이 스프라이트(52×32pt) 동작·프레임별 귀 사이 중앙과 귀 끝 높이.
enum MapHomeHatHeadAnchors {
    static let table: [[CGPoint]] = [
        [CGPoint(x: 31.2, y: 5.7), CGPoint(x: 36.5, y: 2.0), CGPoint(x: 34.5, y: 2.0), CGPoint(x: 35.8, y: 2.0), CGPoint(x: 34.2, y: 5.3), CGPoint(x: 32.7, y: 5.7)],
        [CGPoint(x: 35.5, y: 2.0), CGPoint(x: 34.5, y: 2.0), CGPoint(x: 35.0, y: 2.0), CGPoint(x: 35.0, y: 2.0), CGPoint(x: 35.3, y: 2.0), CGPoint(x: 36.8, y: 2.3)],
        [CGPoint(x: 25.3, y: 2.0), CGPoint(x: 25.3, y: 1.7), CGPoint(x: 24.8, y: 1.7), CGPoint(x: 26.0, y: 1.7), CGPoint(x: 25.5, y: 1.7), CGPoint(x: 24.8, y: 2.3)],
        [CGPoint(x: 19.3, y: 10.0), CGPoint(x: 18.7, y: 9.3), CGPoint(x: 19.3, y: 10.7), CGPoint(x: 19.0, y: 9.3), CGPoint(x: 18.7, y: 10.7), CGPoint(x: 18.3, y: 10.0)],
        [CGPoint(x: 28.7, y: 1.7), CGPoint(x: 28.8, y: 1.7), CGPoint(x: 29.0, y: 1.7), CGPoint(x: 29.0, y: 1.7), CGPoint(x: 28.8, y: 1.7), CGPoint(x: 28.7, y: 1.7)],
        [CGPoint(x: 28.3, y: 9.3), CGPoint(x: 29.7, y: 16.7), CGPoint(x: 27.7, y: 20.0), CGPoint(x: 29.0, y: 20.7), CGPoint(x: 28.7, y: 17.3), CGPoint(x: 28.3, y: 9.3)],
        [CGPoint(x: 21.5, y: 5.7), CGPoint(x: 21.2, y: 5.7), CGPoint(x: 21.3, y: 6.0), CGPoint(x: 20.5, y: 5.3), CGPoint(x: 20.5, y: 5.3), CGPoint(x: 21.2, y: 6.0)],
        [CGPoint(x: 21.8, y: 7.0), CGPoint(x: 23.0, y: 8.0), CGPoint(x: 22.0, y: 6.3), CGPoint(x: 20.5, y: 7.7), CGPoint(x: 21.5, y: 9.3), CGPoint(x: 22.0, y: 8.0)],
        [CGPoint(x: 23.7, y: 1.0), CGPoint(x: 22.2, y: 1.7), CGPoint(x: 23.7, y: 1.0), CGPoint(x: 21.5, y: 4.0), CGPoint(x: 23.7, y: 1.0), CGPoint(x: 23.7, y: 4.7)],
        [CGPoint(x: 31.7, y: 10.3), CGPoint(x: 29.7, y: 10.3), CGPoint(x: 29.3, y: 8.7), CGPoint(x: 32.3, y: 10.3), CGPoint(x: 25.3, y: 5.3), CGPoint(x: 28.3, y: 10.3)],
        [CGPoint(x: 24.0, y: 1.7), CGPoint(x: 24.2, y: 1.7), CGPoint(x: 24.2, y: 2.0), CGPoint(x: 24.0, y: 1.7), CGPoint(x: 23.7, y: 2.0), CGPoint(x: 23.8, y: 5.7)],
        [CGPoint(x: 25.0, y: 1.7), CGPoint(x: 24.8, y: 1.7), CGPoint(x: 25.0, y: 1.7), CGPoint(x: 25.0, y: 1.7), CGPoint(x: 25.0, y: 1.7), CGPoint(x: 25.5, y: 2.3)],
    ]
}
