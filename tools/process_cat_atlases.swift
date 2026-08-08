import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct AtlasSource {
    let name: String
    let path: String
}

let sources = [
    AtlasSource(name: "Calico", path: "/Users/u_mo_c/.codex/generated_images/019fb2fa-4245-7233-84a1-6b4ed90d808b/exec-f87a8a48-ff84-42b5-a90d-9ca9af7c9a4c.png"),
    AtlasSource(name: "White", path: "/Users/u_mo_c/.codex/generated_images/019fb2fa-4245-7233-84a1-6b4ed90d808b/exec-a338eb03-1fd9-4023-aacf-d5183b8153d9.png"),
    AtlasSource(name: "Mackerel", path: "/Users/u_mo_c/.codex/generated_images/019fb2fa-4245-7233-84a1-6b4ed90d808b/exec-5e86e799-508e-445b-a5be-4b4d6bff4605.png"),
    AtlasSource(name: "Black", path: "/Users/u_mo_c/.codex/generated_images/019fb2fa-4245-7233-84a1-6b4ed90d808b/exec-2013eaf2-3229-47cc-92e9-d95babcee57d.png"),
    AtlasSource(name: "Gray", path: "/Users/u_mo_c/.codex/generated_images/019fb2fa-4245-7233-84a1-6b4ed90d808b/exec-fd219466-23dd-4729-b0ea-42eb0940efe3.png"),
    AtlasSource(name: "Cheese", path: "/Users/u_mo_c/.codex/generated_images/019fb2fa-4245-7233-84a1-6b4ed90d808b/exec-93f171ab-d66c-40d8-9d51-c31ea03bf8ba.png"),
    AtlasSource(name: "Cow", path: "/Users/u_mo_c/.codex/generated_images/019fb2fa-4245-7233-84a1-6b4ed90d808b/exec-99d9e6bc-003f-4d3f-8cb5-96f110941533.png")
]

let outputRoots = [
    "/Users/u_mo_c/Documents/taption plan/TaptionPlan/Assets.xcassets",
    "/Users/u_mo_c/Documents/taption plan/TaptionPlanWidget/Assets.xcassets",
    "/Users/u_mo_c/Documents/taption plan/TaptionPlanWatch/Assets.xcassets"
]
let columns = 4
let rows = 3
let cellWidth = 156
let cellHeight = 96

func image(at path: String) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func rgbaPixels(from image: CGImage) -> (pixels: [UInt8], width: Int, height: Int)? {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (pixels, width, height)
}

