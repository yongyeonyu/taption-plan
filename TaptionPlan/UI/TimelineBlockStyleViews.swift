import SwiftUI

struct GoalStripeBackground: View {
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(
                Path(rect),
                with: .color(tint.opacity(0.24))
            )

            var stripePath = Path()
            var x: CGFloat = -size.height
            while x < size.width + size.height {
                stripePath.move(to: CGPoint(x: x, y: size.height))
                stripePath.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 9
            }
            context.stroke(
                stripePath,
                with: .color(tint.opacity(0.48)),
                style: StrokeStyle(
                    lineWidth: 2,
                    lineCap: .butt,
                    lineJoin: .miter
                )
            )

            let dotRadius: CGFloat = 0.9
            var y: CGFloat = 4
            while y < size.height {
                var dotX: CGFloat = 5
                while dotX < size.width {
                    let dotRect = CGRect(
                        x: dotX,
                        y: y,
                        width: dotRadius * 2,
                        height: dotRadius * 2
                    )
                    context.fill(
                        Path(ellipseIn: dotRect),
                        with: .color(tint.opacity(0.34))
                    )
                    dotX += 14
                }
                y += 12
            }
        }
    }
}
