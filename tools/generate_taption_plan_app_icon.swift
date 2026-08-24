import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let size: CGFloat = 1024
private let canvasSize = CGSize(width: size, height: size)

private enum IconVariant {
    case full
    case dark
    case tinted
}

private struct Palette {
    let background: NSColor
    let cat: [NSColor]
    let face: [NSColor]
    let mark: NSColor
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

private func palette(for variant: IconVariant) -> Palette {
    switch variant {
    case .full:
        return Palette(
            background: NSColor(hex: 0xC77B70),
            cat: [NSColor(hex: 0x223A59), NSColor(hex: 0x182D49)],
            face: [NSColor(hex: 0xFFF4D8), NSColor(hex: 0xF6E6C5)],
            mark: NSColor(hex: 0x182D49)
        )
    case .dark:
        return Palette(
            background: NSColor(hex: 0x17202E),
            cat: [NSColor(hex: 0x8AAFC0), NSColor(hex: 0x7798AB)],
            face: [NSColor(hex: 0xFFF0CE), NSColor(hex: 0xF4DFB8)],
            mark: NSColor(hex: 0x17202E)
        )
    case .tinted:
        return Palette(
            background: NSColor(hex: 0xE0E0E0),
            cat: [NSColor(hex: 0x2A2A2A), NSColor(hex: 0x202020)],
            face: [NSColor(hex: 0xF7F7F7), NSColor(hex: 0xEEEEEE)],
            mark: NSColor(hex: 0x202020)
        )
    }
}

private func timelinePath() -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: CGPoint(x: 260, y: 236))
    path.curve(
        to: CGPoint(x: 814, y: 277),
        controlPoint1: CGPoint(x: 425, y: 128),
        controlPoint2: CGPoint(x: 676, y: 139)
    )
    path.curve(
        to: CGPoint(x: 856, y: 802),
        controlPoint1: CGPoint(x: 934, y: 397),
        controlPoint2: CGPoint(x: 947, y: 620)
    )
    return path
}

private func bodyPath() -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: CGPoint(x: 264, y: 1024))
    path.curve(
        to: CGPoint(x: 370, y: 742),
        controlPoint1: CGPoint(x: 270, y: 888),
        controlPoint2: CGPoint(x: 315, y: 802)
    )
    path.curve(
        to: CGPoint(x: 382, y: 638),
        controlPoint1: CGPoint(x: 352, y: 700),
        controlPoint2: CGPoint(x: 356, y: 664)
    )
    path.curve(
        to: CGPoint(x: 447, y: 486),
        controlPoint1: CGPoint(x: 398, y: 594),
        controlPoint2: CGPoint(x: 424, y: 520)
    )
    path.curve(
        to: CGPoint(x: 485, y: 493),
        controlPoint1: CGPoint(x: 458, y: 472),
        controlPoint2: CGPoint(x: 474, y: 476)
    )
    path.curve(
        to: CGPoint(x: 544, y: 620),
        controlPoint1: CGPoint(x: 511, y: 528),
        controlPoint2: CGPoint(x: 531, y: 585)
    )
    path.curve(
        to: CGPoint(x: 614, y: 647),
        controlPoint1: CGPoint(x: 566, y: 634),
        controlPoint2: CGPoint(x: 589, y: 647)
    )
    path.curve(
        to: CGPoint(x: 684, y: 620),
        controlPoint1: CGPoint(x: 639, y: 647),
        controlPoint2: CGPoint(x: 662, y: 634)
    )
    path.curve(
        to: CGPoint(x: 743, y: 493),
        controlPoint1: CGPoint(x: 697, y: 585),
        controlPoint2: CGPoint(x: 717, y: 528)
    )
    path.curve(
        to: CGPoint(x: 781, y: 486),
        controlPoint1: CGPoint(x: 754, y: 476),
        controlPoint2: CGPoint(x: 770, y: 472)
    )
    path.curve(
        to: CGPoint(x: 846, y: 638),
        controlPoint1: CGPoint(x: 804, y: 520),
        controlPoint2: CGPoint(x: 830, y: 594)
    )
    path.curve(
        to: CGPoint(x: 838, y: 752),
        controlPoint1: CGPoint(x: 872, y: 671),
        controlPoint2: CGPoint(x: 870, y: 712)
    )
    path.curve(
        to: CGPoint(x: 986, y: 1024),
        controlPoint1: CGPoint(x: 911, y: 816),
        controlPoint2: CGPoint(x: 963, y: 903)
    )
    path.close()
    return path
}

private func facePath() -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: CGPoint(x: 410, y: 738))
    path.curve(
        to: CGPoint(x: 775, y: 698),
        controlPoint1: CGPoint(x: 480, y: 650),
        controlPoint2: CGPoint(x: 665, y: 630)
    )
    path.curve(
        to: CGPoint(x: 782, y: 901),
        controlPoint1: CGPoint(x: 846, y: 742),
        controlPoint2: CGPoint(x: 844, y: 840)
    )
    path.curve(
        to: CGPoint(x: 408, y: 910),
        controlPoint1: CGPoint(x: 707, y: 974),
        controlPoint2: CGPoint(x: 497, y: 978)
    )
    path.curve(
        to: CGPoint(x: 410, y: 738),
        controlPoint1: CGPoint(x: 347, y: 864),
        controlPoint2: CGPoint(x: 352, y: 789)
    )
    path.close()
    return path
}

