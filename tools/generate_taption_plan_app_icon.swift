import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let size: CGFloat = 1024
private let scale: CGFloat = 1
private let canvasSize = CGSize(width: size * scale, height: size * scale)

private struct PillSpec {
    let orbitDegrees: CGFloat
    let colors: [NSColor]
    let stroke: NSColor
}

private enum IconVariant {
    case full
    case dark
    case tinted
}

private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

private func drawIcon(variant: IconVariant) -> NSImage {
    let image = NSImage(size: canvasSize)
    image.lockFocus()
    guard let context = NSGraphicsContext.current?.cgContext else {
        fatalError("Missing graphics context")
    }
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    context.scaleBy(x: scale, y: scale)

    drawBackground(in: context, variant: variant)
    drawOrbitGlow(in: context, variant: variant)

    switch variant {
    case .full, .dark:
        let specs = [
            PillSpec(
                orbitDegrees: 0,
                colors: [NSColor(hex: 0xF4B5A6), NSColor(hex: 0xF8C8B6), NSColor(hex: 0xF6D99B)],
                stroke: NSColor(hex: 0x171719)
            ),
            PillSpec(
                orbitDegrees: 120,
                colors: [NSColor(hex: 0xA9DFC7), NSColor(hex: 0xBDE8D8), NSColor(hex: 0xB3DBEA)],
                stroke: NSColor(hex: 0x171719)
            ),
            PillSpec(
                orbitDegrees: 240,
                colors: [NSColor(hex: 0xA9BDEB), NSColor(hex: 0xC0CDF1), NSColor(hex: 0xD6BCE9)],
                stroke: NSColor(hex: 0x171719)
            ),
        ]
        drawArcPill(specs[0], startDegrees: 218, endDegrees: 302, in: context, variant: variant)
        drawArcPill(specs[1], startDegrees: 338, endDegrees: 422, in: context, variant: variant)
        drawArcPill(specs[2], startDegrees: 98, endDegrees: 182, in: context, variant: variant)
    case .tinted:
        let specs = [
            PillSpec(
                orbitDegrees: 0,
                colors: [NSColor(hex: 0xF4B5A6), NSColor(hex: 0xF6D99B)],
                stroke: NSColor(hex: 0x171719)
            ),
            PillSpec(
                orbitDegrees: 120,
                colors: [NSColor(hex: 0xA9DFC7), NSColor(hex: 0xB3DBEA)],
                stroke: NSColor(hex: 0x171719)
            ),
            PillSpec(
                orbitDegrees: 240,
                colors: [NSColor(hex: 0xA9BDEB), NSColor(hex: 0xD6BCE9)],
                stroke: NSColor(hex: 0x171719)
            ),
        ]
        drawArcPill(specs[0], startDegrees: 218, endDegrees: 302, in: context, variant: variant)
        drawArcPill(specs[1], startDegrees: 338, endDegrees: 422, in: context, variant: variant)
        drawArcPill(specs[2], startDegrees: 98, endDegrees: 182, in: context, variant: variant)
    }

    drawCenterCutout(in: context, variant: variant)
    image.unlockFocus()
    return image
}

private func drawBackground(in context: CGContext, variant: IconVariant) {
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let baseTop: NSColor
    let baseBottom: NSColor
    switch variant {
    case .full:
        baseTop = NSColor(hex: 0xEAF5EF)
        baseBottom = NSColor(hex: 0xFBE8EB)
    case .dark:
        baseTop = NSColor(hex: 0xDDEBE5)
        baseBottom = NSColor(hex: 0xF1DDE0)
    case .tinted:
        baseTop = NSColor(hex: 0xE9EEF1)
        baseBottom = NSColor(hex: 0xF5E9EE)
    }
    NSGradient(colors: [baseTop, baseBottom])?.draw(in: rect, angle: -90)

    let center = CGPoint(x: size * 0.50, y: size * 0.49)
    let glowColors = [
        NSColor.white.withAlphaComponent(variant == .tinted ? 0.12 : 0.22).cgColor,
        NSColor(hex: 0xF6DFBE, alpha: 0.12).cgColor,
        NSColor.clear.cgColor,
    ] as CFArray
    let locations: [CGFloat] = [0, 0.42, 1]
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let gradient = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: locations) else { return }
    context.drawRadialGradient(
        gradient,
        startCenter: center,
        startRadius: 18,
        endCenter: center,
        endRadius: 500,
        options: [.drawsAfterEndLocation]
    )
}

