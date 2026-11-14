import AppKit

// Frame raw app screenshots for the stores: each capture goes under (or beside) a caption on
// the brand background, at the exact size the store accepts and with no alpha.
//
// Captures and a captions.txt (one `file.png: caption` line per capture, in store
// order) go in the platform's captures folder; framed images replace the output
// folder's contents, numbered in captions.txt order.
//
//   iphone   apple/store/captures/iphone  →  apple/store/screenshots/iphone   (1206x2622)
//   mac      apple/store/captures/mac     →  apple/store/screenshots/mac      (2880x1800)
//   android  android/store/captures       →  android/app/src/main/play/listings/en-US/graphics/phone-screenshots (1080x1920)
//
// Usage: swift tools/framescreenshots.swift <iphone|mac|android>

struct Platform {
    let captures: String
    let output: String
    let width: Int
    let height: Int
    let top: NSColor
    let bottom: NSColor
}

func srgb(_ hex: Int) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

let platforms: [String: Platform] = [
    "iphone": Platform(
        captures: "apple/store/captures/iphone", output: "apple/store/screenshots/iphone",
        width: 1206, height: 2622, top: srgb(0x2b3140), bottom: srgb(0x14161c)),
    "mac": Platform(
        captures: "apple/store/captures/mac", output: "apple/store/screenshots/mac",
        width: 2880, height: 1800, top: srgb(0x2b3140), bottom: srgb(0x14161c)),
    "android": Platform(
        captures: "android/store/captures",
        output: "android/app/src/main/play/listings/en-US/graphics/phone-screenshots",
        width: 1080, height: 1920, top: srgb(0x3873e6), bottom: srgb(0x214fbd)),
]

guard CommandLine.arguments.count == 2, let platform = platforms[CommandLine.arguments[1]] else {
    print("usage: swift tools/framescreenshots.swift <\(platforms.keys.sorted().joined(separator: "|"))>")
    exit(1)
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let capturesDir = root.appendingPathComponent(platform.captures)
let outputDir = root.appendingPathComponent(platform.output)
let captionsText = try String(contentsOf: capturesDir.appendingPathComponent("captions.txt"), encoding: .utf8)
let entries: [(file: String, caption: String)] = captionsText
    .split(separator: "\n")
    .compactMap { (line: Substring) -> (file: String, caption: String)? in
        let parts = line.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return (
            parts[0].trimmingCharacters(in: .whitespaces),
            parts[1].trimmingCharacters(in: .whitespaces))
    }

let fileManager = FileManager.default
try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)
for old in try fileManager.contentsOfDirectory(atPath: outputDir.path) where old.hasSuffix(".png") {
    try fileManager.removeItem(at: outputDir.appendingPathComponent(old))
}

let width = CGFloat(platform.width)
let height = CGFloat(platform.height)
let landscape = width > height
let margin = (landscape ? height : width) * 0.09
// portrait: the caption takes a band at the top, under the fifth of the image Play
// allows; landscape: it takes the left side, beside the capture
let captionArea = landscape
    ? NSRect(x: margin, y: margin, width: width * 0.42 - margin, height: height - 2 * margin)
    : NSRect(x: margin, y: height * 0.85, width: width - 2 * margin, height: height * 0.15 - margin * 0.4)
let captureArea = landscape
    ? NSRect(x: width * 0.46, y: margin * 0.8, width: width * 0.54 - margin, height: height - 1.6 * margin)
    : NSRect(x: margin, y: margin * 0.6, width: width - 2 * margin, height: height * 0.85 - margin * 0.9)
let fontSize = (landscape ? height * 0.07 : width * 0.058)

for (index, entry) in entries.enumerated() {
    guard let capture = NSImage(contentsOf: capturesDir.appendingPathComponent(entry.file)),
        let rep = capture.representations.first as? NSBitmapImageRep
    else {
        print("can't read \(entry.file)")
        exit(1)
    }
    let context = CGContext(
        data: nil, width: platform.width, height: platform.height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    NSGradient(starting: platform.top, ending: platform.bottom)!
        .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = landscape ? .left : .center
    let caption = NSAttributedString(string: entry.caption, attributes: [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraph,
        .kern: -fontSize * 0.01,
    ])
    let captionBounds = caption.boundingRect(with: captionArea.size, options: [.usesLineFragmentOrigin])
    caption.draw(
        with: NSRect(
            x: captionArea.minX, y: captionArea.midY - captionBounds.height / 2,
            width: captionArea.width, height: captionBounds.height),
        options: [.usesLineFragmentOrigin])

    // the capture fills the rest, keeping its proportions
    let pixelSize = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    let area = captureArea
    let scale = min(area.width / pixelSize.width, area.height / pixelSize.height)
    let size = NSSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
    let frame = NSRect(
        x: area.midX - size.width / 2, y: landscape ? area.midY - size.height / 2 : area.maxY - size.height,
        width: size.width, height: size.height)

    if (rep.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) < 0.5 {
        // a window capture brings its own corners and shadow
        capture.draw(in: frame)
    } else {
        let corners = NSBezierPath(roundedRect: frame, xRadius: size.width * 0.08, yRadius: size.width * 0.08)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
        shadow.shadowBlurRadius = width * 0.03
        shadow.shadowOffset = NSSize(width: 0, height: -width * 0.01)
        shadow.set()
        NSColor.black.setFill()
        corners.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        corners.addClip()
        capture.draw(in: frame)
        NSGraphicsContext.restoreGraphicsState()
    }

    let name = String(format: "%02d.png", index + 1)
    let destination = CGImageDestinationCreateWithURL(
        outputDir.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    print("\(entry.file) → \(platform.output)/\(name)")
}