private func drawGradient(
    _ colors: [NSColor],
    clippedTo path: NSBezierPath,
    in context: CGContext
) {
    context.saveGState()
    context.addPath(path.cgPath)
    context.clip()
    guard let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors.map(\.cgColor) as CFArray,
        locations: [0, 1]
    ) else {
        context.restoreGState()
        return
    }
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 150, y: 100),
        end: CGPoint(x: 900, y: 950),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    context.restoreGState()
}

private func drawGradientStroke(
    _ colors: [NSColor],
    path: NSBezierPath,
    width: CGFloat,
    in context: CGContext
) {
    context.saveGState()
    context.addPath(path.cgPath)
    context.setLineWidth(width)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.replacePathWithStrokedPath()
    context.clip()
    guard let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors.map(\.cgColor) as CFArray,
        locations: [0, 1]
    ) else {
        context.restoreGState()
        return
    }
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 150, y: 100),
        end: CGPoint(x: 900, y: 950),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    context.restoreGState()
}

private func fillCircle(
    center: CGPoint,
    radius: CGFloat,
    color: NSColor,
    in context: CGContext
) {
    context.setFillColor(color.cgColor)
    context.fillEllipse(
        in: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
    )
}

private func drawIcon(variant: IconVariant) -> NSImage {
    let palette = palette(for: variant)
    let image = NSImage(size: canvasSize)
    image.lockFocus()
    guard let context = NSGraphicsContext.current?.cgContext else {
        fatalError("Missing graphics context")
    }
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    context.setFillColor(palette.background.cgColor)
    context.fill(CGRect(origin: .zero, size: canvasSize))

    context.saveGState()
    context.translateBy(x: 0, y: size)
    context.scaleBy(x: 1, y: -1)

    let timeline = timelinePath()
    drawGradientStroke(palette.cat, path: timeline, width: 134, in: context)
    context.addPath(timeline.cgPath)
    context.setLineWidth(40)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(palette.background.cgColor)
    context.strokePath()
    [
        CGPoint(x: 260, y: 236),
        CGPoint(x: 705, y: 174),
        CGPoint(x: 910, y: 520),
    ].forEach {
        fillCircle(center: $0, radius: 44, color: palette.background, in: context)
    }
    [
        CGPoint(x: 260, y: 236),
        CGPoint(x: 705, y: 174),
        CGPoint(x: 910, y: 520),
    ].forEach {
        fillCircle(center: $0, radius: 22, color: palette.cat[0], in: context)
    }

    drawGradient(palette.cat, clippedTo: bodyPath(), in: context)
    drawGradient(palette.face, clippedTo: facePath(), in: context)
    fillCircle(center: CGPoint(x: 506, y: 793), radius: 35, color: palette.mark, in: context)
    fillCircle(center: CGPoint(x: 704, y: 768), radius: 35, color: palette.mark, in: context)

    let mouth = NSBezierPath()
    mouth.move(to: CGPoint(x: 613, y: 847))
    mouth.curve(
        to: CGPoint(x: 533, y: 855),
        controlPoint1: CGPoint(x: 595, y: 883),
        controlPoint2: CGPoint(x: 552, y: 884)
    )
    mouth.move(to: CGPoint(x: 613, y: 847))
    mouth.curve(
        to: CGPoint(x: 686, y: 847),
        controlPoint1: CGPoint(x: 630, y: 877),
        controlPoint2: CGPoint(x: 668, y: 878)
    )
    context.addPath(mouth.cgPath)
    context.setLineWidth(22)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(palette.mark.cgColor)
    context.strokePath()

    context.restoreGState()
    image.unlockFocus()
    return image
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
    guard let context = CGContext(
        data: nil,
        width: Int(size),
        height: Int(size),
        bitsPerComponent: 8,
        bytesPerRow: Int(size) * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        throw NSError(domain: "TaptionPlanIcon", code: 2)
    }
    context.setFillColor(NSColor.black.cgColor)
    context.fill(CGRect(origin: .zero, size: canvasSize))
    context.draw(source, in: CGRect(origin: .zero, size: canvasSize))
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

guard CommandLine.arguments.count >= 2 else {
    fatalError("Usage: generate_taption_plan_app_icon.swift <iOS output> [watchOS output]")
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
try writePNG(drawIcon(variant: .full), to: outputDirectory.appendingPathComponent("AppIcon.png"))
try writePNG(drawIcon(variant: .dark), to: outputDirectory.appendingPathComponent("AppIcon-dark.png"))
try writePNG(drawIcon(variant: .tinted), to: outputDirectory.appendingPathComponent("AppIcon-tinted.png"))

if CommandLine.arguments.count >= 3 {
    let watchOutputDirectory = URL(fileURLWithPath: CommandLine.arguments[2])
    try FileManager.default.createDirectory(at: watchOutputDirectory, withIntermediateDirectories: true)
    try writePNG(
        drawIcon(variant: .full),
        to: watchOutputDirectory.appendingPathComponent("AppIcon.png")
    )
}