private func drawOrbitGlow(in context: CGContext, variant: IconVariant) {
    context.saveGState()
    let rect = CGRect(x: 210, y: 210, width: 604, height: 604)
    let path = CGPath(ellipseIn: rect, transform: nil)
    context.addPath(path)
    context.setLineWidth(variant == .tinted ? 28 : 24)
    context.setStrokeColor(NSColor(hex: 0x171719).cgColor)
    context.strokePath()
    context.restoreGState()
}

private func drawArcPill(
    _ spec: PillSpec,
    startDegrees: CGFloat,
    endDegrees: CGFloat,
    in context: CGContext,
    variant: IconVariant
) {
    let center = CGPoint(x: size / 2, y: size / 2)
    let radius: CGFloat = 218
    let bodyWidth: CGFloat = 124
    let strokeWidth: CGFloat = bodyWidth + 34
    let steps = 44
    let start = startDegrees * .pi / 180
    let end = endDegrees * .pi / 180

    context.saveGState()
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setShadow(
        offset: CGSize(width: 0, height: 0),
        blur: variant == .tinted ? 8 : 14,
        color: spec.stroke.withAlphaComponent(variant == .tinted ? 0.08 : 0.16).cgColor
    )
    context.setStrokeColor(spec.stroke.cgColor)
    context.setLineWidth(strokeWidth)
    context.addArc(
        center: center,
        radius: radius,
        startAngle: start,
        endAngle: end,
        clockwise: false
    )
    context.strokePath()

    context.setShadow(offset: .zero, blur: 0, color: nil)
    context.setLineWidth(bodyWidth)
    for index in 0..<steps {
        let t0 = CGFloat(index) / CGFloat(steps)
        let t1 = CGFloat(index + 1) / CGFloat(steps)
        let a0 = start + (end - start) * t0
        let a1 = start + (end - start) * t1
        context.setStrokeColor(interpolatedColor(spec.colors, t: (t0 + t1) / 2).cgColor)
        context.addArc(
            center: center,
            radius: radius,
            startAngle: a0,
            endAngle: a1,
            clockwise: false
        )
        context.strokePath()
    }

    context.setLineWidth(bodyWidth * 0.28)
    context.setStrokeColor(NSColor.white.withAlphaComponent(variant == .tinted ? 0.12 : 0.20).cgColor)
    context.addArc(
        center: center,
        radius: radius - bodyWidth * 0.20,
        startAngle: start + 0.10,
        endAngle: end - 0.18,
        clockwise: false
    )
    context.strokePath()

    context.setLineWidth(bodyWidth * 0.18)
    context.setStrokeColor(NSColor.black.withAlphaComponent(variant == .tinted ? 0.11 : 0.20).cgColor)
    context.addArc(
        center: center,
        radius: radius + bodyWidth * 0.18,
        startAngle: start + 0.18,
        endAngle: end - 0.12,
        clockwise: false
    )
    context.strokePath()
    context.restoreGState()
}

private func interpolatedColor(_ colors: [NSColor], t: CGFloat) -> NSColor {
    guard let first = colors.first else { return .white }
    guard colors.count > 1 else { return first }
    let clamped = max(0, min(1, t))
    let scaled = clamped * CGFloat(colors.count - 1)
    let lowerIndex = min(colors.count - 2, max(0, Int(floor(scaled))))
    let localT = scaled - CGFloat(lowerIndex)
    return blend(colors[lowerIndex], colors[lowerIndex + 1], t: localT)
}

private func blend(_ lhs: NSColor, _ rhs: NSColor, t: CGFloat) -> NSColor {
    let a = lhs.usingColorSpace(.deviceRGB) ?? lhs
    let b = rhs.usingColorSpace(.deviceRGB) ?? rhs
    return NSColor(
        calibratedRed: a.redComponent + (b.redComponent - a.redComponent) * t,
        green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
        blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t,
        alpha: a.alphaComponent + (b.alphaComponent - a.alphaComponent) * t
    )
}

