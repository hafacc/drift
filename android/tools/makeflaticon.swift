import AppKit

// Flat (Material-style) AC icon foreground: solid shapes, no gradients/shadows.
// Writes the transparent foreground + a preview composited on the flat bg.

let S: CGFloat = 432
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}
func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func drawForeground() {
    // Everything is kept inside the adaptive-icon safe zone (inner ~66%) so a
    // circular mask doesn't clip the unit's top corners.
    // AC body — solid white rounded rectangle.
    let bodyW: CGFloat = 204, bodyH: CGFloat = 84
    let bodyX = (S - bodyW) / 2, bodyY: CGFloat = 204
    color(1, 1, 1).setFill()
    rounded(NSRect(x: bodyX, y: bodyY, width: bodyW, height: bodyH), 22).fill()

    // Vent — flat grey strip near the bottom of the body.
    let ventW = bodyW * 0.80, ventH: CGFloat = 18
    let ventX = bodyX + (bodyW - ventW) / 2, ventY = bodyY + 11
    color(0.74, 0.79, 0.85).setFill()
    rounded(NSRect(x: ventX, y: ventY, width: ventW, height: ventH), 9).fill()

    // Airflow — three flat capsules below the body.
    color(1, 1, 1, 0.9).setFill()
    let capW: CGFloat = 14, capH: CGFloat = 58
    let centers: [CGFloat] = [S / 2 - 56, S / 2, S / 2 + 56]
    for cx in centers {
        rounded(NSRect(x: cx - capW / 2, y: bodyY - 16 - capH, width: capW, height: capH), capW / 2).fill()
    }
}

func writePNG(_ image: NSImage, _ path: String) {
    let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: path))
}

let fg = NSImage(size: NSSize(width: S, height: S))
fg.lockFocus()
drawForeground()
fg.unlockFocus()
writePNG(fg, "/tmp/flat_foreground.png")

// Preview masked to the adaptive-icon safe circle (~66dp of 108dp) to check that
// nothing important is clipped by a circular launcher mask.
let safe: CGFloat = S * 66.0 / 108.0
let preview = NSImage(size: NSSize(width: S, height: S))
preview.lockFocus()
NSBezierPath(ovalIn: NSRect(x: (S - safe) / 2, y: (S - safe) / 2, width: safe, height: safe)).addClip()
color(0.22, 0.45, 0.90).setFill()
NSRect(x: 0, y: 0, width: S, height: S).fill()
drawForeground()
preview.unlockFocus()
writePNG(preview, "/tmp/flat_preview.png")
print("wrote /tmp/flat_foreground.png and /tmp/flat_preview.png")
