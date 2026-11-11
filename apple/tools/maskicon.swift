import AppKit

// Mask a rendered, opaque app-icon image to a transparent squircle.
// Detects the squircle relative to the (solid) corner background color, so it
// works whether the source background is white, black, or anything else.
// Usage: swift maskicon.swift <source.png>  ->  /tmp/drift_icon_masked.png

let srcPath = CommandLine.arguments[1]
let src = NSImage(contentsOfFile: srcPath)!
let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let rep = NSBitmapImageRep(cgImage: cg)
let w = rep.pixelsWide, h = rep.pixelsHigh

let background = rep.colorAt(x: 0, y: 0)!
func differs(_ color: NSColor) -> Bool {
    let d = max(
        abs(color.redComponent - background.redComponent),
        abs(color.greenComponent - background.greenComponent),
        abs(color.blueComponent - background.blueComponent))
    return d > 0.06
}

// Bounding box of pixels that differ from the corner background.
var minX = w, minY = h, maxX = 0, maxY = 0
var x = 0
while x < w {
    var y = 0
    while y < h {
        if let color = rep.colorAt(x: x, y: y), differs(color) {
            if x < minX { minX = x }; if x > maxX { maxX = x }
            if y < minY { minY = y }; if y > maxY { maxY = y }
        }
        y += 2
    }
    x += 2
}
print("background \(background), bbox x[\(minX),\(maxX)] y[\(minY),\(maxY)] in \(w)x\(h)")

// Square squircle box from the left/right/top edges (bottom carries the shadow).
let side = maxX - minX
let box = CGRect(x: minX, y: minY, width: side, height: side)
let cropped = NSImage(cgImage: cg.cropping(to: box)!, size: NSSize(width: side, height: side))

// Compose into a 1024 canvas with transparent padding, clipped to a squircle.
let out: CGFloat = 1024
let fill = out * 0.92
let pad = (out - fill) / 2
let canvas = NSImage(size: NSSize(width: out, height: out))
canvas.lockFocus()
let rect = NSRect(x: pad, y: pad, width: fill, height: fill)
let radius = fill * 0.2237
NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
cropped.draw(in: rect)
canvas.unlockFocus()

let png = NSBitmapImageRep(data: canvas.tiffRepresentation!)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "/tmp/drift_icon_masked.png"))
print("wrote /tmp/drift_icon_masked.png")
