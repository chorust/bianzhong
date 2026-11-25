#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

struct CLIOptions {
    var markPath: String?
    var icnsPath: String?
    var iconPreviewPath: String?
    var dmgBgPath: String?
    var dmgBgPreviewPath: String?
}

func parseArgs() -> CLIOptions {
    var opts = CLIOptions()
    let args = Array(CommandLine.arguments.dropFirst())
    var idx = 0
    while idx < args.count {
        let flag = args[idx]
        func nextValue() -> String {
            guard idx + 1 < args.count else {
                fputs("Missing value for \(flag)\n", stderr)
                exit(2)
            }
            idx += 1
            return args[idx]
        }
        switch flag {
        case "--mark":
            opts.markPath = nextValue()
        case "--icns":
            opts.icnsPath = nextValue()
        case "--icon-preview":
            opts.iconPreviewPath = nextValue()
        case "--dmg-bg":
            opts.dmgBgPath = nextValue()
        case "--dmg-bg-preview":
            opts.dmgBgPreviewPath = nextValue()
        case "--help", "-h":
            print("Usage: generate-installer-assets.swift [--mark <png>] [--icns <icns>] [--icon-preview <png>] [--dmg-bg <tiff>] [--dmg-bg-preview <png>]")
            exit(0)
        default:
            fputs("Unknown argument: \(flag)\n", stderr)
            exit(2)
        }
        idx += 1
    }
    return opts
}

func runTool(_ executable: String, _ arguments: [String]) throws {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: executable)
    proc.arguments = arguments
    let stderrPipe = Pipe()
    proc.standardError = stderrPipe
    try proc.run()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else {
        let errText = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw NSError(
            domain: "BianzhongAssetGen",
            code: Int(proc.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "\(executable) failed (\(proc.terminationStatus)): \(errText)"]
        )
    }
}

func makeRGBABitmapContext(width: Int, height: Int, colorSpace: CGColorSpace) throws -> CGContext {
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "BianzhongAssetGen", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGBitmapContext \(width)x\(height)"])
    }
    return ctx
}

func writePNG(_ cgImage: CGImage, logicalSize: CGSize, to path: String) throws {
    let rep = NSBitmapImageRep(cgImage: cgImage)
    rep.size = logicalSize
    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "BianzhongAssetGen", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG for \(path)"])
    }
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try pngData.write(to: url)
}

func superellipsePath(in rect: CGRect, exponent: Double = 5.0, steps: Int = 360) -> CGPath {
    let path = CGMutablePath()
    let cx = rect.midX
    let cy = rect.midY
    let rx = rect.width / 2.0
    let ry = rect.height / 2.0
    let power = 2.0 / exponent

    for i in 0..<steps {
        let theta = Double(i) * 2.0 * Double.pi / Double(steps)
        let cosT = cos(theta)
        let sinT = sin(theta)
        let px = cx + rx * CGFloat(copysign(pow(abs(cosT), power), cosT))
        let py = cy + ry * CGFloat(copysign(pow(abs(sinT), power), sinT))
        if i == 0 {
            path.move(to: CGPoint(x: px, y: py))
        } else {
            path.addLine(to: CGPoint(x: px, y: py))
        }
    }
    path.closeSubpath()
    return path
}

func smoothstep(edge0: Double, edge1: Double, x: Double) -> Double {
    let t = max(0.0, min(1.0, (x - edge0) / (edge1 - edge0)))
    return t * t * (3.0 - 2.0 * t)
}

