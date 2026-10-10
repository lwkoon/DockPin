// Renders the DockPin app icon (1024x1024 PNG): a screen with a Dock bar held in place by a pin.
import Cocoa

let S: CGFloat = 1024
let out = CommandLine.arguments[1]
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r/255, green: g/255, blue: b/255, alpha: a)
}
func gradient(_ c: [CGColor]) -> CGGradient { CGGradient(colorsSpace: cs, colors: c as CFArray, locations: nil)! }
func rounded(_ r: CGRect, _ rad: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil) }

// Base tile, Apple icon grid: 824pt body centred in 1024, with drop shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = rounded(tile, 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(rgb(30, 40, 90)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(64, 120, 255), rgb(88, 56, 200), rgb(40, 24, 110)]),
                       start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
// Soft highlight in the top-left
ctx.drawRadialGradient(gradient([rgb(255, 255, 255, 0.28), rgb(255, 255, 255, 0)]),
                       startCenter: CGPoint(x: 330, y: 840), startRadius: 0,
                       endCenter: CGPoint(x: 330, y: 840), endRadius: 560, options: [])
ctx.restoreGState()

// Dock bar (frosted glass)
let dock = CGRect(x: 190, y: 210, width: 644, height: 150)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: rgb(0, 0, 30, 0.45))
ctx.addPath(rounded(dock, 48)); ctx.setFillColor(rgb(255, 255, 255, 0.28)); ctx.fillPath()
ctx.restoreGState()
ctx.addPath(rounded(dock.insetBy(dx: 1.5, dy: 1.5), 47))
ctx.setStrokeColor(rgb(255, 255, 255, 0.55)); ctx.setLineWidth(3); ctx.strokePath()

// App tiles in the Dock
let appColors: [(CGColor, CGColor)] = [
    (rgb(255, 196, 64), rgb(255, 140, 30)),
    (rgb(80, 220, 140), rgb(20, 160, 90)),
    (rgb(255, 255, 255), rgb(205, 215, 235)),   // centre slot sits under the pin
    (rgb(90, 200, 255), rgb(30, 130, 230)),
    (rgb(255, 110, 160), rgb(220, 50, 110)),
]
let appSize: CGFloat = 100, gap: CGFloat = 22
let rowW = CGFloat(appColors.count) * appSize + CGFloat(appColors.count - 1) * gap
var x = dock.midX - rowW / 2
for (top, bottom) in appColors {
    let r = CGRect(x: x, y: dock.midY - appSize / 2, width: appSize, height: appSize)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 6, color: rgb(0, 0, 0, 0.25))
    ctx.addPath(rounded(r, 24)); ctx.clip()
    ctx.drawLinearGradient(gradient([top, bottom]), start: CGPoint(x: 0, y: r.maxY), end: CGPoint(x: 0, y: r.minY), options: [])
    ctx.restoreGState()
    x += appSize + gap
}

// Map pin, tip resting on the Dock's centre slot
let tip = CGPoint(x: S / 2, y: dock.midY + 8)
let headC = CGPoint(x: S / 2, y: 650), headR: CGFloat = 150
let ang = asin(headR / (headC.y - tip.y))           // tangent angle from tip to head circle
let p = CGMutablePath()
let a1 = -CGFloat.pi / 2 + (.pi / 2 - ang)          // right tangent point angle
let a2 = -CGFloat.pi / 2 - (.pi / 2 - ang)          // left tangent point angle
p.move(to: tip)
p.addLine(to: CGPoint(x: headC.x + headR * cos(a1), y: headC.y + headR * sin(a1)))
p.addArc(center: headC, radius: headR, startAngle: a1, endAngle: a2 + 2 * .pi, clockwise: false)
p.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 26, color: rgb(20, 0, 30, 0.5))
ctx.addPath(p); ctx.setFillColor(rgb(220, 40, 60)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(p); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(255, 105, 105), rgb(232, 44, 64), rgb(170, 20, 45)]),
                       start: CGPoint(x: headC.x - headR, y: headC.y + headR), end: CGPoint(x: headC.x + headR, y: tip.y), options: [])
ctx.restoreGState()
// Gloss on the head
ctx.saveGState()
ctx.addPath(p); ctx.clip()
ctx.drawRadialGradient(gradient([rgb(255, 255, 255, 0.45), rgb(255, 255, 255, 0)]),
                       startCenter: CGPoint(x: headC.x - 55, y: headC.y + 65), startRadius: 0,
                       endCenter: CGPoint(x: headC.x - 55, y: headC.y + 65), endRadius: 120, options: [])
ctx.restoreGState()
// Centre hole
let hole = CGRect(x: headC.x - 56, y: headC.y - 56, width: 112, height: 112)
ctx.setFillColor(rgb(255, 255, 255)); ctx.fillEllipse(in: hole)
ctx.saveGState()
ctx.addEllipse(in: hole); ctx.clip()
ctx.drawLinearGradient(gradient([rgb(255, 255, 255), rgb(225, 230, 245)]),
                       start: CGPoint(x: 0, y: hole.maxY), end: CGPoint(x: 0, y: hole.minY), options: [])
ctx.restoreGState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
