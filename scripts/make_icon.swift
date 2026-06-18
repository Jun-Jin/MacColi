import AppKit
import CoreGraphics
import CoreText
import Foundation

// MacColi app icon — a white makgeolli PET bottle (tall ribbed cap, neck ring,
// big black label) on a warm amber ground. Pure CoreGraphics + CoreText so it
// renders crisply at every appiconset size.
let args = CommandLine.arguments
let S = args.count > 1 ? Double(args[1]) ?? 1024 : 1024
let out = args.count > 2 ? args[2] : "/tmp/maccoli-icon.png"

func hex(_ s: String, _ a: Double = 1) -> CGColor {
    var h = s; if h.hasPrefix("#") { h.removeFirst() }
    let v = UInt32(h, radix: 16) ?? 0
    return CGColor(srgbRed: Double((v >> 16) & 0xff)/255,
                   green: Double((v >> 8) & 0xff)/255,
                   blue: Double(v & 0xff)/255, alpha: a)
}

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S),
    bitsPerComponent: 8, bytesPerRow: 0, space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high

// Centered text helpers (Core Text; y-up context renders upright).
func line(_ s: String, _ size: Double, _ color: CGColor, _ fontName: String) -> CTLine {
    let font = CTFontCreateWithName(fontName as CFString, size, nil)
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
    return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
}
func width(_ l: CTLine) -> Double {
    var a: CGFloat = 0, d: CGFloat = 0, g: CGFloat = 0
    return Double(CTLineGetTypographicBounds(l, &a, &d, &g))
}
func drawCentered(_ l: CTLine, _ centerX: Double, _ baselineY: Double) {
    ctx.textPosition = CGPoint(x: centerX - width(l)/2, y: baselineY)
    CTLineDraw(l, ctx)
}

let inset = S * 0.092
let rect = CGRect(x: inset, y: inset, width: S - inset*2, height: S - inset*2)
let radius = rect.width * 0.2237
func squircle(_ r: CGRect, _ rad: Double) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
}

// Drop shadow + base fill.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -S*0.012), blur: S*0.03, color: hex("000000", 0.30))
ctx.addPath(squircle(rect, radius)); ctx.setFillColor(hex("E59B3C")); ctx.fillPath()
ctx.restoreGState()

// Warm amber ground (same as before).
ctx.saveGState()
ctx.addPath(squircle(rect, radius)); ctx.clip()
let bg = CGGradient(colorsSpace: cs,
    colors: [hex("F4CE82"), hex("E7A646"), hex("C9762B")] as CFArray,
    locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg,
    start: CGPoint(x: rect.midX, y: rect.maxY),
    end: CGPoint(x: rect.midX, y: rect.minY), options: [])

// ── PET bottle geometry (y up).
let cx = rect.midX
let baseY = rect.minY + rect.height*0.080
let bodyTopY = rect.minY + rect.height*0.500       // long taper starts here (low)
let neckTopY = rect.minY + rect.height*0.790        // top of the taper (under cap)
let bw = rect.width*0.150                            // body half-width (slim)
let nw = rect.width*0.056                            // top half-width
let baseR = rect.width*0.040

let bottle = CGMutablePath()
bottle.move(to: CGPoint(x: cx - bw, y: baseY + baseR))
bottle.addLine(to: CGPoint(x: cx - bw, y: bodyTopY))
// one long, gentle taper from the body up to the neck top
bottle.addCurve(to: CGPoint(x: cx - nw, y: neckTopY),
    control1: CGPoint(x: cx - bw, y: bodyTopY + (neckTopY-bodyTopY)*0.50),
    control2: CGPoint(x: cx - nw, y: neckTopY - (neckTopY-bodyTopY)*0.40))
bottle.addLine(to: CGPoint(x: cx + nw, y: neckTopY))
bottle.addCurve(to: CGPoint(x: cx + bw, y: bodyTopY),
    control1: CGPoint(x: cx + nw, y: neckTopY - (neckTopY-bodyTopY)*0.40),
    control2: CGPoint(x: cx + bw, y: bodyTopY + (neckTopY-bodyTopY)*0.50))
bottle.addLine(to: CGPoint(x: cx + bw, y: baseY + baseR))
bottle.addQuadCurve(to: CGPoint(x: cx + bw - baseR, y: baseY), control: CGPoint(x: cx + bw, y: baseY))
bottle.addLine(to: CGPoint(x: cx - bw + baseR, y: baseY))
bottle.addQuadCurve(to: CGPoint(x: cx - bw, y: baseY + baseR), control: CGPoint(x: cx - bw, y: baseY))
bottle.closeSubpath()

// Drop shadow under the bottle.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -S*0.012), blur: S*0.028, color: hex("5A3410", 0.35))
ctx.addPath(bottle); ctx.setFillColor(hex("FFFFFF")); ctx.fillPath()
ctx.restoreGState()

// White PET body with a cylindrical cross-light + top glow + base flutes + label.
ctx.saveGState()
ctx.addPath(bottle); ctx.clip()
let pet = CGGradient(colorsSpace: cs,
    colors: [hex("D5D5D1"), hex("FFFFFF"), hex("FBFBF9"), hex("EBEBE7"), hex("CDCDC8")] as CFArray,
    locations: [0, 0.26, 0.5, 0.74, 1])!
ctx.drawLinearGradient(pet,
    start: CGPoint(x: cx - bw, y: rect.midY), end: CGPoint(x: cx + bw, y: rect.midY), options: [])
let topGlow = CGGradient(colorsSpace: cs,
    colors: [hex("FFFFFF", 0.55), hex("FFFFFF", 0.0)] as CFArray, locations: [0, 1])!