/// Converts the black-backed silver Bianzhong mark into a transparent-background metallic glyph.
func loadMaskedBellImage(from markPath: String, colorSpace: CGColorSpace) throws -> CGImage {
    guard let nsImage = NSImage(contentsOfFile: markPath),
          let srcCG = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw NSError(domain: "BianzhongAssetGen", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unable to load mark PNG at \(markPath)"])
    }

    let w = srcCG.width
    let h = srcCG.height
    let ctx = try makeRGBABitmapContext(width: w, height: h, colorSpace: colorSpace)
    ctx.draw(srcCG, in: CGRect(x: 0, y: 0, width: w, height: h))

    guard let rawPtr = ctx.data else {
        throw NSError(domain: "BianzhongAssetGen", code: 4, userInfo: [NSLocalizedDescriptionKey: "Missing pixel buffer"])
    }
    let buf = rawPtr.bindMemory(to: UInt8.self, capacity: w * h * 4)

    for y in 0..<h {
        let v = h > 1 ? Double(y) / Double(h - 1) : 0.0
        // Subtle metallic silver gradient from bright white-silver at top to cool silver below
        let gradR = 1.0 - 0.188 * v   // 1.000 -> 0.812 (#CFC7? -> #CFD7E6)
        let gradG = 1.0 - 0.157 * v   // 1.000 -> 0.843
        let gradB = 1.0 - 0.098 * v   // 1.000 -> 0.902

        for x in 0..<w {
            let i = (y * w + x) * 4
            let r = Double(buf[i]) / 255.0
            let g = Double(buf[i + 1]) / 255.0
            let b = Double(buf[i + 2]) / 255.0
            let lum = max(r, max(g, b))
            let alpha = smoothstep(edge0: 0.05, edge1: 0.80, x: lum)

            buf[i] = UInt8(max(0, min(255, Int((gradR * alpha * 255.0).rounded()))))
            buf[i + 1] = UInt8(max(0, min(255, Int((gradG * alpha * 255.0).rounded()))))
            buf[i + 2] = UInt8(max(0, min(255, Int((gradB * alpha * 255.0).rounded()))))
            buf[i + 3] = UInt8(max(0, min(255, Int((alpha * 255.0).rounded()))))
        }
    }

    guard let masked = ctx.makeImage() else {
        throw NSError(domain: "BianzhongAssetGen", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize masked bell image"])
    }
    return masked
}

func renderMasterIcon(markPath: String, colorSpace: CGColorSpace) throws -> CGImage {
    let size = 1024
    let ctx = try makeRGBABitmapContext(width: size, height: size, colorSpace: colorSpace)
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

    let squircleRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = superellipsePath(in: squircleRect, exponent: 5.0, steps: 360)

    // Outer drop shadow behind squircle
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -12),
        blur: 28,
        color: CGColor(colorSpace: colorSpace, components: [0, 0, 0, 0.30])!
    )
    ctx.setFillColor(CGColor(colorSpace: colorSpace, components: [0.043, 0.051, 0.067, 1.0])!)
    ctx.addPath(squircle)
    ctx.fillPath()
    ctx.restoreGState()

    // Interior clipped to macOS continuous squircle
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    // Base dark slate-obsidian vertical gradient
    let bgColors = [
        CGColor(colorSpace: colorSpace, components: [0.145, 0.160, 0.196, 1.0])!, // #252932 top
        CGColor(colorSpace: colorSpace, components: [0.082, 0.094, 0.118, 1.0])!, // #15181E mid
        CGColor(colorSpace: colorSpace, components: [0.043, 0.051, 0.067, 1.0])!  // #0B0D11 bottom
    ] as CFArray
    if let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 0.52, 1.0]) {
        ctx.drawLinearGradient(
            bgGrad,
            start: CGPoint(x: 512, y: 924),
            end: CGPoint(x: 512, y: 100),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    // Subtle cool metallic top radial glow
    let glowColors = [
        CGColor(colorSpace: colorSpace, components: [0.863, 0.902, 0.973, 0.11])!,
        CGColor(colorSpace: colorSpace, components: [0.863, 0.902, 0.973, 0.0])!
    ] as CFArray
    if let glowGrad = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
        ctx.drawRadialGradient(
            glowGrad,
            startCenter: CGPoint(x: 512, y: 760),
            startRadius: 0,
            endCenter: CGPoint(x: 512, y: 760),
            endRadius: 460,
            options: [.drawsAfterEndLocation]
        )
    }

    // Metallic bell mark with transparent cutouts
    let bellCG = try loadMaskedBellImage(from: markPath, colorSpace: colorSpace)
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -5),
        blur: 12,
        color: CGColor(colorSpace: colorSpace, components: [0, 0, 0, 0.42])!
    )
    ctx.draw(bellCG, in: CGRect(x: 136, y: 132, width: 752, height: 752))
    ctx.restoreGState()

    // Crisp inner specular rim for contrast on dark Finder/Dock surfaces
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.setLineWidth(3.5)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let rimColors = [
        CGColor(colorSpace: colorSpace, components: [1.0, 1.0, 1.0, 0.24])!,
        CGColor(colorSpace: colorSpace, components: [1.0, 1.0, 1.0, 0.05])!
    ] as CFArray
    if let rimGrad = CGGradient(colorsSpace: colorSpace, colors: rimColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(
            rimGrad,
            start: CGPoint(x: 512, y: 924),
            end: CGPoint(x: 512, y: 100),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }
    ctx.restoreGState()

    ctx.restoreGState()

    guard let master = ctx.makeImage() else {
        throw NSError(domain: "BianzhongAssetGen", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to build master 1024x1024 icon"])
    }
    return master
}

func downsampleCGImage(_ source: CGImage, pixelSize: Int, colorSpace: CGColorSpace) throws -> CGImage {
    if source.width == pixelSize && source.height == pixelSize {
        return source
    }
    let ctx = try makeRGBABitmapContext(width: pixelSize, height: pixelSize, colorSpace: colorSpace)
    ctx.interpolationQuality = .high
    ctx.draw(source, in: CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
    guard let scaled = ctx.makeImage() else {
        throw NSError(domain: "BianzhongAssetGen", code: 7, userInfo: [NSLocalizedDescriptionKey: "Failed to downsample icon to \(pixelSize)px"])
    }
    return scaled
}

func buildICNS(masterIcon: CGImage, to icnsPath: String, colorSpace: CGColorSpace) throws {
    let entries: [(name: String, pixels: Int, logical: Int)] = [
        ("icon_16x16.png", 16, 16),
        ("icon_16x16@2x.png", 32, 16),
        ("icon_32x32.png", 32, 32),
        ("icon_32x32@2x.png", 64, 32),
        ("icon_128x128.png", 128, 128),
        ("icon_128x128@2x.png", 256, 128),
        ("icon_256x256.png", 256, 256),
        ("icon_256x256@2x.png", 512, 256),
        ("icon_512x512.png", 512, 512),
        ("icon_512x512@2x.png", 1024, 512)
    ]

    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("bianzhong-iconset-\(UUID().uuidString)", isDirectory: true)
    let iconsetDir = tempRoot.appendingPathComponent("AppIcon.iconset", isDirectory: true)
    try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    for entry in entries {
        let scaled = try downsampleCGImage(masterIcon, pixelSize: entry.pixels, colorSpace: colorSpace)
        let outFile = iconsetDir.appendingPathComponent(entry.name).path
        try writePNG(scaled, logicalSize: CGSize(width: entry.logical, height: entry.logical), to: outFile)
    }

    let outURL = URL(fileURLWithPath: icnsPath)
    try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try runTool("/usr/bin/iconutil", ["-c", "icns", iconsetDir.path, "-o", outURL.path])
}

func drawCenteredText(
    _ text: String,
    font: NSFont,
    color: NSColor,
    in ctx: CGContext,
    centerX: CGFloat,
    centerY: CGFloat
) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color
    ]
    let attrStr = NSAttributedString(string: text, attributes: attrs)
    let size = attrStr.size()
    let origin = CGPoint(x: centerX - size.width / 2.0, y: centerY - size.height / 2.0)
    attrStr.draw(at: origin)
    NSGraphicsContext.restoreGraphicsState()
}

