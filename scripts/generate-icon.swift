#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum IconError: Error, CustomStringConvertible {
    case usage
    case context
    case write(String)

    var description: String {
        switch self {
        case .usage:
            return "用法：generate-icon.swift <AppIcon.appiconset> <品牌图标.png> <网站图标.png>"
        case .context:
            return "无法创建图标绘图上下文"
        case .write(let path):
            return "无法写入图标：\(path)"
        }
    }
}

private let canvasSize = 1024

func makeContext(size: Int) throws -> CGContext {
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw IconError.context
    }
    context.interpolationQuality = .high
    return context
}

func roundedRectPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(
        roundedRect: rect,
        cornerWidth: radius,
        cornerHeight: radius,
        transform: nil
    )
}

func renderMaster() throws -> CGImage {
    let context = try makeContext(size: canvasSize)
    let scale = CGFloat(canvasSize)

    // A single, flat field keeps the icon legible at menu, Finder and release sizes.
    context.setFillColor(CGColor(red: 0.125, green: 0.125, blue: 0.118, alpha: 1.0))
    context.addPath(
        roundedRectPath(
            CGRect(x: scale * 0.055, y: scale * 0.055, width: scale * 0.89, height: scale * 0.89),
            radius: scale * 0.205
        )
    )
    context.fillPath()

    // Original tunnel aperture: one uninterrupted white silhouette with a blue void.
    let aperture = CGMutablePath()
    aperture.move(to: CGPoint(x: 276, y: 258))
    aperture.addLine(to: CGPoint(x: 276, y: 500))
    aperture.addCurve(
        to: CGPoint(x: 512, y: 790),
        control1: CGPoint(x: 276, y: 676),
        control2: CGPoint(x: 378, y: 790)
    )
    aperture.addCurve(
        to: CGPoint(x: 748, y: 500),
        control1: CGPoint(x: 646, y: 790),
        control2: CGPoint(x: 748, y: 676)
    )
    aperture.addLine(to: CGPoint(x: 748, y: 258))
    aperture.addLine(to: CGPoint(x: 638, y: 258))
    aperture.addLine(to: CGPoint(x: 638, y: 500))
    aperture.addCurve(
        to: CGPoint(x: 512, y: 642),
        control1: CGPoint(x: 638, y: 586),
        control2: CGPoint(x: 582, y: 642)
    )
    aperture.addCurve(
        to: CGPoint(x: 386, y: 500),
        control1: CGPoint(x: 442, y: 642),
        control2: CGPoint(x: 386, y: 586)
    )
    aperture.addLine(to: CGPoint(x: 386, y: 258))
    aperture.closeSubpath()

    context.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
    context.addPath(aperture)
    context.fillPath()

    guard let image = context.makeImage() else { throw IconError.context }
    return image
}

func render(_ source: CGImage, size: Int) throws -> CGImage {
    let context = try makeContext(size: size)
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    context.draw(source, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let image = context.makeImage() else { throw IconError.context }
    return image
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw IconError.write(url.path)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw IconError.write(url.path)
    }
}

do {
    guard CommandLine.arguments.count == 4 else { throw IconError.usage }

    let appIconDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let brandOutput = URL(fileURLWithPath: CommandLine.arguments[2])
    let websiteOutput = URL(fileURLWithPath: CommandLine.arguments[3])

    try FileManager.default.createDirectory(at: appIconDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: brandOutput.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: websiteOutput.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    let master = try renderMaster()
    let outputs: [(String, Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]

    for (filename, size) in outputs {
        try writePNG(
            try render(master, size: size),
            to: appIconDirectory.appendingPathComponent(filename)
        )
    }
    try writePNG(master, to: brandOutput)
    try writePNG(master, to: websiteOutput)

    print("已生成 \(outputs.count) 个 AppIcon 尺寸与 2 个 1024px 品牌图标")
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
