import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct MotionSource {
    let name: String
    let motionPath: String
    let eatingRow: Int
}

private let generatedRoot = "/Users/u_mo_c/.codex/generated_images/019fb2fa-4245-7233-84a1-6b4ed90d808b"
private let projectRoot = "/Users/u_mo_c/Documents/taption plan"
private let sources = [
    MotionSource(name: "Calico", motionPath: "\(generatedRoot)/exec-af9f92a6-f605-4822-add6-67520b20186e.png", eatingRow: 0),
    MotionSource(name: "White", motionPath: "\(generatedRoot)/exec-91c4bfb5-4766-4d27-b130-952a93ad60c9.png", eatingRow: 1),
    MotionSource(name: "Mackerel", motionPath: "\(generatedRoot)/exec-6db2fb91-e7d9-467f-983d-82231e383089.png", eatingRow: 2),
    MotionSource(name: "Black", motionPath: "\(generatedRoot)/exec-9a801dbb-b2ca-4bc8-b845-0cf27b1159ed.png", eatingRow: 3),
    MotionSource(name: "Gray", motionPath: "\(generatedRoot)/exec-7b56329f-a510-4a4e-bc29-fdbb4febfedd.png", eatingRow: 4),
    MotionSource(name: "Cheese", motionPath: "\(generatedRoot)/exec-7aa15de4-27f1-4288-b5c3-f6de4e3129e2.png", eatingRow: 5),
    MotionSource(name: "Cow", motionPath: "\(generatedRoot)/exec-22fde787-9c2a-46d9-a330-8a6bee1263c8.png", eatingRow: 6),
]
private let eatingPath = "\(generatedRoot)/exec-ff910fa1-0ab3-4e44-8e61-de89f50ce8ba.png"
private let groomingPath = "\(generatedRoot)/exec-220807ff-8aaf-4f42-b9a8-ef1f057d9695.png"
private let outputRoots = [
    "\(projectRoot)/TaptionPlan/Assets.xcassets",
    "\(projectRoot)/TaptionPlanWidget/Assets.xcassets",
    "\(projectRoot)/TaptionPlanWatch/Assets.xcassets",
]
private let frameCount = 6
private let actionCount = 12
private let cellWidth = 156
private let cellHeight = 96

private func loadImage(_ path: String) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(
        URL(fileURLWithPath: path) as CFURL,
        nil
    ) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