func renderDMGBackground(scale: Int, colorSpace: CGColorSpace) throws -> CGImage {
    let logicalW: CGFloat = 640
    let logicalH: CGFloat = 432
    let pxW = Int(logicalW) * scale
    let pxH = Int(logicalH) * scale
    let ctx = try makeRGBABitmapContext(width: pxW, height: pxH, colorSpace: colorSpace)
    ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

    // Soft light studio surface gradient (#F5F6FA top -> #E6E9F0 bottom)
    let bgColors = [
        CGColor(colorSpace: colorSpace, components: [0.961, 0.965, 0.980, 1.0])!,
        CGColor(colorSpace: colorSpace, components: [0.902, 0.914, 0.941, 1.0])!
    ] as CFArray
    if let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(
            bgGrad,
            start: CGPoint(x: 320, y: 432),
            end: CGPoint(x: 320, y: 0),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    // Subtle top ambient sheen
    let sheenColors = [
        CGColor(colorSpace: colorSpace, components: [1.0, 1.0, 1.0, 0.45])!,
        CGColor(colorSpace: colorSpace, components: [1.0, 1.0, 1.0, 0.0])!
    ] as CFArray
    if let sheenGrad = CGGradient(colorsSpace: colorSpace, colors: sheenColors, locations: [0.0, 1.0]) {
        ctx.drawRadialGradient(
            sheenGrad,
            startCenter: CGPoint(x: 320, y: 390),
            startRadius: 0,
            endCenter: CGPoint(x: 320, y: 390),
            endRadius: 340,
            options: [.drawsAfterEndLocation]
        )
    }

    // Header
    drawCenteredText(
        "Bianzhong",
        font: NSFont.systemFont(ofSize: 20, weight: .semibold),
        color: NSColor(srgbRed: 0.086, green: 0.094, blue: 0.122, alpha: 1.0), // #16181F
        in: ctx,
        centerX: 320,
        centerY: 362
    )
    drawCenteredText(
        "将 Bianzhong 拖入 Applications 文件夹完成安装",
        font: NSFont.systemFont(ofSize: 12.5, weight: .regular),
        color: NSColor(srgbRed: 0.361, green: 0.384, blue: 0.439, alpha: 1.0), // #5C6270
        in: ctx,
        centerX: 320,
        centerY: 336
    )

    // Left card under Bianzhong.app at Finder Iloc (166, 214)
    let leftCard = CGPath(roundedRect: CGRect(x: 88, y: 134, width: 156, height: 168), cornerWidth: 20, cornerHeight: 20, transform: nil)
    ctx.saveGState()
    ctx.setFillColor(CGColor(colorSpace: colorSpace, components: [1.0, 1.0, 1.0, 0.55])!)
    ctx.addPath(leftCard)
    ctx.fillPath()
    ctx.setStrokeColor(CGColor(colorSpace: colorSpace, components: [0.086, 0.094, 0.122, 0.07])!)
    ctx.setLineWidth(1.0)
    ctx.addPath(leftCard)
    ctx.strokePath()
    ctx.restoreGState()

    // Right dashed drop-zone card under Applications at Finder Iloc (474, 214)
    let rightCard = CGPath(roundedRect: CGRect(x: 396, y: 134, width: 156, height: 168), cornerWidth: 20, cornerHeight: 20, transform: nil)
    ctx.saveGState()
    ctx.setFillColor(CGColor(colorSpace: colorSpace, components: [1.0, 1.0, 1.0, 0.72])!)
    ctx.addPath(rightCard)
    ctx.fillPath()
    ctx.setStrokeColor(CGColor(colorSpace: colorSpace, components: [0.086, 0.094, 0.122, 0.18])!)
    ctx.setLineWidth(1.5)
    ctx.setLineDash(phase: 0, lengths: [6, 4])
    ctx.addPath(rightCard)
    ctx.strokePath()
    ctx.restoreGState()

    // Flanking guide dots around center arrow
    ctx.saveGState()
    ctx.setFillColor(CGColor(colorSpace: colorSpace, components: [0.169, 0.188, 0.235, 0.22])!)
    ctx.fillEllipse(in: CGRect(x: 278 - 2.5, y: 232 - 2.5, width: 5, height: 5))
    ctx.fillEllipse(in: CGRect(x: 362 - 2.5, y: 232 - 2.5, width: 5, height: 5))
    ctx.restoreGState()

    // Center circular arrow pill at (320, 232)
    let pillRect = CGRect(x: 298, y: 210, width: 44, height: 44)
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -2),
        blur: 8,
        color: CGColor(colorSpace: colorSpace, components: [0, 0, 0, 0.08])!
    )
    ctx.setFillColor(CGColor(colorSpace: colorSpace, components: [1.0, 1.0, 1.0, 0.88])!)
    ctx.fillEllipse(in: pillRect)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.setStrokeColor(CGColor(colorSpace: colorSpace, components: [0.086, 0.094, 0.122, 0.08])!)
    ctx.setLineWidth(1.0)
    ctx.strokeEllipse(in: pillRect)
    ctx.restoreGState()

    // Arrow path inside pill (#2B303C)
    ctx.saveGState()
    ctx.setStrokeColor(CGColor(colorSpace: colorSpace, components: [0.169, 0.188, 0.235, 1.0])!)
    ctx.setLineWidth(2.4)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 311, y: 232))
    ctx.addLine(to: CGPoint(x: 329, y: 232))
    ctx.move(to: CGPoint(x: 322, y: 239))
    ctx.addLine(to: CGPoint(x: 329, y: 232))
    ctx.addLine(to: CGPoint(x: 322, y: 225))
    ctx.strokePath()
    ctx.restoreGState()

    // Footer hint
    drawCenteredText(
        "首次打开将自动初始化配置并安装 bz 命令行工具",
        font: NSFont.systemFont(ofSize: 11, weight: .regular),
        color: NSColor(srgbRed: 0.478, green: 0.506, blue: 0.569, alpha: 1.0), // #7A8191
        in: ctx,
        centerX: 320,
        centerY: 54
    )

    guard let img = ctx.makeImage() else {
        throw NSError(domain: "BianzhongAssetGen", code: 8, userInfo: [NSLocalizedDescriptionKey: "Failed to render DMG background @\(scale)x"])
    }
    return img
}