let glowY = rect.minY + rect.height*0.62
ctx.drawRadialGradient(topGlow,
    startCenter: CGPoint(x: cx - bw*0.35, y: glowY), startRadius: 0,
    endCenter: CGPoint(x: cx - bw*0.35, y: glowY), endRadius: bw*1.6, options: [])
// (grip indentations are drawn later, over the label)

// ── Magenta label with a tone-on-tone fret pattern (clipped to the bottle).
let labelBottomY = rect.minY + rect.height*0.150
let labelTopY = rect.minY + rect.height*0.495
let labelH = labelTopY - labelBottomY
let label = CGRect(x: cx - bw - 2, y: labelBottomY, width: bw*2 + 4, height: labelH)
ctx.saveGState()
ctx.addPath(CGPath(rect: label, transform: nil)); ctx.clip()
let mag = CGGradient(colorsSpace: cs,
    colors: [hex("AC3A82"), hex("972D6E"), hex("7C2257")] as CFArray, locations: [0, 0.5, 1])!
ctx.drawLinearGradient(mag,
    start: CGPoint(x: cx, y: labelTopY), end: CGPoint(x: cx, y: labelBottomY), options: [])
ctx.restoreGState()
// label edge keylines
ctx.setStrokeColor(hex("5E1840", 0.6)); ctx.setLineWidth(S*0.003)
ctx.move(to: CGPoint(x: cx - bw, y: labelTopY)); ctx.addLine(to: CGPoint(x: cx + bw, y: labelTopY))
ctx.move(to: CGPoint(x: cx - bw, y: labelBottomY)); ctx.addLine(to: CGPoint(x: cx + bw, y: labelBottomY))
ctx.strokePath()

// Faint molded grip indentations across the body — 3 at even intervals, with a
// slightly deeper dimple at both edges.
let bodyMidY = (baseY + bodyTopY)/2
for gy in [bodyMidY - rect.height*0.090, bodyMidY, bodyMidY + rect.height*0.090] {
    ctx.setStrokeColor(hex("FFFFFF", 0.13)); ctx.setLineWidth(S*0.004)   // lit lower wall
    ctx.move(to: CGPoint(x: cx - bw, y: gy - S*0.008)); ctx.addLine(to: CGPoint(x: cx + bw, y: gy - S*0.008)); ctx.strokePath()
    ctx.setStrokeColor(hex("000000", 0.13)); ctx.setLineWidth(S*0.006)   // shadowed groove
    ctx.move(to: CGPoint(x: cx - bw, y: gy)); ctx.addLine(to: CGPoint(x: cx + bw, y: gy)); ctx.strokePath()
    ctx.setStrokeColor(hex("000000", 0.22)); ctx.setLineWidth(S*0.007)   // deeper at the edges
    ctx.move(to: CGPoint(x: cx - bw, y: gy)); ctx.addLine(to: CGPoint(x: cx - bw + bw*0.20, y: gy)); ctx.strokePath()
    ctx.move(to: CGPoint(x: cx + bw, y: gy)); ctx.addLine(to: CGPoint(x: cx + bw - bw*0.20, y: gy)); ctx.strokePath()
}

ctx.restoreGState()

// ── Neck support ring (a thin white collar just below the cap).
let ringW = rect.width*0.072
let ringH = rect.height*0.020
let ringRect = CGRect(x: cx - ringW, y: neckTopY - rect.height*0.034, width: ringW*2, height: ringH)
ctx.addPath(CGPath(roundedRect: ringRect, cornerWidth: S*0.006, cornerHeight: S*0.006, transform: nil))
ctx.setFillColor(hex("F2F2EF")); ctx.fillPath()
ctx.addPath(CGPath(roundedRect: ringRect, cornerWidth: S*0.006, cornerHeight: S*0.006, transform: nil))
ctx.setStrokeColor(hex("C2C2BD", 0.8)); ctx.setLineWidth(S*0.003); ctx.strokePath()

// ── Tall ribbed white cap.
let capW = rect.width*0.066
let capBottomY = neckTopY - rect.height*0.006
let capTopY = rect.minY + rect.height*0.852
let cap = CGPath(roundedRect: CGRect(x: cx - capW, y: capBottomY, width: capW*2, height: capTopY - capBottomY),
                 cornerWidth: rect.width*0.014, cornerHeight: rect.width*0.014, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -S*0.006), blur: S*0.012, color: hex("000000", 0.30))
ctx.addPath(cap); ctx.clip()
let capGrad = CGGradient(colorsSpace: cs,
    colors: [hex("DCDCD6"), hex("FBFBF8"), hex("F4F4F0"), hex("CECEC8")] as CFArray, locations: [0, 0.32, 0.6, 1])!
ctx.drawLinearGradient(capGrad,
    start: CGPoint(x: cx - capW, y: capBottomY), end: CGPoint(x: cx + capW, y: capBottomY), options: [])
ctx.setStrokeColor(hex("B0B0AB", 0.55)); ctx.setLineWidth(S*0.0035)
var rx = cx - capW + capW*0.22
while rx < cx + capW { ctx.move(to: CGPoint(x: rx, y: capBottomY)); ctx.addLine(to: CGPoint(x: rx, y: capTopY)); rx += capW*0.22 }
ctx.strokePath()
ctx.setFillColor(hex("FFFFFF", 0.30))
ctx.fill(CGRect(x: cx - capW, y: capBottomY, width: capW*0.42, height: capTopY - capBottomY))
ctx.restoreGState()

ctx.restoreGState()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: out))
print("wrote \(out) @ \(Int(S))px")
