import AppKit

// Build an Android adaptive-icon FOREGROUND from the dark AC art: key the bright
// AC unit off the dark background (luminance -> alpha), then center it in the
// 108dp foreground safe zone on transparent. Also writes a navy-composited
// preview so the result can be eyeballed.
// Usage: swift makeforeground.swift <darkSource.png>

let srcPath = CommandLine.arguments[1]
let src = NSImage(contentsOfFile: srcPath)!
let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let rep = NSBitmapImageRep(cgImage: cg)
let w = rep.pixelsWide, h = rep.pixelsHigh

func smoothstep(_ lo: Double, _ hi: Double, _ x: Double) -> Double {
    let t = max(0, min(1, (x - lo) / (hi - lo)))
    return t * t * (3 - 2 * t)
}

// Keyed image: original rgb, alpha from luminance (bright AC kept, dark dropped).
let keyed = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .calibratedRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!

var minX = w, minY = h, maxX = 0, maxY = 0
for y in 0..<h {
    for x in 0..<w {
        let c = rep.colorAt(x: x, y: y)!
        let lum = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        let alpha = smoothstep(0.34, 0.56, lum)
        keyed.setColor(
            NSColor(calibratedRed: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: alpha),
            atX: x, y: y)
        if alpha > 0.15 {
            if x < minX { minX = x }; if x > maxX { maxX = x }
            if y < minY { minY = y }; if y > maxY { maxY = y }
        }
    }
}

let keyedImage = NSImage(size: NSSize(width: w, height: h))
keyedImage.addRepresentation(keyed)

// Crop to the AC bounding box.
let bw = maxX - minX, bh = maxY - minY
let side = max(bw, bh)
let cropX = minX - (side - bw) / 2
let cropY = minY - (side - bh) / 2
print("AC bbox \(bw)x\(bh) at (\(minX),\(minY))")

func drawForeground(on canvas: NSImage, fillFraction: CGFloat) {
    let out = canvas.size.width
    let target = out * fillFraction
    let scale = target / CGFloat(side)
    let drawW = CGFloat(w) * scale, drawH = CGFloat(h) * scale
    // Position so the cropped AC box centers in the canvas.
    let originX = (out - target) / 2 - CGFloat(cropX) * scale
    let originY = (out - target) / 2 - CGFloat(h - cropY - side) * scale
    keyedImage.draw(in: NSRect(x: originX, y: originY, width: drawW, height: drawH))
}

func writePNG(_ image: NSImage, _ path: String) {
    let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: path))
}

// Foreground master at 432 (xxxhdpi), AC ~62% of the layer.
let fg = NSImage(size: NSSize(width: 432, height: 432))
fg.lockFocus()
drawForeground(on: fg, fillFraction: 0.62)
fg.unlockFocus()
writePNG(fg, "/tmp/ac_foreground.png")

// Navy-circle preview to eyeball it.
let preview = NSImage(size: NSSize(width: 432, height: 432))
preview.lockFocus()
NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 432, height: 432)).addClip()
let grad = NSGradient(colors: [
    NSColor(calibratedRed: 0.20, green: 0.23, blue: 0.28, alpha: 1),
    NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.18, alpha: 1),
])!
grad.draw(in: NSRect(x: 0, y: 0, width: 432, height: 432), angle: -90)
drawForeground(on: preview, fillFraction: 0.62)
preview.unlockFocus()
writePNG(preview, "/tmp/android_icon_preview.png")
print("wrote /tmp/ac_foreground.png and /tmp/android_icon_preview.png")
