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
            return "用法：generate-icon.swift <AppIcon.icon> <品牌图标.png> <网站图标.png>"
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

func aperturePath() -> CGPath {
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
    return aperture
}

func renderMaster(plate: (CGFloat, CGFloat, CGFloat) = (0.125, 0.125, 0.118)) throws -> CGImage {
    let context = try makeContext(size: canvasSize)
    let scale = CGFloat(canvasSize)

    // A single, flat field keeps the icon legible at menu, Finder and release sizes.
    context.setFillColor(CGColor(red: plate.0, green: plate.1, blue: plate.2, alpha: 1.0))
    context.addPath(
        roundedRectPath(
            CGRect(x: scale * 0.055, y: scale * 0.055, width: scale * 0.89, height: scale * 0.89),
            radius: scale * 0.205
        )
    )
    context.fillPath()

    context.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
    context.addPath(aperturePath())
    context.fillPath()

    guard let image = context.makeImage() else { throw IconError.context }
    return image
}

func renderAperture() throws -> CGImage {
    let context = try makeContext(size: canvasSize)
    context.clear(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))
    context.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
    context.addPath(aperturePath())
    context.fillPath()
    guard let image = context.makeImage() else { throw IconError.context }
    return image
}

func writeIconDocument(at directory: URL, aperture: CGImage) throws {
    let assets = directory.appendingPathComponent("Assets", isDirectory: true)
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    try writePNG(aperture, to: assets.appendingPathComponent("aperture.png"))

    let document = """
    {
      "fill-specializations" : [
        {
          "value" : {
            "solid" : "extended-srgb:0.12500,0.12500,0.11800,1.00000"
          }
        },
        {
          "appearance" : "dark",
          "value" : {
            "solid" : "extended-srgb:0.06600,0.06600,0.06200,1.00000"
          }
        }
      ],
      "groups" : [
        {
          "layers" : [
            {
              "fill-specializations" : [
                {
                  "value" : {
                    "solid" : "extended-srgb:1.00000,1.00000,1.00000,1.00000"
                  }
                },
                {
                  "appearance" : "dark",
                  "value" : {
                    "solid" : "extended-srgb:1.00000,1.00000,1.00000,1.00000"
                  }
                },
                {
                  "appearance" : "tinted",
                  "value" : {
                    "solid" : "extended-srgb:1.00000,1.00000,1.00000,1.00000"
                  }
                }
              ],
              "glass" : false,
              "image-name" : "aperture.png",
              "name" : "Aperture"
            }
          ],
          "name" : "Aperture",
          "shadow" : {
            "kind" : "neutral",
            "opacity" : 0.35
          },
          "specular" : true,
          "translucency" : {
            "enabled" : true,
            "value" : 0.15
          }
        }
      ],
      "supported-platforms" : {
        "squares" : [
          "macOS"
        ]
      }
    }
    """
    let jsonURL = directory.appendingPathComponent("icon.json")
    guard let data = document.data(using: .utf8) else { throw IconError.write(jsonURL.path) }
    do {
        try data.write(to: jsonURL, options: .atomic)
    } catch {
        throw IconError.write(jsonURL.path)
    }
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

    let iconDocument = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let brandOutput = URL(fileURLWithPath: CommandLine.arguments[2])
    let websiteOutput = URL(fileURLWithPath: CommandLine.arguments[3])

    try FileManager.default.createDirectory(at: iconDocument, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: brandOutput.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: websiteOutput.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    let master = try renderMaster()
    // Dark pages use #181816. The default plate disappears into that background,
    // so the dark mark sits on a lifted field and keeps the same white aperture.
    let darkMaster = try renderMaster(plate: (0.227, 0.227, 0.216))
    try writeIconDocument(at: iconDocument, aperture: try renderAperture())
    try writePNG(master, to: brandOutput)
    try writePNG(master, to: websiteOutput)
    let darkName = websiteOutput.deletingPathExtension().lastPathComponent + "-dark.png"
    let darkOutput = websiteOutput.deletingLastPathComponent().appendingPathComponent(darkName)
    try writePNG(darkMaster, to: darkOutput)

    print("已生成 1 个分层图标、2 个 1024px 品牌图标与 1 个深色页面图标")
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
