import AppKit

// Play Store feature graphic: the site's temperature dial beside the name, on the
// launcher icon's blue. Play wants 1024x500 with no alpha.
// Usage: swift makefeaturegraphic.swift

let width = 1024
let height = 500
let blue = NSColor(srgbRed: 0.22, green: 0.45, blue: 0.90, alpha: 1)
let deepBlue = NSColor(srgbRed: 0.13, green: 0.31, blue: 0.74, alpha: 1)

let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

NSGradient(starting: blue, ending: deepBlue)!
    .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -35)

// the dial: a 270° ring open at the bottom, filled to 24° of a 16–30° range
let center = NSPoint(x: 330, y: 250)
let radius: CGFloat = 125
let lineWidth: CGFloat = 20
let fraction: CGFloat = (24 - 16) / (30 - 16)
let startAngle: CGFloat = 225
let endAngle = startAngle - 270 * fraction

func arc(from start: CGFloat, to end: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
    path.lineWidth = lineWidth
    path.lineCapStyle = .round
    return path
}
NSColor(white: 1, alpha: 0.22).setStroke()
arc(from: startAngle, to: startAngle - 270).stroke()
NSColor.white.setStroke()
arc(from: startAngle, to: endAngle).stroke()

let knobAngle = endAngle * .pi / 180
let knobCenter = NSPoint(x: center.x + radius * cos(knobAngle), y: center.y + radius * sin(knobAngle))
let knob = NSBezierPath(ovalIn: NSRect(x: knobCenter.x - 15, y: knobCenter.y - 15, width: 30, height: 30))
NSColor.white.setFill()
knob.fill()
deepBlue.setStroke()
knob.lineWidth = 6
knob.stroke()

func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, at point: NSPoint, centered: Bool = false) {
    let string = NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(white: 1, alpha: alpha),
        .kern: -size * 0.02,
    ])
    let origin = centered ? NSPoint(x: point.x - string.size().width / 2, y: point.y) : point
    string.draw(at: origin)
}
draw("24°", size: 84, weight: .light, alpha: 1, at: NSPoint(x: center.x + 6, y: center.y - 44), centered: true)
draw("COOLING TO", size: 15, weight: .semibold, alpha: 0.8, at: NSPoint(x: center.x, y: center.y + 44), centered: true)

draw("Drift", size: 96, weight: .semibold, alpha: 1, at: NSPoint(x: 520, y: 240))
draw("Your air conditioner,", size: 32, weight: .regular, alpha: 0.88, at: NSPoint(x: 524, y: 196))
draw("over your own Wi-Fi", size: 32, weight: .regular, alpha: 0.88, at: NSPoint(x: 524, y: 156))

let outputPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../app/src/main/play/listings/en-US/graphics/feature-graphic/feature-graphic.png")
    .standardized
let destination = CGImageDestinationCreateWithURL(outputPath as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
CGImageDestinationFinalize(destination)
print("wrote \(outputPath.path)")