func buildDMGBackgroundTIFF(to tiffPath: String, colorSpace: CGColorSpace) throws {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("bianzhong-dmgbg-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let bg1x = try renderDMGBackground(scale: 1, colorSpace: colorSpace)
    let bg2x = try renderDMGBackground(scale: 2, colorSpace: colorSpace)

    let path1x = tempRoot.appendingPathComponent("bg@1x.png").path
    let path2x = tempRoot.appendingPathComponent("bg@2x.png").path
    let logical = CGSize(width: 640, height: 432)

    try writePNG(bg1x, logicalSize: logical, to: path1x)
    try writePNG(bg2x, logicalSize: logical, to: path2x)

    let outURL = URL(fileURLWithPath: tiffPath)
    try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try runTool("/usr/bin/tiffutil", ["-cathidpicheck", path1x, path2x, "-out", outURL.path])
}

do {
    let opts = parseArgs()
    guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else {
        throw NSError(domain: "BianzhongAssetGen", code: 9, userInfo: [NSLocalizedDescriptionKey: "sRGB color space unavailable"])
    }

    if opts.icnsPath != nil || opts.iconPreviewPath != nil {
        guard let markPath = opts.markPath else {
            fputs("--mark <path> is required when generating --icns or --icon-preview\n", stderr)
            exit(2)
        }
        let master = try renderMasterIcon(markPath: markPath, colorSpace: srgb)
        if let icnsPath = opts.icnsPath {
            try buildICNS(masterIcon: master, to: icnsPath, colorSpace: srgb)
        }
        if let previewPath = opts.iconPreviewPath {
            try writePNG(master, logicalSize: CGSize(width: 1024, height: 1024), to: previewPath)
        }
    }

    if let dmgBgPath = opts.dmgBgPath {
        try buildDMGBackgroundTIFF(to: dmgBgPath, colorSpace: srgb)
    }

    if let bgPreviewPath = opts.dmgBgPreviewPath {
        let bg2x = try renderDMGBackground(scale: 2, colorSpace: srgb)
        try writePNG(bg2x, logicalSize: CGSize(width: 1280, height: 864), to: bgPreviewPath)
    }
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