private func drawPill(_ spec: PillSpec, in context: CGContext, variant: IconVariant) {
    let orbitRadius: CGFloat = variant == .tinted ? 156 : 164
    let pillLength: CGFloat = 526
    let pillHeight: CGFloat = 138
    let angle = spec.orbitDegrees * .pi / 180
    let center = CGPoint(
        x: size / 2 + cos(angle) * orbitRadius,
        y: size / 2 + sin(angle) * orbitRadius
    )
    let tangentDegrees = spec.orbitDegrees + 90
    let rect = CGRect(
        x: -pillLength / 2,
        y: -pillHeight / 2,
        width: pillLength,
        height: pillHeight
    )

    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    context.rotate(by: tangentDegrees * .pi / 180)

    let strokePath = NSBezierPath(
        roundedRect: rect.insetBy(dx: -16, dy: -16),
        xRadius: pillHeight / 2 + 16,
        yRadius: pillHeight / 2 + 16
    )
    context.setShadow(
        offset: CGSize(width: 0, height: 0),
        blur: variant == .tinted ? 20 : 34,
        color: spec.stroke.withAlphaComponent(variant == .tinted ? 0.16 : 0.55).cgColor
    )
    spec.stroke.setFill()
    strokePath.fill()

    let bodyPath = NSBezierPath(
        roundedRect: rect,
        xRadius: pillHeight / 2,
        yRadius: pillHeight / 2
    )
    NSGradient(colors: spec.colors)?.draw(in: bodyPath, angle: 0)

    context.setShadow(offset: .zero, blur: 0, color: nil)
    NSColor.white.withAlphaComponent(variant == .tinted ? 0.10 : 0.18).setFill()
    let highlight = NSBezierPath(
        roundedRect: CGRect(
            x: rect.minX + 32,
            y: rect.minY + 18,
            width: rect.width - 64,
            height: rect.height * 0.38
        ),
        xRadius: rect.height * 0.19,
        yRadius: rect.height * 0.19
    )
    highlight.fill()

    NSColor.black.withAlphaComponent(variant == .tinted ? 0.10 : 0.18).setFill()
    let lowerShade = NSBezierPath(
        roundedRect: CGRect(
            x: rect.minX + 22,
            y: rect.maxY - rect.height * 0.36,
            width: rect.width - 44,
            height: rect.height * 0.18
        ),
        xRadius: rect.height * 0.09,
        yRadius: rect.height * 0.09
    )
    lowerShade.fill()
    context.restoreGState()
}

private func drawCenterCutout(in context: CGContext, variant: IconVariant) {
    context.saveGState()
    let center = CGPoint(x: size / 2, y: size / 2)
    let radius: CGFloat = variant == .tinted ? 128 : 118
    let cutout = CGRect(
        x: center.x - radius,
        y: center.y - radius,
        width: radius * 2,
        height: radius * 2
    )
    let color = variant == .tinted
        ? NSColor(hex: 0x05060C, alpha: 0.78)
        : NSColor(hex: 0x02040B, alpha: 0.70)
    context.setShadow(
        offset: CGSize(width: 0, height: 0),
        blur: 18,
        color: NSColor.black.withAlphaComponent(0.35).cgColor
    )
    color.setFill()
    NSBezierPath(ovalIn: cutout).fill()

    context.setShadow(offset: .zero, blur: 0, color: nil)
    NSColor.white.withAlphaComponent(variant == .tinted ? 0.11 : 0.07).setStroke()
    let ring = NSBezierPath(ovalIn: cutout.insetBy(dx: 8, dy: 8))
    ring.lineWidth = 2
    ring.stroke()
    context.restoreGState()
}

private func writePNG(_ image: NSImage, to url: URL) throws {
    var proposedRect = CGRect(origin: .zero, size: canvasSize)
    guard let source = image.cgImage(
        forProposedRect: &proposedRect,
        context: nil,
        hints: nil
    ) else {
        throw NSError(domain: "TaptionPlanIcon", code: 1)
    }

    let width = Int(size)
    let height = Int(size)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        throw NSError(domain: "TaptionPlanIcon", code: 2)
    }
    context.interpolationQuality = .high
    context.setFillColor(NSColor.black.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard
        let output = context.makeImage(),
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        )
    else {
        throw NSError(domain: "TaptionPlanIcon", code: 3)
    }
    CGImageDestinationAddImage(destination, output, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "TaptionPlanIcon", code: 4)
    }
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)
try writePNG(
    drawIcon(variant: .full),
    to: outputDirectory.appendingPathComponent("AppIcon.png")
)
try writePNG(
    drawIcon(variant: .dark),
    to: outputDirectory.appendingPathComponent("AppIcon-dark.png")
)
try writePNG(
    drawIcon(variant: .tinted),
    to: outputDirectory.appendingPathComponent("AppIcon-tinted.png")
)
