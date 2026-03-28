import AppKit

let fileManager = FileManager.default
let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let appIconSetURL = root
    .appendingPathComponent("FastMissionControl")
    .appendingPathComponent("Assets.xcassets")
    .appendingPathComponent("AppIcon.appiconset")

let canvasSize = CGSize(width: 1024, height: 1024)
let outputName = "AppIcon-1024.png"
let outputURL = appIconSetURL.appendingPathComponent(outputName)
let masterOutputURL = appIconSetURL.appendingPathComponent("AppIcon-master.png")

let renditions: [(name: String, size: Int)] = [
    ("AppIcon-16.png", 16),
    ("AppIcon-16@2x.png", 32),
    ("AppIcon-32.png", 32),
    ("AppIcon-32@2x.png", 64),
    ("AppIcon-128.png", 128),
    ("AppIcon-128@2x.png", 256),
    ("AppIcon-256.png", 256),
    ("AppIcon-256@2x.png", 512),
    ("AppIcon-512.png", 512),
    ("AppIcon-1024.png", 1024),
]

func makeBackgroundPath(in rect: CGRect) -> NSBezierPath {
    let radius = rect.width * 0.24
    return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func fillBackground(in rect: CGRect) {
    let backgroundPath = makeBackgroundPath(in: rect)
    backgroundPath.addClip()

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.07, green: 0.16, blue: 0.35, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.51, blue: 0.86, alpha: 1),
        NSColor(calibratedRed: 0.36, green: 0.92, blue: 0.92, alpha: 1),
    ])!
    gradient.draw(in: backgroundPath, angle: -48)

    NSGraphicsContext.current?.saveGraphicsState()
    let glow = NSBezierPath(ovalIn: CGRect(x: 76, y: 650, width: 720, height: 260))
    glow.addClip()
    NSColor(calibratedWhite: 1, alpha: 0.12).setFill()
    glow.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGraphicsContext.current?.saveGraphicsState()
    backgroundPath.setClip()
    let lineColor = NSColor(calibratedWhite: 1, alpha: 0.08)
    lineColor.setStroke()
    for index in 0..<14 {
        let path = NSBezierPath()
        path.lineWidth = 10
        let offset = CGFloat(index) * 84 - 260
        path.move(to: CGPoint(x: -40, y: 220 + offset))
        path.line(to: CGPoint(x: 1040, y: 620 + offset))
        path.stroke()
    }
    NSGraphicsContext.current?.restoreGraphicsState()
}

func fillPanelShadow(panelRect: CGRect, cornerRadius: CGFloat) {
    let shadowRect = panelRect.offsetBy(dx: 0, dy: -18)
    let shadowPath = NSBezierPath(roundedRect: shadowRect, xRadius: cornerRadius, yRadius: cornerRadius)
    NSGraphicsContext.current?.saveGraphicsState()
    NSColor(calibratedRed: 0.01, green: 0.05, blue: 0.12, alpha: 0.28).setFill()
    shadowPath.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
}

func fillPanel(at rect: CGRect, cornerRadius: CGFloat, accent: NSColor, alpha: CGFloat = 1) {
    fillPanelShadow(panelRect: rect, cornerRadius: cornerRadius)

    let panelPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    panelPath.addClip()

    let panelGradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.95, green: 0.98, blue: 1, alpha: alpha),
        NSColor(calibratedRed: 0.82, green: 0.91, blue: 1, alpha: alpha),
    ])!
    panelGradient.draw(in: panelPath, angle: -90)

    NSColor(calibratedWhite: 1, alpha: 0.65 * alpha).setFill()
    NSBezierPath(roundedRect: CGRect(x: rect.minX, y: rect.maxY - 36, width: rect.width, height: 36), xRadius: cornerRadius, yRadius: cornerRadius).fill()

    let accentRect = CGRect(x: rect.minX + 22, y: rect.minY + 22, width: rect.width - 44, height: rect.height - 66)
    let accentPath = NSBezierPath(roundedRect: accentRect, xRadius: cornerRadius * 0.55, yRadius: cornerRadius * 0.55)
    accent.withAlphaComponent(0.92 * alpha).setFill()
    accentPath.fill()

    let shine = NSBezierPath(roundedRect: CGRect(x: accentRect.minX, y: accentRect.midY + 12, width: accentRect.width, height: accentRect.height * 0.42), xRadius: cornerRadius * 0.55, yRadius: cornerRadius * 0.55)
    NSColor(calibratedWhite: 1, alpha: 0.13 * alpha).setFill()
    shine.fill()

    NSColor(calibratedWhite: 1, alpha: 0.35 * alpha).setStroke()
    panelPath.lineWidth = 3
    panelPath.stroke()
}

func fillSpeedLines() {
    let lineColor = NSColor(calibratedWhite: 1, alpha: 0.2)
    lineColor.setStroke()
    for (y, width) in [(804.0, 188.0), (760.0, 134.0), (716.0, 88.0)] {
        let path = NSBezierPath()
        path.lineWidth = 18
        path.lineCapStyle = .round
        path.move(to: CGPoint(x: 162, y: y))
        path.line(to: CGPoint(x: 162 + width, y: y))
        path.stroke()
    }
}

