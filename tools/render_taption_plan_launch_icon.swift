import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard (3...5).contains(CommandLine.arguments.count) else {
    fatalError("Usage: render_taption_plan_launch_icon.swift <source.svg> <output.png> [content-scale] [opaque]")
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
let contentScale = CommandLine.arguments.count >= 4
    ? CGFloat(Double(CommandLine.arguments[3]) ?? 1)
    : 1
let rendersOpaqueBackground = CommandLine.arguments.count == 5
    && CommandLine.arguments[4] == "opaque"
let canvasSize = CGSize(width: 941, height: 1672)

guard contentScale > 0, contentScale <= 1 else {
    fatalError("Content scale must be greater than zero and no larger than one")
}

guard let sourceImage = NSImage(contentsOf: sourceURL) else {
    fatalError("Unable to read launch SVG")
}

var sourceRect = CGRect(origin: .zero, size: canvasSize)
guard let source = sourceImage.cgImage(
    forProposedRect: &sourceRect,
    context: nil,
    hints: [.interpolation: NSImageInterpolation.high]
) else {
    fatalError("Unable to render launch SVG")
}

guard let context = CGContext(
    data: nil,
    width: Int(canvasSize.width),
    height: Int(canvasSize.height),
    bitsPerComponent: 8,
    bytesPerRow: Int(canvasSize.width) * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: rendersOpaqueBackground
        ? CGImageAlphaInfo.noneSkipLast.rawValue
        : CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("Unable to create launch bitmap")
}

context.interpolationQuality = .high
if rendersOpaqueBackground {
    context.setFillColor(
        CGColor(
            red: 0xC7 / 255,
            green: 0x7B / 255,
            blue: 0x70 / 255,
            alpha: 1
        )
    )
    context.fill(CGRect(origin: .zero, size: canvasSize))
} else {
    context.clear(CGRect(origin: .zero, size: canvasSize))
}
let renderSize = CGSize(
    width: canvasSize.width * contentScale,
    height: canvasSize.height * contentScale
)
context.draw(
    source,
    in: CGRect(
        x: (canvasSize.width - renderSize.width) / 2,
        y: (canvasSize.height - renderSize.height) / 2,
        width: renderSize.width,
        height: renderSize.height
    )
)

guard
    let output = context.makeImage(),
    let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    )
else {
    fatalError("Unable to create launch PNG destination")
}

CGImageDestinationAddImage(destination, output, nil)
guard CGImageDestinationFinalize(destination) else {
    fatalError("Unable to write launch PNG")
}
