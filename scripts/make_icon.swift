import AppKit
import CoreGraphics
import Foundation

let args = CommandLine.arguments
let S = args.count > 1 ? Double(args[1]) ?? 1024 : 1024
let out = args.count > 2 ? args[2] : "/tmp/maccoli-volcano.png"

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

let inset = S * 0.092
let rect = CGRect(x: inset, y: inset, width: S - inset*2, height: S - inset*2)
let radius = rect.width * 0.2237
func squircle(_ r: CGRect, _ rad: Double) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
}

// Drop shadow + base fill.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -S*0.012), blur: S*0.03, color: hex("000000", 0.30))
ctx.addPath(squircle(rect, radius)); ctx.setFillColor(hex("241A3A")); ctx.fillPath()
ctx.restoreGState()

// Twilight-sky gradient.
ctx.saveGState()
ctx.addPath(squircle(rect, radius)); ctx.clip()
let sky = CGGradient(colorsSpace: cs,
    colors: [hex("2A2350"), hex("3A2A5C"), hex("5A2E55")] as CFArray,
    locations: [0, 0.55, 1])!
ctx.drawLinearGradient(sky,
    start: CGPoint(x: rect.midX, y: rect.maxY),
    end: CGPoint(x: rect.midX, y: rect.minY), options: [])

// Warm glow behind the crater.
let glow = CGGradient(colorsSpace: cs,
    colors: [hex("FF7A3C", 0.55), hex("FF7A3C", 0.0)] as CFArray, locations: [0, 1])!
let craterX = rect.midX
let craterY = rect.minY + rect.height*0.46
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: craterX, y: craterY), startRadius: 0,
    endCenter: CGPoint(x: craterX, y: craterY), endRadius: rect.width*0.42, options: [])

// Volcano silhouette (trapezoid with a notched crater).
let baseY = rect.minY + rect.height*0.18
let peakY = rect.minY + rect.height*0.50
let halfBase = rect.width*0.40
let halfTop = rect.width*0.135
let v = CGMutablePath()
v.move(to: CGPoint(x: craterX - halfBase, y: baseY))
v.addLine(to: CGPoint(x: craterX - halfTop, y: peakY))
// crater dip
v.addLine(to: CGPoint(x: craterX - halfTop*0.45, y: peakY - rect.height*0.028))
v.addLine(to: CGPoint(x: craterX + halfTop*0.45, y: peakY - rect.height*0.028))
v.addLine(to: CGPoint(x: craterX + halfTop, y: peakY))
v.addLine(to: CGPoint(x: craterX + halfBase, y: baseY))
v.closeSubpath()
ctx.addPath(v)
ctx.setFillColor(hex("171026"))
ctx.fillPath()

// Lava crater pool + two streaks down the slope.
ctx.addPath(CGPath(ellipseIn: CGRect(x: craterX - halfTop*0.5, y: peakY - rect.height*0.045,
    width: halfTop, height: rect.height*0.035), transform: nil))
ctx.setFillColor(hex("FFD24A"))
ctx.fillPath()

func streak(_ dir: Double) {
    let p = CGMutablePath()
    let w = rect.width*0.022
    let sx = craterX + dir*halfTop*0.3
    p.move(to: CGPoint(x: sx - w, y: peakY - rect.height*0.02))
    p.addLine(to: CGPoint(x: sx + w, y: peakY - rect.height*0.02))
    p.addLine(to: CGPoint(x: craterX + dir*halfBase*0.62 + w*1.5, y: baseY + rect.height*0.02))
    p.addLine(to: CGPoint(x: craterX + dir*halfBase*0.62 - w*1.5, y: baseY + rect.height*0.02))
    p.closeSubpath()
    ctx.addPath(p)
}
let lava = CGGradient(colorsSpace: cs,
    colors: [hex("FFD24A"), hex("FF6B3D")] as CFArray, locations: [0, 1])!
for d in [-1.0, 1.0] {
    ctx.saveGState(); streak(d); ctx.clip()
    ctx.drawLinearGradient(lava, start: CGPoint(x: craterX, y: peakY),
        end: CGPoint(x: craterX, y: baseY), options: [])
    ctx.restoreGState()
}

// A few stars.
ctx.setFillColor(hex("FFFFFF", 0.85))
for (sx, sy, r) in [(0.26, 0.80, 0.010), (0.74, 0.86, 0.008), (0.82, 0.70, 0.006), (0.20, 0.66, 0.006)] {
    ctx.addPath(CGPath(ellipseIn: CGRect(
        x: rect.minX + rect.width*sx, y: rect.minY + rect.height*sy,
        width: rect.width*r*2, height: rect.width*r*2), transform: nil))
}
ctx.fillPath()
ctx.restoreGState()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: out))
print("wrote \(out) @ \(Int(S))px")
