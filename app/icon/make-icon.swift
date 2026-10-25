// Renders the LOQ Fan Control app icon (1024x1024 PNG).
// Run:  swift make-icon.swift <output.png>
import AppKit
import CoreGraphics

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"

let S: CGFloat = 1024
let center = CGPoint(x: S / 2, y: S / 2)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

func polar(_ r: CGFloat, _ deg: CGFloat) -> CGPoint {
    let a = deg * .pi / 180
    return CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
}

// MARK: - canvas

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("no context")
}
ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)

// MARK: - squircle plate with drop shadow

let inset: CGFloat = 82
let plate = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
let corner: CGFloat = (S - inset * 2) * 0.2237

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 36,
              color: rgb(0x000000, 0.45))
let platePath = CGPath(roundedRect: plate, cornerWidth: corner, cornerHeight: corner, transform: nil)
ctx.addPath(platePath)
ctx.setFillColor(rgb(0x1B2534))
ctx.fillPath()
ctx.restoreGState()

// Background gradient (clip to plate)
ctx.saveGState()
ctx.addPath(platePath)
ctx.clip()
if let bg = CGGradient(colorsSpace: cs, colors: [
    rgb(0x31435E), rgb(0x25344A), rgb(0x0D1522)
] as CFArray, locations: [0.0, 0.45, 1.0]) {
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])
}
// Soft top-left sheen
if let sheen = CGGradient(colorsSpace: cs, colors: [
    rgb(0xFFFFFF, 0.14), rgb(0xFFFFFF, 0.0)
] as CFArray, locations: [0.0, 1.0]) {
    ctx.drawRadialGradient(sheen, startCenter: CGPoint(x: 260, y: S - 220), startRadius: 0,
                           endCenter: CGPoint(x: 260, y: S - 220), endRadius: 640,
                           options: [])
}

// Fan guard ring
ctx.setLineWidth(7)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.10))
ctx.strokeEllipse(in: CGRect(x: center.x - 336, y: center.y - 336, width: 672, height: 672))
ctx.restoreGState()

// MARK: - blades

func bladePath(_ angle: CGFloat) -> CGPath {
    let r0: CGFloat = 96          // hub attach radius (hidden under the hub cap)
    let r1: CGFloat = 304         // tip radius
    let inHalf: CGFloat = 27      // half width at hub (degrees)
    let sweep: CGFloat = 26       // tip swept forward, gives the pinwheel look
    let tipHalf: CGFloat = 13
    let p = CGMutablePath()
    p.move(to: polar(r0, angle - inHalf))
    // trailing edge out to the tip (mirrors the leading edge)
    p.addCurve(to: polar(r1, angle + sweep - tipHalf),
               control1: polar(r0 + 150, angle - inHalf + 6),
               control2: polar(r1 - 120, angle + sweep - tipHalf - 14))
    // rounded tip cap
    p.addCurve(to: polar(r1, angle + sweep + tipHalf),
               control1: polar(r1 + 22, angle + sweep - tipHalf + 5),
               control2: polar(r1 + 22, angle + sweep + tipHalf - 5))
    // leading edge back to the hub
    p.addCurve(to: polar(r0, angle + inHalf),
               control1: polar(r1 - 120, angle + sweep + tipHalf + 14),
               control2: polar(r0 + 150, angle + inHalf - 6))
    p.closeSubpath()
    return p
}

if let bladeGrad = CGGradient(colorsSpace: cs, colors: [
    rgb(0x6FBCFF), rgb(0x2E7BEB), rgb(0x1D4FAE)
] as CFArray, locations: [0.0, 0.55, 1.0]) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0x001A3D, 0.55))
    for base in [CGFloat(45), 135, 225, 315] {
        let path = bladePath(base)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        // Light from top-left regardless of blade rotation
        ctx.drawLinearGradient(bladeGrad,
                               start: CGPoint(x: 0, y: S),
                               end: CGPoint(x: S * 0.85, y: 0),
                               options: [])
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.22))
        ctx.setLineWidth(3)
        ctx.strokePath()
    }
    ctx.restoreGState()
}

// MARK: - hub

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 10, color: rgb(0x000000, 0.35))
if let hubGrad = CGGradient(colorsSpace: cs, colors: [
    rgb(0xF4F9FF), rgb(0xC9DCF3)
] as CFArray, locations: [0.0, 1.0]) {
    ctx.drawRadialGradient(hubGrad,
                           startCenter: CGPoint(x: center.x - 26, y: center.y + 30), startRadius: 6,
                           endCenter: center, endRadius: 118,
                           options: [])
}
ctx.restoreGState()

// Hub inner details: ring + center cap
ctx.setLineWidth(5)
ctx.setStrokeColor(rgb(0x2E4B6E, 0.55))
ctx.strokeEllipse(in: CGRect(x: center.x - 68, y: center.y - 68, width: 136, height: 136))

if let capGrad = CGGradient(colorsSpace: cs, colors: [
    rgb(0x4C9AF0), rgb(0x1C4FB4)
] as CFArray, locations: [0.0, 1.0]) {
    ctx.drawRadialGradient(capGrad,
                           startCenter: CGPoint(x: center.x - 8, y: center.y + 9), startRadius: 2,
                           endCenter: center, endRadius: 40,
                           options: [])
}
ctx.setFillColor(rgb(0xFFFFFF, 0.35))
ctx.fillEllipse(in: CGRect(x: center.x - 14, y: center.y - 14, width: 28, height: 28))

// MARK: - write PNG

guard let img = ctx.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: img)
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("no data") }
try! data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