func transparentImage(from source: CGImage) -> CGImage? {
    guard var decoded = rgbaPixels(from: source) else { return nil }
    let width = decoded.width
    let height = decoded.height
    let count = width * height
    var background = [Bool](repeating: false, count: count)
    var queue = [Int]()
    queue.reserveCapacity(count / 2)

    func isLightNeutral(_ index: Int) -> Bool {
        let offset = index * 4
        let r = Int(decoded.pixels[offset])
        let g = Int(decoded.pixels[offset + 1])
        let b = Int(decoded.pixels[offset + 2])
        return min(r, g, b) > 226 && max(r, g, b) - min(r, g, b) < 18
    }

    func enqueue(_ index: Int) {
        guard !background[index], isLightNeutral(index) else { return }
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

    for index in 0..<count where background[index] {
        decoded.pixels[index * 4 + 3] = 0
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

func normalizedAtlas(from source: CGImage) -> CGImage? {
    guard let transparent = transparentImage(from: source),
          let decoded = rgbaPixels(from: transparent),
          let output = CGContext(
            data: nil,
            width: columns * cellWidth,
            height: rows * cellHeight,
            bitsPerComponent: 8,
            bytesPerRow: columns * cellWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else { return nil }

    output.interpolationQuality = .high
    var labels = [Int](repeating: -1, count: decoded.width * decoded.height)
    var components = [(count: Int, minX: Int, maxX: Int, minY: Int, maxY: Int, sumX: Int64, sumY: Int64)]()
    var queue = [Int]()

    for seed in 0..<labels.count where labels[seed] == -1 && decoded.pixels[seed * 4 + 3] > 12 {
        let label = components.count
        var component = (count: 0, minX: decoded.width, maxX: 0, minY: decoded.height, maxY: 0, sumX: Int64(0), sumY: Int64(0))
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
                y + 1 < decoded.height ? index + decoded.width : -1
            ] where neighbor >= 0 && labels[neighbor] == -1 && decoded.pixels[neighbor * 4 + 3] > 12 {
                labels[neighbor] = label
                queue.append(neighbor)
            }
        }
        components.append(component)
    }

    var groups = [[Int]](repeating: [], count: columns * rows)
    for (index, component) in components.enumerated() where component.count >= 4 {
        let centerX = Int(component.sumX / Int64(component.count))
        let centerY = Int(component.sumY / Int64(component.count))
        let column = min(columns - 1, max(0, centerX * columns / decoded.width))
        let row = min(rows - 1, max(0, centerY * rows / decoded.height))
        groups[row * columns + column].append(index)
    }

    for row in 0..<rows {
        for column in 0..<columns {
            let group = Set(groups[row * columns + column])
            guard !group.isEmpty else { continue }
            let selected = group.map { components[$0] }
            let minX = selected.map(\.minX).min() ?? 0
            let maxX = selected.map(\.maxX).max() ?? 0
            let minY = selected.map(\.minY).min() ?? 0
            let maxY = selected.map(\.maxY).max() ?? 0
            let padding = 4
            let crop = CGRect(
                x: max(0, minX - padding),
                y: max(0, minY - padding),
                width: min(decoded.width - 1, maxX + padding) - max(0, minX - padding) + 1,
                height: min(decoded.height - 1, maxY + padding) - max(0, minY - padding) + 1
            )
            let cropX = Int(crop.minX)
            let cropY = Int(crop.minY)
            let cropWidth = Int(crop.width)
            let cropHeight = Int(crop.height)
            var spritePixels = [UInt8](repeating: 0, count: cropWidth * cropHeight * 4)
            for y in 0..<cropHeight {
                for x in 0..<cropWidth {
                    let sourceIndex = (cropY + y) * decoded.width + cropX + x
                    guard group.contains(labels[sourceIndex]) else { continue }
                    let sourceOffset = sourceIndex * 4
                    let destinationOffset = (y * cropWidth + x) * 4
                    spritePixels[destinationOffset..<(destinationOffset + 4)] = decoded.pixels[sourceOffset..<(sourceOffset + 4)]
                }
            }
            guard let spriteContext = CGContext(
                data: &spritePixels,
                width: cropWidth,
                height: cropHeight,
                bitsPerComponent: 8,
                bytesPerRow: cropWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let sprite = spriteContext.makeImage() else { continue }

            let usableWidth = CGFloat(cellWidth - 8)
            let usableHeight = CGFloat(cellHeight - 6)
            let scale = min(usableWidth / crop.width, usableHeight / crop.height)
            let drawWidth = crop.width * scale
            let drawHeight = crop.height * scale
            let destination = CGRect(
                x: CGFloat(column * cellWidth) + (CGFloat(cellWidth) - drawWidth) / 2,
                y: CGFloat((rows - row - 1) * cellHeight) + (CGFloat(cellHeight) - drawHeight) / 2,
                width: drawWidth,
                height: drawHeight
            )
            output.draw(sprite, in: destination)
        }
    }
    return output.makeImage()
}

func write(_ image: CGImage, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

for source in sources {
    guard let original = image(at: source.path),
          let atlas = normalizedAtlas(from: original) else {
        fatalError("Unable to process \(source.name)")
    }
    for root in outputRoots {
        let directory = "\(root)/TaptionCatAtlas\(source.name).imageset"
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        try write(atlas, to: "\(directory)/atlas.png")
        let contents = """
        {
          "images" : [
            {
              "filename" : "atlas.png",
              "idiom" : "universal",
              "scale" : "1x"
            }
          ],
          "info" : {
            "author" : "xcode",
            "version" : 1
          }
        }
        """
        try contents.write(
            toFile: "\(directory)/Contents.json",
            atomically: true,
            encoding: .utf8
        )
    }
}