func fillFocusRing() {
    let outer = NSBezierPath(roundedRect: CGRect(x: 208, y: 188, width: 608, height: 500), xRadius: 98, yRadius: 98)
    NSColor(calibratedWhite: 1, alpha: 0.18).setStroke()
    outer.lineWidth = 10
    outer.stroke()
}

func drawIcon() {
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: canvasSize).fill()

    fillBackground(in: CGRect(origin: .zero, size: canvasSize))
    fillSpeedLines()
    fillFocusRing()

    fillPanel(
        at: CGRect(x: 238, y: 492, width: 242, height: 184),
        cornerRadius: 40,
        accent: NSColor(calibratedRed: 0.16, green: 0.40, blue: 0.92, alpha: 1)
    )
    fillPanel(
        at: CGRect(x: 544, y: 492, width: 242, height: 184),
        cornerRadius: 40,
        accent: NSColor(calibratedRed: 0.13, green: 0.79, blue: 0.78, alpha: 1)
    )
    fillPanel(
        at: CGRect(x: 238, y: 268, width: 242, height: 184),
        cornerRadius: 40,
        accent: NSColor(calibratedRed: 0.26, green: 0.55, blue: 0.98, alpha: 1),
        alpha: 0.94
    )
    fillPanel(
        at: CGRect(x: 544, y: 268, width: 242, height: 184),
        cornerRadius: 40,
        accent: NSColor(calibratedRed: 0.35, green: 0.91, blue: 0.90, alpha: 1),
        alpha: 0.94
    )

    let centerGlow = NSBezierPath(ovalIn: CGRect(x: 466, y: 434, width: 92, height: 92))
    NSColor(calibratedWhite: 1, alpha: 0.18).setFill()
    centerGlow.fill()
}

func pngData(for image: NSImage, pixelSize: Int) -> Data? {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        return nil
    }

    bitmap.size = CGSize(width: pixelSize, height: pixelSize)

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        NSGraphicsContext.restoreGraphicsState()
        return nil
    }
    NSGraphicsContext.current = context
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize).fill()
    image.draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    return bitmap.representation(using: .png, properties: [:])
}

func runSips(input: URL, output: URL, pixelSize: Int) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    process.arguments = [
        "-z", String(pixelSize), String(pixelSize),
        input.path,
        "--out", output.path,
    ]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? "unknown sips error"
        throw NSError(domain: "AppIconGenerator", code: Int(process.terminationStatus), userInfo: [
            NSLocalizedDescriptionKey: output
        ])
    }
}

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvasSize.width),
    pixelsHigh: Int(canvasSize.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("Failed to create bitmap.\n", stderr)
    exit(1)
}

bitmap.size = canvasSize

NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Failed to create graphics context.\n", stderr)
    exit(1)
}
NSGraphicsContext.current = context
drawIcon()
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let basePNGData = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Failed to render PNG data.\n", stderr)
    exit(1)
}

do {
    try basePNGData.write(to: masterOutputURL)

    for rendition in renditions {
        try runSips(
            input: masterOutputURL,
            output: appIconSetURL.appendingPathComponent(rendition.name),
            pixelSize: rendition.size
        )
    }

    let contentsJSON = """
    {
      "images" : [
        {
          "filename" : "AppIcon-16.png",
          "idiom" : "mac",
          "scale" : "1x",
          "size" : "16x16"
        },
        {
          "filename" : "AppIcon-16@2x.png",
          "idiom" : "mac",
          "scale" : "2x",
          "size" : "16x16"
        },
        {
          "filename" : "AppIcon-32.png",
          "idiom" : "mac",
          "scale" : "1x",
          "size" : "32x32"
        },
        {
          "filename" : "AppIcon-32@2x.png",
          "idiom" : "mac",
          "scale" : "2x",
          "size" : "32x32"
        },
        {
          "filename" : "AppIcon-128.png",
          "idiom" : "mac",
          "scale" : "1x",
          "size" : "128x128"
        },
        {
          "filename" : "AppIcon-128@2x.png",
          "idiom" : "mac",
          "scale" : "2x",
          "size" : "128x128"
        },
        {
          "filename" : "AppIcon-256.png",
          "idiom" : "mac",
          "scale" : "1x",
          "size" : "256x256"
        },
        {
          "filename" : "AppIcon-256@2x.png",
          "idiom" : "mac",
          "scale" : "2x",
          "size" : "256x256"
        },
        {
          "filename" : "AppIcon-512.png",
          "idiom" : "mac",
          "scale" : "1x",
          "size" : "512x512"
        },
        {
          "filename" : "AppIcon-1024.png",
          "idiom" : "mac",
          "scale" : "2x",
          "size" : "512x512"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }
    """
    try contentsJSON.write(
        to: appIconSetURL.appendingPathComponent("Contents.json"),
        atomically: true,
        encoding: .utf8
    )
    let legacyOutputURL = appIconSetURL.appendingPathComponent("AppIcon-512@2x.png")
    if fileManager.fileExists(atPath: legacyOutputURL.path) {
        try? fileManager.removeItem(at: legacyOutputURL)
    }
    try? fileManager.removeItem(at: masterOutputURL)

    print("Wrote app icon assets to \(appIconSetURL.path)")
} catch {
    fputs("Failed to write icon: \(error)\n", stderr)
    exit(1)
}