private func rgbaPixels(
    from image: CGImage
) -> (pixels: [UInt8], width: Int, height: Int)? {
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    guard let context = CGContext(
        data: &pixels,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return (pixels, image.width, image.height)
}

private func transparentImage(from source: CGImage) -> CGImage? {
    guard var decoded = rgbaPixels(from: source) else { return nil }
    let width = decoded.width
    let height = decoded.height
    let count = width * height
    var background = [Bool](repeating: false, count: count)
    var queue = [Int]()
    queue.reserveCapacity(count / 2)
    let corner = (0..<min(25, count)).reduce(into: (0, 0, 0)) { sum, index in
        sum.0 += Int(decoded.pixels[index * 4])
        sum.1 += Int(decoded.pixels[index * 4 + 1])
        sum.2 += Int(decoded.pixels[index * 4 + 2])
    }
    let cornerCount = max(1, min(25, count))
    let usesCyanKey = corner.0 / cornerCount < 100
        && corner.1 / cornerCount > 150
        && corner.2 / cornerCount > 120

    func isBackground(_ index: Int) -> Bool {
        let offset = index * 4
        if decoded.pixels[offset + 3] < 8 { return true }
        let r = Int(decoded.pixels[offset])
        let g = Int(decoded.pixels[offset + 1])
        let b = Int(decoded.pixels[offset + 2])
        if usesCyanKey {
            return g > 20 && b > 20 && g - r > 4 && b - r > 4
        }
        return min(r, g, b) > 224 && max(r, g, b) - min(r, g, b) < 22
    }

    var barrier = [Bool](repeating: false, count: count)
    for index in 0..<count where decoded.pixels[index * 4 + 3] >= 8 && !isBackground(index) {
        barrier[index] = true
    }
    for _ in 0..<6 {
        var expanded = barrier
        for index in barrier.indices where barrier[index] {
            let x = index % width
            let y = index / width
            if x > 0 { expanded[index - 1] = true }
            if x + 1 < width { expanded[index + 1] = true }
            if y > 0 { expanded[index - width] = true }
            if y + 1 < height { expanded[index + width] = true }
        }
        barrier = expanded
    }

    func enqueue(_ index: Int) {
        guard !background[index], !barrier[index], isBackground(index) else {
            return
        }
        background[index] = true
        queue.append(index)
    }

    for x in 0..<width {
        enqueue(x)
        enqueue((height - 1) * width + x)
    }
    for y in 0..<height {
        enqueue(y * width)
        enqueue(y * width + width - 1)
    }

    var cursor = 0
    while cursor < queue.count {
        let index = queue[cursor]
        cursor += 1
        let x = index % width
        let y = index / width
        if x > 0 { enqueue(index - 1) }
        if x + 1 < width { enqueue(index + 1) }
        if y > 0 { enqueue(index - width) }
        if y + 1 < height { enqueue(index + width) }
    }

    for index in 0..<count {
        if background[index] || (usesCyanKey && isBackground(index)) {
            let offset = index * 4
            decoded.pixels[offset] = 0
            decoded.pixels[offset + 1] = 0
            decoded.pixels[offset + 2] = 0
            decoded.pixels[offset + 3] = 0
        }
    }
    guard let context = CGContext(
        data: &decoded.pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    return context.makeImage()
}

private func sprite(
    from image: CGImage,
    columns: Int,
    rows: Int,
    column: Int,
    row: Int,
    expands: Bool = true,
    expandsVertically: Bool = false,
    keepsDetachedComponents: Bool = true
) -> CGImage? {
    let baseX0 = column * image.width / columns
    let baseX1 = (column + 1) * image.width / columns
    let baseY0 = row * image.height / rows
    let baseY1 = (row + 1) * image.height / rows
    let marginX = expands ? (baseX1 - baseX0) / 4 : 0
    let marginY = expandsVertically ? (baseY1 - baseY0) / 3 : 0
    let cropX = max(0, baseX0 - marginX)
    let cropY = max(0, baseY0 - marginY)
    let cropMaxX = min(image.width, baseX1 + marginX)
    let cropMaxY = min(image.height, baseY1 + marginY)
    guard let cropped = image.cropping(
        to: CGRect(
            x: cropX,
            y: cropY,
            width: cropMaxX - cropX,
            height: cropMaxY - cropY
        )
    ), let cell = transparentImage(from: cropped),
       let decoded = rgbaPixels(from: cell) else { return nil }

    struct Component {
        var count = 0
        var minX = Int.max
        var maxX = 0
        var minY = Int.max
        var maxY = 0
        var sumX: Int64 = 0
        var sumY: Int64 = 0
    }
    var labels = [Int](repeating: -1, count: decoded.width * decoded.height)
    var components: [Component] = []
    var queue: [Int] = []
    for seed in labels.indices where labels[seed] == -1 && decoded.pixels[seed * 4 + 3] > 12 {
        let label = components.count
        var component = Component()
        queue.removeAll(keepingCapacity: true)
        queue.append(seed)
        labels[seed] = label
        var cursor = 0
        while cursor < queue.count {
            let index = queue[cursor]
            cursor += 1
            let x = index % decoded.width
            let y = index / decoded.width
            component.count += 1
            component.minX = min(component.minX, x)
            component.maxX = max(component.maxX, x)
            component.minY = min(component.minY, y)
            component.maxY = max(component.maxY, y)
            component.sumX += Int64(x)
            component.sumY += Int64(y)
            for neighbor in [
                x > 0 ? index - 1 : -1,
                x + 1 < decoded.width ? index + 1 : -1,
                y > 0 ? index - decoded.width : -1,
                y + 1 < decoded.height ? index + decoded.width : -1,
            ] where neighbor >= 0 && labels[neighbor] == -1 && decoded.pixels[neighbor * 4 + 3] > 12 {
                labels[neighbor] = label
                queue.append(neighbor)
            }
        }
        components.append(component)
    }

    let localCore = CGRect(
        x: baseX0 - cropX,
        y: decoded.height - (baseY1 - cropY),
        width: baseX1 - baseX0,
        height: baseY1 - baseY0
    )
    let candidates = components.indices.filter { index in
        let component = components[index]
        guard component.count >= 4 else { return false }
        return localCore.contains(
            CGPoint(
                x: Double(component.sumX) / Double(component.count),
                y: Double(component.sumY) / Double(component.count)
            )
        )
    }
    let selected = keepsDetachedComponents
        ? Set(candidates)
        : Set(candidates.max { components[$0].count < components[$1].count }.map { [$0] } ?? [])
    guard !selected.isEmpty else { return nil }
    let chosen = selected.map { components[$0] }
    let minX = chosen.map(\.minX).min() ?? 0
    let maxX = chosen.map(\.maxX).max() ?? 0
    let minY = chosen.map(\.minY).min() ?? 0
    let maxY = chosen.map(\.maxY).max() ?? 0
    let padding = 3
    let outputX = max(0, minX - padding)
    let outputY = max(0, minY - padding)
    let outputWidth = min(decoded.width - 1, maxX + padding) - outputX + 1
    let outputHeight = min(decoded.height - 1, maxY + padding) - outputY + 1
    var pixels = [UInt8](repeating: 0, count: outputWidth * outputHeight * 4)
    for y in 0..<outputHeight {
        for x in 0..<outputWidth {
            let sourceIndex = (outputY + y) * decoded.width + outputX + x
            guard selected.contains(labels[sourceIndex]) else { continue }
            let sourceOffset = sourceIndex * 4
            let targetOffset = (y * outputWidth + x) * 4
            pixels[targetOffset..<(targetOffset + 4)] = decoded.pixels[sourceOffset..<(sourceOffset + 4)]
        }
    }
    guard let context = CGContext(
        data: &pixels,
        width: outputWidth,
        height: outputHeight,
        bitsPerComponent: 8,
        bytesPerRow: outputWidth * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    return context.makeImage()
}

private func motionAtlas(
    source: MotionSource,
    eatingSheet: CGImage,
    groomingSheet: CGImage
) -> CGImage? {
    guard let motion = loadImage(source.motionPath),
          let legacy = loadImage(
            "\(projectRoot)/.cat-visual-check/legacy-atlases/TaptionCatAtlas\(source.name).png"
          ),
          let output = CGContext(
            data: nil,
            width: frameCount * cellWidth,
            height: actionCount * cellHeight,
            bitsPerComponent: 8,
            bytesPerRow: frameCount * cellWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else { return nil }

    output.interpolationQuality = .high
    for action in 0..<actionCount {
        var frames: [CGImage] = []
        if action == 4 || action == 5 {
            let sheet = action == 4 ? groomingSheet : eatingSheet
            let generated = (0..<3).compactMap {
                sprite(
                    from: sheet,
                    columns: 3,
                    rows: 7,
                    column: $0,
                    row: source.eatingRow,
                    expands: false,
                    keepsDetachedComponents: action == 5
                )
            }
            frames = generated + generated.reversed()
        } else {
            frames = (0..<5).compactMap {
                sprite(
                    from: motion,
                    columns: 5,
                    rows: actionCount,
                    column: $0,
                    row: action,
                    expandsVertically: action >= 10,
                    keepsDetachedComponents: action == 8
                )
            }
            if let legacyFrame = sprite(
                from: legacy,
                columns: 4,
                rows: 3,
                column: action % 4,
                row: action / 4,
                expands: false,
                keepsDetachedComponents: action == 8
            ) {
                frames.append(legacyFrame)
            }
        }
        guard frames.count == frameCount else {
            fatalError("Missing frames for \(source.name) action \(action): \(frames.count)")
        }

        for (frame, image) in frames.enumerated() {
            let scale = min(
                CGFloat(cellWidth - 8) / CGFloat(image.width),
                CGFloat(cellHeight - 6) / CGFloat(image.height)
            )
            let width = CGFloat(image.width) * scale
            let height = CGFloat(image.height) * scale
            output.draw(
                image,
                in: CGRect(
                    x: CGFloat(frame * cellWidth) + (CGFloat(cellWidth) - width) / 2,
                    y: CGFloat((actionCount - action - 1) * cellHeight) + 3,
                    width: width,
                    height: height
                )
            )
        }
    }
    return output.makeImage()
}

private func write(_ image: CGImage, to path: String) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown)
    }
}

guard let eatingSheet = loadImage(eatingPath) else {
    fatalError("Unable to load corrected eating frames")
}
guard let groomingSheet = loadImage(groomingPath) else {
    fatalError("Unable to load corrected grooming frames")
}
for source in sources {
    guard let atlas = motionAtlas(
        source: source,
        eatingSheet: eatingSheet,
        groomingSheet: groomingSheet
    ) else {
        fatalError("Unable to process \(source.name)")
    }
    for root in outputRoots {
        let path = "\(root)/TaptionCatAtlas\(source.name).imageset/atlas.png"
        try write(atlas, to: path)
    }
}
